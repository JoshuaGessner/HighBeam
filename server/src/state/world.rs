use std::sync::atomic::{AtomicU16, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use dashmap::DashMap;
use tokio::time::Instant;

use super::vehicle::Vehicle;
use crate::net::packet::VehicleInfo;

/// Authoritative game state: all vehicles across all players.
pub struct WorldState {
    /// Key: (player_id, vehicle_id) → Vehicle
    vehicles: DashMap<(u32, u16), Vehicle>,
    next_vehicle_id: AtomicU16,
    /// Serializes the per-player count check + insert in `try_spawn_vehicle` so
    /// concurrent spawns cannot collectively exceed `MaxCarsPerPlayer` (TOCTOU).
    spawn_guard: std::sync::Mutex<()>,
}

impl WorldState {
    pub fn new() -> Self {
        Self {
            vehicles: DashMap::new(),
            next_vehicle_id: AtomicU16::new(1),
            spawn_guard: std::sync::Mutex::new(()),
        }
    }

    pub fn restore_vehicle_snapshot(&self, vehicles: &[VehicleInfo]) {
        self.vehicles.clear();

        let mut max_vehicle_id = 0u16;
        for vehicle in vehicles {
            max_vehicle_id = max_vehicle_id.max(vehicle.vehicle_id);
            let config_revision = serde_json::from_str::<serde_json::Value>(&vehicle.data)
                .ok()
                .and_then(|value| {
                    value
                        .get("configRevision")
                        .and_then(serde_json::Value::as_u64)
                })
                .unwrap_or(0);
            self.vehicles.insert(
                (vehicle.player_id, vehicle.vehicle_id),
                Vehicle {
                    id: vehicle.vehicle_id,
                    owner_id: vehicle.player_id,
                    config: vehicle.data.clone(),
                    position: vehicle.position,
                    rotation: vehicle.rotation,
                    velocity: vehicle.velocity,
                    motion_epoch: None,
                    motion_sequence: 0,
                    damage: vehicle.damage.clone(),
                    electrics: vehicle.electrics.clone(),
                    powertrain: vehicle.powertrain.clone(),
                    damage_epoch: 0,
                    damage_revision: 0,
                    config_revision,
                    last_update: Instant::now(),
                },
            );
        }

        // Advance counter past the highest restored ID.
        // wrapping_add handles u16::MAX; skip 0 since the client treats it as "unassigned".
        let next = max_vehicle_id.wrapping_add(1);
        let next = if next == 0 { 1 } else { next };
        self.next_vehicle_id.store(next, Ordering::Relaxed);
    }

    /// Spawn a new vehicle for the given player. Returns the assigned vehicle_id.
    pub fn spawn_vehicle(&self, owner_id: u32, config: String) -> u16 {
        let mut vid = self.next_vehicle_id.fetch_add(1, Ordering::Relaxed);
        // Vehicle ID 0 is used as "unassigned" by the client — skip it on wrap.
        if vid == 0 {
            vid = self.next_vehicle_id.fetch_add(1, Ordering::Relaxed);
        }
        let now = Instant::now();
        let vehicle = Vehicle {
            id: vid,
            owner_id,
            config,
            position: [0.0; 3],
            rotation: [0.0, 0.0, 0.0, 1.0],
            velocity: [0.0; 3],
            motion_epoch: None,
            motion_sequence: 0,
            damage: None,
            electrics: None,
            powertrain: None,
            damage_epoch: 0,
            damage_revision: 0,
            config_revision: 0,
            last_update: now,
        };
        self.vehicles.insert((owner_id, vid), vehicle);
        tracing::debug!(owner_id, vid, "Vehicle spawned");
        vid
    }

    /// Atomically enforce `max_cars` per player and spawn if there is room.
    /// Returns the new vehicle_id, or `None` if the player is already at the cap.
    ///
    /// The count + insert run under `spawn_guard` so concurrent spawns from the
    /// same player cannot race past the limit (the previous check-then-spawn was
    /// a TOCTOU window).
    pub fn try_spawn_vehicle(&self, owner_id: u32, config: String, max_cars: u32) -> Option<u16> {
        let _guard = self
            .spawn_guard
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if self.vehicle_count_for_player(owner_id) >= max_cars {
            return None;
        }
        Some(self.spawn_vehicle(owner_id, config))
    }

    /// Remove a specific vehicle.
    pub fn remove_vehicle(&self, owner_id: u32, vehicle_id: u16) {
        self.vehicles.remove(&(owner_id, vehicle_id));
        tracing::debug!(owner_id, vehicle_id, "Vehicle removed");
    }

    /// Remove all vehicles belonging to a player. Returns the list of removed vehicle IDs.
    pub fn remove_all_for_player(&self, player_id: u32) -> Vec<u16> {
        let keys: Vec<(u32, u16)> = self
            .vehicles
            .iter()
            .filter(|e| e.value().owner_id == player_id)
            .map(|e| *e.key())
            .collect();

        let mut removed = Vec::with_capacity(keys.len());
        for key in keys {
            if self.vehicles.remove(&key).is_some() {
                removed.push(key.1);
            }
        }
        tracing::debug!(
            player_id,
            count = removed.len(),
            "Removed all vehicles for player"
        );
        removed
    }

    /// Update a vehicle's position data (called from UDP relay path).
    pub fn update_position(
        &self,
        player_id: u32,
        vehicle_id: u16,
        pos: [f32; 3],
        rot: [f32; 4],
        vel: [f32; 3],
    ) {
        if let Some(mut entry) = self.vehicles.get_mut(&(player_id, vehicle_id)) {
            entry.position = pos;
            entry.rotation = rot;
            entry.velocity = vel;
            entry.last_update = Instant::now();
        }
    }

    /// Update a protocol-v3 position only if its motion epoch/sequence is newer
    /// than the last accepted sample. This shared gate orders UDP and TCP
    /// fallback against each other and keeps late-join snapshots current.
    pub fn update_position_ordered(
        &self,
        player_id: u32,
        vehicle_id: u16,
        pos: [f32; 3],
        rot: [f32; 4],
        vel: [f32; 3],
        motion_order: (u32, u32),
    ) -> bool {
        let (epoch, sequence) = motion_order;
        if epoch == 0 {
            return false;
        }
        let Some(mut entry) = self.vehicles.get_mut(&(player_id, vehicle_id)) else {
            return false;
        };
        let accepted = match entry.motion_epoch {
            None => true,
            Some(current) if current == epoch => sequence > entry.motion_sequence,
            Some(current) => {
                let delta = epoch.wrapping_sub(current);
                delta > 0 && delta < (u32::MAX / 2 + 1)
            }
        };
        if !accepted {
            return false;
        }
        entry.motion_epoch = Some(epoch);
        entry.motion_sequence = sequence;
        entry.position = pos;
        entry.rotation = rot;
        entry.velocity = vel;
        entry.last_update = Instant::now();
        true
    }

    /// Update a vehicle's config (from VehicleEdit).
    pub fn update_config(&self, player_id: u32, vehicle_id: u16, config: String) -> bool {
        if let Some(mut entry) = self.vehicles.get_mut(&(player_id, vehicle_id)) {
            // Try to merge delta JSON into existing config (for delta compression).
            // If the incoming config is valid JSON and the stored config is too,
            // merge only the provided keys. Otherwise, full replace.
            if let (Ok(mut stored), Ok(delta)) = (
                serde_json::from_str::<serde_json::Value>(&entry.config),
                serde_json::from_str::<serde_json::Value>(&config),
            ) {
                if let (Some(stored_obj), Some(delta_obj)) =
                    (stored.as_object_mut(), delta.as_object())
                {
                    if delta_obj.contains_key("model") || delta_obj.contains_key("partConfig") {
                        let incoming_revision = delta_obj
                            .get("configRevision")
                            .and_then(serde_json::Value::as_u64)
                            .unwrap_or_else(|| entry.config_revision.saturating_add(1));
                        if incoming_revision != entry.config_revision.saturating_add(1) {
                            tracing::warn!(
                                player_id,
                                vehicle_id,
                                current_revision = entry.config_revision,
                                incoming_revision,
                                "Rejected non-monotonic topology revision"
                            );
                            return false;
                        }
                        entry.config_revision = incoming_revision;
                        entry.damage = None;
                        entry.damage_epoch = delta_obj
                            .get("damageEpoch")
                            .and_then(serde_json::Value::as_u64)
                            .map_or_else(
                                || entry.damage_epoch.saturating_add(1),
                                |epoch| entry.damage_epoch.max(epoch),
                            );
                        entry.damage_revision = 0;
                    }
                    for (k, v) in delta_obj {
                        stored_obj.insert(k.clone(), v.clone());
                    }
                    entry.config = serde_json::to_string(&stored).unwrap_or(config);
                    return true;
                }
            }
            return false;
        }
        false
    }

    /// Update a vehicle's position from a VehicleReset event.
    /// Attempts to parse position/rotation from the JSON data blob.
    pub fn update_reset_position(&self, player_id: u32, vehicle_id: u16, data: &str) {
        if let Some(mut entry) = self.vehicles.get_mut(&(player_id, vehicle_id)) {
            // Reset/repair begins a new pristine damage epoch even if the
            // transform payload is malformed.
            entry.damage = None;
            entry.damage_revision = 0;
            // Best-effort parse of {"pos":[x,y,z],"rot":[x,y,z,w]}
            if let Ok(val) = serde_json::from_str::<serde_json::Value>(data) {
                if let Some(epoch) = val
                    .get("motionEpoch")
                    .and_then(serde_json::Value::as_u64)
                    .and_then(|value| u32::try_from(value).ok())
                    .filter(|value| *value > 0)
                {
                    let is_newer = entry.motion_epoch.is_none_or(|current| {
                        current == epoch || {
                            let delta = epoch.wrapping_sub(current);
                            delta > 0 && delta < (u32::MAX / 2 + 1)
                        }
                    });
                    if is_newer && entry.motion_epoch != Some(epoch) {
                        entry.motion_epoch = Some(epoch);
                        entry.motion_sequence = 0;
                    }
                }
                if let Some(epoch) = val.get("damageEpoch").and_then(serde_json::Value::as_u64) {
                    // Versioned reset epochs come from the authoritative
                    // owner. Duplicate delivery is therefore idempotent.
                    entry.damage_epoch = entry.damage_epoch.max(epoch);
                } else {
                    entry.damage_epoch = entry.damage_epoch.saturating_add(1);
                }
                if let Some(pos) = val.get("pos").and_then(|p| p.as_array()) {
                    if pos.len() >= 3 {
                        if let (Some(x), Some(y), Some(z)) =
                            (pos[0].as_f64(), pos[1].as_f64(), pos[2].as_f64())
                        {
                            entry.position = [x as f32, y as f32, z as f32];
                        }
                    }
                }
                if let Some(rot) = val.get("rot").and_then(|r| r.as_array()) {
                    if rot.len() >= 4 {
                        if let (Some(x), Some(y), Some(z), Some(w)) = (
                            rot[0].as_f64(),
                            rot[1].as_f64(),
                            rot[2].as_f64(),
                            rot[3].as_f64(),
                        ) {
                            entry.rotation = [x as f32, y as f32, z as f32, w as f32];
                        }
                    }
                }
                entry.velocity = [0.0; 3];
                entry.last_update = Instant::now();
            } else {
                entry.damage_epoch = entry.damage_epoch.saturating_add(1);
            }
        }
    }

    /// Retain the owner's latest full damage snapshot for late joiners and
    /// internal puppet respawns. Ownership/size validation happens in TCP.
    pub fn update_damage(
        &self,
        player_id: u32,
        vehicle_id: u16,
        data: String,
        epoch: Option<u64>,
        revision: Option<u64>,
        config_revision: Option<u64>,
    ) -> bool {
        if let Some(mut entry) = self.vehicles.get_mut(&(player_id, vehicle_id)) {
            if config_revision.is_some_and(|revision| revision != entry.config_revision) {
                return false;
            }
            if let (Some(epoch), Some(revision)) = (epoch, revision) {
                if epoch < entry.damage_epoch
                    || (epoch == entry.damage_epoch && revision <= entry.damage_revision)
                {
                    return false;
                }
                entry.damage_epoch = epoch;
                entry.damage_revision = revision;
            } else {
                entry.damage_revision = entry.damage_revision.saturating_add(1);
            }
            entry.damage = Some(data);
            return true;
        }
        false
    }

    pub fn update_electrics(&self, player_id: u32, vehicle_id: u16, data: String) -> bool {
        if let Some(mut entry) = self.vehicles.get_mut(&(player_id, vehicle_id)) {
            entry.electrics = Some(data);
            return true;
        }
        false
    }

    pub fn update_powertrain(&self, player_id: u32, vehicle_id: u16, data: String) -> bool {
        if let Some(mut entry) = self.vehicles.get_mut(&(player_id, vehicle_id)) {
            entry.powertrain = Some(data);
            return true;
        }
        false
    }

    /// Get a snapshot of the entire world for sending to a newly joined player.
    pub fn get_vehicle_snapshot(&self) -> Vec<VehicleInfo> {
        self.vehicles
            .iter()
            .map(|entry| {
                let v = entry.value();
                VehicleInfo {
                    player_id: v.owner_id,
                    vehicle_id: v.id,
                    data: v.config.clone(),
                    position: v.position,
                    rotation: v.rotation,
                    velocity: v.velocity,
                    damage: v.damage.clone(),
                    electrics: v.electrics.clone(),
                    powertrain: v.powertrain.clone(),
                    snapshot_time_ms: Some(
                        SystemTime::now()
                            .duration_since(UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as u64,
                    ),
                }
            })
            .collect()
    }

    /// Check if a vehicle exists and is owned by the given player.
    pub fn is_owner(&self, player_id: u32, vehicle_id: u16) -> bool {
        self.vehicles.contains_key(&(player_id, vehicle_id))
    }
    /// Get the number of vehicles owned by a player.
    pub fn vehicle_count_for_player(&self, player_id: u32) -> u32 {
        self.vehicles
            .iter()
            .filter(|e| e.value().owner_id == player_id)
            .count() as u32
    }

    pub fn vehicle_count(&self) -> usize {
        self.vehicles.len()
    }

    /// Get the centroid position of a player's vehicles (for distance-based LOD).
    /// Returns None if the player has no vehicles.
    pub fn player_centroid(&self, player_id: u32) -> Option<[f32; 3]> {
        let mut sum = [0.0f32; 3];
        let mut count = 0u32;
        for entry in self.vehicles.iter() {
            if entry.value().owner_id == player_id {
                let pos = entry.value().position;
                sum[0] += pos[0];
                sum[1] += pos[1];
                sum[2] += pos[2];
                count += 1;
            }
        }
        if count == 0 {
            return None;
        }
        let c = count as f32;
        Some([sum[0] / c, sum[1] / c, sum[2] / c])
    }

    /// Remove vehicles whose `last_update` is older than `max_age`.
    /// Returns a list of (owner_id, vehicle_id) pairs that were reaped.
    pub fn reap_stale_vehicles(&self, max_age: std::time::Duration) -> Vec<(u32, u16)> {
        let now = Instant::now();
        let stale_keys: Vec<(u32, u16)> = self
            .vehicles
            .iter()
            .filter(|e| now.duration_since(e.value().last_update) > max_age)
            .map(|e| *e.key())
            .collect();

        let mut reaped = Vec::with_capacity(stale_keys.len());
        for key in stale_keys {
            if let Some((k, _v)) = self.vehicles.remove(&key) {
                reaped.push(k);
            }
        }
        if !reaped.is_empty() {
            tracing::warn!(
                count = reaped.len(),
                max_age_sec = max_age.as_secs(),
                "Reaped stale vehicles"
            );
        }
        reaped
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn restore_vehicle_snapshot_rebuilds_world_and_next_id() {
        let world = WorldState::new();
        let snapshot = vec![
            VehicleInfo {
                player_id: 7,
                vehicle_id: 20,
                data: "{\"model\":\"pickup\"}".into(),
                position: [1.0, 2.0, 3.0],
                rotation: [0.0, 0.0, 0.0, 1.0],
                velocity: [0.1, 0.2, 0.3],
                damage: Some("{\"broken\":[4]}".into()),
                electrics: Some("{\"lights_state\":1}".into()),
                powertrain: Some("{\"ignLevel\":2}".into()),
                snapshot_time_ms: Some(1_700_000_000_000),
            },
            VehicleInfo {
                player_id: 8,
                vehicle_id: 31,
                data: "{\"model\":\"sunburst\"}".into(),
                position: [4.0, 5.0, 6.0],
                rotation: [0.0, 0.0, 0.0, 1.0],
                velocity: [0.0, 0.0, 0.0],
                damage: None,
                electrics: None,
                powertrain: None,
                snapshot_time_ms: Some(1_700_000_000_000),
            },
        ];

        world.restore_vehicle_snapshot(&snapshot);
        assert_eq!(world.vehicle_count(), 2);
        assert!(world.is_owner(7, 20));
        assert!(world.is_owner(8, 31));

        let new_vid = world.spawn_vehicle(9, "{}".into());
        assert_eq!(new_vid, 32);
    }

    #[test]
    fn damage_is_retained_for_snapshots_and_cleared_by_reset() {
        let world = WorldState::new();
        let vehicle_id = world.spawn_vehicle(7, "{}".into());
        assert!(world.update_damage(7, vehicle_id, "{\"broken\":[12]}".into(), None, None, None,));

        let snapshot = world.get_vehicle_snapshot();
        assert_eq!(snapshot.len(), 1);
        assert_eq!(snapshot[0].damage.as_deref(), Some("{\"broken\":[12]}"));

        // Damage repair must not depend on successfully parsing reset pose data.
        world.update_reset_position(7, vehicle_id, "malformed");
        let snapshot = world.get_vehicle_snapshot();
        assert_eq!(snapshot[0].damage, None);
    }

    #[test]
    fn replaceable_components_are_retained_for_late_joiners() {
        let world = WorldState::new();
        let vehicle_id = world.spawn_vehicle(7, "{}".into());
        assert!(world.update_electrics(7, vehicle_id, r#"{"transbrake":0}"#.into()));
        assert!(world.update_powertrain(7, vehicle_id, r#"{"hydraulics":{"arm":1.25}}"#.into()));

        let snapshot = world.get_vehicle_snapshot();
        assert_eq!(
            snapshot[0].electrics.as_deref(),
            Some(r#"{"transbrake":0}"#)
        );
        assert_eq!(
            snapshot[0].powertrain.as_deref(),
            Some(r#"{"hydraulics":{"arm":1.25}}"#)
        );
    }

    #[test]
    fn versioned_damage_respects_reset_and_config_barriers() {
        let world = WorldState::new();
        let vehicle_id = world.spawn_vehicle(7, "{}".into());
        assert!(world.update_damage(7, vehicle_id, "first".into(), Some(0), Some(1), Some(0)));
        assert!(!world.update_damage(7, vehicle_id, "duplicate".into(), Some(0), Some(1), Some(0)));

        world.update_reset_position(7, vehicle_id, "malformed");
        assert!(!world.update_damage(7, vehicle_id, "pre-reset".into(), Some(0), Some(2), Some(0)));
        assert!(world.update_damage(
            7,
            vehicle_id,
            "post-reset".into(),
            Some(1),
            Some(1),
            Some(0)
        ));

        assert!(world.update_config(
            7,
            vehicle_id,
            r#"{"partConfig":"new.pc","configRevision":1}"#.into(),
        ));
        assert!(!world.update_config(
            7,
            vehicle_id,
            r#"{"partConfig":"stale.pc","configRevision":1}"#.into(),
        ));
        assert!(!world.update_damage(
            7,
            vehicle_id,
            "old-topology".into(),
            Some(1),
            Some(2),
            Some(0)
        ));
        assert!(world.update_damage(
            7,
            vehicle_id,
            "new-topology".into(),
            Some(2),
            Some(1),
            Some(1)
        ));
    }

    #[test]
    fn duplicate_versioned_reset_is_epoch_idempotent() {
        let world = WorldState::new();
        let vehicle_id = world.spawn_vehicle(9, "{}".into());
        let reset = r#"{"pos":[0,0,0],"rot":[0,0,0,1],"damageEpoch":1}"#;

        world.update_reset_position(9, vehicle_id, reset);
        world.update_reset_position(9, vehicle_id, reset);

        assert!(world.update_damage(
            9,
            vehicle_id,
            "after-duplicate-reset".into(),
            Some(1),
            Some(1),
            Some(0)
        ));
    }

    #[test]
    fn motion_epoch_orders_udp_tcp_and_reset_barriers() {
        let world = WorldState::new();
        let vehicle_id = world.spawn_vehicle(12, "{}".into());
        let rot = [0.0, 0.0, 0.0, 1.0];
        let vel = [0.0; 3];

        assert!(world.update_position_ordered(12, vehicle_id, [1.0, 0.0, 0.0], rot, vel, (7, 1)));
        assert!(!world.update_position_ordered(12, vehicle_id, [2.0, 0.0, 0.0], rot, vel, (7, 1)));
        assert!(!world.update_position_ordered(12, vehicle_id, [3.0, 0.0, 0.0], rot, vel, (6, 99)));
        assert!(world.update_position_ordered(12, vehicle_id, [4.0, 0.0, 0.0], rot, vel, (8, 0)));

        world.update_reset_position(
            12,
            vehicle_id,
            r#"{"pos":[10,0,0],"rot":[0,0,0,1],"time":0,"motionEpoch":9,"damageEpoch":1}"#,
        );
        assert!(!world.update_position_ordered(
            12,
            vehicle_id,
            [5.0, 0.0, 0.0],
            rot,
            vel,
            (8, 100)
        ));
        assert!(world.update_position_ordered(12, vehicle_id, [11.0, 0.0, 0.0], rot, vel, (9, 1)));
        assert_eq!(world.get_vehicle_snapshot()[0].position, [11.0, 0.0, 0.0]);
    }
}
