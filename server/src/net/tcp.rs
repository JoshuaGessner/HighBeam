use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;
use tokio::time::{timeout, Instant};

use crate::config::ServerConfig;
use crate::session::manager::SessionManager;
use crate::session::rate_limiter::ServerRateLimiters;
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

    // Create rate limiters
    let rate_limiters = Arc::new(ServerRateLimiters::new());

    loop {
        let (stream, addr) = listener.accept().await?;
        let config = config.clone();
        let sessions = sessions.clone();
        let world = world.clone();
        let rate_limiters = rate_limiters.clone();
        tokio::spawn(async move {
            if let Err(e) =
                handle_connection(stream, addr, config, sessions, world, rate_limiters).await
            {
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
    rate_limiters: Arc<ServerRateLimiters>,
) -> Result<()> {
    tracing::info!(%addr, "New TCP connection");

    // 1. Set TCP_NODELAY for low-latency packet delivery
    stream.set_nodelay(true)?;

    // 3. Send ServerHello immediately
    let hello = TcpPacket::ServerHello {
        version: PROTOCOL_VERSION,
        name: config.general.name.clone(),
        map: config.general.map.clone(),
        players: sessions.player_count() as u32,
        max_players: config.general.max_players,
        max_cars: config.general.max_cars_per_player,
    };
    write_packet(&mut stream, &hello).await?;

    // Check auth rate limit before processing
    if !rate_limiters.check_auth_limit(&addr).await {
        tracing::warn!(%addr, "Auth rate limit exceeded");
        let response = TcpPacket::AuthResponse {
            success: false,
            player_id: None,
            session_token: None,
            error: Some("Too many auth attempts. Try again later.".into()),
        };
        write_packet(&mut stream, &response).await?;
        return Ok(());
    }

    // 4. Wait for AuthRequest with timeout
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

    // Validate username
    let username = match crate::validation::validate_username(&username) {
        Ok(u) => u,
        Err(e) => {
            let response = TcpPacket::AuthResponse {
                success: false,
                player_id: None,
                session_token: None,
                error: Some(format!("Invalid username: {}", e)),
            };
            write_packet(&mut stream, &response).await?;
            return Ok(());
        }
    };

    // 4. Validate auth based on configured mode
    match config.auth.mode.as_str() {
        "open" => { /* Accept all */ }
        "password" => {
            let client_password = match &auth_packet {
                TcpPacket::AuthRequest { password, .. } => password.clone(),
                _ => None,
            };
            let expected = config.auth.password.as_deref().unwrap_or("");
            match client_password.as_deref() {
                Some(pw) if pw == expected => { /* Password matches */ }
                _ => {
                    tracing::warn!(%addr, name = %username, "Password auth failed");
                    let response = TcpPacket::AuthResponse {
                        success: false,
                        player_id: None,
                        session_token: None,
                        error: Some("Incorrect password.".into()),
                    };
                    write_packet(&mut stream, &response).await?;
                    return Ok(());
                }
            }
        }
        "allowlist" => {
            let allowed = config.auth.allowlist.as_ref().map_or(false, |list| {
                list.iter().any(|name| name.eq_ignore_ascii_case(&username))
            });
            if !allowed {
                tracing::warn!(%addr, name = %username, "Allowlist auth rejected");
                let response = TcpPacket::AuthResponse {
                    success: false,
                    player_id: None,
                    session_token: None,
                    error: Some("You are not on the server's allowlist.".into()),
                };
                write_packet(&mut stream, &response).await?;
                return Ok(());
            }
        }
        other => {
            tracing::error!(mode = %other, "Unknown auth mode in config");
        }
    }

    // 4b. Enforce MaxPlayers limit
    if sessions.player_count() >= config.general.max_players as usize {
        tracing::warn!(%addr, name = %username, "Server full ({} players)", config.general.max_players);
        let response = TcpPacket::AuthResponse {
            success: false,
            player_id: None,
            session_token: None,
            error: Some("Server is full.".into()),
        };
        write_packet(&mut stream, &response).await?;
        return Ok(());
    }

    // 5-6. Create a channel for this player's outbound TCP packets.
    //       SessionManager assigns player_id and generates the session token.
    let (tcp_tx, mut tcp_rx) = mpsc::channel::<TcpPacket>(64);
    let tcp_tx_ping = tcp_tx.clone();  // Clone for ping task
    let (player_id, session_token) = match sessions.add_player(username.clone(), addr, tcp_tx.clone()) {
        Ok(result) => result,
        Err(e) => {
            tracing::warn!(%addr, error = %e, "Failed to create session");
            let response = TcpPacket::AuthResponse {
                success: false,
                player_id: None,
                session_token: None,
                error: Some(format!("Session creation failed: {e}")),
            };
            write_packet(&mut stream, &response).await?;
            return Ok(());
        }
    };

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


    // Spawn a ping task to send heartbeat pings every 20s and monitor pong timeout (Phase 2.2)
    let ping_tx = tcp_tx_ping;
    let ping_sessions = sessions.clone();
    let ping_task = tokio::spawn(async move {
        let ping_interval = Duration::from_secs(20);
        let pong_timeout = Duration::from_secs(30);
        let mut seq = 0u32;

        loop {
            tokio::time::sleep(ping_interval).await;
            if let Err(e) = ping_tx.send(TcpPacket::PingPong { seq }).await {
                tracing::debug!(player_id, "Ping send failed: {e}");
                break;
            }
            tracing::debug!(player_id, seq, "Ping sent");
            seq = seq.wrapping_add(1);
            if let Some(player) = ping_sessions.get_player(player_id) {
                if player.last_pong_time.elapsed() > pong_timeout {
                    tracing::warn!(player_id, "Pong timeout after {}s", pong_timeout.as_secs());
                    break;
                }
            } else {
                break;
            }
        }
    });

    // 11. Main receive loop
    let mut read_half = tokio::io::BufReader::new(read_half);
    let recv_result = receive_loop(
        player_id,
        &mut read_half,
        &sessions,
        &world,
        &rate_limiters,
        config.logging.log_chat,
        config.general.max_cars_per_player,
    )
    .await;

    // 12. Disconnect cleanup
    write_task.abort();
    ping_task.abort();

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
/// Also enforces idle timeout to detect dead connections.
async fn receive_loop<R: AsyncReadExt + Unpin>(
    player_id: u32,
    reader: &mut R,
    sessions: &Arc<SessionManager>,
    world: &Arc<WorldState>,
    rate_limiters: &Arc<ServerRateLimiters>,
    log_chat: bool,
    max_cars: u32,
) -> Result<()> {
    let idle_timeout = Duration::from_secs(60); // 60-second idle timeout
    let mut last_activity = Instant::now();

    loop {
        // Check for idle timeout
        if last_activity.elapsed() > idle_timeout {
            anyhow::bail!("Connection idle for too long");
        }

        // Use timeout on read to allow periodic idle checks
        let read_timeout = Duration::from_secs(15);
        let packet = match timeout(read_timeout, read_packet_from(reader)).await {
            Ok(Ok(p)) => p,
            Ok(Err(e)) => return Err(e),
            Err(_) => {
                // Timeout on read, loop back to check idle
                continue;
            }
        };

        last_activity = Instant::now();

        match packet {
            TcpPacket::VehicleSpawn { data, .. } => {
                // Check spawn rate limit
                if !rate_limiters.check_spawn_limit(player_id).await {
                    tracing::warn!(player_id, "Vehicle spawn rate limit exceeded");
                    continue;
                }

                // Validate vehicle config size
                if let Err(e) = crate::validation::validate_vehicle_config_size(&data) {
                    tracing::warn!(player_id, error = %e, "VehicleSpawn rejected: invalid config");
                    continue;
                }

                // Enforce MaxCarsPerPlayer
                let current_count = world.vehicle_count_for_player(player_id);
                if current_count >= max_cars {
                    tracing::warn!(player_id, current_count, max_cars, "MaxCarsPerPlayer limit reached");
                    continue;
                }

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
                // Validate vehicle ID and config
                if let Err(e) = crate::validation::validate_vehicle_id(vehicle_id) {
                    tracing::warn!(player_id, video_id = vehicle_id, error = %e, "VehicleEdit: invalid vehicle ID");
                    continue;
                }
                if let Err(e) = crate::validation::validate_vehicle_config_size(&data) {
                    tracing::warn!(player_id, error = %e, "VehicleEdit: invalid config");
                    continue;
                }

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
                if let Err(e) = crate::validation::validate_vehicle_id(vehicle_id) {
                    tracing::warn!(player_id, vehicle_id, error = %e, "VehicleDelete: invalid vehicle ID");
                    continue;
                }

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
                if let Err(e) = crate::validation::validate_vehicle_id(vehicle_id) {
                    tracing::warn!(player_id, vehicle_id, error = %e, "VehicleReset: invalid vehicle ID");
                    continue;
                }
                if let Err(e) = crate::validation::validate_vehicle_config_size(&data) {
                    tracing::warn!(player_id, error = %e, "VehicleReset: invalid config");
                    continue;
                }

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
            TcpPacket::ChatMessage { text } => {
                // Check chat rate limit
                if !rate_limiters.check_chat_limit(player_id).await {
                    tracing::warn!(player_id, "Chat rate limit exceeded");
                    continue;
                }

                // Validate chat message
                match crate::validation::validate_chat_message(&text) {
                    Ok(validated_text) => {
                        if let Some(player) = sessions.get_player(player_id) {
                            if log_chat {
                                tracing::info!(
                                    target: "highbeam::chat",
                                    player_id,
                                    player_name = %player.name,
                                    text = %validated_text,
                                    "[CHAT]"
                                );
                            }

                            let broadcast_packet = TcpPacket::ChatBroadcast {
                                player_id,
                                player_name: player.name.clone(),
                                text: validated_text,
                            };
                            sessions.broadcast(broadcast_packet, None);
                        } else {
                            tracing::warn!(player_id, "ChatMessage from unknown player");
                        }
                    }
                    Err(e) => {
                        tracing::warn!(player_id, error = %e, "ChatMessage rejected: invalid content");
                    }
                }
            }
            TcpPacket::PingPong { seq } => {
                // Handle pong response from client (Phase 2.2: heartbeat)
                if let Some(mut player) = sessions.get_player_mut(player_id) {
                    player.last_pong_time = Instant::now();
                    tracing::debug!(player_id, seq, "Pong received");
                } else {
                    tracing::warn!(player_id, "PingPong from unknown player");
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
