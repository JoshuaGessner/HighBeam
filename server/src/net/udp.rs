use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use serde::Serialize;
use tokio::net::UdpSocket;
use tokio::time::Instant;

use crate::control::ControlPlane;
use crate::metrics;
use crate::net::packet::PROTOCOL_VERSION;
use crate::session::manager::SessionManager;
use crate::state::world::WorldState;

const DISCOVERY_QUERY_PACKET: u8 = 0x7A;

#[derive(Serialize)]
struct DiscoveryResponse {
    name: String,
    map: String,
    players: usize,
    max_players: u32,
    port: u16,
    protocol_version: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    mod_sync_port: Option<u16>,
}

/// Start the UDP receiver loop. Runs forever, routing packets between players.
pub async fn start_udp(
    port: u16,
    tick_rate: u32,
    control: Arc<ControlPlane>,
    sessions: Arc<SessionManager>,
    world: Arc<WorldState>,
) -> Result<()> {
    let addr = format!("0.0.0.0:{port}");
    let socket = UdpSocket::bind(&addr)
        .await
        .with_context(|| format!("Failed to bind UDP socket on {addr}"))?;

    tracing::info!(port, "UDP socket bound");

    let mut buf = vec![0u8; 65535];
    let relay_interval = Duration::from_secs_f64(1.0 / tick_rate.max(1) as f64);
    let mut last_relay_at = std::collections::HashMap::<u32, Instant>::new();

    // Per-source-IP rate limiting for unauthenticated discovery queries.
    // Prevents UDP amplification: a 1-byte query yields ~250 bytes in response.
    let mut disc_rate: std::collections::HashMap<std::net::IpAddr, (u32, Instant)> =
        std::collections::HashMap::new();
    const DISC_RATE_MAX: u32 = 5;
    let disc_rate_window = Duration::from_secs(60);
    let disc_rate_prune_interval = Duration::from_secs(120);
    let mut disc_rate_last_prune = Instant::now();

    // Cached serialised discovery response; rebuilt at most once per 5 s.
    // Avoids taking the ControlPlane snapshot lock on every inbound query.
    let mut disc_cache: Option<(Vec<u8>, Instant)> = None;
    let disc_cache_ttl = Duration::from_secs(5);

    loop {
        let (len, addr) = socket.recv_from(&mut buf).await?;
        if let Some(metrics) = metrics::global() {
            metrics.record_udp_rx();
        }

        // Unauthenticated server discovery query.
        if len >= 1 && buf[0] == DISCOVERY_QUERY_PACKET {
            let now = Instant::now();
            let src_ip = addr.ip();

            // Rate-limit: allow at most DISC_RATE_MAX queries per disc_rate_window per IP.
            let allowed = {
                let entry = disc_rate.entry(src_ip).or_insert((0, now));
                if now.duration_since(entry.1) > disc_rate_window {
                    *entry = (1, now);
                    true
                } else if entry.0 < DISC_RATE_MAX {
                    entry.0 += 1;
                    true
                } else {
                    false
                }
            };
            if !allowed {
                tracing::debug!(%addr, "Discovery rate limit exceeded; dropping query");
                continue;
            }

            // Prune stale entries periodically to keep disc_rate memory bounded.
            if now.duration_since(disc_rate_last_prune) >= disc_rate_prune_interval {
                disc_rate.retain(|_, (_, ts)| now.duration_since(*ts) < disc_rate_window);
                disc_rate_last_prune = now;
            }

            // Serve from cache; rebuild only when the cached snapshot is stale.
            let data = match &disc_cache {
                Some((cached, ts)) if now.duration_since(*ts) < disc_cache_ttl => cached.clone(),
                _ => {
                    let snap = control.snapshot();
                    let payload = DiscoveryResponse {
                        name: snap.server_name,
                        map: snap.map_display_name,
                        players: snap.player_count,
                        max_players: snap.max_players,
                        port: snap.port,
                        protocol_version: PROTOCOL_VERSION,
                        mod_sync_port: control.active_mod_sync_port(),
                    };
                    let bytes = serde_json::to_vec(&payload).unwrap_or_default();
                    disc_cache = Some((bytes.clone(), now));
                    bytes
                }
            };

            if !data.is_empty() {
                let _ = socket.send_to(&data, addr).await;
            }
            continue;
        }

        // Minimum packet: 16-byte session hash + 1-byte type
        if len < 17 {
            continue;
        }

        let session_hash: [u8; 16] = match buf[..16].try_into() {
            Ok(h) => h,
            Err(_) => continue,
        };
        let packet_type = buf[16];

        // Validate session
        let player_id = match sessions.lookup_by_hash(&session_hash) {
            Some(id) => id,
            None => continue, // Silently drop unknown sessions
        };

        match packet_type {
            // UdpBind: register this addr for the player
            0x01 => {
                sessions.register_udp_addr(player_id, addr);
            }

            // Position update (0x10)
            // Client sends 63 bytes: [16B hash][0x10][2B vid][12B pos][16B rot][12B vel][4B time]
            // Server relays 65 bytes: [16B hash][0x10][2B pid][2B vid][12B pos][16B rot][12B vel][4B time]
            0x10 => {
                if len < 63 {
                    continue;
                }

                // Extract vehicle_id and position data for world state tracking
                let vid = u16::from_le_bytes([buf[17], buf[18]]);

                // Parse position, rotation, velocity from the binary payload
                let pos = read_f32x3(&buf[19..31]);
                let rot = read_f32x4(&buf[31..47]);
                let vel = read_f32x3(&buf[47..59]);

                if !all_finite3(&pos) || !all_finite4(&rot) || !all_finite3(&vel) {
                    tracing::debug!(player_id, vid, "Dropping non-finite UDP position payload");
                    continue;
                }

                // Update world state
                world.update_position(player_id, vid, pos, rot, vel);

                let now = Instant::now();
                let should_relay = last_relay_at
                    .get(&player_id)
                    .map(|last| now.duration_since(*last) >= relay_interval)
                    .unwrap_or(true);

                if !should_relay {
                    continue;
                }
                last_relay_at.insert(player_id, now);

                // Build relay packet: insert player_id (u16 LE) after type byte
                let mut relay = Vec::with_capacity(65);
                relay.extend_from_slice(&buf[..17]); // hash + type
                relay.extend_from_slice(&(player_id as u16).to_le_bytes()); // pid
                relay.extend_from_slice(&buf[17..len]); // vid + pos + rot + vel + time

                // Relay to all other players' registered UDP addresses
                let relay_targets = sessions.player_count().saturating_sub(1) as u64;
                if let Some(metrics) = metrics::global() {
                    metrics.record_udp_tx(relay_targets);
                }

                // Use distance-based LOD: skip relaying to players > 1000m away
                const LOD_DISTANCE: f32 = 1000.0;
                let lod_distance_sq = LOD_DISTANCE * LOD_DISTANCE;
                let world_ref = &world;
                sessions
                    .broadcast_udp_lod(&socket, &relay, player_id, pos, lod_distance_sq, |pid| {
                        world_ref.player_centroid(pid)
                    })
                    .await;
            }

            _ => { /* Unknown type, ignore */ }
        }
    }
}

/// Read 3 consecutive f32 values from a byte slice (little-endian).
fn read_f32x3(data: &[u8]) -> [f32; 3] {
    [
        f32::from_le_bytes([data[0], data[1], data[2], data[3]]),
        f32::from_le_bytes([data[4], data[5], data[6], data[7]]),
        f32::from_le_bytes([data[8], data[9], data[10], data[11]]),
    ]
}

/// Read 4 consecutive f32 values from a byte slice (little-endian).
fn read_f32x4(data: &[u8]) -> [f32; 4] {
    [
        f32::from_le_bytes([data[0], data[1], data[2], data[3]]),
        f32::from_le_bytes([data[4], data[5], data[6], data[7]]),
        f32::from_le_bytes([data[8], data[9], data[10], data[11]]),
        f32::from_le_bytes([data[12], data[13], data[14], data[15]]),
    ]
}

fn all_finite3(values: &[f32; 3]) -> bool {
    values.iter().all(|v| v.is_finite())
}

fn all_finite4(values: &[f32; 4]) -> bool {
    values.iter().all(|v| v.is_finite())
}
