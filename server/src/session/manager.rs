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

#[derive(Debug, Clone)]
pub struct PlayerAdminSnapshot {
    pub player_id: u32,
    pub name: String,
    pub addr: SocketAddr,
    pub connected_secs: u64,
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

        // Generate a session token with collision retry (iterative, bounded).
        const MAX_TOKEN_ATTEMPTS: u32 = 5;
        let mut token = String::new();
        let mut session_hash = [0u8; 16];

        for attempt in 1..=MAX_TOKEN_ATTEMPTS {
            token = {
                let mut rng = rand::thread_rng();
                let mut bytes = [0u8; 64];
                use rand::RngCore;
                rng.fill_bytes(&mut bytes);
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

            session_hash = compute_session_hash(&token);

            if !self.session_hashes.contains_key(&session_hash) {
                break;
            }

            tracing::warn!(
                attempt,
                "Session hash collision detected (extremely rare), retrying..."
            );
            if attempt == MAX_TOKEN_ATTEMPTS {
                bail!(
                    "Failed to generate unique session token after {MAX_TOKEN_ATTEMPTS} attempts"
                );
            }
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

    pub fn get_player_admin_snapshot(&self) -> Vec<PlayerAdminSnapshot> {
        self.players
            .iter()
            .map(|entry| {
                let p = entry.value();
                PlayerAdminSnapshot {
                    player_id: p.id,
                    name: p.name.clone(),
                    addr: p.addr,
                    connected_secs: p.connected_at.elapsed().as_secs(),
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

    /// Broadcast a UDP packet to all players except the sender, but skip
    /// players whose centroid is farther than `lod_distance` from `sender_pos`.
    /// `get_centroid` resolves a player_id to their centroid position.
    pub async fn broadcast_udp_lod(
        &self,
        socket: &UdpSocket,
        data: &[u8],
        exclude: u32,
        sender_pos: [f32; 3],
        lod_distance_sq: f32,
        get_centroid: impl Fn(u32) -> Option<[f32; 3]>,
    ) {
        for entry in self.players.iter() {
            let player = entry.value();
            if player.id == exclude {
                continue;
            }
            if let Some(addr) = player.udp_addr {
                // Distance check: skip if receiver is too far
                if let Some(recv_pos) = get_centroid(player.id) {
                    let dx = sender_pos[0] - recv_pos[0];
                    let dy = sender_pos[1] - recv_pos[1];
                    let dz = sender_pos[2] - recv_pos[2];
                    let dist_sq = dx * dx + dy * dy + dz * dz;
                    if dist_sq > lod_distance_sq {
                        continue;
                    }
                }
                if let Err(e) = socket.send_to(data, addr).await {
                    tracing::warn!(player_id = player.id, %addr, "UDP send failed: {e}");
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rapid_connect_disconnect_cycles() {
        let manager = SessionManager::new();
        let addr: SocketAddr = "127.0.0.1:18860".parse().expect("valid socket addr");

        let mut ids = Vec::new();
        for i in 0..500 {
            let (tx, _rx) = mpsc::channel(8);
            let username = format!("player_{i}");
            let (player_id, _token) = manager
                .add_player(username, addr, tx)
                .expect("add player should succeed");
            ids.push(player_id);

            assert_eq!(manager.player_count(), 1);
            manager.remove_player(player_id);
            assert_eq!(manager.player_count(), 0);
        }

        for win in ids.windows(2) {
            assert!(win[1] > win[0], "player IDs should increase monotonically");
        }
    }

    #[test]
    fn test_session_cleanup_after_bulk_disconnect() {
        let manager = SessionManager::new();
        let addr: SocketAddr = "127.0.0.1:18861".parse().expect("valid socket addr");

        let mut player_ids = Vec::new();
        for i in 0..100 {
            let (tx, _rx) = mpsc::channel(8);
            let (player_id, token) = manager
                .add_player(format!("bulk_{i}"), addr, tx)
                .expect("add player should succeed");
            player_ids.push((player_id, token));
        }

        assert_eq!(manager.player_count(), 100);

        for (player_id, token) in &player_ids {
            let hash = compute_session_hash(token);
            assert_eq!(manager.lookup_by_hash(&hash), Some(*player_id));
        }

        for (player_id, token) in player_ids {
            manager.remove_player(player_id);
            let hash = compute_session_hash(&token);
            assert_eq!(manager.lookup_by_hash(&hash), None);
        }

        assert_eq!(manager.player_count(), 0);
    }
}
