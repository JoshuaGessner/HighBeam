use std::path::Path;
use std::sync::Arc;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use crate::control::ControlPlane;
use crate::net::packet::VehicleInfo;
use crate::session::manager::PlayerAdminSnapshot;
use crate::state::world::WorldState;

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PersistedPlayer {
    player_id: u32,
    name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PersistedState {
    version: u32,
    active_map: String,
    vehicles: Vec<VehicleInfo>,
    players: Vec<PersistedPlayer>,
}

impl PersistedState {
    const VERSION: u32 = 1;
}

pub fn load_state(
    path: &str,
    control: &Arc<ControlPlane>,
    world: &Arc<WorldState>,
) -> Result<bool> {
    let state_path = Path::new(path);
    if !state_path.exists() {
        return Ok(false);
    }

    let raw = std::fs::read_to_string(state_path)
        .with_context(|| format!("Failed reading state file: {}", state_path.display()))?;
    let state: PersistedState = serde_json::from_str(&raw)
        .with_context(|| format!("Failed parsing state file: {}", state_path.display()))?;

    if state.version != PersistedState::VERSION {
        tracing::warn!(
            path = %state_path.display(),
            expected = PersistedState::VERSION,
            actual = state.version,
            "State file version mismatch; skipping load"
        );
        return Ok(false);
    }

    world.restore_vehicle_snapshot(&state.vehicles);
    if let Err(e) = control.set_active_map(state.active_map.clone()) {
        tracing::warn!(error = %e, "Failed to restore active map from state file");
    }

    tracing::info!(
        path = %state_path.display(),
        vehicles = state.vehicles.len(),
        players = state.players.len(),
        "State restored"
    );

    Ok(true)
}

pub fn save_state(path: &str, control: &Arc<ControlPlane>, world: &Arc<WorldState>) -> Result<()> {
    let state_path = Path::new(path);

    if let Some(parent) = state_path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent).with_context(|| {
                format!("Failed creating state directory: {}", parent.display())
            })?;
        }
    }

    let players = control
        .get_player_admin_snapshot()
        .into_iter()
        .map(|p: PlayerAdminSnapshot| PersistedPlayer {
            player_id: p.player_id,
            name: p.name,
        })
        .collect();

    let state = PersistedState {
        version: PersistedState::VERSION,
        active_map: control.get_active_map(),
        vehicles: world.get_vehicle_snapshot(),
        players,
    };

    let serialized = serde_json::to_string_pretty(&state).context("Failed serializing state")?;
    std::fs::write(state_path, serialized)
        .with_context(|| format!("Failed writing state file: {}", state_path.display()))?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::config::ServerConfig;
    use crate::session::manager::SessionManager;

    #[test]
    fn save_and_load_round_trip_restores_world_and_map() {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let path = std::env::temp_dir().join(format!("highbeam_state_test_{unique}.json"));
        let path_str = path.to_string_lossy().to_string();

        let config = Arc::new(ServerConfig::default());
        let sessions = Arc::new(SessionManager::new());
        let world = Arc::new(WorldState::new());
        let control = Arc::new(ControlPlane::new(config, sessions, world.clone(), None));

        control
            .set_active_map("/levels/west_coast_usa/info.json".into())
            .expect("set map should succeed");
        world.spawn_vehicle(1, "{\"model\":\"pickup\"}".into());

        save_state(&path_str, &control, &world).expect("save should succeed");

        control
            .set_active_map("/levels/gridmap_v2/info.json".into())
            .expect("set map should succeed");
        world.restore_vehicle_snapshot(&[]);

        let loaded = load_state(&path_str, &control, &world).expect("load should succeed");
        assert!(loaded);
        assert_eq!(control.get_active_map(), "/levels/west_coast_usa/info.json");
        assert_eq!(world.vehicle_count(), 1);

        let _ = std::fs::remove_file(path);
    }
}
