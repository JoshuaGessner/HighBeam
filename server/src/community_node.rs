//! Community Node Discovery Mesh — decentralised server discovery for HighBeam.
//!
//! Every server operator that opts in becomes a node in the mesh.  Nodes gossip
//! with each other every 30 seconds, exchanging server and peer lists.  Any
//! single node can serve the full aggregated list to game clients.
//!
//! HTTP API (hand-built, no hyper dependency):
//!   GET  /servers        — server list, NO addr fields (clients)
//!   GET  /resolve/{id}   — {"addr":"ip:port"} for one server, rate-limited
//!   GET  /peers          — known peer addresses
//!   POST /gossip         — node-to-node exchange (includes addr fields)
//!   GET  /health         — {"ok":true,"peers":N,"servers":N}
//!
//! See docs/versioning/VERSION_PLAN.md §v0.8.0 for the full design spec.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, RwLock};
use std::time::{SystemTime, UNIX_EPOCH};

use rand::seq::SliceRandom;
use rand::Rng;
use serde::{Deserialize, Serialize};
use tokio::sync::broadcast;

use crate::config::ServerConfig;
use crate::control::ControlPlane;

// ── Constants ──────────────────────────────────────────────────────────────────

const MAX_SERVERS: usize = 500;
const MAX_PEERS: usize = 200;
const SERVER_TTL_SECS: u64 = 90;
const PEER_TTL_SECS: u64 = 300; // 5 minutes
const GOSSIP_INTERVAL_SECS: u64 = 30;
const MAX_REQUEST_BODY: usize = 256 * 1024; // 256 KB
const MAX_GOSSIP_TARGETS: usize = 3;
const RESOLVE_RATE_PER_MIN: u32 = 10;
const GENERAL_RATE_PER_MIN: u32 = 30;
const BACKOFF_BASE_SECS: u64 = 30;
const BACKOFF_MAX_SECS: u64 = 300;
const PUBLIC_NODES_IN_RESPONSE: usize = 10;

const STATE_FILE: &str = "community_node.json";

// ── Public data types ──────────────────────────────────────────────────────────

/// A mod entry as shared in the gossip mesh / /servers response.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NodeModInfo {
    pub name: String,
    pub size_bytes: u64,
}

/// Full server record used internally and in gossip messages (includes addr fields).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerEntry {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub map: String,
    #[serde(default)]
    pub players: u32,
    #[serde(default)]
    pub max_players: u32,
    #[serde(default)]
    pub region: String,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default = "default_auth_mode")]
    pub auth_mode: String,
    #[serde(default)]
    pub mods: Vec<NodeModInfo>,
    /// Game server TCP/UDP address (ip:port).  Present in gossip; NEVER in /servers responses.
    pub addr: String,
    /// HTTP community-node address (ip:port).  Present in gossip; NEVER in /servers responses.
    pub node_addr: String,
    /// Unix epoch seconds of last heartbeat/gossip update.
    pub last_seen: u64,
}

fn default_auth_mode() -> String {
    "open".to_string()
}

/// Status snapshot exposed to the GUI and console.
#[derive(Debug, Clone)]
pub struct CommunityNodeStatus {
    pub enabled: bool,
    pub server_id: String,
    pub listen_port: u16,
    pub region: String,
    pub tags: Vec<String>,
    pub seed_nodes: Vec<String>,
    pub peer_count: usize,
    pub server_count: usize,
    pub last_gossip_at: u64,
    pub running: bool,
}

// ── Internal types ─────────────────────────────────────────────────────────────

/// Public-facing server record for /servers — addr and node_addr deliberately absent.
#[derive(Serialize)]
struct PublicServerEntry<'a> {
    id: &'a str,
    name: &'a str,
    description: &'a str,
    map: &'a str,
    players: u32,
    max_players: u32,
    region: &'a str,
    tags: &'a Vec<String>,
    auth_mode: &'a str,
    mods: &'a Vec<NodeModInfo>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PeerEntry {
    addr: String,
    last_seen: u64,
    #[serde(default)]
    failures: u32,
    #[serde(default)]
    next_retry: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct GossipMessage {
    from: String,
    peers: Vec<GossipPeerRef>,
    servers: Vec<ServerEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct GossipPeerRef {
    addr: String,
    last_seen: u64,
}

/// Shape persisted to `community_node.json`.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct PersistedState {
    #[serde(default)]
    enabled: bool,
    #[serde(default)]
    server_id: String,
    #[serde(default = "default_node_port")]
    listen_port: u16,
    #[serde(default)]
    region: String,
    #[serde(default)]
    tags: Vec<String>,
    #[serde(default)]
    seed_nodes: Vec<String>,
    #[serde(default)]
    known_peers: Vec<String>,
}

fn default_node_port() -> u16 {
    18862
}

/// Rate-limit bucket per IP: (requests in current window, window start epoch secs).
type RateBucket = (u32, u64);

struct InnerState {
    enabled: bool,
    server_id: String,
    listen_port: u16,
    region: String,
    tags: Vec<String>,
    seed_nodes: Vec<String>,
    servers: Vec<ServerEntry>,
    peers: Vec<PeerEntry>,
    last_gossip_at: u64,
    rate_general: HashMap<String, RateBucket>,
    rate_resolve: HashMap<String, RateBucket>,
    running: bool,
}

impl InnerState {
    fn from_persisted(p: PersistedState) -> Self {
        let now = now_secs();
        let peers = p
            .known_peers
            .iter()
            .map(|addr| PeerEntry {
                addr: addr.clone(),
                last_seen: now,
                failures: 0,
                next_retry: 0,
            })
            .collect();
        InnerState {
            enabled: p.enabled,
            server_id: p.server_id,
            listen_port: p.listen_port,
            region: p.region,
            tags: p.tags,
            seed_nodes: p.seed_nodes,
            servers: Vec::new(),
            peers,
            last_gossip_at: 0,
            rate_general: HashMap::new(),
            rate_resolve: HashMap::new(),
            running: false,
        }
    }

    fn to_persisted(&self) -> PersistedState {
        let known_peers: Vec<String> = self
            .peers
            .iter()
            .filter(|p| p.failures < 10)
            .map(|p| p.addr.clone())
            .collect();
        PersistedState {
            enabled: self.enabled,
            server_id: self.server_id.clone(),
            listen_port: self.listen_port,
            region: self.region.clone(),
            tags: self.tags.clone(),
            seed_nodes: self.seed_nodes.clone(),
            known_peers,
        }
    }

    fn check_general_rate(&mut self, ip: &str) -> bool {
        check_rate(&mut self.rate_general, ip, GENERAL_RATE_PER_MIN)
    }

    fn check_resolve_rate(&mut self, ip: &str) -> bool {
        check_rate(&mut self.rate_resolve, ip, RESOLVE_RATE_PER_MIN)
    }
}

fn check_rate(map: &mut HashMap<String, RateBucket>, ip: &str, limit: u32) -> bool {
    let now = now_secs();
    let bucket = map.entry(ip.to_string()).or_insert((0, now));
    if now >= bucket.1 + 60 {
        *bucket = (1, now);
        return true;
    }
    if bucket.0 >= limit {
        return false;
    }
    bucket.0 += 1;
    true
}

// ── Public state handle ────────────────────────────────────────────────────────

/// Thread-safe handle to the community node.  Obtained from [`start()`].
pub struct CommunityNodeState {
    inner: Arc<RwLock<InnerState>>,
    data_dir: String,
    config: Arc<ServerConfig>,
}

// ── Helper functions ───────────────────────────────────────────────────────────

// ── Pure helper exposed for external callers ───────────────────────────────────

/// Returns the current Unix epoch in seconds.  Exposed so `control.rs` can
/// compute "seconds since last gossip" without duplicating the timestamp logic.
pub fn now_secs_pub() -> u64 {
    now_secs()
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn generate_server_id() -> String {
    let hex: String = rand::thread_rng()
        .sample_iter(rand::distributions::Uniform::new(0u8, 16))
        .take(6)
        .map(|n| format!("{:x}", n))
        .collect();
    format!("hb-{}", hex)
}

fn is_private_host(host: &str) -> bool {
    let lower = host.to_lowercase();
    if lower == "localhost" || lower == "::1" || lower == "[::1]" {
        return true;
    }
    if lower.starts_with("127.") || lower.starts_with("0.0.0.0") {
        return true;
    }
    if lower.starts_with("10.") || lower.starts_with("192.168.") {
        return true;
    }
    if let Some(b) = lower.strip_prefix("172.").and_then(|rest| {
        rest.split('.').next().and_then(|n| n.parse::<u8>().ok())
    }) {
        if (16..=31).contains(&b) {
            return true;
        }
    }
    false
}

fn sanitize_str(s: &str, max_len: usize) -> String {
    s.chars()
        .filter(|c| !c.is_control() && *c != '%')
        .take(max_len)
        .collect()
}

fn validate_gossip_server(s: &ServerEntry) -> bool {
    // server_id must be hb-[0-9a-f]{6}
    if s.id.len() != 9 || !s.id.starts_with("hb-") {
        return false;
    }
    if !s.id[3..].chars().all(|c| matches!(c, '0'..='9' | 'a'..='f')) {
        return false;
    }
    if s.addr.is_empty() || s.node_addr.is_empty() {
        return false;
    }
    // Reasonable string length limits
    if s.name.len() > 128 || s.description.len() > 512 || s.map.len() > 512 {
        return false;
    }
    if !matches!(s.auth_mode.as_str(), "open" | "password" | "allowlist") {
        return false;
    }
    if s.tags.len() > 10 || s.mods.len() > 100 {
        return false;
    }
    // Reject entries with last_seen more than 5 minutes in the future (clock skew guard)
    if s.last_seen > now_secs() + 300 {
        return false;
    }
    true
}

// ── Minimal HTTP primitives ────────────────────────────────────────────────────

struct HttpRequest {
    method: String,
    path: String,
    body: Vec<u8>,
    peer_ip: String,
}

fn find_double_crlf(buf: &[u8]) -> Option<usize> {
    buf.windows(4).position(|w| w == b"\r\n\r\n")
}

fn extract_content_length(header_str: &str) -> usize {
    for line in header_str.lines().skip(1) {
        if let Some(val) = line.to_ascii_lowercase().strip_prefix("content-length:") {
            if let Ok(n) = val.trim().parse::<usize>() {
                return n;
            }
        }
    }
    0
}

async fn read_request(stream: &mut tokio::net::TcpStream, peer_ip: String) -> Option<HttpRequest> {
    use tokio::io::AsyncReadExt;

    let deadline =
        tokio::time::Instant::now() + std::time::Duration::from_secs(5);
    let mut buf: Vec<u8> = Vec::with_capacity(2048);
    let mut tmp = [0u8; 4096];

    loop {
        if tokio::time::Instant::now() > deadline {
            return None;
        }
        let n = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            stream.read(&mut tmp),
        )
        .await
        .ok()?.ok()?;
        if n == 0 {
            return None;
        }
        buf.extend_from_slice(&tmp[..n]);
        if buf.len() > MAX_REQUEST_BODY + 8192 {
            return None;
        }

        if let Some(hdr_end) = find_double_crlf(&buf) {
            let header_bytes = &buf[..hdr_end];
            let header_str = std::str::from_utf8(header_bytes).ok()?;

            let mut lines = header_str.lines();
            let request_line = lines.next()?;
            let mut parts = request_line.split_whitespace();
            let method = parts.next()?.to_string();
            let path = parts.next()?.to_string();

            let content_length = extract_content_length(header_str);
            if content_length > MAX_REQUEST_BODY {
                return None;
            }

            let body_start = hdr_end + 4;
            let mut body: Vec<u8> = buf.get(body_start..).unwrap_or_default().to_vec();

            while body.len() < content_length {
                if tokio::time::Instant::now() > deadline {
                    return None;
                }
                let n = tokio::time::timeout(
                    std::time::Duration::from_secs(3),
                    stream.read(&mut tmp),
                )
                .await
                .ok()?.ok()?;
                if n == 0 {
                    break;
                }
                body.extend_from_slice(&tmp[..n]);
                if body.len() > MAX_REQUEST_BODY {
                    return None;
                }
            }

            return Some(HttpRequest {
                method,
                path,
                body,
                peer_ip,
            });
        }
    }
}

fn http_response_bytes(status: u16, status_text: &str, body: &str) -> Vec<u8> {
    let content = body.as_bytes();
    let headers = format!(
        "HTTP/1.0 {} {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
        status, status_text, content.len()
    );
    let mut out = headers.into_bytes();
    out.extend_from_slice(content);
    out
}

fn http_ok(body: &str) -> Vec<u8> {
    http_response_bytes(200, "OK", body)
}
fn http_not_found() -> Vec<u8> {
    http_response_bytes(404, "Not Found", r#"{"error":"not found"}"#)
}
fn http_rate_limited() -> Vec<u8> {
    http_response_bytes(429, "Too Many Requests", r#"{"error":"rate limited"}"#)
}
fn http_bad_request(msg: &str) -> Vec<u8> {
    let escaped = msg.replace('"', "'");
    http_response_bytes(400, "Bad Request", &format!(r#"{{"error":"{}"}}"#, escaped))
}

// ── Request route handlers ─────────────────────────────────────────────────────

fn handle_get_servers(state: &CommunityNodeState, ip: &str) -> Vec<u8> {
    let mut inner = state.inner.write().unwrap();
    if !inner.check_general_rate(ip) {
        return http_rate_limited();
    }
    let public: Vec<PublicServerEntry> = inner
        .servers
        .iter()
        .map(|s| PublicServerEntry {
            id: &s.id,
            name: &s.name,
            description: &s.description,
            map: &s.map,
            players: s.players,
            max_players: s.max_players,
            region: &s.region,
            tags: &s.tags,
            auth_mode: &s.auth_mode,
            mods: &s.mods,
        })
        .collect();
    // Include a handful of peer node addresses so clients can discover more bootstrap points.
    let now = now_secs();
    let nodes: Vec<&str> = inner
        .peers
        .iter()
        .filter(|p| now.saturating_sub(p.last_seen) < PEER_TTL_SECS)
        .take(PUBLIC_NODES_IN_RESPONSE)
        .map(|p| p.addr.as_str())
        .collect();

    let body = match serde_json::to_string(&serde_json::json!({
        "servers": public,
        "nodes": nodes,
    })) {
        Ok(s) => s,
        Err(_) => r#"{"servers":[],"nodes":[]}"#.to_string(),
    };
    http_ok(&body)
}

fn handle_get_resolve(state: &CommunityNodeState, ip: &str, server_id: &str) -> Vec<u8> {
    let mut inner = state.inner.write().unwrap();
    if !inner.check_general_rate(ip) {
        return http_rate_limited();
    }
    if !inner.check_resolve_rate(ip) {
        return http_rate_limited();
    }
    // Validate server_id format before lookup
    if server_id.len() != 9
        || !server_id.starts_with("hb-")
        || !server_id[3..].chars().all(|c| c.is_ascii_hexdigit())
    {
        return http_not_found();
    }
    match inner.servers.iter().find(|s| s.id == server_id) {
        Some(entry) => {
            let body = match serde_json::to_string(&serde_json::json!({ "addr": entry.addr })) {
                Ok(s) => s,
                Err(_) => r#"{"addr":""}"#.to_string(),
            };
            http_ok(&body)
        }
        None => http_not_found(),
    }
}

fn handle_get_peers(state: &CommunityNodeState, ip: &str) -> Vec<u8> {
    let mut inner = state.inner.write().unwrap();
    if !inner.check_general_rate(ip) {
        return http_rate_limited();
    }
    let peers: Vec<&str> = inner.peers.iter().map(|p| p.addr.as_str()).collect();
    let body = match serde_json::to_string(&serde_json::json!({ "peers": peers })) {
        Ok(s) => s,
        Err(_) => r#"{"peers":[]}"#.to_string(),
    };
    http_ok(&body)
}

fn handle_post_gossip(state: &CommunityNodeState, ip: &str, body_bytes: &[u8]) -> Vec<u8> {
    let mut inner = state.inner.write().unwrap();
    if !inner.check_general_rate(ip) {
        return http_rate_limited();
    }
    let msg: GossipMessage = match serde_json::from_slice(body_bytes) {
        Ok(m) => m,
        Err(_) => return http_bad_request("invalid json"),
    };

    let now = now_secs();

    // Merge incoming servers
    for entry in msg.servers.into_iter().take(MAX_SERVERS) {
        if !validate_gossip_server(&entry) {
            continue;
        }
        if let Some(existing) = inner.servers.iter_mut().find(|s| s.id == entry.id) {
            if entry.last_seen > existing.last_seen {
                *existing = entry;
            }
        } else if inner.servers.len() < MAX_SERVERS {
            inner.servers.push(entry);
        }
    }

    // Merge incoming peers
    for peer_ref in msg.peers.into_iter().take(MAX_PEERS) {
        if peer_ref.addr.is_empty() || peer_ref.last_seen > now + 300 {
            continue;
        }
        if let Some(existing) = inner.peers.iter_mut().find(|p| p.addr == peer_ref.addr) {
            if peer_ref.last_seen > existing.last_seen {
                existing.last_seen = peer_ref.last_seen;
            }
        } else if inner.peers.len() < MAX_PEERS {
            inner.peers.push(PeerEntry {
                addr: peer_ref.addr,
                last_seen: peer_ref.last_seen,
                failures: 0,
                next_retry: 0,
            });
        }
    }

    cap_servers(&mut inner.servers, MAX_SERVERS);
    cap_peers(&mut inner.peers, MAX_PEERS);

    // Reply with our current state
    let reply = GossipMessage {
        from: format!("0.0.0.0:{}", inner.listen_port),
        peers: inner
            .peers
            .iter()
            .map(|p| GossipPeerRef {
                addr: p.addr.clone(),
                last_seen: p.last_seen,
            })
            .collect(),
        servers: inner.servers.clone(),
    };
    let body = serde_json::to_string(&reply).unwrap_or_else(|_| "{}".to_string());
    http_ok(&body)
}

fn handle_get_health(state: &CommunityNodeState, ip: &str) -> Vec<u8> {
    let mut inner = state.inner.write().unwrap();
    if !inner.check_general_rate(ip) {
        return http_rate_limited();
    }
    let body = format!(
        r#"{{"ok":true,"peers":{},"servers":{}}}"#,
        inner.peers.len(),
        inner.servers.len()
    );
    http_ok(&body)
}

fn route_request(state: &Arc<CommunityNodeState>, req: &HttpRequest) -> Vec<u8> {
    let ip = &req.peer_ip;
    let path = req.path.split('?').next().unwrap_or(&req.path);
    match req.method.as_str() {
        "GET" => {
            if path == "/servers" {
                handle_get_servers(state, ip)
            } else if path == "/peers" {
                handle_get_peers(state, ip)
            } else if path == "/health" {
                handle_get_health(state, ip)
            } else if let Some(id) = path.strip_prefix("/resolve/") {
                handle_get_resolve(state, ip, id.trim_end_matches('/'))
            } else {
                http_not_found()
            }
        }
        "POST" => {
            if path == "/gossip" {
                handle_post_gossip(state, ip, &req.body)
            } else {
                http_not_found()
            }
        }
        _ => http_not_found(),
    }
}

async fn handle_connection(
    mut stream: tokio::net::TcpStream,
    peer_addr: SocketAddr,
    state: Arc<CommunityNodeState>,
) {
    use tokio::io::AsyncWriteExt;
    let ip = peer_addr.ip().to_string();
    let Some(req) = read_request(&mut stream, ip).await else {
        return;
    };
    let response = route_request(&state, &req);
    let _ = stream.write_all(&response).await;
}

// ── Capacity helpers ───────────────────────────────────────────────────────────

fn cap_servers(list: &mut Vec<ServerEntry>, max: usize) {
    if list.len() > max {
        list.sort_unstable_by(|a, b| b.last_seen.cmp(&a.last_seen));
        list.truncate(max);
    }
}

fn cap_peers(list: &mut Vec<PeerEntry>, max: usize) {
    if list.len() > max {
        list.sort_unstable_by(|a, b| b.last_seen.cmp(&a.last_seen));
        list.truncate(max);
    }
}

// ── Background tasks ───────────────────────────────────────────────────────────

async fn http_listener_task(
    state: Arc<CommunityNodeState>,
    port: u16,
    mut shutdown: broadcast::Receiver<()>,
) {
    let addr = format!("0.0.0.0:{}", port);
    let listener = match tokio::net::TcpListener::bind(&addr).await {
        Ok(l) => l,
        Err(e) => {
            tracing::error!(port = port, error = %e, "Community node HTTP listener failed to bind");
            if let Ok(mut inner) = state.inner.write() {
                inner.running = false;
            }
            return;
        }
    };
    tracing::info!(port = port, "Community node HTTP listener started");

    loop {
        tokio::select! {
            result = listener.accept() => {
                match result {
                    Ok((stream, peer_addr)) => {
                        let s = state.clone();
                        tokio::spawn(async move {
                            handle_connection(stream, peer_addr, s).await;
                        });
                    }
                    Err(e) => {
                        tracing::warn!(error = %e, "Community node accept error");
                    }
                }
            }
            _ = shutdown.recv() => { break; }
        }
    }
    tracing::info!(port = port, "Community node HTTP listener stopped");
}

async fn gossip_task(
    state: Arc<CommunityNodeState>,
    control: Arc<ControlPlane>,
    mut shutdown: broadcast::Receiver<()>,
) {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .unwrap_or_else(|_| reqwest::Client::new());

    let mut interval =
        tokio::time::interval(std::time::Duration::from_secs(GOSSIP_INTERVAL_SECS));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    loop {
        tokio::select! {
            _ = interval.tick() => {
                run_gossip_round(&state, &control, &client).await;
            }
            _ = shutdown.recv() => { break; }
        }
    }
    tracing::info!("Community node gossip task stopped");
}

async fn run_gossip_round(
    state: &Arc<CommunityNodeState>,
    control: &Arc<ControlPlane>,
    client: &reqwest::Client,
) {
    update_self_entry(state, control).await;

    let (targets, payload) = {
        let inner = state.inner.read().unwrap();
        let targets = pick_gossip_targets(&inner);
        let payload = build_gossip_payload(&inner);
        (targets, payload)
    };

    let now = now_secs();

    for target_addr in targets {
        let url = format!("http://{}/gossip", target_addr);
        match client.post(&url).json(&payload).send().await {
            Ok(resp) if resp.status().is_success() => {
                if let Ok(incoming) = resp.json::<GossipMessage>().await {
                    merge_incoming(&state.inner, &incoming);
                }
                if let Ok(mut inner) = state.inner.write() {
                    if let Some(peer) = inner.peers.iter_mut().find(|p| p.addr == target_addr) {
                        peer.failures = 0;
                        peer.next_retry = 0;
                        peer.last_seen = now;
                    }
                }
            }
            Err(e) => {
                tracing::debug!(peer = %target_addr, error = %e, "Gossip to peer failed");
                if let Ok(mut inner) = state.inner.write() {
                    if let Some(peer) = inner.peers.iter_mut().find(|p| p.addr == target_addr) {
                        peer.failures = peer.failures.saturating_add(1);
                        let secs = (BACKOFF_BASE_SECS * (1u64 << peer.failures.min(4)))
                            .min(BACKOFF_MAX_SECS);
                        peer.next_retry = now + secs;
                    } else {
                        // Seed node not yet in peer list; add it with backoff
                        inner.peers.push(PeerEntry {
                            addr: target_addr,
                            last_seen: 0,
                            failures: 1,
                            next_retry: now + BACKOFF_BASE_SECS,
                        });
                    }
                }
            }
            _ => {}
        }
    }

    prune_stale(&state.inner);

    if let Ok(mut inner) = state.inner.write() {
        inner.last_gossip_at = now_secs();
    }

    state.save_to_disk();
}

fn pick_gossip_targets(inner: &InnerState) -> Vec<String> {
    let now = now_secs();
    let mut targets: Vec<String> = Vec::new();

    // Always include ≥1 seed (eclipse-attack resistance)
    for seed in &inner.seed_nodes {
        let backoff_ok = inner
            .peers
            .iter()
            .find(|p| &p.addr == seed)
            .map(|p| p.next_retry <= now)
            .unwrap_or(true);
        if backoff_ok {
            targets.push(seed.clone());
            break; // one seed is enough for the mandatory slot
        }
    }

    // Add random non-seed peers for the remaining slots
    let eligible: Vec<&PeerEntry> = inner
        .peers
        .iter()
        .filter(|p| !inner.seed_nodes.contains(&p.addr) && p.next_retry <= now)
        .collect();
    let n_extra = MAX_GOSSIP_TARGETS.saturating_sub(targets.len());
    let extra: Vec<String> = eligible
        .choose_multiple(&mut rand::thread_rng(), n_extra)
        .map(|p| p.addr.clone())
        .collect();
    targets.extend(extra);

    // If no peers at all yet, fall back to all seed nodes
    if targets.is_empty() {
        targets.extend(inner.seed_nodes.iter().cloned());
    }

    targets.truncate(MAX_GOSSIP_TARGETS);
    targets
}

fn build_gossip_payload(inner: &InnerState) -> GossipMessage {
    GossipMessage {
        from: format!("0.0.0.0:{}", inner.listen_port),
        peers: inner
            .peers
            .iter()
            .map(|p| GossipPeerRef {
                addr: p.addr.clone(),
                last_seen: p.last_seen,
            })
            .collect(),
        servers: inner.servers.clone(),
    }
}

fn merge_incoming(shared: &Arc<RwLock<InnerState>>, msg: &GossipMessage) {
    let now = now_secs();
    let Ok(mut inner) = shared.write() else {
        return;
    };
    for entry in &msg.servers {
        if !validate_gossip_server(entry) {
            continue;
        }
        if let Some(existing) = inner.servers.iter_mut().find(|s| s.id == entry.id) {
            if entry.last_seen > existing.last_seen {
                *existing = entry.clone();
            }
        } else if inner.servers.len() < MAX_SERVERS {
            inner.servers.push(entry.clone());
        }
    }
    for peer_ref in &msg.peers {
        if peer_ref.addr.is_empty() || peer_ref.last_seen > now + 300 {
            continue;
        }
        if let Some(existing) = inner.peers.iter_mut().find(|p| p.addr == peer_ref.addr) {
            if peer_ref.last_seen > existing.last_seen {
                existing.last_seen = peer_ref.last_seen;
            }
        } else if inner.peers.len() < MAX_PEERS {
            inner.peers.push(PeerEntry {
                addr: peer_ref.addr.clone(),
                last_seen: peer_ref.last_seen,
                failures: 0,
                next_retry: 0,
            });
        }
    }
}

fn prune_stale(shared: &Arc<RwLock<InnerState>>) {
    let now = now_secs();
    let Ok(mut inner) = shared.write() else {
        return;
    };
    let own_id = inner.server_id.clone();
    inner.servers.retain(|s| {
        s.id == own_id || now.saturating_sub(s.last_seen) <= SERVER_TTL_SECS
    });
    let seeds = inner.seed_nodes.clone();
    inner.peers.retain(|p| {
        seeds.contains(&p.addr) || now.saturating_sub(p.last_seen) <= PEER_TTL_SECS
    });
}

async fn update_self_entry(state: &Arc<CommunityNodeState>, control: &Arc<ControlPlane>) {
    let snapshot = control.snapshot();
    let mods = control.list_client_mods().unwrap_or_default();

    let Ok(mut inner) = state.inner.write() else {
        return;
    };

    if inner.server_id.is_empty() {
        return; // Not yet initialised; supervisor generates the ID before starting tasks
    }

    let node_mods: Vec<NodeModInfo> = mods
        .iter()
        .map(|m| NodeModInfo {
            name: m.name.clone(),
            size_bytes: m.size_bytes,
        })
        .collect();

    let game_port = state.config.general.port;
    let game_addr = format!("0.0.0.0:{}", game_port);
    let node_addr = format!("0.0.0.0:{}", inner.listen_port);
    let auth_mode = state.config.auth.mode.clone();
    let now = now_secs();

    let entry = ServerEntry {
        id: inner.server_id.clone(),
        name: sanitize_str(&snapshot.server_name, 64),
        description: sanitize_str(&state.config.general.description, 256),
        map: sanitize_str(&snapshot.map_display_name, 128),
        players: snapshot.player_count as u32,
        max_players: snapshot.max_players,
        region: inner.region.clone(),
        tags: inner.tags.clone(),
        auth_mode,
        mods: node_mods,
        addr: game_addr,
        node_addr,
        last_seen: now,
    };

    if let Some(existing) = inner.servers.iter_mut().find(|s| s.id == entry.id) {
        *existing = entry;
    } else {
        inner.servers.push(entry);
    }
}

// ── Supervisor ─────────────────────────────────────────────────────────────────

/// Long-running task that watches the enabled flag and manages HTTP + gossip tasks.
async fn node_supervisor(state: Arc<CommunityNodeState>, control: Arc<ControlPlane>) {
    let mut stop_tx: Option<broadcast::Sender<()>> = None;
    let mut running_port: Option<u16> = None;

    loop {
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;

        let (want_enabled, want_port) = {
            let Ok(inner) = state.inner.read() else {
                continue;
            };
            (inner.enabled, inner.listen_port)
        };

        let is_running = stop_tx.is_some();

        if want_enabled && !is_running {
            // Ensure server_id is set
            {
                let Ok(mut inner) = state.inner.write() else {
                    continue;
                };
                if inner.server_id.is_empty() {
                    inner.server_id = generate_server_id();
                    tracing::info!(server_id = %inner.server_id, "Generated community node server ID");
                }
                // Ensure all seed nodes are in peers list
                for seed in inner.seed_nodes.clone() {
                    if !inner.peers.iter().any(|p| p.addr == seed) {
                        inner.peers.push(PeerEntry {
                            addr: seed,
                            last_seen: 0,
                            failures: 0,
                            next_retry: 0,
                        });
                    }
                }
            }
            let (tx, _) = broadcast::channel::<()>(4);
            let rx_http = tx.subscribe();
            let rx_gossip = tx.subscribe();
            let control_for_gossip = control.clone();
            tokio::spawn(http_listener_task(state.clone(), want_port, rx_http));
            tokio::spawn(gossip_task(state.clone(), control_for_gossip, rx_gossip));
            running_port = Some(want_port);
            stop_tx = Some(tx);
            if let Ok(mut inner) = state.inner.write() {
                inner.running = true;
            }
            state.save_to_disk();
            tracing::info!(port = want_port, "Community node started");
        } else if !want_enabled && is_running {
            if let Some(tx) = stop_tx.take() {
                let _ = tx.send(());
            }
            running_port = None;
            if let Ok(mut inner) = state.inner.write() {
                inner.running = false;
            }
            state.save_to_disk();
            tracing::info!("Community node stopped");
        } else if want_enabled && is_running && running_port != Some(want_port) {
            // Port changed — restart listener
            if let Some(tx) = stop_tx.take() {
                let _ = tx.send(());
            }
            tokio::time::sleep(std::time::Duration::from_millis(200)).await;
            let (tx, _) = broadcast::channel::<()>(4);
            let rx_http = tx.subscribe();
            let rx_gossip = tx.subscribe();
            let control_for_gossip = control.clone();
            tokio::spawn(http_listener_task(state.clone(), want_port, rx_http));
            tokio::spawn(gossip_task(state.clone(), control_for_gossip, rx_gossip));
            running_port = Some(want_port);
            stop_tx = Some(tx);
            state.save_to_disk();
            tracing::info!(port = want_port, "Community node restarted on new port");
        }
    }
}

// ── Public API ─────────────────────────────────────────────────────────────────

impl CommunityNodeState {
    fn new(config: Arc<ServerConfig>, data_dir: String) -> Arc<Self> {
        let persisted = load_from_disk(&data_dir);
        let inner = InnerState::from_persisted(persisted);
        Arc::new(Self {
            inner: Arc::new(RwLock::new(inner)),
            data_dir,
            config,
        })
    }

    /// Read-only status snapshot for GUI / console display.
    pub fn status(&self) -> CommunityNodeStatus {
        let inner = self.inner.read().unwrap();
        CommunityNodeStatus {
            enabled: inner.enabled,
            server_id: inner.server_id.clone(),
            listen_port: inner.listen_port,
            region: inner.region.clone(),
            tags: inner.tags.clone(),
            seed_nodes: inner.seed_nodes.clone(),
            peer_count: inner.peers.len(),
            server_count: inner.servers.len(),
            last_gossip_at: inner.last_gossip_at,
            running: inner.running,
        }
    }

    /// Apply new settings from the GUI or console.  Persists immediately; the
    /// supervisor picks up the enabled/port change within ~1 second.
    pub fn apply_settings(
        &self,
        enabled: bool,
        port: u16,
        region: String,
        tags: Vec<String>,
        seed_nodes: Vec<String>,
    ) {
        let mut inner = self.inner.write().unwrap();
        inner.enabled = enabled;
        inner.listen_port = port;
        inner.region = region;
        inner.tags = tags;
        inner.seed_nodes = seed_nodes.clone();
        // Ensure seed nodes exist in the peer list
        for seed in &seed_nodes {
            if !inner.peers.iter().any(|p| &p.addr == seed) {
                inner.peers.push(PeerEntry {
                    addr: seed.clone(),
                    last_seen: 0,
                    failures: 0,
                    next_retry: 0,
                });
            }
        }
        drop(inner);
        self.save_to_disk();
    }

    pub fn add_seed_node(&self, addr: String) {
        let mut inner = self.inner.write().unwrap();
        if !inner.seed_nodes.contains(&addr) {
            inner.seed_nodes.push(addr.clone());
        }
        if !inner.peers.iter().any(|p| p.addr == addr) {
            inner.peers.push(PeerEntry {
                addr,
                last_seen: 0,
                failures: 0,
                next_retry: 0,
            });
        }
        drop(inner);
        self.save_to_disk();
    }

    pub fn remove_seed_node(&self, addr: &str) {
        let mut inner = self.inner.write().unwrap();
        inner.seed_nodes.retain(|s| s != addr);
        drop(inner);
        self.save_to_disk();
    }

    pub fn set_enabled(&self, enabled: bool) {
        self.inner.write().unwrap().enabled = enabled;
        self.save_to_disk();
    }

    pub fn set_port(&self, port: u16) {
        self.inner.write().unwrap().listen_port = port;
        self.save_to_disk();
    }

    pub fn set_region(&self, region: String) {
        self.inner.write().unwrap().region = region;
        self.save_to_disk();
    }

    pub fn set_tags(&self, tags: Vec<String>) {
        self.inner.write().unwrap().tags = tags;
        self.save_to_disk();
    }

    fn save_to_disk(&self) {
        let persisted = self.inner.read().unwrap().to_persisted();
        let path = std::path::Path::new(&self.data_dir).join(STATE_FILE);
        match serde_json::to_string_pretty(&persisted) {
            Ok(json) => {
                if let Err(e) = std::fs::write(&path, &json) {
                    tracing::warn!(path = %path.display(), error = %e, "Failed to save community node state");
                }
            }
            Err(e) => {
                tracing::warn!(error = %e, "Failed to serialise community node state");
            }
        }
    }
}

fn load_from_disk(data_dir: &str) -> PersistedState {
    let path = std::path::Path::new(data_dir).join(STATE_FILE);
    if let Ok(json) = std::fs::read_to_string(&path) {
        if let Ok(state) = serde_json::from_str::<PersistedState>(&json) {
            return state;
        }
    }
    PersistedState::default()
}

/// Initialise the community node.  Spawns a supervisor task that watches the
/// `enabled` flag and manages the HTTP listener and gossip loop.
///
/// Returns an [`Arc<CommunityNodeState>`] that should be stored in
/// [`ControlPlane`] for GUI and console access.
pub fn start(config: Arc<ServerConfig>, control: Arc<ControlPlane>) -> Arc<CommunityNodeState> {
    let data_dir = std::path::Path::new(&config.general.state_file)
        .parent()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|| ".".to_string());

    let state = CommunityNodeState::new(config, data_dir);
    let state_for_supervisor = state.clone();
    tokio::spawn(node_supervisor(state_for_supervisor, control));
    state
}

// ── Unit tests ─────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn make_entry(id: &str, last_seen: u64) -> ServerEntry {
        ServerEntry {
            id: id.to_string(),
            name: "Test".to_string(),
            description: String::new(),
            map: String::new(),
            players: 0,
            max_players: 10,
            region: String::new(),
            tags: Vec::new(),
            auth_mode: "open".to_string(),
            mods: Vec::new(),
            addr: "1.2.3.4:18860".to_string(),
            node_addr: "1.2.3.4:18862".to_string(),
            last_seen,
        }
    }

    #[test]
    fn test_validate_gossip_server_valid() {
        let e = make_entry("hb-1a2b3c", now_secs());
        assert!(validate_gossip_server(&e));
    }

    #[test]
    fn test_validate_gossip_server_bad_id() {
        let e = make_entry("bad-id", now_secs());
        assert!(!validate_gossip_server(&e));
    }

    #[test]
    fn test_validate_gossip_server_future_last_seen() {
        let e = make_entry("hb-1a2b3c", now_secs() + 9999);
        assert!(!validate_gossip_server(&e));
    }

    #[test]
    fn test_merge_keeps_newer_last_seen() {
        let shared = Arc::new(RwLock::new(InnerState::from_persisted(
            PersistedState::default(),
        )));
        let old = make_entry("hb-aabbcc", 100);
        let new = make_entry("hb-aabbcc", 200);
        {
            shared.write().unwrap().servers.push(old);
        }
        let msg = GossipMessage {
            from: "peer".to_string(),
            peers: Vec::new(),
            servers: vec![new],
        };
        merge_incoming(&shared, &msg);
        let inner = shared.read().unwrap();
        assert_eq!(inner.servers.len(), 1);
        assert_eq!(inner.servers[0].last_seen, 200);
    }

    #[test]
    fn test_merge_discards_older_last_seen() {
        let shared = Arc::new(RwLock::new(InnerState::from_persisted(
            PersistedState::default(),
        )));
        {
            shared
                .write()
                .unwrap()
                .servers
                .push(make_entry("hb-aabbcc", 500));
        }
        let older = make_entry("hb-aabbcc", 100);
        let msg = GossipMessage {
            from: "peer".to_string(),
            peers: Vec::new(),
            servers: vec![older],
        };
        merge_incoming(&shared, &msg);
        assert_eq!(shared.read().unwrap().servers[0].last_seen, 500);
    }

    #[test]
    fn test_cap_servers_enforced() {
        let mut list: Vec<ServerEntry> = (0..600)
            .map(|i| {
                let id = format!("hb-{:06x}", i);
                make_entry(&id, i as u64)
            })
            .collect();
        cap_servers(&mut list, MAX_SERVERS);
        assert_eq!(list.len(), MAX_SERVERS);
    }

    #[test]
    fn test_prune_stale_removes_old_servers() {
        let shared = Arc::new(RwLock::new(InnerState::from_persisted(
            PersistedState::default(),
        )));
        let expired = {
            let mut e = make_entry("hb-111111", 1); // very old
            e.id = "hb-111111".to_string();
            e
        };
        let fresh = make_entry("hb-aabbcc", now_secs());
        {
            let mut inner = shared.write().unwrap();
            inner.servers.push(expired);
            inner.servers.push(fresh);
        }
        prune_stale(&shared);
        let inner = shared.read().unwrap();
        assert_eq!(inner.servers.len(), 1);
        assert_eq!(inner.servers[0].id, "hb-aabbcc");
    }

    #[test]
    fn test_servers_response_omits_addr() {
        // Construct inner state with one server and verify JSON doesn't include "addr"
        let mut inner = InnerState::from_persisted(PersistedState::default());
        inner.servers.push(make_entry("hb-ffffff", now_secs()));
        let public: Vec<PublicServerEntry> = inner
            .servers
            .iter()
            .map(|s| PublicServerEntry {
                id: &s.id,
                name: &s.name,
                description: &s.description,
                map: &s.map,
                players: s.players,
                max_players: s.max_players,
                region: &s.region,
                tags: &s.tags,
                auth_mode: &s.auth_mode,
                mods: &s.mods,
            })
            .collect();
        let json = serde_json::to_string(&serde_json::json!({ "servers": public })).unwrap();
        assert!(
            !json.contains("\"addr\""),
            "/servers response must NOT contain addr field"
        );
        assert!(!json.contains("\"node_addr\""));
    }

    #[test]
    fn test_generate_server_id_format() {
        for _ in 0..20 {
            let id = generate_server_id();
            assert_eq!(id.len(), 9);
            assert!(id.starts_with("hb-"));
            assert!(id[3..].chars().all(|c| c.is_ascii_hexdigit()));
        }
    }

    #[test]
    fn test_rate_limiter_allows_under_limit() {
        let mut map: HashMap<String, RateBucket> = HashMap::new();
        for _ in 0..GENERAL_RATE_PER_MIN {
            assert!(check_rate(&mut map, "1.2.3.4", GENERAL_RATE_PER_MIN));
        }
    }

    #[test]
    fn test_rate_limiter_blocks_over_limit() {
        let mut map: HashMap<String, RateBucket> = HashMap::new();
        for _ in 0..GENERAL_RATE_PER_MIN {
            check_rate(&mut map, "1.2.3.4", GENERAL_RATE_PER_MIN);
        }
        assert!(!check_rate(&mut map, "1.2.3.4", GENERAL_RATE_PER_MIN));
    }

    #[test]
    fn test_is_private_host() {
        assert!(is_private_host("localhost"));
        assert!(is_private_host("127.0.0.1"));
        assert!(is_private_host("192.168.1.1"));
        assert!(is_private_host("10.0.0.1"));
        assert!(is_private_host("172.16.0.1"));
        assert!(!is_private_host("203.0.113.10"));
        assert!(!is_private_host("8.8.8.8"));
    }
}
