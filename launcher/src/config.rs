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
    pub connect_timeout_sec: u64,
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
            connect_timeout_sec: 10,
        }
    }
}
