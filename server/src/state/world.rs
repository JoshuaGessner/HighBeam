use std::sync::atomic::{AtomicU16, Ordering};

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
            entry.config = config;
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
}
