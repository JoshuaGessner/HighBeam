use std::net::SocketAddr;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::time::Duration;

use dashmap::DashMap;
use sha2::{Digest, Sha256};
use tokio::net::UdpSocket;
use tokio::sync::mpsc;
use tokio::task::JoinSet;
use tokio::time::{timeout, Instant};

use crate::net::packet::{PlayerInfo, PlayerPingInfo, TcpPacket};

use super::player::Player;

/// Error returned when a new player cannot be admitted.
#[derive(Debug)]
pub enum AddPlayerError {
    /// The server is at capacity (`MaxPlayers` reached).
    Full,
    /// The request was invalid (e.g. empty username) or a session token
    /// could not be generated.
    Invalid(String),
}

impl std::fmt::Display for AddPlayerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AddPlayerError::Full => write!(f, "Server is full"),
            AddPlayerError::Invalid(msg) => write!(f, "{msg}"),
        }
    }
}

impl std::error::Error for AddPlayerError {}

/// Thread-safe session manager. Tracks all connected players.
pub struct SessionManager {
    players: DashMap<u32, Player>,
    token_map: DashMap<String, u32>,
    /// Truncated SHA-256 of session token → player_id (for UDP authentication).
    session_hashes: DashMap<[u8; 16], u32>,
    next_id: AtomicU32,
    /// Serializes the capacity check + insert in `add_player` so concurrent
    /// authentications cannot race past `MaxPlayers` (TOCTOU). Held only for the
    /// brief, non-async admission critical section.
    admit_guard: std::sync::Mutex<()>,
    reliable_enqueued: AtomicU64,
    reliable_timed_out: AtomicU64,
    reliable_closed: AtomicU64,
    best_effort_enqueued: AtomicU64,
    best_effort_dropped: AtomicU64,
}

const RELIABLE_BROADCAST_ENQUEUE_TIMEOUT: Duration = Duration::from_secs(1);

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct BroadcastReport {
    pub recipients: u64,
    pub enqueued: u64,
    pub timed_out: u64,
    pub closed: u64,
}

impl BroadcastReport {
    pub fn all_enqueued(&self) -> bool {
        self.enqueued == self.recipients
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct OutboundDeliveryStats {
    pub reliable_enqueued: u64,
    pub reliable_timed_out: u64,
    pub reliable_closed: u64,
    pub best_effort_enqueued: u64,
    pub best_effort_dropped: u64,
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
            admit_guard: std::sync::Mutex::new(()),
            reliable_enqueued: AtomicU64::new(0),
            reliable_timed_out: AtomicU64::new(0),
            reliable_closed: AtomicU64::new(0),
            best_effort_enqueued: AtomicU64::new(0),
            best_effort_dropped: AtomicU64::new(0),
        }
    }

    /// Register a new player. Returns `(player_id, session_token)`.
    ///
    /// `max_players` is enforced atomically with the insert under `admit_guard`,
    /// so concurrent connections cannot collectively exceed the cap.
    pub fn add_player(
        &self,
        name: String,
        addr: SocketAddr,
        tcp_tx: mpsc::Sender<TcpPacket>,
        max_players: u32,
    ) -> Result<(u32, String), AddPlayerError> {
        let trimmed_name = name.trim();
        if trimmed_name.is_empty() {
            tracing::warn!(%addr, "Rejected player with empty username at session creation");
            return Err(AddPlayerError::Invalid("Username cannot be empty".into()));
        }

        // Serialize the capacity check + insert. The lock is never held across an
        // await (this function is synchronous), so a std Mutex is appropriate.
        let _admit = self
            .admit_guard
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());

        if self.players.len() >= max_players as usize {
            return Err(AddPlayerError::Full);
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
                return Err(AddPlayerError::Invalid(format!(
                    "Failed to generate unique session token after {MAX_TOKEN_ATTEMPTS} attempts"
                )));
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
            last_pong_time: now, // Initialize pong time (Phase 2.2)
            last_ping_seq_sent: None,
            last_ping_sent_at: None,
            ping_ms: None,
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

    /// Count of players with a registered UDP address (for diagnostics).
    pub fn udp_bound_count(&self) -> usize {
        self.players
            .iter()
            .filter(|e| e.value().udp_addr.is_some())
            .count()
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
                    ping_ms: p.ping_ms,
                }
            })
            .collect()
    }

    /// Get lightweight ping-only metrics snapshot for frequent HUD updates.
    pub fn get_player_metrics_snapshot(&self) -> Vec<PlayerPingInfo> {
        self.players
            .iter()
            .map(|entry| {
                let p = entry.value();
                PlayerPingInfo {
                    player_id: p.id,
                    ping_ms: p.ping_ms,
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
    /// Best-effort fanout for replaceable, high-rate state only. Lifecycle and
    /// durable component packets must use `broadcast_reliable`.
    pub fn broadcast_best_effort(&self, packet: TcpPacket, exclude: Option<u32>) {
        for entry in self.players.iter() {
            let player = entry.value();
            if Some(player.id) == exclude {
                continue;
            }
            match player.tcp_tx.try_send(packet.clone()) {
                Ok(()) => {
                    self.best_effort_enqueued.fetch_add(1, Ordering::Relaxed);
                }
                Err(e) => {
                    self.best_effort_dropped.fetch_add(1, Ordering::Relaxed);
                    tracing::debug!(player_id = player.id, "Best-effort broadcast dropped: {e}");
                }
            }
        }
    }

    /// Compatibility wrapper for non-state-critical callers. New code should
    /// choose `broadcast_reliable` or `broadcast_best_effort` explicitly.
    pub fn broadcast(&self, packet: TcpPacket, exclude: Option<u32>) {
        self.broadcast_best_effort(packet, exclude);
    }

    /// Enqueue a durable packet for every target, waiting concurrently for
    /// bounded channel capacity. A timeout/closed channel is surfaced in the
    /// report and diagnostics instead of being silently discarded.
    pub async fn broadcast_reliable(
        &self,
        packet: TcpPacket,
        exclude: Option<u32>,
    ) -> BroadcastReport {
        self.broadcast_reliable_with_timeout(packet, exclude, RELIABLE_BROADCAST_ENQUEUE_TIMEOUT)
            .await
    }

    async fn broadcast_reliable_with_timeout(
        &self,
        packet: TcpPacket,
        exclude: Option<u32>,
        enqueue_timeout: Duration,
    ) -> BroadcastReport {
        let recipients: Vec<(u32, mpsc::Sender<TcpPacket>)> = self
            .players
            .iter()
            .filter_map(|entry| {
                let player = entry.value();
                (Some(player.id) != exclude).then(|| (player.id, player.tcp_tx.clone()))
            })
            .collect();

        let mut report = BroadcastReport {
            recipients: recipients.len() as u64,
            ..BroadcastReport::default()
        };
        let mut pending = JoinSet::new();
        let mut failed_players = Vec::new();

        for (player_id, tx) in recipients {
            let packet = packet.clone();
            pending.spawn(async move {
                let outcome = timeout(enqueue_timeout, tx.send(packet)).await;
                (player_id, outcome)
            });
        }

        while let Some(joined) = pending.join_next().await {
            match joined {
                Ok((_player_id, Ok(Ok(())))) => {
                    report.enqueued += 1;
                    self.reliable_enqueued.fetch_add(1, Ordering::Relaxed);
                }
                Ok((player_id, Ok(Err(_)))) => {
                    report.closed += 1;
                    self.reliable_closed.fetch_add(1, Ordering::Relaxed);
                    tracing::warn!(player_id, "Reliable broadcast channel closed");
                    failed_players.push(player_id);
                }
                Ok((player_id, Err(_))) => {
                    report.timed_out += 1;
                    self.reliable_timed_out.fetch_add(1, Ordering::Relaxed);
                    tracing::warn!(
                        player_id,
                        ?enqueue_timeout,
                        "Reliable broadcast enqueue timed out"
                    );
                    failed_players.push(player_id);
                }
                Err(e) => {
                    report.closed += 1;
                    self.reliable_closed.fetch_add(1, Ordering::Relaxed);
                    tracing::error!(error = %e, "Reliable broadcast enqueue task failed");
                }
            }
        }

        for player_id in failed_players {
            // A peer that cannot accept a lifecycle packet within the bounded
            // window cannot remain state-consistent. Removing its session is
            // safer than leaving a connected client that permanently missed a
            // reset, spawn, or damage revision.
            self.remove_player(player_id);
        }

        report
    }

    pub fn outbound_delivery_stats(&self) -> OutboundDeliveryStats {
        OutboundDeliveryStats {
            reliable_enqueued: self.reliable_enqueued.load(Ordering::Relaxed),
            reliable_timed_out: self.reliable_timed_out.load(Ordering::Relaxed),
            reliable_closed: self.reliable_closed.load(Ordering::Relaxed),
            best_effort_enqueued: self.best_effort_enqueued.load(Ordering::Relaxed),
            best_effort_dropped: self.best_effort_dropped.load(Ordering::Relaxed),
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
        // C1: snapshot targets first, then release all DashMap guards before
        // awaiting any send. Holding shard guards across `await send_to` serialized
        // the UDP task against map contention and added latency under load.
        let targets: Vec<(u32, SocketAddr)> = self
            .players
            .iter()
            .filter(|entry| Some(entry.value().id) != exclude)
            .filter_map(|entry| entry.value().udp_addr.map(|addr| (entry.value().id, addr)))
            .collect();

        for (player_id, addr) in targets {
            if let Err(e) = socket.send_to(data, addr).await {
                tracing::warn!(player_id, %addr, "UDP send failed: {e}");
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
        // C1: resolve the eligible targets (including the distance check, which
        // calls `get_centroid` → WorldState) into a snapshot while iterating, then
        // drop the iterator/guards before awaiting any send.
        let targets: Vec<(u32, SocketAddr)> = self
            .players
            .iter()
            .filter_map(|entry| {
                let player = entry.value();
                if player.id == exclude {
                    return None;
                }
                let addr = player.udp_addr?;
                // Distance check: skip if receiver is too far.
                if let Some(recv_pos) = get_centroid(player.id) {
                    let dx = sender_pos[0] - recv_pos[0];
                    let dy = sender_pos[1] - recv_pos[1];
                    let dz = sender_pos[2] - recv_pos[2];
                    if dx * dx + dy * dy + dz * dz > lod_distance_sq {
                        return None;
                    }
                }
                Some((player.id, addr))
            })
            .collect();

        for (player_id, addr) in targets {
            if let Err(e) = socket.send_to(data, addr).await {
                tracing::warn!(player_id, %addr, "UDP send failed: {e}");
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
                .add_player(username, addr, tx, u32::MAX)
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
                .add_player(format!("bulk_{i}"), addr, tx, u32::MAX)
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

    #[test]
    fn test_add_player_enforces_max_players() {
        let manager = SessionManager::new();
        let addr: SocketAddr = "127.0.0.1:18862".parse().expect("valid socket addr");

        for i in 0..3 {
            let (tx, _rx) = mpsc::channel(8);
            manager
                .add_player(format!("cap_{i}"), addr, tx, 3)
                .expect("under cap should succeed");
        }
        assert_eq!(manager.player_count(), 3);

        let (tx, _rx) = mpsc::channel(8);
        let result = manager.add_player("overflow".into(), addr, tx, 3);
        assert!(
            matches!(result, Err(AddPlayerError::Full)),
            "exceeding MaxPlayers should return Full"
        );
        assert_eq!(manager.player_count(), 3);
    }

    #[tokio::test]
    async fn reliable_broadcast_waits_for_saturated_channel_capacity() {
        let manager = std::sync::Arc::new(SessionManager::new());
        let addr: SocketAddr = "127.0.0.1:18861".parse().expect("valid socket addr");
        let (tx, mut rx) = mpsc::channel(1);
        manager
            .add_player("slow_peer".into(), addr, tx.clone(), 4)
            .expect("player added");

        tx.send(TcpPacket::ServerMessage {
            text: "occupy queue".into(),
        })
        .await
        .expect("prefill outbound queue");

        let broadcast_manager = manager.clone();
        let broadcast = tokio::spawn(async move {
            broadcast_manager
                .broadcast_reliable(
                    TcpPacket::VehicleDamage {
                        player_id: Some(7),
                        vehicle_id: 2,
                        data: r#"{"broken":[3]}"#.into(),
                    },
                    None,
                )
                .await
        });

        tokio::task::yield_now().await;
        assert!(
            !broadcast.is_finished(),
            "reliable fanout must wait instead of dropping on a full channel"
        );

        let first = rx.recv().await.expect("prefilled packet");
        assert!(matches!(first, TcpPacket::ServerMessage { .. }));

        let report = timeout(Duration::from_millis(250), broadcast)
            .await
            .expect("broadcast completed after capacity became available")
            .expect("broadcast task did not panic");
        assert_eq!(
            report,
            BroadcastReport {
                recipients: 1,
                enqueued: 1,
                timed_out: 0,
                closed: 0,
            }
        );
        assert!(matches!(
            rx.recv().await.expect("reliable packet"),
            TcpPacket::VehicleDamage { .. }
        ));
        assert_eq!(manager.outbound_delivery_stats().reliable_enqueued, 1);
    }

    #[tokio::test]
    async fn reliable_broadcast_reports_saturation_timeout() {
        let manager = SessionManager::new();
        let addr: SocketAddr = "127.0.0.1:18862".parse().expect("valid socket addr");
        let (tx, _rx) = mpsc::channel(1);
        manager
            .add_player("blocked_peer".into(), addr, tx.clone(), 4)
            .expect("player added");
        tx.send(TcpPacket::ServerMessage {
            text: "occupy queue".into(),
        })
        .await
        .expect("prefill outbound queue");

        let report = manager
            .broadcast_reliable_with_timeout(
                TcpPacket::VehicleReset {
                    player_id: Some(7),
                    vehicle_id: 2,
                    data: "{}".into(),
                },
                None,
                Duration::from_millis(10),
            )
            .await;

        assert_eq!(report.recipients, 1);
        assert_eq!(report.enqueued, 0);
        assert_eq!(report.timed_out, 1);
        assert_eq!(report.closed, 0);
        assert_eq!(manager.outbound_delivery_stats().reliable_timed_out, 1);
        assert_eq!(manager.player_count(), 0, "timed-out peer is quarantined");
    }

    #[test]
    fn best_effort_broadcast_counts_saturation_drop() {
        let manager = SessionManager::new();
        let addr: SocketAddr = "127.0.0.1:18863".parse().expect("valid socket addr");
        let (tx, _rx) = mpsc::channel(1);
        manager
            .add_player("telemetry_peer".into(), addr, tx.clone(), 4)
            .expect("player added");
        tx.try_send(TcpPacket::ServerMessage {
            text: "occupy queue".into(),
        })
        .expect("prefill outbound queue");

        manager.broadcast_best_effort(
            TcpPacket::VehicleInputs {
                player_id: Some(7),
                vehicle_id: 2,
                data: "{}".into(),
            },
            None,
        );

        let stats = manager.outbound_delivery_stats();
        assert_eq!(stats.best_effort_enqueued, 0);
        assert_eq!(stats.best_effort_dropped, 1);
    }
}
