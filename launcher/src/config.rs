use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LauncherConfig {
    pub server_addr: String,
    pub mod_sync_addr: Option<String>,
    pub cache_dir: String,
    pub beamng_exe: Option<String>,
    pub beamng_userfolder: Option<String>,
    #[serde(default)]
    pub discovery_relays: Vec<String>,
    #[serde(default)]
    pub favorite_servers: Vec<String>,
    #[serde(default)]
    pub recent_servers: Vec<String>,
    #[serde(default = "default_query_timeout_ms")]
    pub query_timeout_ms: u64,
    pub connect_timeout_sec: u64,
    #[serde(default = "default_max_cache_size_mb")]
    pub max_cache_size_mb: u64,
}

impl LauncherConfig {
    pub fn load(path: &Path) -> Result<Self> {
        if path.exists() {
            let data = std::fs::read_to_string(path)
                .with_context(|| format!("Failed to read launcher config: {}", path.display()))?;
            let mut cfg: Self = toml::from_str(&data)
                .with_context(|| format!("Failed to parse launcher config: {}", path.display()))?;
            if cfg.mod_sync_addr.as_deref() == Some("") {
                cfg.mod_sync_addr = None;
            }
            if cfg.beamng_exe.as_deref() == Some("") {
                cfg.beamng_exe = None;
            }
            if cfg.beamng_userfolder.as_deref() == Some("") {
                cfg.beamng_userfolder = None;
            }
            Ok(cfg)
        } else {
            tracing::warn!(path = %path.display(), "Launcher config not found; using defaults");
            Ok(Self::default())
        }
    }

    pub fn save(&self, path: &Path) -> Result<()> {
        let content = toml::to_string_pretty(self)
            .with_context(|| format!("Failed to serialize launcher config: {}", path.display()))?;
        std::fs::write(path, content)
            .with_context(|| format!("Failed to write launcher config: {}", path.display()))?;
        Ok(())
    }

    pub fn add_favorite_server(&mut self, addr: &str) -> bool {
        let trimmed = addr.trim();
        if trimmed.is_empty() {
            return false;
        }
        if self.favorite_servers.iter().any(|s| s == trimmed) {
            return false;
        }
        self.favorite_servers.push(trimmed.to_string());
        self.favorite_servers.sort();
        true
    }

    pub fn remove_favorite_server(&mut self, addr: &str) -> bool {
        let before = self.favorite_servers.len();
        self.favorite_servers.retain(|s| s != addr.trim());
        before != self.favorite_servers.len()
    }

    pub fn note_recent_server(&mut self, addr: &str) {
        let trimmed = addr.trim();
        if trimmed.is_empty() {
            return;
        }
        self.recent_servers.retain(|s| s != trimmed);
        self.recent_servers.insert(0, trimmed.to_string());
        self.recent_servers.truncate(20);
    }
}

impl Default for LauncherConfig {
    fn default() -> Self {
        Self {
            server_addr: "127.0.0.1:18860".to_string(),
            mod_sync_addr: None,
            cache_dir: crate::mod_cache::default_cache_dir()
                .to_string_lossy()
                .to_string(),
            beamng_exe: None,
            beamng_userfolder: None,
            discovery_relays: Vec::new(),
            favorite_servers: Vec::new(),
            recent_servers: Vec::new(),
            query_timeout_ms: default_query_timeout_ms(),
            connect_timeout_sec: 10,
            max_cache_size_mb: default_max_cache_size_mb(),
        }
    }
}

fn default_query_timeout_ms() -> u64 {
    1500
}

fn default_max_cache_size_mb() -> u64 {
    2048
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn add_and_remove_favorite_server_is_idempotent() {
        let mut cfg = LauncherConfig::default();

        assert!(cfg.add_favorite_server("127.0.0.1:18860"));
        assert!(!cfg.add_favorite_server("127.0.0.1:18860"));
        assert_eq!(cfg.favorite_servers.len(), 1);

        assert!(cfg.remove_favorite_server("127.0.0.1:18860"));
        assert!(!cfg.remove_favorite_server("127.0.0.1:18860"));
        assert!(cfg.favorite_servers.is_empty());
    }

    #[test]
    fn recent_servers_are_deduplicated_and_capped() {
        let mut cfg = LauncherConfig::default();

        for idx in 1..=25 {
            cfg.note_recent_server(&format!("127.0.0.1:{}", 18000 + idx));
        }
        assert_eq!(cfg.recent_servers.len(), 20);

        cfg.note_recent_server("127.0.0.1:18010");
        assert_eq!(cfg.recent_servers[0], "127.0.0.1:18010");
    }
}
