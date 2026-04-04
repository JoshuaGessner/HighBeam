use std::collections::HashMap;
use std::fs::File;
use std::io::{BufReader, Read};
use std::path::Path;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::net::packet::ModDescriptor;

const HASH_CACHE_FILE: &str = "manifest_cache.json";

#[derive(Debug, Clone, Serialize, Deserialize)]
struct CachedHash {
    hash: String,
    size: u64,
    mtime_secs: u64,
}

/// Build a deterministic manifest of server mods from `Resources/Client/*.zip`.
/// Uses a file-system–level hash cache keyed by (filename, size, mtime) to avoid
/// rehashing unchanged files on every startup.
pub fn build_manifest(resource_folder: &str) -> Result<Vec<ModDescriptor>> {
    let client_dir = Path::new(resource_folder).join("Client");
    tracing::info!(
        path = %client_dir.display(),
        "Building mod manifest from Resources/Client/"
    );

    if !client_dir.exists() {
        tracing::warn!(
            path = %client_dir.display(),
            "Resources/Client directory not found; mod manifest is empty"
        );
        return Ok(Vec::new());
    }

    let cache_path = Path::new(resource_folder).join(HASH_CACHE_FILE);
    let mut hash_cache = load_hash_cache(&cache_path);
    let mut new_cache: HashMap<String, CachedHash> = HashMap::new();

    let mut mods = Vec::new();

    for entry in std::fs::read_dir(&client_dir)
        .with_context(|| format!("Failed to read directory: {}", client_dir.display()))?
    {
        let entry = entry?;
        let path = entry.path();

        if !path.is_file() {
            continue;
        }

        let ext = path.extension().and_then(|v| v.to_str()).unwrap_or("");
        if !ext.eq_ignore_ascii_case("zip") {
            continue;
        }

        let name = match path.file_name().and_then(|v| v.to_str()) {
            Some(v) => v.to_string(),
            None => {
                tracing::warn!(path = %path.display(), "Skipping non-UTF8 filename in mod folder");
                continue;
            }
        };

        let metadata = std::fs::metadata(&path)
            .with_context(|| format!("Failed to stat mod file: {}", path.display()))?;
        let size = metadata.len();
        let mtime_secs = metadata
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs())
            .unwrap_or(0);

        let hash = if let Some(cached) = hash_cache.remove(&name) {
            if cached.size == size && cached.mtime_secs == mtime_secs {
                tracing::debug!(name = %name, "Using cached hash");
                cached.hash.clone()
            } else {
                sha256_file_hex(&path)?
            }
        } else {
            sha256_file_hex(&path)?
        };

        new_cache.insert(
            name.clone(),
            CachedHash {
                hash: hash.clone(),
                size,
                mtime_secs,
            },
        );

        mods.push(ModDescriptor { name, size, hash });
    }

    mods.sort_by(|a, b| a.name.cmp(&b.name));

    if let Err(e) = save_hash_cache(&cache_path, &new_cache) {
        tracing::warn!(error = %e, "Failed to save hash cache");
    }

    if mods.is_empty() {
        tracing::info!(
            path = %client_dir.display(),
            "No client mods found in Resources/Client/ (directory exists but contains no .zip files)"
        );
    } else {
        tracing::info!(count = mods.len(), "Mod manifest built");
        for m in &mods {
            tracing::info!(
                name = %m.name,
                size = m.size,
                hash = %m.hash,
                "Registered client mod"
            );
        }
    }

    Ok(mods)
}

fn load_hash_cache(path: &Path) -> HashMap<String, CachedHash> {
    let data = match std::fs::read_to_string(path) {
        Ok(d) => d,
        Err(_) => return HashMap::new(),
    };
    serde_json::from_str(&data).unwrap_or_default()
}

fn save_hash_cache(path: &Path, cache: &HashMap<String, CachedHash>) -> Result<()> {
    let data = serde_json::to_string(cache)?;
    std::fs::write(path, data)
        .with_context(|| format!("Failed to write hash cache: {}", path.display()))?;
    Ok(())
}

fn sha256_file_hex(path: &Path) -> Result<String> {
    let file = File::open(path)
        .with_context(|| format!("Failed to open mod file for hashing: {}", path.display()))?;
    let mut reader = BufReader::new(file);
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 64 * 1024];

    loop {
        let n = reader.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }

    Ok(format!("{:x}", hasher.finalize()))
}
