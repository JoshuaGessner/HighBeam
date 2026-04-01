use std::collections::HashMap;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

const INDEX_FILE: &str = "cache_index.json";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CacheEntry {
    pub hash: String,
    pub file_name: String,
    pub size: u64,
    /// Address of the last server this mod was downloaded from (informational).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_server: Option<String>,
    /// Unix timestamp (seconds since epoch) when this mod was cached.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub downloaded_at: Option<u64>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct CacheIndex {
    pub entries: HashMap<String, CacheEntry>,
}

pub fn default_cache_dir() -> PathBuf {
    #[cfg(target_os = "windows")]
    {
        if let Some(base) = std::env::var_os("LOCALAPPDATA") {
            return PathBuf::from(base).join("HighBeam").join("cache");
        }
    }

    if let Some(home) = std::env::var_os("HOME") {
        return PathBuf::from(home).join(".highbeam").join("cache");
    }

    PathBuf::from(".highbeam/cache")
}

pub fn ensure_cache_dir(cache_dir: &Path) -> Result<()> {
    std::fs::create_dir_all(cache_dir)
        .with_context(|| format!("Failed to create cache dir: {}", cache_dir.display()))?;
    Ok(())
}

pub fn load_index(cache_dir: &Path) -> Result<CacheIndex> {
    let index_path = cache_dir.join(INDEX_FILE);
    if !index_path.exists() {
        return Ok(CacheIndex::default());
    }

    let data = std::fs::read_to_string(&index_path)
        .with_context(|| format!("Failed to read cache index: {}", index_path.display()))?;
    let index: CacheIndex = serde_json::from_str(&data)
        .with_context(|| format!("Failed to parse cache index: {}", index_path.display()))?;
    Ok(index)
}

pub fn save_index(cache_dir: &Path, index: &CacheIndex) -> Result<()> {
    let index_path = cache_dir.join(INDEX_FILE);
    let data = serde_json::to_string_pretty(index)?;
    std::fs::write(&index_path, data)
        .with_context(|| format!("Failed to write cache index: {}", index_path.display()))?;
    Ok(())
}

pub fn clear_cache(cache_dir: &Path) -> Result<()> {
    if cache_dir.exists() {
        std::fs::remove_dir_all(cache_dir)
            .with_context(|| format!("Failed to clear cache dir: {}", cache_dir.display()))?;
    }
    std::fs::create_dir_all(cache_dir)
        .with_context(|| format!("Failed to recreate cache dir: {}", cache_dir.display()))?;
    Ok(())
}
