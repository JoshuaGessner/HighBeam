use std::fs::File;
use std::io::{BufReader, Read};
use std::path::Path;

use anyhow::{Context, Result};
use sha2::{Digest, Sha256};

use crate::net::packet::ModDescriptor;

/// Build a deterministic manifest of server mods from `Resources/Client/*.zip`.
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
        let hash = sha256_file_hex(&path)?;

        mods.push(ModDescriptor {
            name,
            size: metadata.len(),
            hash,
        });
    }

    mods.sort_by(|a, b| a.name.cmp(&b.name));

    if mods.is_empty() {
        tracing::info!(
            path = %client_dir.display(),
            "No client mods found in Resources/Client/ (directory exists but contains no .zip files)"
        );
    } else {
        tracing::info!(
            count = mods.len(),
            "Mod manifest built"
        );
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
