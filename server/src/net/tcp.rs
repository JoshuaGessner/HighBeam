use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;
use tokio::time::timeout;

use crate::config::ServerConfig;
use crate::session::manager::SessionManager;
use crate::state::world::WorldState;

use super::packet::{self, TcpPacket, MAX_PACKET_SIZE, PROTOCOL_VERSION};

/// Start the TCP listener. Runs forever, accepting connections.
pub async fn start_listener(
    config: Arc<ServerConfig>,
    sessions: Arc<SessionManager>,
    world: Arc<WorldState>,
) -> Result<()> {
    let addr = format!("0.0.0.0:{}", config.general.port);
    let listener = TcpListener::bind(&addr)
        .await
        .with_context(|| format!("Failed to bind TCP listener on {addr}"))?;

    tracing::info!(port = config.general.port, "TCP listener started");

    loop {
        let (stream, addr) = listener.accept().await?;
        let config = config.clone();
        let sessions = sessions.clone();
        let world = world.clone();
        tokio::spawn(async move {
            if let Err(e) = handle_connection(stream, addr, config, sessions, world).await {
                tracing::warn!(%addr, error = %e, "Connection error");
            }
        });
    }
}

/// Handle a single client TCP connection through the full lifecycle:
/// handshake → auth → main loop → disconnect.
async fn handle_connection(
    mut stream: TcpStream,
    addr: SocketAddr,
    config: Arc<ServerConfig>,
    sessions: Arc<SessionManager>,
    world: Arc<WorldState>,
) -> Result<()> {
    tracing::info!(%addr, "New TCP connection");

    // 1. Set TCP_NODELAY for low-latency packet delivery
    stream.set_nodelay(true)?;

    // 2. Send ServerHello immediately
    let hello = TcpPacket::ServerHello {
        version: PROTOCOL_VERSION,
        name: config.general.name.clone(),
        map: config.general.map.clone(),
        players: sessions.player_count() as u32,
        max_players: config.general.max_players,
        max_cars: config.general.max_cars_per_player,
    };
    write_packet(&mut stream, &hello).await?;

    // 3. Wait for AuthRequest with timeout
    let auth_timeout = Duration::from_secs(config.auth.auth_timeout_sec);
    let auth_packet = timeout(auth_timeout, read_packet(&mut stream))
        .await
        .with_context(|| format!("Auth timeout after {}s", config.auth.auth_timeout_sec))?
        .context("Failed to read auth request")?;

    let username = match &auth_packet {
        TcpPacket::AuthRequest { username, .. } => username.clone(),
        other => {
            anyhow::bail!(
                "Expected AuthRequest, got {:?}",
                std::mem::discriminant(other)
            );
        }
    };

    // 4. Validate auth (v0.1.0: open mode — accept all)
    if config.auth.mode != "open" {
        tracing::warn!("Only 'open' auth mode is supported in v0.1.0");
    }

    // 5-6. Create a channel for this player's outbound TCP packets.
    //       SessionManager assigns player_id and generates the session token.
    let (tcp_tx, mut tcp_rx) = mpsc::channel::<TcpPacket>(64);
    let (player_id, session_token) = sessions.add_player(username.clone(), addr, tcp_tx);

    tracing::info!(player_id, %addr, name = %username, "Player authenticated");

    // Send AuthResponse
    let auth_response = TcpPacket::AuthResponse {
        success: true,
        player_id: Some(player_id),
        session_token: Some(session_token.clone()),
        error: None,
    };
    write_packet(&mut stream, &auth_response).await?;

    // 8. Wait for Ready packet
    let ready_timeout = Duration::from_secs(10);
    let ready_packet = timeout(ready_timeout, read_packet(&mut stream))
        .await
        .context("Timeout waiting for Ready packet")?
        .context("Failed to read Ready packet")?;

    match &ready_packet {
        TcpPacket::Ready {} => {}
        other => {
            anyhow::bail!("Expected Ready, got {:?}", std::mem::discriminant(other));
        }
    }

    tracing::info!(player_id, name = %username, "Player ready");

    // 9. Send WorldState snapshot to the new player
    let world_snapshot = TcpPacket::WorldState {
        players: sessions.get_player_snapshot(),
        vehicles: world.get_vehicle_snapshot(),
    };
    write_packet(&mut stream, &world_snapshot).await?;

    // 10. Broadcast PlayerJoin to all other connected players
    sessions.broadcast(
        TcpPacket::PlayerJoin {
            player_id,
            name: username.clone(),
        },
        Some(player_id),
    );

    // Split stream for concurrent read/write
    let (read_half, mut write_half) = stream.into_split();

    // Spawn a task to forward outbound packets from the channel to the TCP stream
    let write_task = tokio::spawn(async move {
        while let Some(packet) = tcp_rx.recv().await {
            if let Err(e) = write_packet_to(&mut write_half, &packet).await {
                tracing::warn!(player_id, "Write error: {e}");
                break;
            }
        }
    });

    // 11. Main receive loop
    let mut read_half = tokio::io::BufReader::new(read_half);
    let recv_result = receive_loop(player_id, &mut read_half, &sessions, &world).await;

    // 12. Disconnect cleanup
    write_task.abort();

    // Remove all vehicles for this player and notify others
    let removed_vehicles = world.remove_all_for_player(player_id);
    for vid in &removed_vehicles {
        sessions.broadcast(
            TcpPacket::VehicleDelete {
                player_id: Some(player_id),
                vehicle_id: *vid,
            },
            None,
        );
    }

    sessions.broadcast(TcpPacket::PlayerLeave { player_id }, Some(player_id));
    sessions.remove_player(player_id);
    tracing::info!(player_id, name = %username, vehicles_removed = removed_vehicles.len(), "Player disconnected");

    if let Err(e) = recv_result {
        tracing::debug!(player_id, "Receive loop ended: {e}");
    }

    Ok(())
}

/// Main receive loop: read packets until the client disconnects or errors.
async fn receive_loop<R: AsyncReadExt + Unpin>(
    player_id: u32,
    reader: &mut R,
    sessions: &Arc<SessionManager>,
    world: &Arc<WorldState>,
) -> Result<()> {
    loop {
        let packet = read_packet_from(reader).await?;
        match packet {
            TcpPacket::VehicleSpawn { data, .. } => {
                let vid = world.spawn_vehicle(player_id, data.clone());
                // Broadcast to ALL players (including sender so they learn the server-assigned ID)
                sessions.broadcast(
                    TcpPacket::VehicleSpawn {
                        player_id: Some(player_id),
                        vehicle_id: vid,
                        data,
                    },
                    None,
                );
            }
            TcpPacket::VehicleEdit {
                vehicle_id, data, ..
            } => {
                if world.is_owner(player_id, vehicle_id) {
                    world.update_config(player_id, vehicle_id, data.clone());
                    sessions.broadcast(
                        TcpPacket::VehicleEdit {
                            player_id: Some(player_id),
                            vehicle_id,
                            data,
                        },
                        Some(player_id),
                    );
                } else {
                    tracing::warn!(player_id, vehicle_id, "VehicleEdit for unowned vehicle");
                }
            }
            TcpPacket::VehicleDelete { vehicle_id, .. } => {
                if world.is_owner(player_id, vehicle_id) {
                    world.remove_vehicle(player_id, vehicle_id);
                    sessions.broadcast(
                        TcpPacket::VehicleDelete {
                            player_id: Some(player_id),
                            vehicle_id,
                        },
                        None,
                    );
                } else {
                    tracing::warn!(player_id, vehicle_id, "VehicleDelete for unowned vehicle");
                }
            }
            TcpPacket::VehicleReset {
                vehicle_id, data, ..
            } => {
                if world.is_owner(player_id, vehicle_id) {
                    sessions.broadcast(
                        TcpPacket::VehicleReset {
                            player_id: Some(player_id),
                            vehicle_id,
                            data,
                        },
                        Some(player_id),
                    );
                } else {
                    tracing::warn!(player_id, vehicle_id, "VehicleReset for unowned vehicle");
                }
            }
            other => {
                tracing::debug!(player_id, ?other, "Unhandled packet");
            }
        }
    }
}

// ── Wire helpers ─────────────────────────────────────────────────────

/// Read exactly one length-prefixed packet from a reader.
async fn read_packet(stream: &mut TcpStream) -> Result<TcpPacket> {
    read_packet_from(stream).await
}

/// Read exactly one length-prefixed packet from any AsyncRead.
async fn read_packet_from<R: AsyncReadExt + Unpin>(reader: &mut R) -> Result<TcpPacket> {
    let mut len_buf = [0u8; 4];
    reader.read_exact(&mut len_buf).await?;
    let len = u32::from_le_bytes(len_buf);
    if len > MAX_PACKET_SIZE {
        anyhow::bail!("Packet too large: {len} bytes (max {MAX_PACKET_SIZE})");
    }
    let mut payload = vec![0u8; len as usize];
    reader.read_exact(&mut payload).await?;
    packet::decode(&payload)
}

/// Write a packet to a TcpStream.
async fn write_packet(stream: &mut TcpStream, packet: &TcpPacket) -> Result<()> {
    let data = packet::encode(packet)?;
    stream.write_all(&data).await?;
    stream.flush().await?;
    Ok(())
}

/// Write a packet to an OwnedWriteHalf.
async fn write_packet_to<W: AsyncWriteExt + Unpin>(
    writer: &mut W,
    packet: &TcpPacket,
) -> Result<()> {
    let data = packet::encode(packet)?;
    writer.write_all(&data).await?;
    writer.flush().await?;
    Ok(())
}
