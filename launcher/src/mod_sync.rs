use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::mod_cache::{CacheEntry, CacheIndex};

#[derive(Debug, Clone)]
pub struct ServerMod {
    pub name: String,
    pub hash: String,
    pub size: u64,
}

#[derive(Debug, Default)]
pub struct SyncReport {
    pub total_server_mods: usize,
    pub missing_mods: usize,
    pub downloaded_mods: usize,
    pub server_mods: Vec<ServerMod>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ModDescriptor {
    name: String,
    size: u64,
    hash: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
enum ModPacket {
    #[serde(rename = "mod_list")]
    ModList { mods: Vec<ModDescriptor> },
    #[serde(rename = "mod_request")]
    ModRequest { names: Vec<String> },
}

pub fn sync_mods(
    server_addr: &str,
    mod_sync_addr: Option<&str>,
    connect_timeout_sec: u64,
    cache_dir: &Path,
    index: &mut CacheIndex,
) -> Result<SyncReport> {
    let endpoint = mod_sync_addr
        .map(ToString::to_string)
        .unwrap_or_else(|| resolve_mod_sync_endpoint(server_addr));

    let mut stream = TcpStream::connect(&endpoint)
        .with_context(|| format!("Failed to connect to mod sync endpoint: {endpoint}"))?;
    stream.set_read_timeout(Some(Duration::from_secs(connect_timeout_sec)))?;
    stream.set_write_timeout(Some(Duration::from_secs(connect_timeout_sec)))?;

    let packet = read_packet(&mut stream)?;
    let server_mods = match packet {
        ModPacket::ModList { mods } => mods,
        _ => return Err(anyhow!("Expected mod_list packet from server")),
    };

    let mut expected_by_name = HashMap::new();
    let missing: Vec<String> = server_mods
        .iter()
        .filter_map(|m| {
            expected_by_name.insert(m.name.clone(), m.clone());
            if index.entries.contains_key(&m.hash) {
                None
            } else {
                Some(m.name.clone())
            }
        })
        .collect();

    write_packet(
        &mut stream,
        &ModPacket::ModRequest {
            names: missing.clone(),
        },
    )?;

    let mut downloaded = 0usize;
    for _ in 0..missing.len() {
        let (name, path, size) = receive_file_frame(&mut stream, cache_dir, &expected_by_name)?;
        let expected = expected_by_name
            .get(&name)
            .ok_or_else(|| anyhow!("Received unexpected mod: {name}"))?;

        if size != expected.size {
            return Err(anyhow!(
                "Downloaded size mismatch for {name}: got {size}, expected {}",
                expected.size
            ));
        }

        index.entries.insert(
            expected.hash.clone(),
            CacheEntry {
                hash: expected.hash.clone(),
                file_name: name,
                size,
            },
        );

        tracing::info!(path = %path.display(), "Downloaded mod to cache");
        downloaded += 1;
    }

    let synced_mods = server_mods
        .iter()
        .map(|m| ServerMod {
            name: m.name.clone(),
            hash: m.hash.clone(),
            size: m.size,
        })
        .collect();

    Ok(SyncReport {
        total_server_mods: server_mods.len(),
        missing_mods: missing.len(),
        downloaded_mods: downloaded,
        server_mods: synced_mods,
    })
}

fn resolve_mod_sync_endpoint(server_addr: &str) -> String {
    if let Some((host, port_str)) = server_addr.rsplit_once(':') {
        if let Ok(port) = port_str.parse::<u16>() {
            return format!("{host}:{}", port.saturating_add(1));
        }
    }
    server_addr.to_string()
}

fn read_packet(stream: &mut TcpStream) -> Result<ModPacket> {
    let mut len_buf = [0u8; 4];
    stream.read_exact(&mut len_buf)?;
    let len = u32::from_le_bytes(len_buf);
    let mut payload = vec![0u8; len as usize];
    stream.read_exact(&mut payload)?;
    let packet: ModPacket = serde_json::from_slice(&payload)?;
    Ok(packet)
}

fn write_packet(stream: &mut TcpStream, packet: &ModPacket) -> Result<()> {
    let json = serde_json::to_vec(packet)?;
    let len = u32::try_from(json.len()).map_err(|_| anyhow!("Packet payload too large"))?;
    stream.write_all(&len.to_le_bytes())?;
    stream.write_all(&json)?;
    stream.flush()?;
    Ok(())
}

fn receive_file_frame(
    stream: &mut TcpStream,
    cache_dir: &Path,
    expected_by_name: &HashMap<String, ModDescriptor>,
) -> Result<(String, PathBuf, u64)> {
    let mut name_len_buf = [0u8; 2];
    stream.read_exact(&mut name_len_buf)?;
    let name_len = u16::from_le_bytes(name_len_buf) as usize;

    let mut name_buf = vec![0u8; name_len];
    stream.read_exact(&mut name_buf)?;
    let name = String::from_utf8(name_buf)?;

    let mut size_buf = [0u8; 8];
    stream.read_exact(&mut size_buf)?;
    let file_size = u64::from_le_bytes(size_buf);

    let expected = expected_by_name
        .get(&name)
        .ok_or_else(|| anyhow!("Received mod frame for unknown file: {name}"))?;

    let temp_path = cache_dir.join(format!("{}.part", expected.hash));
    let final_path = cache_dir.join(format!("{}.zip", expected.hash));

    let mut file = File::create(&temp_path)
        .with_context(|| format!("Failed to create temp cache file: {}", temp_path.display()))?;
    let mut hasher = Sha256::new();
    let mut remaining = file_size;
    let mut buf = [0u8; 64 * 1024];

    while remaining > 0 {
        let chunk = usize::try_from(remaining.min(buf.len() as u64)).unwrap_or(buf.len());
        stream.read_exact(&mut buf[..chunk])?;
        file.write_all(&buf[..chunk])?;
        hasher.update(&buf[..chunk]);
        remaining -= chunk as u64;
    }
    file.flush()?;

    let hash = format!("{:x}", hasher.finalize());
    if hash != expected.hash {
        let _ = std::fs::remove_file(&temp_path);
        return Err(anyhow!(
            "SHA-256 mismatch for {name}: got {hash}, expected {}",
            expected.hash
        ));
    }

    std::fs::rename(&temp_path, &final_path).with_context(|| {
        format!(
            "Failed to move downloaded file into cache: {} -> {}",
            temp_path.display(),
            final_path.display()
        )
    })?;

    Ok((name, final_path, file_size))
}
