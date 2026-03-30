use std::net::SocketAddr;

use tokio::sync::mpsc;
use tokio::time::Instant;

use crate::net::packet::TcpPacket;

/// Represents a connected player's server-side state.
pub struct Player {
    pub id: u32,
    pub name: String,
    pub session_token: String,
    pub addr: SocketAddr,
    /// Channel to send packets to this player's TCP writer task.
    pub tcp_tx: mpsc::Sender<TcpPacket>,
    /// Registered UDP address (set when client sends UdpBind).
    pub udp_addr: Option<SocketAddr>,
    /// First 16 bytes of SHA-256(session_token), used to authenticate UDP packets.
    pub session_hash: [u8; 16],
    pub connected_at: Instant,
    pub last_activity: Instant,
}
