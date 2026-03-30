use std::sync::Arc;

use anyhow::{Context, Result};
use tokio::net::UdpSocket;

use crate::session::manager::SessionManager;
use crate::state::world::WorldState;

/// Start the UDP receiver loop. Runs forever, routing packets between players.
pub async fn start_udp(
    port: u16,
    sessions: Arc<SessionManager>,
    world: Arc<WorldState>,
) -> Result<()> {
    let addr = format!("0.0.0.0:{port}");
    let socket = UdpSocket::bind(&addr)
        .await
        .with_context(|| format!("Failed to bind UDP socket on {addr}"))?;

    tracing::info!(port, "UDP socket bound");

    let mut buf = vec![0u8; 65535];
    loop {
        let (len, addr) = socket.recv_from(&mut buf).await?;

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

                // Update world state
                world.update_position(player_id, vid, pos, rot, vel);

                // Build relay packet: insert player_id (u16 LE) after type byte
                let mut relay = Vec::with_capacity(65);
                relay.extend_from_slice(&buf[..17]); // hash + type
                relay.extend_from_slice(&(player_id as u16).to_le_bytes()); // pid
                relay.extend_from_slice(&buf[17..len]); // vid + pos + rot + vel + time

                // Relay to all other players' registered UDP addresses
                sessions
                    .broadcast_udp(&socket, &relay, Some(player_id))
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
