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
}

impl WorldState {
    pub fn new() -> Self {
        Self {
            vehicles: DashMap::new(),
            next_vehicle_id: AtomicU16::new(1),
        }
    }

    pub fn restore_vehicle_snapshot(&self, vehicles: &[VehicleInfo]) {
        self.vehicles.clear();

        let mut max_vehicle_id = 0u16;
        for vehicle in vehicles {
            max_vehicle_id = max_vehicle_id.max(vehicle.vehicle_id);
            self.vehicles.insert(
                (vehicle.player_id, vehicle.vehicle_id),
                Vehicle {
                    id: vehicle.vehicle_id,
                    owner_id: vehicle.player_id,
                    config: vehicle.data.clone(),
                    position: vehicle.position,
                    rotation: vehicle.rotation,
                    velocity: vehicle.velocity,
                    last_update: Instant::now(),
                },
            );
        }

        self.next_vehicle_id
            .store(max_vehicle_id.saturating_add(1), Ordering::Relaxed);
    }

    /// Spawn a new vehicle for the given player. Returns the assigned vehicle_id.
    pub fn spawn_vehicle(&self, owner_id: u32, config: String) -> u16 {
        let vid = self.next_vehicle_id.fetch_add(1, Ordering::Relaxed);
        let now = Instant::now();
        let vehicle = Vehicle {
            id: vid,
            owner_id,
            config,
            position: [0.0; 3],
            rotation: [0.0, 0.0, 0.0, 1.0],
            velocity: [0.0; 3],
            last_update: now,
        };
        self.vehicles.insert((owner_id, vid), vehicle);
        tracing::debug!(owner_id, vid, "Vehicle spawned");
        vid
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

    /// Update a vehicle's config (from VehicleEdit).
    pub fn update_config(&self, player_id: u32, vehicle_id: u16, config: String) {
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
                    for (k, v) in delta_obj {
                        stored_obj.insert(k.clone(), v.clone());
                    }
                    entry.config = serde_json::to_string(&stored).unwrap_or(config);
                    return;
                }
            }
            entry.config = config;
        }
    }

    /// Update a vehicle's position from a VehicleReset event.
    /// Attempts to parse position/rotation from the JSON data blob.
    pub fn update_reset_position(&self, player_id: u32, vehicle_id: u16, data: &str) {
        if let Some(mut entry) = self.vehicles.get_mut(&(player_id, vehicle_id)) {
            // Best-effort parse of {"pos":[x,y,z],"rot":[x,y,z,w]}
            if let Ok(val) = serde_json::from_str::<serde_json::Value>(data) {
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
            }
        }
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
                snapshot_time_ms: Some(1_700_000_000_000),
            },
            VehicleInfo {
                player_id: 8,
                vehicle_id: 31,
                data: "{\"model\":\"sunburst\"}".into(),
                position: [4.0, 5.0, 6.0],
                rotation: [0.0, 0.0, 0.0, 1.0],
                velocity: [0.0, 0.0, 0.0],
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
}
