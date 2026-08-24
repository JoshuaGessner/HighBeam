use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};

use tokio::sync::mpsc;
use tokio::sync::Notify;
use tokio::time::Instant;

use crate::net::packet::TcpPacket;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
enum ReplaceableKind {
    Pose,
    Inputs,
    Electrics,
    Powertrain,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
struct ReplaceableKey {
    kind: ReplaceableKind,
    vehicle_id: u16,
}

fn replaceable_key(packet: &TcpPacket) -> Option<ReplaceableKey> {
    let (kind, vehicle_id) = match packet {
        TcpPacket::VehiclePose { vehicle_id, .. } => (ReplaceableKind::Pose, *vehicle_id),
        TcpPacket::VehicleInputs { vehicle_id, .. } => (ReplaceableKind::Inputs, *vehicle_id),
        TcpPacket::VehicleElectrics { vehicle_id, .. } => (ReplaceableKind::Electrics, *vehicle_id),
        TcpPacket::VehiclePowertrain { vehicle_id, .. } => {
            (ReplaceableKind::Powertrain, *vehicle_id)
        }
        _ => return None,
    };
    Some(ReplaceableKey { kind, vehicle_id })
}

/// One latest-value slot per replaceable component and vehicle. This sits next
/// to the bounded reliable channel so high-rate snapshots coalesce instead of
/// disappearing when a slow peer temporarily fills that channel.
pub struct ReplaceableOutbox {
    pending: Mutex<HashMap<ReplaceableKey, TcpPacket>>,
    notify: Notify,
}

impl ReplaceableOutbox {
    pub fn new() -> Self {
        Self {
            pending: Mutex::new(HashMap::new()),
            notify: Notify::new(),
        }
    }

    /// Returns Some(true) when an older value was replaced, Some(false) when a
    /// new slot was inserted, and None for a non-replaceable packet.
    pub fn insert(&self, packet: TcpPacket) -> Option<bool> {
        let key = replaceable_key(&packet)?;
        let mut pending = self.pending.lock().unwrap_or_else(|p| p.into_inner());
        let replaced = pending.insert(key, packet).is_some();
        drop(pending);
        self.notify.notify_one();
        Some(replaced)
    }

    pub fn clear_vehicle(&self, vehicle_id: u16) -> usize {
        let mut pending = self.pending.lock().unwrap_or_else(|p| p.into_inner());
        let before = pending.len();
        pending.retain(|key, _| key.vehicle_id != vehicle_id);
        before - pending.len()
    }

    pub fn remove_matching(&self, packet: &TcpPacket) -> bool {
        let Some(key) = replaceable_key(packet) else {
            return false;
        };
        self.pending
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .remove(&key)
            .is_some()
    }

    pub fn drain(&self) -> Vec<TcpPacket> {
        let mut pending = self.pending.lock().unwrap_or_else(|p| p.into_inner());
        pending.drain().map(|(_, packet)| packet).collect()
    }

    pub fn len(&self) -> usize {
        self.pending.lock().unwrap_or_else(|p| p.into_inner()).len()
    }

    pub async fn notified(&self) {
        self.notify.notified().await;
    }
}

/// Represents a connected player's server-side state.
pub struct Player {
    pub id: u32,
    pub name: String,
    pub session_token: String,
    pub addr: SocketAddr,
    /// Channel to send packets to this player's TCP writer task.
    pub tcp_tx: mpsc::Sender<TcpPacket>,
    pub replaceable_outbox: Arc<ReplaceableOutbox>,
    /// Registered UDP address (set when client sends UdpBind).
    pub udp_addr: Option<SocketAddr>,
    /// First 16 bytes of SHA-256(session_token), used to authenticate UDP packets.
    pub session_hash: [u8; 16],
    pub connected_at: Instant,
    /// Last time a pong was received from this player (Phase 2.2 heartbeat).
    pub last_pong_time: Instant,
    /// Last ping sequence sent to this player.
    pub last_ping_seq_sent: Option<u32>,
    /// Timestamp of the last ping sent to this player.
    pub last_ping_sent_at: Option<Instant>,
    /// Smoothed round-trip latency in milliseconds.
    pub ping_ms: Option<u32>,
}
