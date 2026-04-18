use constant_time_eq::constant_time_eq;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::broadcast;
use tokio::sync::mpsc;
use tokio::time::{timeout, Instant};
use tokio_rustls::TlsAcceptor;

use crate::config::ServerConfig;
use crate::control::ControlPlane;
use crate::metrics;
use crate::plugin::events::PluginEvent;
use crate::plugin::runtime::PluginRuntime;
use crate::session::manager::SessionManager;
use crate::session::rate_limiter::ServerRateLimiters;
use crate::state::world::WorldState;
use crate::tls;

use super::packet::{self, TcpPacket, MAX_PACKET_SIZE, PROTOCOL_VERSION};

/// Start the TCP listener. Runs forever, accepting connections.
pub async fn start_listener(
    config: Arc<ServerConfig>,
    control: Arc<ControlPlane>,
    sessions: Arc<SessionManager>,
    world: Arc<WorldState>,
    plugins: Arc<PluginRuntime>,
    mut shutdown_rx: broadcast::Receiver<()>,
) -> Result<()> {
    let addr = format!("0.0.0.0:{}", config.general.port);
    let listener = TcpListener::bind(&addr)
        .await
        .with_context(|| format!("Failed to bind TCP listener on {addr}"))?;

    tracing::info!(port = config.general.port, "TCP listener started");

    // Initialize TLS acceptor if enabled
    let tls_acceptor = if let Some(tls_cfg) = &config.tls {
        if tls_cfg.enabled {
            let tls_config = tls::TlsConfig::new(&tls_cfg.cert_path, &tls_cfg.key_path)
                .with_autogenerate(tls_cfg.auto_generate);
            let acceptor = tls::load_or_generate_acceptor(&tls_config)?;
            tracing::info!("TLS enabled for TCP connections");
            Some(acceptor)
        } else {
            None
        }
    } else {
        None
    };
    let tls_acceptor = Arc::new(tls_acceptor);

    // Create rate limiters
    let rate_limiters = Arc::new(ServerRateLimiters::new());
    let cleanup_limiters = rate_limiters.clone();
    tokio::spawn(async move {
        let interval = Duration::from_secs(60);
        loop {
            tokio::time::sleep(interval).await;
            let removed = cleanup_limiters.prune_expired().await;
            if removed > 0 {
                tracing::debug!(removed, "Pruned expired rate limiter records");
            }
        }
    });

    // Periodic stale vehicle reaper (every 30s, reap vehicles not updated in 60s)
    let reap_world = world.clone();
    let reap_sessions = sessions.clone();
    tokio::spawn(async move {
        let interval = Duration::from_secs(30);
        let max_age = Duration::from_secs(60);
        loop {
            tokio::time::sleep(interval).await;
            let reaped = reap_world.reap_stale_vehicles(max_age);
            for (owner_id, vehicle_id) in &reaped {
                let delete_packet = packet::TcpPacket::VehicleDelete {
                    player_id: Some(*owner_id),
                    vehicle_id: *vehicle_id,
                };
                reap_sessions.broadcast(delete_packet, None);
                tracing::info!(
                    owner_id,
                    vehicle_id,
                    "Broadcast VehicleDelete for stale vehicle"
                );
            }
        }
    });

    loop {
        let accept_result = tokio::select! {
            _ = shutdown_rx.recv() => {
                tracing::info!("TCP listener received shutdown signal");
                break;
            }
            result = listener.accept() => result,
        };

        let (stream, addr) = match accept_result {
            Ok(v) => v,
            Err(e) => {
                tracing::warn!(error = %e, "TCP accept failed; continuing listener loop");
                continue;
            }
        };
        let config = config.clone();
        let sessions = sessions.clone();
        let world = world.clone();
        let plugins = plugins.clone();
        let control = control.clone();
        let rate_limiters = rate_limiters.clone();
        let tls_acceptor = tls_acceptor.clone();

        tokio::spawn(async move {
            if let Err(e) = handle_connection_wrapper(
                stream,
                addr,
                config,
                control,
                sessions,
                world,
                plugins,
                rate_limiters,
                tls_acceptor,
            )
            .await
            {
                tracing::warn!(%addr, error = %e, "Connection error");
            }
        });
    }

    Ok(())
}

/// Wrapper that handles both plain TCP and TLS connections
#[allow(clippy::too_many_arguments)]
async fn handle_connection_wrapper(
    stream: TcpStream,
    addr: SocketAddr,
    config: Arc<ServerConfig>,
    control: Arc<ControlPlane>,
    sessions: Arc<SessionManager>,
    world: Arc<WorldState>,
    plugins: Arc<PluginRuntime>,
    rate_limiters: Arc<ServerRateLimiters>,
    tls_acceptor: Arc<Option<TlsAcceptor>>,
) -> Result<()> {
    // Set TCP_NODELAY before TLS wrapping
    stream.set_nodelay(true)?;

    if let Some(acceptor) = tls_acceptor.as_ref() {
        // TLS connection
        let tls_stream = acceptor
            .accept(stream)
            .await
            .context("Failed to establish TLS connection")?;
        handle_connection_core(
            tls_stream,
            addr,
            config,
            control,
            sessions,
            world,
            plugins,
            rate_limiters,
        )
        .await
    } else {
        // Plain TCP connection
        handle_connection_core(
            stream,
            addr,
            config,
            control,
            sessions,
            world,
            plugins,
            rate_limiters,
        )
        .await
    }
}

/// Generic connection handler that works with both plain TCP and TLS streams
#[allow(clippy::too_many_arguments)]
async fn handle_connection_core<S>(
    stream: S,
    addr: SocketAddr,
    config: Arc<ServerConfig>,
    control: Arc<ControlPlane>,
    sessions: Arc<SessionManager>,
    world: Arc<WorldState>,
    plugins: Arc<PluginRuntime>,
    rate_limiters: Arc<ServerRateLimiters>,
) -> Result<()>
where
    S: AsyncReadExt + AsyncWriteExt + Unpin + std::fmt::Debug + Send + 'static,
{
    tracing::info!(%addr, "New connection");

    let mut stream = stream;

    // 3. Send ServerHello immediately
    let hello = TcpPacket::ServerHello {
        version: PROTOCOL_VERSION,
        name: config.general.name.clone(),
        map: control.get_active_map(),
        players: sessions.player_count() as u32,
        max_players: config.general.max_players,
        max_cars: config.general.max_cars_per_player,
    };
    write_packet_generic(&mut stream, &hello).await?;

    // Check auth rate limit before processing
    if !rate_limiters.check_auth_limit(&addr).await {
        tracing::warn!(%addr, "Auth rate limit exceeded");
        let response = TcpPacket::AuthResponse {
            success: false,
            player_id: None,
            session_token: None,
            error: Some("Too many auth attempts. Try again later.".into()),
        };
        write_packet_generic(&mut stream, &response).await?;
        return Ok(());
    }

    // 4. Wait for AuthRequest with timeout
    let auth_timeout = Duration::from_secs(config.auth.auth_timeout_sec);
    let auth_packet = timeout(auth_timeout, read_packet_from(&mut stream))
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
            write_packet_generic(&mut stream, &response).await?;
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
                Some(pw) if constant_time_eq(pw.as_bytes(), expected.as_bytes()) => {
                    /* Password matches */
                }
                _ => {
                    tracing::warn!(%addr, name = %username, "Password auth failed");
                    let response = TcpPacket::AuthResponse {
                        success: false,
                        player_id: None,
                        session_token: None,
                        error: Some("Incorrect password.".into()),
                    };
                    write_packet_generic(&mut stream, &response).await?;
                    return Ok(());
                }
            }
        }
        "allowlist" => {
            let allowed =
                config.auth.allowlist.as_ref().is_some_and(|list| {
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
                write_packet_generic(&mut stream, &response).await?;
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
        write_packet_generic(&mut stream, &response).await?;
        return Ok(());
    }

    // Plugin hook: allow plugins to reject auth.
    if let Some(reason) = plugins.dispatch_event(&PluginEvent::PlayerAuth {
        username: username.clone(),
        addr: addr.to_string(),
    }) {
        tracing::warn!(%addr, name = %username, reason = %reason, "Auth rejected by plugin");
        let response = TcpPacket::AuthResponse {
            success: false,
            player_id: None,
            session_token: None,
            error: Some(reason),
        };
        write_packet_generic(&mut stream, &response).await?;
        return Ok(());
    }

    // 5-6. Create a channel for this player's outbound TCP packets.
    //       SessionManager assigns player_id and generates the session token.
    let (tcp_tx, mut tcp_rx) = mpsc::channel::<TcpPacket>(64);
    let tcp_tx_ping = tcp_tx.clone(); // Clone for ping task
    let (player_id, session_token) =
        match sessions.add_player(username.clone(), addr, tcp_tx.clone()) {
            Ok(result) => result,
            Err(e) => {
                tracing::warn!(%addr, error = %e, "Failed to create session");
                let response = TcpPacket::AuthResponse {
                    success: false,
                    player_id: None,
                    session_token: None,
                    error: Some(format!("Session creation failed: {e}")),
                };
                write_packet_generic(&mut stream, &response).await?;
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
    write_packet_generic(&mut stream, &auth_response).await?;

    // 8. Wait for Ready packet
    let ready_timeout = Duration::from_secs(10);
    let ready_result = timeout(ready_timeout, read_packet_from(&mut stream)).await;

    let ready_packet = match ready_result {
        Ok(Ok(p)) => p,
        Ok(Err(e)) => {
            // Read error before Ready — clean up the session we just created.
            tracing::warn!(player_id, name = %username, error = %e, "Failed to read Ready packet; cleaning up session");
            sessions.remove_player(player_id);
            return Err(e.context("Failed to read Ready packet"));
        }
        Err(_) => {
            // Timeout — clean up the session we just created.
            tracing::warn!(player_id, name = %username, "Timeout waiting for Ready packet; cleaning up session");
            sessions.remove_player(player_id);
            anyhow::bail!("Timeout waiting for Ready packet after 10s");
        }
    };

    match &ready_packet {
        TcpPacket::Ready {} => {}
        other => {
            sessions.remove_player(player_id);
            anyhow::bail!("Expected Ready, got {:?}", std::mem::discriminant(other));
        }
    }

    tracing::info!(player_id, name = %username, "Player ready");

    // 9. Send WorldState snapshot to the new player
    let world_snapshot = TcpPacket::WorldState {
        players: sessions.get_player_snapshot(),
        vehicles: world.get_vehicle_snapshot(),
    };
    write_packet_generic(&mut stream, &world_snapshot).await?;

    // 10. Broadcast PlayerJoin to all other connected players
    sessions.broadcast(
        TcpPacket::PlayerJoin {
            player_id,
            name: username.clone(),
        },
        Some(player_id),
    );

    // Split stream for concurrent read/write
    let (read_half, write_half) = tokio::io::split(stream);

    // Spawn a task to forward outbound packets from the channel to the TCP stream
    let write_task = tokio::spawn(async move {
        let mut write_half = write_half;
        while let Some(packet) = tcp_rx.recv().await {
            if let Err(e) = write_packet_to(&mut write_half, &packet).await {
                tracing::warn!(player_id, "Write error: {e}");
                break;
            }
        }
    });

    // Spawn a ping task to send heartbeat pings and periodic player metrics.
    let ping_tx = tcp_tx_ping;
    let ping_sessions = sessions.clone();
    let ping_task = tokio::spawn(async move {
        let ping_interval = Duration::from_secs(5);
        let metrics_interval = Duration::from_secs(5);
        let pong_timeout = Duration::from_secs(30);
        let mut seq = 0u32;
        let mut ping_tick = tokio::time::interval(ping_interval);
        let mut metrics_tick = tokio::time::interval(metrics_interval);

        loop {
            tokio::select! {
                _ = ping_tick.tick() => {
                    if let Some(mut player) = ping_sessions.get_player_mut(player_id) {
                        player.last_ping_seq_sent = Some(seq);
                        player.last_ping_sent_at = Some(Instant::now());
                    }

                    if let Err(e) = ping_tx.send(TcpPacket::PingPong { seq }).await {
                        tracing::debug!(player_id, "Ping send failed: {e}");
                        break;
                    }
                    tracing::debug!(player_id, seq, "Ping sent");
                    seq = seq.wrapping_add(1);
                }
                _ = metrics_tick.tick() => {
                    let metrics = ping_sessions.get_player_metrics_snapshot();
                    if let Err(e) = ping_tx.send(TcpPacket::PlayerMetrics { players: metrics }).await {
                        tracing::debug!(player_id, "Player metrics send failed: {e}");
                        break;
                    }
                }
            }

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
        &plugins,
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
            Some(player_id),
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
#[allow(clippy::too_many_arguments)]
async fn receive_loop<R: AsyncReadExt + Unpin>(
    player_id: u32,
    reader: &mut R,
    sessions: &Arc<SessionManager>,
    world: &Arc<WorldState>,
    plugins: &Arc<PluginRuntime>,
    rate_limiters: &Arc<ServerRateLimiters>,
    log_chat: bool,
    max_cars: u32,
) -> Result<()> {
    let idle_timeout = Duration::from_secs(60); // 60-second idle timeout
    let mut last_activity = Instant::now();
    let mut component_diag_last = Instant::now();
    let component_diag_interval = Duration::from_secs(5);
    let mut diag_component_rx: u64 = 0;
    let mut diag_component_relay: u64 = 0;
    let mut diag_component_reject_owner: u64 = 0;
    let mut diag_component_reject_validation: u64 = 0;
    let mut diag_edit_rx: u64 = 0;
    let mut diag_reset_rx: u64 = 0;
    let mut diag_damage_rx: u64 = 0;
    let mut diag_electrics_rx: u64 = 0;
    let mut diag_pose_rx: u64 = 0;
    let mut diag_coupling_rx: u64 = 0;

    loop {
        if component_diag_last.elapsed() >= component_diag_interval {
            tracing::info!(
                player_id,
                component_rx = diag_component_rx,
                component_relay = diag_component_relay,
                reject_owner = diag_component_reject_owner,
                reject_validation = diag_component_reject_validation,
                edit_rx = diag_edit_rx,
                reset_rx = diag_reset_rx,
                damage_rx = diag_damage_rx,
                electrics_rx = diag_electrics_rx,
                pose_rx = diag_pose_rx,
                coupling_rx = diag_coupling_rx,
                world_vehicle_count = world.vehicle_count(),
                player_vehicle_count = world.vehicle_count_for_player(player_id),
                "TCP component diagnostics"
            );
            component_diag_last = Instant::now();
            diag_component_rx = 0;
            diag_component_relay = 0;
            diag_component_reject_owner = 0;
            diag_component_reject_validation = 0;
            diag_edit_rx = 0;
            diag_reset_rx = 0;
            diag_damage_rx = 0;
            diag_electrics_rx = 0;
            diag_pose_rx = 0;
            diag_coupling_rx = 0;
        }

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
            TcpPacket::VehicleSpawn {
                data,
                spawn_request_id,
                ..
            } => {
                let reject_spawn = |reason: &str| {
                    let sent = sessions.send_to_player(
                        player_id,
                        TcpPacket::VehicleSpawnRejected {
                            spawn_request_id,
                            reason: reason.to_string(),
                        },
                    );
                    if !sent {
                        tracing::debug!(player_id, "Failed to send VehicleSpawnRejected to player");
                    }
                };

                // Check spawn rate limit
                if !rate_limiters.check_spawn_limit(player_id).await {
                    tracing::warn!(player_id, "Vehicle spawn rate limit exceeded");
                    reject_spawn("spawn_rate_limited");
                    continue;
                }

                // Validate vehicle config size
                if let Err(e) = crate::validation::validate_vehicle_config_size(&data) {
                    tracing::warn!(player_id, error = %e, "VehicleSpawn rejected: invalid config");
                    reject_spawn("invalid_vehicle_config");
                    continue;
                }

                // Enforce MaxCarsPerPlayer
                let current_count = world.vehicle_count_for_player(player_id);
                if current_count >= max_cars {
                    tracing::warn!(
                        player_id,
                        current_count,
                        max_cars,
                        "MaxCarsPerPlayer limit reached"
                    );
                    reject_spawn("max_cars_reached");
                    continue;
                }

                if let Some(reason) = plugins.dispatch_event(&PluginEvent::VehicleSpawn {
                    player_id,
                    data: data.clone(),
                }) {
                    tracing::warn!(player_id, reason = %reason, "VehicleSpawn blocked by plugin");
                    reject_spawn("blocked_by_plugin");
                    continue;
                }

                let vid = world.spawn_vehicle(player_id, data.clone());
                // Step 1: Confirm to the spawner first so they learn the
                // server-assigned vehicle_id before anyone else sends updates.
                sessions.send_to_player(
                    player_id,
                    TcpPacket::VehicleSpawn {
                        player_id: Some(player_id),
                        vehicle_id: vid,
                        data: data.clone(),
                        spawn_request_id,
                    },
                );
                // Step 2: Broadcast to all other players.
                sessions.broadcast(
                    TcpPacket::VehicleSpawn {
                        player_id: Some(player_id),
                        vehicle_id: vid,
                        data,
                        spawn_request_id,
                    },
                    Some(player_id),
                );
            }
            TcpPacket::VehicleEdit {
                vehicle_id, data, ..
            } => {
                diag_component_rx += 1;
                diag_edit_rx += 1;
                // Validate vehicle ID and config
                if let Err(e) = crate::validation::validate_vehicle_id(vehicle_id) {
                    diag_component_reject_validation += 1;
                    tracing::warn!(player_id, video_id = vehicle_id, error = %e, "VehicleEdit: invalid vehicle ID");
                    continue;
                }
                if let Err(e) = crate::validation::validate_vehicle_config_size(&data) {
                    diag_component_reject_validation += 1;
                    tracing::warn!(player_id, error = %e, "VehicleEdit: invalid config");
                    continue;
                }

                if world.is_owner(player_id, vehicle_id) {
                    let payload_bytes = data.len();
                    world.update_config(player_id, vehicle_id, data.clone());
                    sessions.broadcast(
                        TcpPacket::VehicleEdit {
                            player_id: Some(player_id),
                            vehicle_id,
                            data,
                        },
                        Some(player_id),
                    );
                    diag_component_relay += 1;
                    tracing::debug!(player_id, vehicle_id, payload_bytes, "Relayed VehicleEdit");
                } else {
                    diag_component_reject_owner += 1;
                    tracing::warn!(
                        player_id,
                        vehicle_id,
                        player_vehicle_count = world.vehicle_count_for_player(player_id),
                        world_vehicle_count = world.vehicle_count(),
                        "VehicleEdit for unowned vehicle"
                    );
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
                diag_component_rx += 1;
                diag_reset_rx += 1;
                if let Err(e) = crate::validation::validate_vehicle_id(vehicle_id) {
                    diag_component_reject_validation += 1;
                    tracing::warn!(player_id, vehicle_id, error = %e, "VehicleReset: invalid vehicle ID");
                    continue;
                }
                if let Err(e) = crate::validation::validate_vehicle_config_size(&data) {
                    diag_component_reject_validation += 1;
                    tracing::warn!(player_id, error = %e, "VehicleReset: invalid config");
                    continue;
                }

                if world.is_owner(player_id, vehicle_id) {
                    let payload_bytes = data.len();
                    world.update_reset_position(player_id, vehicle_id, &data);
                    sessions.broadcast(
                        TcpPacket::VehicleReset {
                            player_id: Some(player_id),
                            vehicle_id,
                            data,
                        },
                        Some(player_id),
                    );
                    diag_component_relay += 1;
                    tracing::debug!(player_id, vehicle_id, payload_bytes, "Relayed VehicleReset");
                } else {
                    diag_component_reject_owner += 1;
                    tracing::warn!(
                        player_id,
                        vehicle_id,
                        player_vehicle_count = world.vehicle_count_for_player(player_id),
                        world_vehicle_count = world.vehicle_count(),
                        "VehicleReset for unowned vehicle"
                    );
                }
            }
            TcpPacket::VehicleDamage {
                vehicle_id, data, ..
            } => {
                diag_component_rx += 1;
                diag_damage_rx += 1;
                if let Err(e) = crate::validation::validate_vehicle_id(vehicle_id) {
                    diag_component_reject_validation += 1;
                    tracing::warn!(player_id, vehicle_id, error = %e, "VehicleDamage: invalid vehicle ID");
                    continue;
                }
                if let Err(e) = crate::validation::validate_vehicle_config_size(&data) {
                    diag_component_reject_validation += 1;
                    tracing::warn!(player_id, error = %e, "VehicleDamage: invalid payload");
                    continue;
                }

                if world.is_owner(player_id, vehicle_id) {
                    let payload_bytes = data.len();
                    sessions.broadcast(
                        TcpPacket::VehicleDamage {
                            player_id: Some(player_id),
                            vehicle_id,
                            data,
                        },
                        Some(player_id),
                    );
                    diag_component_relay += 1;
                    tracing::debug!(
                        player_id,
                        vehicle_id,
                        payload_bytes,
                        "Relayed VehicleDamage"
                    );
                } else {
                    diag_component_reject_owner += 1;
                    tracing::warn!(
                        player_id,
                        vehicle_id,
                        player_vehicle_count = world.vehicle_count_for_player(player_id),
                        world_vehicle_count = world.vehicle_count(),
                        "VehicleDamage for unowned vehicle"
                    );
                }
            }
            TcpPacket::VehicleElectrics {
                vehicle_id, data, ..
            } => {
                diag_component_rx += 1;
                diag_electrics_rx += 1;
                if let Err(e) = crate::validation::validate_vehicle_id(vehicle_id) {
                    diag_component_reject_validation += 1;
                    tracing::warn!(player_id, vehicle_id, error = %e, "VehicleElectrics: invalid vehicle ID");
                    continue;
                }
                if let Err(e) = crate::validation::validate_vehicle_config_size(&data) {
                    diag_component_reject_validation += 1;
                    tracing::warn!(player_id, error = %e, "VehicleElectrics: invalid payload");
                    continue;
                }

                if world.is_owner(player_id, vehicle_id) {
                    let payload_bytes = data.len();
                    sessions.broadcast(
                        TcpPacket::VehicleElectrics {
                            player_id: Some(player_id),
                            vehicle_id,
                            data,
                        },
                        Some(player_id),
                    );
                    diag_component_relay += 1;
                    tracing::debug!(
                        player_id,
                        vehicle_id,
                        payload_bytes,
                        "Relayed VehicleElectrics"
                    );
                } else {
                    diag_component_reject_owner += 1;
                    tracing::warn!(
                        player_id,
                        vehicle_id,
                        player_vehicle_count = world.vehicle_count_for_player(player_id),
                        world_vehicle_count = world.vehicle_count(),
                        "VehicleElectrics for unowned vehicle"
                    );
                }
            }
            TcpPacket::VehicleInputs {
                vehicle_id, data, ..
            } => {
                diag_component_rx += 1;
                if let Err(e) = crate::validation::validate_vehicle_id(vehicle_id) {
                    diag_component_reject_validation += 1;
                    tracing::warn!(player_id, vehicle_id, error = %e, "VehicleInputs: invalid vehicle ID");
                    continue;
                }
                if let Err(e) = crate::validation::validate_vehicle_config_size(&data) {
                    diag_component_reject_validation += 1;
                    tracing::warn!(player_id, error = %e, "VehicleInputs: invalid payload");
                    continue;
                }

                if world.is_owner(player_id, vehicle_id) {
                    sessions.broadcast(
                        TcpPacket::VehicleInputs {
                            player_id: Some(player_id),
                            vehicle_id,
                            data,
                        },
                        Some(player_id),
                    );
                    diag_component_relay += 1;
                } else {
                    diag_component_reject_owner += 1;
                    tracing::warn!(
                        player_id,
                        vehicle_id,
                        player_vehicle_count = world.vehicle_count_for_player(player_id),
                        world_vehicle_count = world.vehicle_count(),
                        "VehicleInputs for unowned vehicle"
                    );
                }
            }
            TcpPacket::VehiclePowertrain {
                vehicle_id, data, ..
            } => {
                diag_component_rx += 1;
                if let Err(e) = crate::validation::validate_vehicle_id(vehicle_id) {
                    diag_component_reject_validation += 1;
                    tracing::warn!(player_id, vehicle_id, error = %e, "VehiclePowertrain: invalid vehicle ID");
                    continue;
                }
                if let Err(e) = crate::validation::validate_vehicle_config_size(&data) {
                    diag_component_reject_validation += 1;
                    tracing::warn!(player_id, error = %e, "VehiclePowertrain: invalid payload");
                    continue;
                }

                if world.is_owner(player_id, vehicle_id) {
                    sessions.broadcast(
                        TcpPacket::VehiclePowertrain {
                            player_id: Some(player_id),
                            vehicle_id,
                            data,
                        },
                        Some(player_id),
                    );
                    diag_component_relay += 1;
                } else {
                    diag_component_reject_owner += 1;
                    tracing::warn!(
                        player_id,
                        vehicle_id,
                        player_vehicle_count = world.vehicle_count_for_player(player_id),
                        world_vehicle_count = world.vehicle_count(),
                        "VehiclePowertrain for unowned vehicle"
                    );
                }
            }
            TcpPacket::VehiclePose {
                vehicle_id, data, ..
            } => {
                diag_component_rx += 1;
                diag_pose_rx += 1;
                if let Err(e) = crate::validation::validate_vehicle_id(vehicle_id) {
                    diag_component_reject_validation += 1;
                    tracing::warn!(player_id, vehicle_id, error = %e, "VehiclePose: invalid vehicle ID");
                    continue;
                }
                if let Err(e) = crate::validation::validate_vehicle_config_size(&data) {
                    diag_component_reject_validation += 1;
                    tracing::warn!(player_id, error = %e, "VehiclePose: invalid payload");
                    continue;
                }

                if world.is_owner(player_id, vehicle_id) {
                    if let Ok(val) = serde_json::from_str::<serde_json::Value>(&data) {
                        let pos_arr = val.get("pos").and_then(|v| v.as_array());
                        let rot_arr = val.get("rot").and_then(|v| v.as_array());
                        let vel_arr = val.get("vel").and_then(|v| v.as_array());
                        if let (Some(pos), Some(rot), Some(vel)) = (pos_arr, rot_arr, vel_arr) {
                            if pos.len() >= 3 && rot.len() >= 4 && vel.len() >= 3 {
                                if let (
                                    Some(px),
                                    Some(py),
                                    Some(pz),
                                    Some(rx),
                                    Some(ry),
                                    Some(rz),
                                    Some(rw),
                                    Some(vx),
                                    Some(vy),
                                    Some(vz),
                                ) = (
                                    pos[0].as_f64(),
                                    pos[1].as_f64(),
                                    pos[2].as_f64(),
                                    rot[0].as_f64(),
                                    rot[1].as_f64(),
                                    rot[2].as_f64(),
                                    rot[3].as_f64(),
                                    vel[0].as_f64(),
                                    vel[1].as_f64(),
                                    vel[2].as_f64(),
                                ) {
                                    world.update_position(
                                        player_id,
                                        vehicle_id,
                                        [px as f32, py as f32, pz as f32],
                                        [rx as f32, ry as f32, rz as f32, rw as f32],
                                        [vx as f32, vy as f32, vz as f32],
                                    );
                                }
                            }
                        }
                    }

                    sessions.broadcast(
                        TcpPacket::VehiclePose {
                            player_id: Some(player_id),
                            vehicle_id,
                            data,
                        },
                        Some(player_id),
                    );
                    diag_component_relay += 1;
                } else {
                    diag_component_reject_owner += 1;
                    tracing::warn!(
                        player_id,
                        vehicle_id,
                        player_vehicle_count = world.vehicle_count_for_player(player_id),
                        world_vehicle_count = world.vehicle_count(),
                        "VehiclePose for unowned vehicle"
                    );
                }
            }
            TcpPacket::VehicleCoupling {
                vehicle_id,
                target_vehicle_id,
                coupled,
                node_id,
                target_node_id,
                ..
            } => {
                diag_component_rx += 1;
                diag_coupling_rx += 1;
                if let Err(e) = crate::validation::validate_vehicle_id(vehicle_id) {
                    diag_component_reject_validation += 1;
                    tracing::warn!(player_id, vehicle_id, error = %e, "VehicleCoupling: invalid vehicle ID");
                    continue;
                }
                if let Err(e) = crate::validation::validate_vehicle_id(target_vehicle_id) {
                    diag_component_reject_validation += 1;
                    tracing::warn!(player_id, target_vehicle_id, error = %e, "VehicleCoupling: invalid target vehicle ID");
                    continue;
                }

                if world.is_owner(player_id, vehicle_id) {
                    sessions.broadcast(
                        TcpPacket::VehicleCoupling {
                            player_id: Some(player_id),
                            vehicle_id,
                            target_vehicle_id,
                            coupled,
                            node_id,
                            target_node_id,
                        },
                        Some(player_id),
                    );
                    diag_component_relay += 1;
                } else {
                    diag_component_reject_owner += 1;
                    tracing::warn!(
                        player_id,
                        vehicle_id,
                        player_vehicle_count = world.vehicle_count_for_player(player_id),
                        world_vehicle_count = world.vehicle_count(),
                        "VehicleCoupling for unowned vehicle"
                    );
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
                        if let Some(reason) = plugins.dispatch_event(&PluginEvent::ChatMessage {
                            player_id,
                            text: validated_text.clone(),
                        }) {
                            tracing::warn!(player_id, reason = %reason, "ChatMessage blocked by plugin");
                            continue;
                        }

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

                    // RTT is only valid for the most recent ping sequence.
                    if player.last_ping_seq_sent == Some(seq) {
                        if let Some(sent_at) = player.last_ping_sent_at {
                            let rtt_ms = sent_at.elapsed().as_millis().min(5_000) as u32;
                            player.ping_ms = Some(match player.ping_ms {
                                Some(prev) => ((prev * 3) + rtt_ms) / 4,
                                None => rtt_ms,
                            });
                        }
                    }
                    tracing::debug!(player_id, seq, "Pong received");
                } else {
                    tracing::warn!(player_id, "PingPong from unknown player");
                }
            }
            TcpPacket::TriggerServerEvent { name, payload } => {
                if let Some(reason) = plugins.dispatch_event(&PluginEvent::ClientEvent {
                    player_id,
                    name,
                    payload,
                }) {
                    tracing::warn!(player_id, reason = %reason, "TriggerServerEvent blocked by plugin");
                }
            }
            other => {
                tracing::debug!(player_id, ?other, "Unhandled packet");
            }
        }
    }
}

// ── Wire helpers ─────────────────────────────────────────────────────

/// Write a packet to any AsyncWrite type (works with both TcpStream and TlsStream)
async fn write_packet_generic<W: AsyncWriteExt + Unpin>(
    writer: &mut W,
    packet: &TcpPacket,
) -> Result<()> {
    let data = packet::encode(packet)?;
    writer.write_all(&data).await?;
    writer.flush().await?;
    if let Some(metrics) = metrics::global() {
        metrics.record_tcp_tx();
    }
    Ok(())
}

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
    if let Some(metrics) = metrics::global() {
        metrics.record_tcp_rx();
    }
    packet::decode(&payload)
}

/// Write a packet to a TcpStream.
async fn write_packet(stream: &mut TcpStream, packet: &TcpPacket) -> Result<()> {
    let data = packet::encode(packet)?;
    stream.write_all(&data).await?;
    stream.flush().await?;
    if let Some(metrics) = metrics::global() {
        metrics.record_tcp_tx();
    }
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
    if let Some(metrics) = metrics::global() {
        metrics.record_tcp_tx();
    }
    Ok(())
}
