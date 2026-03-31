use std::net::{SocketAddr, UdpSocket};
use std::time::Duration;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

const DISCOVERY_QUERY_PACKET: u8 = 0x7A;

#[derive(Debug, Clone, Deserialize)]
pub struct ServerQueryResponse {
    pub name: String,
    pub map: String,
    pub players: usize,
    pub max_players: u32,
    pub port: u16,
    pub protocol_version: u32,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct RelayServerEntry {
    pub addr: String,
    pub name: Option<String>,
    pub map: Option<String>,
    pub players: Option<usize>,
    pub max_players: Option<u32>,
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum RelayListResponse {
    Wrapped { servers: Vec<RelayServerEntry> },
    Direct(Vec<RelayServerEntry>),
}

pub fn query_server(addr: &str, timeout_ms: u64) -> Result<ServerQueryResponse> {
    let target: SocketAddr = addr
        .parse()
        .with_context(|| format!("Invalid server address: {}", addr))?;

    let socket = UdpSocket::bind("0.0.0.0:0").context("Failed to bind local UDP socket")?;
    socket
        .set_read_timeout(Some(Duration::from_millis(timeout_ms)))
        .context("Failed to set UDP timeout")?;

    socket
        .send_to(&[DISCOVERY_QUERY_PACKET], target)
        .with_context(|| format!("Failed to send discovery query to {}", target))?;

    let mut buf = [0u8; 65535];
    let (len, _src) = socket
        .recv_from(&mut buf)
        .context("No discovery response received before timeout")?;

    let response: ServerQueryResponse =
        serde_json::from_slice(&buf[..len]).context("Failed to parse discovery response JSON")?;
    Ok(response)
}

pub fn fetch_relay_servers(relay_url: &str, timeout_ms: u64) -> Result<Vec<RelayServerEntry>> {
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_millis(timeout_ms))
        .build()
        .context("Failed to build relay HTTP client")?;

    let response = client
        .get(relay_url)
        .send()
        .with_context(|| format!("Failed to fetch relay server list from {relay_url}"))?
        .error_for_status()
        .with_context(|| format!("Relay returned error status: {relay_url}"))?;

    let parsed: RelayListResponse = response
        .json()
        .with_context(|| format!("Failed to parse relay response from {relay_url}"))?;

    let mut list = match parsed {
        RelayListResponse::Wrapped { servers } => servers,
        RelayListResponse::Direct(servers) => servers,
    };

    list.retain(|entry| !entry.addr.trim().is_empty());
    list.sort_by(|a, b| a.addr.cmp(&b.addr));
    list.dedup_by(|a, b| a.addr == b.addr);
    Ok(list)
}
