use std::sync::Arc;
use std::sync::RwLock;
use std::time::Instant;

use anyhow::{bail, Context, Result};

use crate::config::ServerConfig;
use crate::net::packet::TcpPacket;
use crate::plugin::runtime::PluginRuntime;
use crate::session::manager::{PlayerAdminSnapshot, SessionManager};
use crate::state::world::WorldState;

#[derive(Debug, Clone)]
pub struct ServerSnapshot {
    pub server_name: String,
    pub map: String,
    pub port: u16,
    pub max_players: u32,
    pub player_count: usize,
    pub vehicle_count: usize,
    pub plugin_count: usize,
    pub uptime_secs: u64,
}

#[derive(Debug, Clone)]
pub enum AdminCommand {
    GetSnapshot,
    BroadcastServerMessage { text: String },
    KickPlayer { player_id: u32, reason: String },
    ReloadPlugins,
    SetActiveMap { map: String },
}

#[derive(Debug, Clone)]
pub enum AdminCommandResult {
    Snapshot(ServerSnapshot),
    Broadcasted { recipients: usize },
    Kicked { player_id: u32, delivered: bool },
    PluginsReloaded { count: usize },
    MapUpdated { map: String },
}

#[derive(Debug, Clone)]
pub struct ClientModEntry {
    pub name: String,
    pub size_bytes: u64,
}

#[derive(Debug, Clone)]
pub struct MapEntry {
    pub map_path: String,
}

pub struct ControlPlane {
    config: Arc<ServerConfig>,
    sessions: Arc<SessionManager>,
    world: Arc<WorldState>,
    plugins: Option<Arc<PluginRuntime>>,
    current_map: RwLock<String>,
    started_at: Instant,
}

impl ControlPlane {
    pub fn new(
        config: Arc<ServerConfig>,
        sessions: Arc<SessionManager>,
        world: Arc<WorldState>,
        plugins: Option<Arc<PluginRuntime>>,
    ) -> Self {
        let initial_map = config.general.map.clone();
        Self {
            config,
            sessions,
            world,
            plugins,
            current_map: RwLock::new(initial_map),
            started_at: Instant::now(),
        }
    }

    pub fn snapshot(&self) -> ServerSnapshot {
        let map = self
            .current_map
            .read()
            .map(|m| m.clone())
            .unwrap_or_else(|_| self.config.general.map.clone());
        ServerSnapshot {
            server_name: self.config.general.name.clone(),
            map,
            port: self.config.general.port,
            max_players: self.config.general.max_players,
            player_count: self.sessions.player_count(),
            vehicle_count: self.world.vehicle_count(),
            plugin_count: self.plugins.as_ref().map_or(0, |p| p.plugin_count()),
            uptime_secs: self.started_at.elapsed().as_secs(),
        }
    }

    pub fn execute_admin_command(&self, command: AdminCommand) -> Result<AdminCommandResult> {
        match command {
            AdminCommand::GetSnapshot => Ok(AdminCommandResult::Snapshot(self.snapshot())),
            AdminCommand::BroadcastServerMessage { text } => {
                let recipients = self.sessions.player_count();
                self.sessions
                    .broadcast(TcpPacket::ServerMessage { text }, None);
                Ok(AdminCommandResult::Broadcasted { recipients })
            }
            AdminCommand::KickPlayer { player_id, reason } => {
                let delivered = self
                    .sessions
                    .send_to_player(player_id, TcpPacket::Kick { reason });
                Ok(AdminCommandResult::Kicked {
                    player_id,
                    delivered,
                })
            }
            AdminCommand::ReloadPlugins => {
                let Some(plugins) = &self.plugins else {
                    bail!("Plugin runtime unavailable")
                };
                plugins.reload()?;
                Ok(AdminCommandResult::PluginsReloaded {
                    count: plugins.plugin_count(),
                })
            }
            AdminCommand::SetActiveMap { map } => {
                self.set_active_map(map.clone())?;
                Ok(AdminCommandResult::MapUpdated { map })
            }
        }
    }

    pub fn get_active_map(&self) -> String {
        self.current_map
            .read()
            .map(|m| m.clone())
            .unwrap_or_else(|_| self.config.general.map.clone())
    }

    pub fn set_active_map(&self, map: String) -> Result<()> {
        let trimmed = map.trim();
        if trimmed.is_empty() {
            bail!("Map path cannot be empty")
        }
        let mut guard = self
            .current_map
            .write()
            .map_err(|_| anyhow::anyhow!("Map state lock poisoned"))?;
        *guard = trimmed.to_string();
        Ok(())
    }

    pub fn get_player_admin_snapshot(&self) -> Vec<PlayerAdminSnapshot> {
        self.sessions.get_player_admin_snapshot()
    }

    pub fn plugin_names(&self) -> Vec<String> {
        self.plugins
            .as_ref()
            .map(|p| p.plugin_names())
            .unwrap_or_default()
    }

    pub fn list_client_mods(&self) -> Result<Vec<ClientModEntry>> {
        let mods_dir = std::path::Path::new(&self.config.general.resource_folder).join("Client");
        if !mods_dir.exists() {
            return Ok(Vec::new());
        }

        let mut entries = Vec::new();
        for entry in std::fs::read_dir(&mods_dir)
            .with_context(|| format!("Failed to read mods folder: {}", mods_dir.display()))?
        {
            let entry = entry?;
            let path = entry.path();
            if !path.is_file() {
                continue;
            }
            let Some(name) = path.file_name().and_then(|s| s.to_str()) else {
                continue;
            };
            let meta = std::fs::metadata(&path)?;
            entries.push(ClientModEntry {
                name: name.to_string(),
                size_bytes: meta.len(),
            });
        }

        entries.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(entries)
    }

    pub fn list_available_maps(&self) -> Result<Vec<MapEntry>> {
        let mut map_set = std::collections::BTreeSet::new();
        map_set.insert(self.get_active_map());

        let maps_dir = std::path::Path::new(&self.config.general.resource_folder).join("Maps");
        if !maps_dir.exists() {
            return Ok(map_set
                .into_iter()
                .map(|map_path| MapEntry { map_path })
                .collect());
        }

        for info_path in discover_map_info_files(&maps_dir)? {
            let Ok(relative_info_path) = info_path.strip_prefix(&maps_dir) else {
                continue;
            };
            let Some(level_dir) = relative_info_path.parent() else {
                continue;
            };

            let level = level_dir.to_string_lossy().replace('\\', "/");
            if level.is_empty() {
                continue;
            }

            map_set.insert(format!("/levels/{level}/info.json"));
        }

        Ok(map_set
            .into_iter()
            .map(|map_path| MapEntry { map_path })
            .collect())
    }

    pub fn add_client_mod_from_path(&self, source_path: &str) -> Result<String> {
        let source = std::path::Path::new(source_path);
        if !source.exists() || !source.is_file() {
            bail!("Source file does not exist: {}", source.display())
        }

        let mods_dir = std::path::Path::new(&self.config.general.resource_folder).join("Client");
        std::fs::create_dir_all(&mods_dir)
            .with_context(|| format!("Failed to create mods folder: {}", mods_dir.display()))?;

        let file_name = source
            .file_name()
            .and_then(|s| s.to_str())
            .ok_or_else(|| anyhow::anyhow!("Invalid source file name"))?
            .to_string();

        let target = mods_dir.join(&file_name);
        std::fs::copy(source, &target).with_context(|| {
            format!(
                "Failed to copy mod from {} to {}",
                source.display(),
                target.display()
            )
        })?;

        Ok(file_name)
    }

    pub fn remove_client_mod(&self, file_name: &str) -> Result<()> {
        let sanitized = file_name.trim();
        if sanitized.is_empty() || sanitized.contains("/") || sanitized.contains("\\") {
            bail!("Invalid mod filename")
        }

        let path = std::path::Path::new(&self.config.general.resource_folder)
            .join("Client")
            .join(sanitized);
        if !path.exists() {
            bail!("Mod file not found: {}", sanitized)
        }

        std::fs::remove_file(&path)
            .with_context(|| format!("Failed to remove mod file: {}", path.display()))?;
        Ok(())
    }

    pub fn eval_in_plugin(&self, plugin_name: &str, code: &str) -> Result<String> {
        let Some(plugins) = &self.plugins else {
            bail!("Plugin runtime unavailable")
        };
        plugins.eval_in_plugin(plugin_name, code)
    }

    pub fn execute_console_line(&self, line: &str) -> Result<String> {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            return Ok(String::new());
        }

        if trimmed == "status" {
            let snap = self.snapshot();
            return Ok(format!(
                "{}:{} players={}/{} vehicles={} plugins={} uptime={}s map={} ",
                snap.server_name,
                snap.port,
                snap.player_count,
                snap.max_players,
                snap.vehicle_count,
                snap.plugin_count,
                snap.uptime_secs,
                snap.map
            ));
        }

        if let Some(rest) = trimmed.strip_prefix("say ") {
            let text = rest.trim();
            if text.is_empty() {
                bail!("Usage: say <text>");
            }
            let result = self.execute_admin_command(AdminCommand::BroadcastServerMessage {
                text: text.to_string(),
            })?;
            if let AdminCommandResult::Broadcasted { recipients } = result {
                return Ok(format!("Sent server message to {} players", recipients));
            }
        }

        if let Some(rest) = trimmed.strip_prefix("kick ") {
            let mut parts = rest.splitn(2, ' ');
            let Some(id_raw) = parts.next() else {
                bail!("Usage: kick <player_id> [reason]");
            };
            let player_id: u32 = id_raw
                .parse()
                .map_err(|_| anyhow::anyhow!("Invalid player_id: {id_raw}"))?;
            let reason = parts
                .next()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .unwrap_or("Kicked by admin")
                .to_string();

            let result =
                self.execute_admin_command(AdminCommand::KickPlayer { player_id, reason })?;
            if let AdminCommandResult::Kicked {
                player_id,
                delivered,
            } = result
            {
                return Ok(format!(
                    "Kick sent to player {} (delivered={})",
                    player_id, delivered
                ));
            }
        }

        if trimmed == "plugins reload" {
            let result = self.execute_admin_command(AdminCommand::ReloadPlugins)?;
            if let AdminCommandResult::PluginsReloaded { count } = result {
                return Ok(format!("Plugins reloaded (count={})", count));
            }
        }

        if let Some(rest) = trimmed.strip_prefix("map ") {
            let map = rest.trim();
            if map.is_empty() {
                bail!("Usage: map <beamng_map_path>");
            }
            let result = self.execute_admin_command(AdminCommand::SetActiveMap {
                map: map.to_string(),
            })?;
            if let AdminCommandResult::MapUpdated { map } = result {
                return Ok(format!("Active map updated to {}", map));
            }
        }

        if let Some(rest) = trimmed.strip_prefix("lua ") {
            let mut parts = rest.splitn(2, ' ');
            let Some(plugin_name) = parts.next() else {
                bail!("Usage: lua <plugin_name> <code>");
            };
            let Some(code) = parts.next() else {
                bail!("Usage: lua <plugin_name> <code>");
            };

            let result = self.eval_in_plugin(plugin_name, code)?;
            return Ok(format!("Lua eval ok: {}", result));
        }

        Ok("Commands: status | say <text> | kick <player_id> [reason] | plugins reload | map <path> | lua <plugin_name> <code>".to_string())
    }
}

fn discover_map_info_files(base_dir: &std::path::Path) -> Result<Vec<std::path::PathBuf>> {
    let mut found = Vec::new();
    let mut stack = vec![base_dir.to_path_buf()];

    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir)
            .with_context(|| format!("Failed to read maps directory: {}", dir.display()))?
        {
            let entry = entry?;
            let path = entry.path();

            if path.is_dir() {
                stack.push(path);
                continue;
            }

            if path
                .file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|name| name.eq_ignore_ascii_case("info.json"))
            {
                found.push(path);
            }
        }
    }

    Ok(found)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn test_snapshot_defaults() {
        let config = Arc::new(ServerConfig::default());
        let sessions = Arc::new(SessionManager::new());
        let world = Arc::new(WorldState::new());
        let control = ControlPlane::new(config, sessions, world, None);

        let snapshot = control.snapshot();
        assert_eq!(snapshot.player_count, 0);
        assert_eq!(snapshot.vehicle_count, 0);
        assert_eq!(snapshot.plugin_count, 0);
        assert!(snapshot.max_players > 0);
    }

    #[test]
    fn test_console_help_for_unknown_command() {
        let config = Arc::new(ServerConfig::default());
        let sessions = Arc::new(SessionManager::new());
        let world = Arc::new(WorldState::new());
        let control = ControlPlane::new(config, sessions, world, None);

        let output = control
            .execute_console_line("unknown_cmd")
            .expect("should return help");
        assert!(output.contains("Commands:"));
    }

    #[test]
    fn test_list_available_maps_discovers_resource_maps() {
        let temp = tempfile::tempdir().expect("tempdir should be created");
        let resource_dir = temp.path().join("Resources");
        let maps_dir = resource_dir.join("Maps");

        let map_a = maps_dir.join("gridmap_v2");
        let map_b = maps_dir.join("west_coast_usa");
        std::fs::create_dir_all(&map_a).expect("gridmap directory should be created");
        std::fs::create_dir_all(&map_b).expect("west coast directory should be created");

        let mut file_a = std::fs::File::create(map_a.join("info.json")).expect("create info");
        file_a.write_all(b"{}").expect("write info");
        let mut file_b = std::fs::File::create(map_b.join("info.json")).expect("create info");
        file_b.write_all(b"{}").expect("write info");

        let mut cfg = ServerConfig::default();
        cfg.general.resource_folder = resource_dir.to_string_lossy().to_string();
        cfg.general.map = "/levels/italy/info.json".to_string();

        let control = ControlPlane::new(
            Arc::new(cfg),
            Arc::new(SessionManager::new()),
            Arc::new(WorldState::new()),
            None,
        );

        let maps = control
            .list_available_maps()
            .expect("map discovery should succeed");
        let map_paths: Vec<String> = maps.into_iter().map(|m| m.map_path).collect();

        assert!(map_paths.contains(&"/levels/gridmap_v2/info.json".to_string()));
        assert!(map_paths.contains(&"/levels/west_coast_usa/info.json".to_string()));
        assert!(map_paths.contains(&"/levels/italy/info.json".to_string()));
    }
}
