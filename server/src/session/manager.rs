use std::net::SocketAddr;
use std::sync::atomic::{AtomicU32, Ordering};

use dashmap::DashMap;
use tokio::sync::mpsc;
use tokio::time::Instant;

use crate::net::packet::TcpPacket;

use super::player::Player;

/// Thread-safe session manager. Tracks all connected players.
pub struct SessionManager {
    players: DashMap<u32, Player>,
    token_map: DashMap<String, u32>,
    next_id: AtomicU32,
}

impl SessionManager {
    pub fn new() -> Self {
        Self {
            players: DashMap::new(),
            token_map: DashMap::new(),
            next_id: AtomicU32::new(1),
        }
    }

    /// Register a new player. Returns `(player_id, session_token)`.
    pub fn add_player(
        &self,
        name: String,
        addr: SocketAddr,
        tcp_tx: mpsc::Sender<TcpPacket>,
    ) -> (u32, String) {
        let player_id = self.next_id.fetch_add(1, Ordering::Relaxed);

        // Generate a session token: 32 random bytes, hex-encoded
        let token: String = {
            let mut rng = rand::thread_rng();
            let bytes: [u8; 32] = rand::Rng::gen(&mut rng);
            bytes.iter().map(|b| format!("{b:02x}")).collect()
        };

        let now = Instant::now();
        let player = Player {
            id: player_id,
            name,
            session_token: token.clone(),
            addr,
            tcp_tx,
            connected_at: now,
            last_activity: now,
        };

        self.token_map.insert(token.clone(), player_id);
        self.players.insert(player_id, player);

        (player_id, token)
    }

    /// Remove a player by ID.
    pub fn remove_player(&self, player_id: u32) {
        if let Some((_, player)) = self.players.remove(&player_id) {
            self.token_map.remove(&player.session_token);
            tracing::debug!(player_id, name = %player.name, "Removed from session manager");
        }
    }

    /// Look up a player by ID.
    pub fn get_player(&self, player_id: u32) -> Option<dashmap::mapref::one::Ref<'_, u32, Player>> {
        self.players.get(&player_id)
    }

    /// Current number of connected players.
    pub fn player_count(&self) -> usize {
        self.players.len()
    }

    /// Send a packet to all connected players, optionally excluding one.
    pub fn broadcast(&self, packet: TcpPacket, exclude: Option<u32>) {
        for entry in self.players.iter() {
            let player = entry.value();
            if Some(player.id) == exclude {
                continue;
            }
            // Use try_send to avoid blocking — if a player's channel is full,
            // drop the packet (they may be slow/disconnecting).
            if let Err(e) = player.tcp_tx.try_send(packet.clone()) {
                tracing::warn!(player_id = player.id, "Broadcast send failed: {e}");
            }
        }
    }
}
