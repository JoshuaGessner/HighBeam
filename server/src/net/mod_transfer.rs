use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result};
use tokio::fs::File;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

use crate::net::packet::{self, ModDescriptor, TcpPacket};

pub async fn start_listener(
    port: u16,
    resource_folder: Arc<String>,
    manifest: Arc<Vec<ModDescriptor>>,
) -> Result<()> {
    let addr = format!("0.0.0.0:{port}");
    let listener = TcpListener::bind(&addr)
        .await
        .with_context(|| format!("Failed to bind mod transfer listener on {addr}"))?;

    tracing::info!(port, "Mod transfer listener started");

    loop {
        let (stream, addr) = listener.accept().await?;
        let resource_folder = resource_folder.clone();
        let manifest = manifest.clone();
        tokio::spawn(async move {
            if let Err(e) = handle_connection(stream, resource_folder, manifest).await {
                tracing::warn!(%addr, error = %e, "Mod transfer connection error");
            }
        });
    }
}

async fn handle_connection(
    mut stream: TcpStream,
    resource_folder: Arc<String>,
    manifest: Arc<Vec<ModDescriptor>>,
) -> Result<()> {
    let mod_list = TcpPacket::ModList {
        mods: manifest.as_ref().clone(),
    };
    write_packet(&mut stream, &mod_list).await?;

    let request = read_packet(&mut stream).await?;
    let names = match request {
        TcpPacket::ModRequest { names } => names,
        other => {
            anyhow::bail!(
                "Expected mod_request packet, got {:?}",
                std::mem::discriminant(&other)
            );
        }
    };

    for name in names {
        if !is_safe_mod_name(&name) {
            tracing::warn!(%name, "Skipping unsafe mod name request");
            continue;
        }

        let Some(mod_info) = manifest.iter().find(|m| m.name == name) else {
            tracing::warn!(%name, "Requested mod not found in manifest");
            continue;
        };

        let path = Path::new(resource_folder.as_str())
            .join("Client")
            .join(&mod_info.name);
        send_file_frame(&mut stream, &mod_info.name, &path).await?;
    }

    Ok(())
}

async fn send_file_frame(stream: &mut TcpStream, name: &str, path: &Path) -> Result<()> {
    let mut file = File::open(path)
        .await
        .with_context(|| format!("Failed to open mod file: {}", path.display()))?;
    let metadata = file.metadata().await?;

    let name_bytes = name.as_bytes();
    let name_len = u16::try_from(name_bytes.len())
        .map_err(|_| anyhow::anyhow!("mod name too long for frame header: {name}"))?;

    stream.write_all(&name_len.to_le_bytes()).await?;
    stream.write_all(name_bytes).await?;
    stream.write_all(&metadata.len().to_le_bytes()).await?;

    let mut buf = [0u8; 64 * 1024];
    loop {
        let n = file.read(&mut buf).await?;
        if n == 0 {
            break;
        }
        stream.write_all(&buf[..n]).await?;
    }
    stream.flush().await?;
    Ok(())
}

fn is_safe_mod_name(name: &str) -> bool {
    if name.contains('/') || name.contains('\\') {
        return false;
    }

    let path = PathBuf::from(name);
    path.file_name().and_then(|v| v.to_str()) == Some(name)
}

async fn read_packet(stream: &mut TcpStream) -> Result<TcpPacket> {
    let mut len_buf = [0u8; 4];
    stream.read_exact(&mut len_buf).await?;
    let len = u32::from_le_bytes(len_buf);
    let mut payload = vec![0u8; len as usize];
    stream.read_exact(&mut payload).await?;
    packet::decode(&payload)
}

async fn write_packet(stream: &mut TcpStream, packet: &TcpPacket) -> Result<()> {
    let data = packet::encode(packet)?;
    stream.write_all(&data).await?;
    stream.flush().await?;
    Ok(())
}
