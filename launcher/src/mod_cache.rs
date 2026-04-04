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
    let data = serde_json::to_string(index)?;
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

/// Evict oldest cached mods until total size is under `max_size_bytes`.
/// Entries with no `downloaded_at` timestamp are evicted first.
pub fn evict_to_size(cache_dir: &Path, index: &mut CacheIndex, max_size_bytes: u64) {
    let total: u64 = index.entries.values().map(|e| e.size).sum();
    if total <= max_size_bytes {
        return;
    }

    let mut entries: Vec<(String, u64, u64)> = index
        .entries
        .iter()
        .map(|(k, v)| (k.clone(), v.size, v.downloaded_at.unwrap_or(0)))
        .collect();
    // Sort oldest first (smallest timestamp first)
    entries.sort_by_key(|(_, _, ts)| *ts);

    let mut running = total;
    for (hash, size, _) in entries {
        if running <= max_size_bytes {
            break;
        }
        // Remove from disk
        let file_path = cache_dir.join(format!("{hash}.zip"));
        if let Err(e) = std::fs::remove_file(&file_path) {
            tracing::warn!(path = %file_path.display(), error = %e, "Failed to remove evicted cache file");
        }
        index.entries.remove(&hash);
        running = running.saturating_sub(size);
        tracing::info!(hash = %hash, freed = size, remaining = running, "Evicted cached mod");
    }
}
