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
    pub map_path: String,
    pub map_display_name: String,
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
    pub display_name: String,
    pub source: String,
}

pub struct ControlPlane {
    config: Arc<ServerConfig>,
    sessions: Arc<SessionManager>,
    world: Arc<WorldState>,
    plugins: Option<Arc<PluginRuntime>>,
    current_map: RwLock<String>,
    started_at: Instant,
    community_node: RwLock<Option<Arc<crate::community_node::CommunityNodeState>>>,
    mod_sync_state: RwLock<Option<Arc<crate::mod_sync_state::ModSyncState>>>,
}

fn canonical_map_path(input: &str, fallback: &str) -> String {
    let trimmed = input.trim().replace('\\', "/");
    if trimmed.is_empty() {
        return fallback.to_string();
    }

    let mut level = if let Some(rest) = trimmed.strip_prefix("/levels/") {
        rest.strip_suffix("/info.json").unwrap_or(rest).to_string()
    } else if let Some(rest) = trimmed.strip_prefix("levels/") {
        rest.strip_suffix("/info.json").unwrap_or(rest).to_string()
    } else {
        trimmed
    };

    // Guard legacy aliases that show up in stale state/config and break map loading.
    let level_lower = level.to_lowercase();
    if level_lower == "gridmap" {
        level = "gridmap_v2".to_string();
    } else if level_lower == "orv" {
        let fallback_level = fallback
            .trim()
            .replace('\\', "/")
            .trim_start_matches("/levels/")
            .trim_start_matches("levels/")
            .trim_end_matches("/info.json")
            .to_string();
        level = if fallback_level.is_empty() {
            "gridmap_v2".to_string()
        } else {
            fallback_level
        };
    }

    if level.is_empty() {
        return fallback.to_string();
    }

    format!("/levels/{level}/info.json")
}

fn map_display_name(map_path: &str) -> String {
    let normalized = map_path.trim().replace('\\', "/");
    let level = normalized
        .trim_start_matches("/levels/")
        .trim_start_matches("levels/")
        .trim_end_matches("/info.json")
        .trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or(map_path);

    level
        .split('_')
        .filter(|part| !part.is_empty())
        .map(|part| {
            if part.len() <= 3 && part.chars().all(|ch| ch.is_ascii_alphanumeric()) {
                part.to_ascii_uppercase()
            } else {
                let mut chars = part.chars();
                match chars.next() {
                    Some(first) => {
                        let mut out = first.to_uppercase().to_string();
                        out.push_str(&chars.as_str().to_ascii_lowercase());
                        out
                    }
                    None => String::new(),
                }
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn make_map_entry(map_path: String, source: &str) -> MapEntry {
    MapEntry {
        display_name: map_display_name(&map_path),
        map_path,
        source: source.to_string(),
    }
}

fn default_beamng_levels_roots() -> Vec<std::path::PathBuf> {
    #[allow(unused_mut)]
    let mut roots = Vec::new();

    #[cfg(target_os = "windows")]
    {
        roots.push(std::path::PathBuf::from(
            r"C:\Program Files (x86)\Steam\steamapps\common\BeamNG.drive\content\levels",
        ));
        roots.push(std::path::PathBuf::from(
            r"C:\Program Files\Steam\steamapps\common\BeamNG.drive\content\levels",
        ));
    }

    #[cfg(target_os = "macos")]
    {
        if let Some(home) = std::env::var_os("HOME") {
            roots.push(std::path::PathBuf::from(home).join(
                "Library/Application Support/Steam/steamapps/common/BeamNG.drive/content/levels",
            ));
        }
    }

    roots
}

fn insert_map_entry(
    map_entries: &mut std::collections::BTreeMap<String, MapEntry>,
    raw_map: &str,
    fallback: &str,
    source: &str,
) {
    let canonical = canonical_map_path(raw_map, fallback);
    map_entries
        .entry(canonical.clone())
        .or_insert_with(|| make_map_entry(canonical, source));
}

fn discover_default_game_maps() -> Vec<MapEntry> {
    let mut map_entries = std::collections::BTreeMap::new();

    for root in default_beamng_levels_roots() {
        let Ok(entries) = std::fs::read_dir(&root) else {
            continue;
        };

        for entry in entries.flatten() {
            let path = entry.path();

            if path.is_dir() {
                if let Some(name) = path.file_name().and_then(|s| s.to_str()) {
                    if path.join("info.json").is_file() {
                        insert_map_entry(
                            &mut map_entries,
                            &format!("/levels/{name}/info.json"),
                            "/levels/gridmap_v2/info.json",
                            "Default",
                        );
                    }
                }
                continue;
            }

            let is_zip = path
                .extension()
                .and_then(|s| s.to_str())
                .is_some_and(|ext| ext.eq_ignore_ascii_case("zip"));
            if !is_zip {
                continue;
            }

            if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                insert_map_entry(
                    &mut map_entries,
                    &format!("/levels/{stem}/info.json"),
                    "/levels/gridmap_v2/info.json",
                    "Default",
                );
            }
        }
    }

    map_entries.into_values().collect()
}

impl ControlPlane {
    pub fn new(
        config: Arc<ServerConfig>,
        sessions: Arc<SessionManager>,
        world: Arc<WorldState>,
        plugins: Option<Arc<PluginRuntime>>,
    ) -> Self {
        let initial_map = canonical_map_path(&config.general.map, "/levels/gridmap_v2/info.json");
        Self {
            config,
            sessions,
            world,
            plugins,
            current_map: RwLock::new(initial_map),
            started_at: Instant::now(),
            community_node: RwLock::new(None),
            mod_sync_state: RwLock::new(None),
        }
    }

    /// Wire in the community node state after it has been created.
    pub fn set_community_node(&self, state: Arc<crate::community_node::CommunityNodeState>) {
        if let Ok(mut guard) = self.community_node.write() {
            *guard = Some(state);
        }
    }

    /// Borrow the community node state, if available.
    pub fn get_community_node(&self) -> Option<Arc<crate::community_node::CommunityNodeState>> {
        self.community_node
            .read()
            .ok()
            .and_then(|g| g.as_ref().map(Arc::clone))
    }

    /// Wire in the mod sync state after it has been created.
    pub fn set_mod_sync_state(&self, state: Arc<crate::mod_sync_state::ModSyncState>) {
        if let Ok(mut guard) = self.mod_sync_state.write() {
            *guard = Some(state);
        }
    }

    /// Borrow the mod sync state, if available.
    pub fn get_mod_sync_state(&self) -> Option<Arc<crate::mod_sync_state::ModSyncState>> {
        self.mod_sync_state
            .read()
            .ok()
            .and_then(|g| g.as_ref().map(Arc::clone))
    }

    /// Get the active mod sync port if enabled and mods exist, or None otherwise.
    pub fn active_mod_sync_port(&self) -> Option<u16> {
        self.get_mod_sync_state()
            .and_then(|state| state.active_port_if_ready())
    }

    /// Borrow the server configuration.
    pub fn get_server_config(&self) -> Arc<ServerConfig> {
        self.config.clone()
    }

    pub fn snapshot(&self) -> ServerSnapshot {
        let map_path = self
            .current_map
            .read()
            .map(|m| m.clone())
            .unwrap_or_else(|_| self.config.general.map.clone());
        ServerSnapshot {
            server_name: self.config.general.name.clone(),
            map_path: map_path.clone(),
            map_display_name: map_display_name(&map_path),
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
        if map.trim().is_empty() {
            bail!("Map path cannot be empty")
        }
        let normalized = canonical_map_path(&map, &self.config.general.map);
        let mut guard = self
            .current_map
            .write()
            .map_err(|_| anyhow::anyhow!("Map state lock poisoned"))?;
        *guard = normalized;
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
        let fallback = self.config.general.map.clone();
        let mut map_entries = std::collections::BTreeMap::new();

        insert_map_entry(
            &mut map_entries,
            &self.get_active_map(),
            &fallback,
            "Active",
        );

        for entry in discover_default_game_maps() {
            map_entries.entry(entry.map_path.clone()).or_insert(entry);
        }

        let maps_dir = std::path::Path::new(&self.config.general.resource_folder).join("Maps");
        if !maps_dir.exists() {
            return Ok(map_entries.into_values().collect());
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

            insert_map_entry(
                &mut map_entries,
                &format!("/levels/{level}/info.json"),
                &fallback,
                "Mod",
            );
        }

        Ok(map_entries.into_values().collect())
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
                snap.map_display_name
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

        if let Some(rest) = trimmed.strip_prefix("community") {
            return self.execute_community_command(rest.trim());
        }

        Ok("Commands: status | say <text> | kick <player_id> [reason] | plugins reload | map <path> | lua <plugin_name> <code> | community <subcommand>".to_string())
    }

    fn execute_community_command(&self, cmd: &str) -> Result<String> {
        let cn = self
            .community_node
            .read()
            .map_err(|_| anyhow::anyhow!("Community node lock poisoned"))?;
        let Some(state) = cn.as_ref() else {
            bail!("Community node not initialised");
        };

        match cmd {
            "enable" => {
                state.set_enabled(true);
                Ok("Community node enabled".to_string())
            }
            "disable" => {
                state.set_enabled(false);
                Ok("Community node disabled".to_string())
            }
            "status" => {
                let s = state.status();
                Ok(format!(
                    "community node: enabled={} running={} id={} port={} region={} tags=[{}] seeds={} peers={} servers={} last_gossip={}s ago",
                    s.enabled,
                    s.running,
                    if s.server_id.is_empty() { "(unset)" } else { &s.server_id },
                    s.listen_port,
                    if s.region.is_empty() { "-" } else { &s.region },
                    s.tags.join(","),
                    s.seed_nodes.len(),
                    s.peer_count,
                    s.server_count,
                    if s.last_gossip_at == 0 { 0 } else {
                        crate::community_node::now_secs_pub().saturating_sub(s.last_gossip_at)
                    }
                ))
            }
            other if other.starts_with("port ") => {
                let port_str = other.trim_start_matches("port ").trim();
                let port: u16 = port_str
                    .parse()
                    .map_err(|_| anyhow::anyhow!("Invalid port: {}", port_str))?;
                if port < 1024 {
                    bail!("Port must be 1024 or higher");
                }
                state.set_port(port);
                Ok(format!("Community node port set to {}", port))
            }
            other if other.starts_with("region ") => {
                let region = other.trim_start_matches("region ").trim().to_string();
                if !region.is_empty()
                    && !matches!(region.as_str(), "NA" | "EU" | "AP" | "SA" | "OC" | "AF")
                {
                    bail!("Region must be one of: NA, EU, AP, SA, OC, AF, or empty");
                }
                state.set_region(region.clone());
                Ok(format!("Community node region set to '{}'", region))
            }
            other if other.starts_with("tags ") => {
                let raw = other.trim_start_matches("tags ").trim();
                let tags: Vec<String> = raw
                    .split(',')
                    .map(|t| t.trim().to_string())
                    .filter(|t| !t.is_empty())
                    .collect();
                crate::validation::validate_community_node_settings(&tags, "", &[], 18862)?;
                state.set_tags(tags.clone());
                Ok(format!("Community node tags set to: {}", tags.join(", ")))
            }
            other if other.starts_with("add-seed ") => {
                let addr = other.trim_start_matches("add-seed ").trim().to_string();
                crate::validation::validate_community_node_settings(
                    &[],
                    "",
                    std::slice::from_ref(&addr),
                    18862,
                )?;
                state.add_seed_node(addr.clone());
                Ok(format!("Added seed node: {}", addr))
            }
            other if other.starts_with("remove-seed ") => {
                let addr = other.trim_start_matches("remove-seed ").trim();
                state.remove_seed_node(addr);
                Ok(format!("Removed seed node: {}", addr))
            }
            "peers" => {
                let peers = state.peer_statuses();
                if peers.is_empty() {
                    return Ok("No known peers yet.".to_string());
                }
                let now = crate::community_node::now_secs_pub();
                let mut lines = vec!["Known peers:".to_string()];
                for peer in peers {
                    let last_seen = if peer.last_seen == 0 {
                        "never".to_string()
                    } else {
                        format!("{}s ago", now.saturating_sub(peer.last_seen))
                    };
                    let retry = if peer.next_retry <= now {
                        "ready now".to_string()
                    } else {
                        format!("retry in {}s", peer.next_retry.saturating_sub(now))
                    };
                    lines.push(format!(
                        "  {} | last_seen={} | failures={} | {}",
                        peer.addr, last_seen, peer.failures, retry
                    ));
                }
                Ok(lines.join("\n"))
            }
            _ => Ok(
                "community subcommands: enable | disable | status | port <n> | region <code> | tags <a,b> | add-seed <addr> | remove-seed <addr> | peers"
                    .to_string(),
            ),
        }
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
        assert_eq!(snapshot.map_path, "/levels/gridmap_v2/info.json");
        assert_eq!(snapshot.map_display_name, "Gridmap V2");
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
    fn test_set_active_map_normalizes_legacy_aliases() {
        let config = Arc::new(ServerConfig::default());
        let sessions = Arc::new(SessionManager::new());
        let world = Arc::new(WorldState::new());
        let control = ControlPlane::new(config, sessions, world, None);

        control
            .set_active_map("/levels/GridMap/info.json".to_string())
            .expect("set map should succeed");
        assert_eq!(control.get_active_map(), "/levels/gridmap_v2/info.json");

        control
            .set_active_map("ORV".to_string())
            .expect("set map should succeed");
        assert_eq!(control.get_active_map(), "/levels/gridmap_v2/info.json");
    }

    #[test]
    fn test_set_active_map_normalizes_bare_level_name() {
        let config = Arc::new(ServerConfig::default());
        let sessions = Arc::new(SessionManager::new());
        let world = Arc::new(WorldState::new());
        let control = ControlPlane::new(config, sessions, world, None);

        control
            .set_active_map("west_coast_usa".to_string())
            .expect("set map should succeed");
        assert_eq!(control.get_active_map(), "/levels/west_coast_usa/info.json");
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

    #[test]
    fn test_discover_default_game_maps_from_zip_names() {
        let temp = tempfile::tempdir().expect("tempdir should be created");
        let levels_dir = temp.path().join("levels");
        std::fs::create_dir_all(&levels_dir).expect("levels dir should be created");
        std::fs::write(levels_dir.join("gridmap_v2.zip"), b"zip").expect("write zip placeholder");
        std::fs::write(levels_dir.join("west_coast_usa.zip"), b"zip")
            .expect("write zip placeholder");

        let mut map_entries = std::collections::BTreeMap::new();
        for entry in std::fs::read_dir(&levels_dir)
            .expect("read_dir should succeed")
            .flatten()
        {
            let path = entry.path();
            if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                insert_map_entry(
                    &mut map_entries,
                    &format!("/levels/{stem}/info.json"),
                    "/levels/gridmap_v2/info.json",
                    "Default",
                );
            }
        }

        let maps: Vec<MapEntry> = map_entries.into_values().collect();
        assert!(maps
            .iter()
            .any(|m| m.map_path == "/levels/gridmap_v2/info.json"));
        assert!(maps
            .iter()
            .any(|m| m.map_path == "/levels/west_coast_usa/info.json"));
    }
}
