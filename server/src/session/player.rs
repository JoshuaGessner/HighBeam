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
    pub connected_at: Instant,
    pub last_activity: Instant,
}
