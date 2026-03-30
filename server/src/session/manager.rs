use std::net::SocketAddr;
use std::sync::atomic::{AtomicU32, Ordering};

use anyhow::{bail, Result};
use dashmap::DashMap;
use sha2::{Digest, Sha256};
use tokio::net::UdpSocket;
use tokio::sync::mpsc;
use tokio::time::Instant;

use crate::net::packet::{PlayerInfo, TcpPacket};

use super::player::Player;

/// Thread-safe session manager. Tracks all connected players.
pub struct SessionManager {
    players: DashMap<u32, Player>,
    token_map: DashMap<String, u32>,
    /// Truncated SHA-256 of session token → player_id (for UDP authentication).
    session_hashes: DashMap<[u8; 16], u32>,
    next_id: AtomicU32,
}

/// Compute the 16-byte session hash from a session token.
fn compute_session_hash(token: &str) -> [u8; 16] {
    let digest = Sha256::digest(token.as_bytes());
    let mut hash = [0u8; 16];
    hash.copy_from_slice(&digest[..16]);
    hash
}

impl SessionManager {
    pub fn new() -> Self {
        Self {
            players: DashMap::new(),
            token_map: DashMap::new(),
            session_hashes: DashMap::new(),
            next_id: AtomicU32::new(1),
        }
    }

    /// Register a new player. Returns `(player_id, session_token)`.
    pub fn add_player(
        &self,
        name: String,
        addr: SocketAddr,
        tcp_tx: mpsc::Sender<TcpPacket>,
    ) -> Result<(u32, String)> {
        let trimmed_name = name.trim();
        if trimmed_name.is_empty() {
            tracing::warn!(%addr, "Rejected player with empty username at session creation");
            bail!("Username cannot be empty");
        }

        let player_id = self.next_id.fetch_add(1, Ordering::Relaxed);

        // Generate a session token: 64 random bytes, hex-encoded (extra entropy for uniqueness)
        let token: String = {
            let mut rng = rand::thread_rng();
            let mut bytes = [0u8; 64];
            use rand::RngCore;
            rng.fill_bytes(&mut bytes);
            // Include timestamp to further reduce collision risk
            let timestamp = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos();
            format!(
                "{:x}:{}",
                timestamp,
                bytes.iter().map(|b| format!("{b:02x}")).collect::<String>()
            )
        };

        let session_hash = compute_session_hash(&token);

        // Verify collision didn't occur (paranoia check)
        if self.session_hashes.contains_key(&session_hash) {
            tracing::warn!("Session hash collision detected (extremely rare), retrying...");
            // In the extremely unlikely event of a collision, recursively retry.
            return self.add_player(trimmed_name.to_string(), addr, tcp_tx);
        }

        let now = Instant::now();
        let player = Player {
            id: player_id,
            name: trimmed_name.to_string(),
            session_token: token.clone(),
            addr,
            tcp_tx,
            udp_addr: None,
            session_hash,
            connected_at: now,
            last_activity: now,
            last_pong_time: now, // Initialize pong time (Phase 2.2)
        };

        self.session_hashes.insert(session_hash, player_id);
        self.token_map.insert(token.clone(), player_id);
        self.players.insert(player_id, player);

        Ok((player_id, token))
    }

    /// Remove a player by ID.
    pub fn remove_player(&self, player_id: u32) {
        if let Some((_, player)) = self.players.remove(&player_id) {
            self.token_map.remove(&player.session_token);
            self.session_hashes.remove(&player.session_hash);
            tracing::debug!(player_id, name = %player.name, "Removed from session manager");
        }
    }

    /// Look up a player by ID.
    pub fn get_player(&self, player_id: u32) -> Option<dashmap::mapref::one::Ref<'_, u32, Player>> {
        self.players.get(&player_id)
    }

    /// Look up a player by ID (mutable), for updating player state (Phase 2.2).
    pub fn get_player_mut(
        &self,
        player_id: u32,
    ) -> Option<dashmap::mapref::one::RefMut<'_, u32, Player>> {
        self.players.get_mut(&player_id)
    }

    /// Look up a player_id by the 16-byte session hash (for UDP authentication).
    pub fn lookup_by_hash(&self, hash: &[u8; 16]) -> Option<u32> {
        self.session_hashes.get(hash).map(|r| *r.value())
    }

    /// Register a UDP address for a player (called when UdpBind is received).
    pub fn register_udp_addr(&self, player_id: u32, addr: SocketAddr) {
        if let Some(mut entry) = self.players.get_mut(&player_id) {
            entry.udp_addr = Some(addr);
            tracing::info!(player_id, %addr, "UDP address registered");
        }
    }

    /// Current number of connected players.
    pub fn player_count(&self) -> usize {
        self.players.len()
    }

    /// Get a snapshot of all connected players (for WorldState).
    pub fn get_player_snapshot(&self) -> Vec<PlayerInfo> {
        self.players
            .iter()
            .map(|entry| {
                let p = entry.value();
                PlayerInfo {
                    player_id: p.id,
                    name: p.name.clone(),
                }
            })
            .collect()
    }

    /// Send a TCP packet to all connected players, optionally excluding one.
    pub fn broadcast(&self, packet: TcpPacket, exclude: Option<u32>) {
        for entry in self.players.iter() {
            let player = entry.value();
            if Some(player.id) == exclude {
                continue;
            }
            if let Err(e) = player.tcp_tx.try_send(packet.clone()) {
                tracing::warn!(player_id = player.id, "Broadcast send failed: {e}");
            }
        }
    }

    /// Send a TCP packet to a single player by id.
    pub fn send_to_player(&self, player_id: u32, packet: TcpPacket) -> bool {
        let Some(player) = self.players.get(&player_id) else {
            return false;
        };
        player.tcp_tx.try_send(packet).is_ok()
    }

    /// Broadcast a UDP packet to all players with registered UDP addresses, optionally excluding one.
    pub async fn broadcast_udp(&self, socket: &UdpSocket, data: &[u8], exclude: Option<u32>) {
        for entry in self.players.iter() {
            let player = entry.value();
            if Some(player.id) == exclude {
                continue;
            }
            if let Some(addr) = player.udp_addr {
                if let Err(e) = socket.send_to(data, addr).await {
                    tracing::warn!(player_id = player.id, %addr, "UDP send failed: {e}");
                }
            }
        }
    }
}
