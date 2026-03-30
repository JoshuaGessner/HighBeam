# HighBeam Build Guide

> **Master implementation blueprint for the HighBeam project.**
> This document provides step-by-step instructions for building every component.
> Follow each phase in order. Each phase produces a testable deliverable.
>
> **Last updated:** 2026-03-29

---

## How to Use This Guide

1. **Work one phase at a time.** Each phase builds on the previous.
2. **Follow the file list exactly.** Each phase lists every file to create or modify.
3. **Run the acceptance tests** at the end of each phase before moving on.
4. **Update CHANGELOG.md** after completing each phase.
5. **Commit at each phase boundary** with a conventional commit.

### Original Work Policy

> **CRITICAL: HighBeam is 100% original code. Do NOT reference, translate, port, or adapt code from BeamMP.**
>
> BeamMP (Server, Launcher, and Client Mod) is licensed under **AGPL-3.0**, which is incompatible with HighBeam's **MIT** license. Even "translating" their C++ into Rust or their Lua patterns line-by-line would create a derivative work and force relicensing.
>
> **Rules:**
> - Never open BeamMP source files while writing HighBeam code.
> - Never copy function signatures, packet formats, or wire protocols from their codebase.
> - Our architecture docs describe *what* to build. Implement *how* from first principles, Rust/Lua documentation, and general game networking knowledge (Glenn Fiedler, Gabriel Gambetta, etc.).
> - If you need to understand a BeamNG.drive API, read BeamNG's own docs or test in the game console — do not look at how BeamMP calls it.
> - The `docs/reference/BEAMMP_RESEARCH.md` file documents public-facing behavior for competitive analysis only. It is NOT a code reference.

### Port Convention

HighBeam uses **port 18860** (TCP + UDP on the same port).

> Karl Benz patented the first automobile on January 29, **1886**. Port 18860 is our tribute to the birth of driving.

---

## Phase 0 — Project Scaffolding

**Goal:** Create the Rust project, client mod skeleton, and development tooling so all future phases have a home.

### 0.1 — Server Cargo Project

```bash
cd server/
cargo init --name highbeam-server
```

**Create `server/Cargo.toml`:**
```toml
[package]
name = "highbeam-server"
version = "0.1.0"
edition = "2021"
description = "HighBeam multiplayer server for BeamNG.drive"
license = "MIT"

[dependencies]
tokio = { version = "1", features = ["full"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
toml = "0.8"
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
bytes = "1"
thiserror = "2"
anyhow = "1"
rand = "0.8"
sha2 = "0.10"
```

> **Note:** `mlua`, `dashmap`, `argon2` are added in later phases when needed. Start lean.

**Create `server/src/main.rs`:**
```rust
use anyhow::Result;

mod config;

#[tokio::main]
async fn main() -> Result<()> {
    // Initialize logging
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info".into()),
        )
        .init();

    tracing::info!("HighBeam server v{}", env!("CARGO_PKG_VERSION"));

    // Load config
    let config = config::ServerConfig::load()?;
    tracing::info!(name = %config.general.name, port = config.general.port, "Configuration loaded");

    Ok(())
}
```

**Create `server/src/config.rs`:**
```rust
use anyhow::{Context, Result};
use serde::Deserialize;
use std::path::Path;

#[derive(Debug, Deserialize)]
pub struct ServerConfig {
    #[serde(rename = "General")]
    pub general: GeneralConfig,
    #[serde(rename = "Auth")]
    pub auth: AuthConfig,
    #[serde(rename = "Network")]
    pub network: NetworkConfig,
    #[serde(rename = "Logging")]
    pub logging: LoggingConfig,
}

#[derive(Debug, Deserialize)]
pub struct GeneralConfig {
    #[serde(rename = "Name")]
    pub name: String,
    #[serde(rename = "Port", default = "default_port")]
    pub port: u16,
    #[serde(rename = "MaxPlayers", default = "default_max_players")]
    pub max_players: u32,
    #[serde(rename = "MaxCarsPerPlayer", default = "default_max_cars")]
    pub max_cars_per_player: u32,
    #[serde(rename = "Map")]
    pub map: String,
    #[serde(rename = "Description", default)]
    pub description: String,
    #[serde(rename = "ResourceFolder", default = "default_resource_folder")]
    pub resource_folder: String,
}

#[derive(Debug, Deserialize)]
pub struct AuthConfig {
    #[serde(rename = "Mode", default = "default_auth_mode")]
    pub mode: String,
    #[serde(rename = "MaxAuthAttempts", default = "default_max_auth_attempts")]
    pub max_auth_attempts: u32,
    #[serde(rename = "AuthTimeoutSec", default = "default_auth_timeout")]
    pub auth_timeout_sec: u64,
}

#[derive(Debug, Deserialize)]
pub struct NetworkConfig {
    #[serde(rename = "TickRate", default = "default_tick_rate")]
    pub tick_rate: u32,
    #[serde(rename = "UdpBufferSize", default = "default_udp_buffer")]
    pub udp_buffer_size: usize,
    #[serde(rename = "TcpKeepAliveSec", default = "default_tcp_keepalive")]
    pub tcp_keepalive_sec: u64,
}

#[derive(Debug, Deserialize)]
pub struct LoggingConfig {
    #[serde(rename = "Level", default = "default_log_level")]
    pub level: String,
    #[serde(rename = "LogFile", default = "default_log_file")]
    pub log_file: String,
    #[serde(rename = "LogChat", default)]
    pub log_chat: bool,
}

fn default_port() -> u16 { 18860 }
fn default_max_players() -> u32 { 20 }
fn default_max_cars() -> u32 { 3 }
fn default_resource_folder() -> String { "Resources".into() }
fn default_auth_mode() -> String { "open".into() }
fn default_max_auth_attempts() -> u32 { 5 }
fn default_auth_timeout() -> u64 { 30 }
fn default_tick_rate() -> u32 { 20 }
fn default_udp_buffer() -> usize { 65535 }
fn default_tcp_keepalive() -> u64 { 15 }
fn default_log_level() -> String { "info".into() }
fn default_log_file() -> String { "server.log".into() }

impl ServerConfig {
    pub fn load() -> Result<Self> {
        let path = std::env::args()
            .nth(1)
            .unwrap_or_else(|| "ServerConfig.toml".into());

        if Path::new(&path).exists() {
            let contents = std::fs::read_to_string(&path)
                .with_context(|| format!("Failed to read config file: {path}"))?;
            toml::from_str(&contents)
                .with_context(|| format!("Failed to parse config file: {path}"))
        } else {
            tracing::warn!("No config file found at '{path}', using defaults");
            Ok(Self::default())
        }
    }
}

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            general: GeneralConfig {
                name: "HighBeam Server".into(),
                port: 18860,
                max_players: 20,
                max_cars_per_player: 3,
                map: "/levels/gridmap_v2/info.json".into(),
                description: String::new(),
                resource_folder: "Resources".into(),
            },
            auth: AuthConfig {
                mode: "open".into(),
                max_auth_attempts: 5,
                auth_timeout_sec: 30,
            },
            network: NetworkConfig {
                tick_rate: 20,
                udp_buffer_size: 65535,
                tcp_keepalive_sec: 15,
            },
            logging: LoggingConfig {
                level: "info".into(),
                log_file: "server.log".into(),
                log_chat: false,
            },
        }
    }
}
```

**Create `server/ServerConfig.toml`:**
```toml
[General]
Name = "My HighBeam Server"
Port = 18860
MaxPlayers = 20
MaxCarsPerPlayer = 3
Map = "/levels/gridmap_v2/info.json"
Description = "A HighBeam server"
ResourceFolder = "Resources"

[Auth]
Mode = "open"
MaxAuthAttempts = 5
AuthTimeoutSec = 30

[Network]
TickRate = 20
UdpBufferSize = 65535
TcpKeepAliveSec = 15

[Logging]
Level = "info"
LogFile = "server.log"
LogChat = true
```

### 0.2 — Client Mod Skeleton

**Create `client/scripts/highbeam/modScript.lua`:**
```lua
load('highbeam')
setExtensionUnloadMode('highbeam', 'manual')
```

**Create `client/lua/ge/extensions/highbeam.lua`:**
```lua
-- HighBeam - Decentralized multiplayer for BeamNG.drive
-- Main extension entry point (GELUA)

local M = {}
local logTag = "HighBeam"

-- Subsystem references (loaded in onExtensionLoaded)
local connection   -- highbeam/connection.lua
local protocol     -- highbeam/protocol.lua
local vehicles     -- highbeam/vehicles.lua
local state        -- highbeam/state.lua
local chat         -- highbeam/chat.lua
local config       -- highbeam/config.lua

M.onExtensionLoaded = function()
  log('I', logTag, 'HighBeam extension loaded')
end

M.onExtensionUnloaded = function()
  log('I', logTag, 'HighBeam extension unloaded')
end

M.onUpdate = function(dtReal, dtSim, dtRaw)
  -- Network tick: process incoming, send outgoing
end

return M
```

**Create stub files for each subsystem:**

`client/lua/ge/extensions/highbeam/config.lua`:
```lua
local M = {}
local logTag = "HighBeam.Config"

M.defaults = {
  updateRate = 20,
  interpolation = true,
  directConnectHost = "",
  directConnectPort = 18860,
  username = "",
  showChat = true,
}

M.current = {}

M.load = function()
  -- Copy defaults as starting config
  for k, v in pairs(M.defaults) do
    M.current[k] = v
  end
  log('I', logTag, 'Configuration loaded')
end

M.get = function(key)
  return M.current[key]
end

M.set = function(key, value)
  M.current[key] = value
end

return M
```

`client/lua/ge/extensions/highbeam/connection.lua`:
```lua
local M = {}
local logTag = "HighBeam.Connection"

-- Connection states
M.STATE_DISCONNECTED    = 0
M.STATE_CONNECTING      = 1
M.STATE_AUTHENTICATING  = 2
M.STATE_CONNECTED       = 3
M.STATE_DISCONNECTING   = 4

M.state = 0  -- STATE_DISCONNECTED

M.connect = function(host, port, username, password)
  log('I', logTag, 'Connect requested: ' .. host .. ':' .. tostring(port))
end

M.disconnect = function()
  log('I', logTag, 'Disconnect requested')
end

M.tick = function(dt)
  -- Process network I/O each frame
end

M.getState = function()
  return M.state
end

return M
```

`client/lua/ge/extensions/highbeam/protocol.lua`:
```lua
local M = {}
local logTag = "HighBeam.Protocol"

M.VERSION = 1

-- TCP packet encode/decode stubs
M.encodeTcp = function(packetType, data)
  return nil
end

M.decodeTcp = function(rawData)
  return nil
end

-- UDP packet encode/decode stubs
-- Binary UDP encode/decode (fixed-layout, zero JSON overhead)
-- See PROTOCOL.md for packet layouts

local ffi = require("ffi")

-- Position update: type 0x10
-- Layout: [vid:u16] [pos:3xf32] [rot:4xf32] [vel:3xf32] [time:f32]
-- Total payload (after session hash + type byte): 46 bytes

M.encodePositionUpdate = function(sessionHash, vehicleId, pos, rot, vel, simTime)
  local buf = ffi.new("uint8_t[63]")  -- 16 hash + 1 type + 46 payload
  ffi.copy(buf, sessionHash, 16)
  buf[16] = 0x10  -- type byte

  local ptr = ffi.cast("uint16_t*", buf + 17)
  ptr[0] = vehicleId

  local fp = ffi.cast("float*", buf + 19)
  fp[0], fp[1], fp[2] = pos[1], pos[2], pos[3]          -- pos  (12B)
  fp[3], fp[4], fp[5], fp[6] = rot[1], rot[2], rot[3], rot[4]  -- rot  (16B)
  fp[7], fp[8], fp[9] = vel[1], vel[2], vel[3]          -- vel  (12B)
  fp[10] = simTime                                        -- time (4B)

  return ffi.string(buf, 63)
end

-- Decode relayed position update from server
-- Server-relayed layout adds pid:u16 after type byte → 65 bytes total
M.decodePositionUpdate = function(data)
  if #data < 65 then return nil end
  local buf = ffi.cast("const uint8_t*", data)
  -- buf[0..15] = session hash (already validated by caller)
  -- buf[16] = 0x10 type (already matched by caller)

  local pid = ffi.cast("const uint16_t*", buf + 17)[0]
  local vid = ffi.cast("const uint16_t*", buf + 19)[0]
  local fp  = ffi.cast("const float*", buf + 21)

  return {
    playerId  = pid,
    vehicleId = vid,
    pos  = { fp[0], fp[1], fp[2] },
    rot  = { fp[3], fp[4], fp[5], fp[6] },
    vel  = { fp[7], fp[8], fp[9] },
    time = fp[10],
  }
end

return M
```

`client/lua/ge/extensions/highbeam/vehicles.lua`:
```lua
local M = {}
local logTag = "HighBeam.Vehicles"

M.remoteVehicles = {}  -- [playerId_vehicleId] = vehicleData

M.spawnRemote = function(playerId, vehicleId, configData)
end

M.updateRemote = function(playerId, vehicleId, pos, rot, vel)
end

M.removeRemote = function(playerId, vehicleId)
end

M.removeAllForPlayer = function(playerId)
end

M.tick = function(dt)
  -- Apply interpolation to remote vehicles
end

return M
```

`client/lua/ge/extensions/highbeam/state.lua`:
```lua
local M = {}
local logTag = "HighBeam.State"

M.localVehicles = {}  -- [gameVehicleId] = { serverId, lastSentTime, ... }
M.playerId = nil
M.sessionToken = nil

M.tick = function(dt)
  -- Check for vehicle spawns/deletes, send position updates at configured rate
end

return M
```

`client/lua/ge/extensions/highbeam/chat.lua`:
```lua
local M = {}
local logTag = "HighBeam.Chat"

M.messages = {}

M.send = function(message)
end

M.receive = function(playerId, playerName, message)
  table.insert(M.messages, {
    playerId = playerId,
    name = playerName,
    message = message,
    time = os.time(),
  })
end

return M
```

### 0.3 — Verify Scaffolding

**Server acceptance test:**
```bash
cd server && cargo build 2>&1 | tail -5
# Expected: Compiling highbeam-server v0.1.0, Finished
./target/debug/highbeam-server
# Expected: "HighBeam server v0.1.0" then "No config file found" warning
./target/debug/highbeam-server ServerConfig.toml
# Expected: "Configuration loaded" with name and port 18860
```

**Client acceptance test:**
1. Zip the `client/` contents into `highbeam.zip`
2. Place in BeamNG's mods folder
3. Launch BeamNG, check the console (`~` key) for "HighBeam extension loaded"

**Commit:** `feat: scaffold server cargo project and client mod skeleton`

---

## Phase 1 — TCP Connection & Auth (v0.1.0)

**Goal:** A client can connect to a server over TCP, complete the auth handshake, and see "Player connected" in the server log.

### 1.1 — Server: TCP Listener

**Create `server/src/net/mod.rs`:**
```rust
pub mod tcp;
pub mod packet;
```

**Create `server/src/net/packet.rs`:**

Define the packet types as Rust enums:

```rust
use serde::{Deserialize, Serialize};

/// All TCP packet types (JSON-encoded, length-prefixed)
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum TcpPacket {
    // Server → Client
    #[serde(rename = "server_hello")]
    ServerHello {
        version: u32,
        name: String,
        map: String,
        players: u32,
        max_players: u32,
        max_cars: u32,
    },
    #[serde(rename = "auth_response")]
    AuthResponse {
        success: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        player_id: Option<u32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        session_token: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    #[serde(rename = "player_join")]
    PlayerJoin { player_id: u32, name: String },
    #[serde(rename = "player_leave")]
    PlayerLeave { player_id: u32 },
    #[serde(rename = "kick")]
    Kick { reason: String },

    // Client → Server
    #[serde(rename = "auth_request")]
    AuthRequest {
        username: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        password: Option<String>,
    },
    #[serde(rename = "ready")]
    Ready {},
}
```

Key implementation details for `packet.rs`:
- Add `pub fn encode(packet: &TcpPacket) -> Vec<u8>` — serializes to JSON, prepends 4-byte LE length
- Add `pub fn decode(buf: &[u8]) -> Result<TcpPacket>` — reads 4-byte LE length, deserializes JSON payload
- Add comprehensive `#[cfg(test)]` round-trip tests for every variant
- Use `serde_json` for serialization
- Maximum packet size constant: `const MAX_PACKET_SIZE: u32 = 1_048_576;` (1 MB)

**Create `server/src/net/tcp.rs`:**

This is the TCP listener and per-connection handler.

```rust
// Pseudocode structure:
pub async fn start_listener(config: Arc<ServerConfig>, sessions: Arc<SessionManager>) -> Result<()> {
    let listener = TcpListener::bind(("0.0.0.0", config.general.port)).await?;
    tracing::info!(port = config.general.port, "TCP listener started");

    loop {
        let (stream, addr) = listener.accept().await?;
        let config = config.clone();
        let sessions = sessions.clone();
        tokio::spawn(async move {
            if let Err(e) = handle_connection(stream, addr, config, sessions).await {
                tracing::warn!(%addr, error = %e, "Connection error");
            }
        });
    }
}
```

Per-connection handler flow:
1. Set TCP_NODELAY on the socket
2. Send `ServerHello` packet immediately
3. Wait for `AuthRequest` with timeout (`auth_timeout_sec`)
4. Validate auth (for v0.1.0, `open` mode only — accept all)
5. Generate session token (32 bytes, hex-encoded, from `rand`)
6. Assign player_id (incrementing counter)
7. Send `AuthResponse` with success, player_id, session_token
8. Wait for `Ready` packet
9. Register player in SessionManager
10. Enter main receive loop: read length-prefixed packets, dispatch to handlers
11. On disconnect: deregister from SessionManager, log

**TCP framing helper:**
```rust
// Read exactly one length-prefixed packet from a TcpStream
async fn read_packet(stream: &mut TcpStream) -> Result<TcpPacket> {
    let mut len_buf = [0u8; 4];
    stream.read_exact(&mut len_buf).await?;
    let len = u32::from_le_bytes(len_buf);
    if len > MAX_PACKET_SIZE {
        anyhow::bail!("Packet too large: {len} bytes");
    }
    let mut payload = vec![0u8; len as usize];
    stream.read_exact(&mut payload).await?;
    let packet: TcpPacket = serde_json::from_slice(&payload)?;
    Ok(packet)
}

async fn write_packet(stream: &mut TcpStream, packet: &TcpPacket) -> Result<()> {
    let json = serde_json::to_vec(packet)?;
    let len = (json.len() as u32).to_le_bytes();
    stream.write_all(&len).await?;
    stream.write_all(&json).await?;
    stream.flush().await?;
    Ok(())
}
```

### 1.2 — Server: Session Manager

**Create `server/src/session/mod.rs`:**
```rust
pub mod manager;
pub mod player;
```

**Create `server/src/session/player.rs`:**
```rust
pub struct Player {
    pub id: u32,
    pub name: String,
    pub session_token: String,
    pub addr: SocketAddr,
    pub tcp_tx: mpsc::Sender<TcpPacket>,  // Channel to send packets to this player's TCP writer
    pub connected_at: Instant,
    pub last_activity: Instant,
}
```

**Create `server/src/session/manager.rs`:**
```rust
pub struct SessionManager {
    players: DashMap<u32, Player>,        // player_id → Player
    token_map: DashMap<String, u32>,      // session_token → player_id
    next_id: AtomicU32,
}

impl SessionManager {
    pub fn new() -> Self { ... }
    pub fn add_player(&self, name: String, addr: SocketAddr, tcp_tx: mpsc::Sender<TcpPacket>) -> (u32, String) { ... }
    pub fn remove_player(&self, player_id: u32) { ... }
    pub fn get_player(&self, player_id: u32) -> Option<Ref<u32, Player>> { ... }
    pub fn player_count(&self) -> usize { ... }
    pub fn broadcast(&self, packet: TcpPacket, exclude: Option<u32>) { ... }
}
```

> **Note:** Add `dashmap = "6"` to Cargo.toml when implementing this phase.

### 1.3 — Client: TCP Connection

**Implement `client/lua/ge/extensions/highbeam/connection.lua`:**

The critical networking question: **How do we open TCP sockets from within BeamNG's Lua?**

BeamNG uses LuaJIT. We attempt to load `socket` (LuaSocket) which is commonly bundled:

```lua
local socket = require("socket")  -- LuaSocket library
```

If LuaSocket is not available, we fall back to LuaJIT FFI for raw socket access. **Try LuaSocket first** — it's simpler and sufficient for our needs.

Key connection.lua implementation:

```lua
local socket = require("socket")

local M = {}
local logTag = "HighBeam.Connection"
local tcp = nil
local recvBuffer = ""
local HEADER_SIZE = 4  -- 4-byte LE uint32 length prefix

M.connect = function(host, port, username, password)
  M.state = M.STATE_CONNECTING
  tcp = socket.tcp()
  tcp:settimeout(0)  -- NON-BLOCKING: critical for not freezing the game

  local ok, err = tcp:connect(host, port)
  -- Non-blocking connect returns nil, "timeout" immediately
  -- Must check with socket.select() on subsequent ticks
  if ok or err == "timeout" then
    -- Connection in progress
    M._pendingAuth = { username = username, password = password }
  else
    log('E', logTag, 'Connect failed: ' .. tostring(err))
    M.state = M.STATE_DISCONNECTED
  end
end

M.tick = function(dt)
  if M.state == M.STATE_CONNECTING then
    -- Check if TCP connect completed
    local _, writable = socket.select(nil, {tcp}, 0)
    if writable and #writable > 0 then
      -- Connected! Wait for ServerHello
      M.state = M.STATE_AUTHENTICATING
    end
  end

  if M.state == M.STATE_AUTHENTICATING or M.state == M.STATE_CONNECTED then
    -- Read available data (non-blocking)
    local data, err, partial = tcp:receive(8192)
    local chunk = data or partial
    if chunk and #chunk > 0 then
      recvBuffer = recvBuffer .. chunk
      M._processBuffer()
    end
    if err == "closed" then
      M._onDisconnect("Connection closed by server")
    end
  end
end

M._processBuffer = function()
  while #recvBuffer >= HEADER_SIZE do
    -- Read 4-byte LE length
    local b1, b2, b3, b4 = recvBuffer:byte(1, 4)
    local payloadLen = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
    if payloadLen > 1048576 then
      M._onDisconnect("Packet too large")
      return
    end
    if #recvBuffer < HEADER_SIZE + payloadLen then
      break  -- Wait for more data
    end
    local json = recvBuffer:sub(HEADER_SIZE + 1, HEADER_SIZE + payloadLen)
    recvBuffer = recvBuffer:sub(HEADER_SIZE + payloadLen + 1)
    M._handlePacket(json)
  end
end

M._sendPacket = function(packetTable)
  local json = require("highbeam/lib/json").encode(packetTable)
  local len = #json
  local header = string.char(
    len % 256,
    math.floor(len / 256) % 256,
    math.floor(len / 65536) % 256,
    math.floor(len / 16777216) % 256
  )
  tcp:send(header .. json)
end
```

> **JSON library:** BeamNG includes `jsonDecode`/`jsonEncode` globally, or we can bundle a small `dkjson.lua` or `json.lua` in `highbeam/lib/`. Check BeamNG's available globals first.

**Handshake flow in `_handlePacket`:**
1. Receive `server_hello` → validate protocol version → send `auth_request`
2. Receive `auth_response` → if success, store player_id + session_token → send `ready`
3. Receive `world_state` → transition to `STATE_CONNECTED`, populate vehicles
4. All other packets → dispatch to appropriate subsystem

### 1.4 — Wire It Together

**Update `server/src/main.rs`:**
```rust
mod config;
mod net;
mod session;

#[tokio::main]
async fn main() -> Result<()> {
    // ... logging, config loading ...
    let sessions = Arc::new(session::manager::SessionManager::new());
    net::tcp::start_listener(Arc::new(config), sessions).await?;
    Ok(())
}
```

**Update `client/lua/ge/extensions/highbeam.lua` `onUpdate`:**
```lua
M.onUpdate = function(dtReal, dtSim, dtRaw)
  if connection then
    connection.tick(dtReal)
  end
end
```

### 1.5 — Phase 1 Acceptance Tests

| Test | How | Expected Result |
|------|-----|-----------------|
| Server starts | `cargo run` | Logs "TCP listener started" on port 18860 |
| Client connects | BeamNG → HighBeam connect to `127.0.0.1:18860` | Server logs "Player connected", client sees `STATE_CONNECTED` |
| Auth works | Connect with username "TestPlayer" | Server assigns player_id=1, client receives session token |
| Disconnect clean | Close BeamNG or call disconnect | Server logs "Player disconnected", removes session |
| Reject oversized | Send >1MB packet | Server drops connection, logs warning |
| Multiple clients | Two BeamNG instances connect | Both get unique player_ids, server shows count=2 |

**Commit:** `feat(server,client): TCP handshake and auth flow (v0.1.0)`

---

## Phase 2 — Vehicle Sync (v0.2.0)

**Goal:** Multiple players can see each other's vehicles driving in real-time.

### 2.1 — Server: UDP Socket

**Create `server/src/net/udp.rs`:**

```rust
pub async fn start_udp(
    port: u16,
    sessions: Arc<SessionManager>,
    state: Arc<WorldState>,
) -> Result<()> {
    let socket = UdpSocket::bind(("0.0.0.0", port)).await?;
    tracing::info!(port, "UDP socket bound");

    let mut buf = vec![0u8; 65535];
    loop {
        let (len, addr) = socket.recv_from(&mut buf).await?;
        if len < 17 { continue; }  // Minimum: 16B session hash + 1B type

        let session_hash = &buf[..16];
        let packet_type = buf[16];

        // Validate session
        let player_id = match sessions.lookup_by_hash(session_hash) {
            Some(id) => id,
            None => continue,  // Silently drop unknown sessions
        };

        match packet_type {
            0x01 => { /* UdpBind: register this addr for the player */ }
            0x10 => {
                // Position update: binary format (see PROTOCOL.md)
                // Client sends 63 bytes: [16B hash][0x10][2B vid][12B pos][16B rot][12B vel][4B time]
                // Server relays 65 bytes: [16B hash][0x10][2B pid][2B vid][12B pos][16B rot][12B vel][4B time]
                if len < 63 { continue; }

                // Build relay packet: insert player_id (u16 LE) after type byte
                let mut relay = Vec::with_capacity(65);
                relay.extend_from_slice(&buf[..17]);          // hash + type
                relay.extend_from_slice(&(player_id as u16).to_le_bytes());  // pid
                relay.extend_from_slice(&buf[17..len]);       // vid + pos + rot + vel + time

                // Relay to all other players' registered UDP addresses
                sessions.broadcast_udp(&socket, &relay, Some(player_id)).await;
            }
            _ => { /* Unknown type, ignore */ }
        }
    }
}
```

**UDP session hash lookup:** The `SessionManager` needs a new map:
```rust
session_hashes: DashMap<[u8; 16], u32>,  // truncated SHA-256 of token → player_id
```

Computed when a player is added: `SHA256(session_token)[0..16]`.

### 2.2 — Server: Vehicle State

**Create `server/src/state/mod.rs`:**
```rust
pub mod vehicle;
pub mod world;
```

**Create `server/src/state/vehicle.rs`:**
```rust
pub struct Vehicle {
    pub id: u16,
    pub owner_id: u32,
    pub config: String,      // JSON blob of vehicle config
    pub position: [f32; 3],
    pub rotation: [f32; 4],
    pub velocity: [f32; 3],
    pub last_update: Instant,
}
```

**Create `server/src/state/world.rs`:**
```rust
pub struct WorldState {
    vehicles: DashMap<(u32, u16), Vehicle>,  // (player_id, vehicle_id) → Vehicle
    next_vehicle_id: AtomicU16,
}

impl WorldState {
    pub fn spawn_vehicle(&self, owner_id: u32, config: String) -> u16 { ... }
    pub fn remove_vehicle(&self, owner_id: u32, vehicle_id: u16) { ... }
    pub fn remove_all_for_player(&self, player_id: u32) { ... }
    pub fn update_position(&self, player_id: u32, vehicle_id: u16, pos: [f32;3], rot: [f32;4], vel: [f32;3]) { ... }
    pub fn get_world_snapshot(&self) -> Vec<(u32, Vehicle)> { ... }
}
```

### 2.3 — Server: Vehicle TCP Handlers

Add new packet variants to `packet.rs`:
```rust
#[serde(rename = "vehicle_spawn")]
VehicleSpawn { player_id: Option<u32>, vehicle_id: u16, data: String },
#[serde(rename = "vehicle_edit")]
VehicleEdit { player_id: Option<u32>, vehicle_id: u16, data: String },
#[serde(rename = "vehicle_delete")]
VehicleDelete { player_id: Option<u32>, vehicle_id: u16 },
#[serde(rename = "vehicle_reset")]
VehicleReset { player_id: Option<u32>, vehicle_id: u16, data: String },
#[serde(rename = "world_state")]
WorldState { players: Vec<PlayerInfo>, vehicles: Vec<VehicleInfo> },
```

Handle in the TCP receive loop:
- `VehicleSpawn` → validate ownership, register in `WorldState`, broadcast to others
- `VehicleEdit` → validate ownership, update config, broadcast
- `VehicleDelete` → validate ownership, remove from `WorldState`, broadcast
- On player join → send `WorldState` with all current vehicles
- On player disconnect → remove all vehicles for that player, broadcast `VehicleDelete` for each

### 2.4 — Client: UDP Position Sending

**Implement in `client/lua/ge/extensions/highbeam/state.lua`:**

```lua
local M = {}
local sendTimer = 0
local updateInterval  -- set from config.get("updateRate")

M.tick = function(dt)
  if not connection or connection.getState() ~= connection.STATE_CONNECTED then return end

  updateInterval = 1.0 / (config.get("updateRate") or 20)
  sendTimer = sendTimer + dt
  if sendTimer < updateInterval then return end
  sendTimer = sendTimer - updateInterval

  -- Get all local vehicles and send position updates
  local playerVehicle = be:getPlayerVehicle(0)
  if playerVehicle then
    local pos = playerVehicle:getPosition()
    local rot = quatFromDir(playerVehicle:getDirectionVector(), playerVehicle:getDirectionVectorUp())
    local vel = playerVehicle:getVelocity()

    connection.sendUdp(protocol.encodePositionUpdate(
      connection.getSessionHash(),              -- 16-byte session hash
      M.localVehicles[playerVehicle:getId()],   -- server-assigned vehicle ID
      {pos.x, pos.y, pos.z},
      {rot.x, rot.y, rot.z, rot.w},
      {vel.x, vel.y, vel.z},
      playerVehicle:getSimTime()                -- simulation time
    ))
  end
end
```

**Get vehicle data from BeamNG:**
- `be:getPlayerVehicle(n)` returns the nth player vehicle object
- `vehicle:getPosition()` returns vec3
- `vehicle:getVelocity()` returns vec3
- Rotation: use `vehicle:getRotation()` or compute from direction vectors
- For multi-vehicle support, iterate `be:getObjectCount()` and `be:getObject(i)`

### 2.5 — Client: UDP Socket & Position Receiving

**Add to `connection.lua`:**
```lua
local udp = nil

M.bindUdp = function(host, port, sessionToken)
  udp = socket.udp()
  udp:settimeout(0)  -- Non-blocking
  udp:setpeername(host, port)  -- Connected mode for ~30% performance gain

  -- Send UdpBind packet
  local hash = M._computeSessionHash(sessionToken)
  udp:send(hash .. string.char(0x01))
end

M.sendUdp = function(data)
  if udp then udp:send(data) end
end

M._tickUdp = function()
  if not udp then return end
  -- Read all available UDP packets (non-blocking)
  while true do
    local data = udp:receive()
    if not data then break end
    if #data >= 65 and data:byte(17) == 0x10 then
      -- Binary position update — decode and dispatch directly
      local decoded = protocol.decodePositionUpdate(data)
      if decoded then
        vehicles.updateRemote(decoded)
      end
    end
  end
end
```

**Position update reception in `vehicles.lua`:**

The connection layer calls `protocol.decodePositionUpdate(data)` on each received UDP packet,
then dispatches the decoded struct here:

```lua
M.updateRemote = function(decoded)
  local key = decoded.playerId .. "_" .. decoded.vehicleId
  local rv = M.remoteVehicles[key]
  if not rv then return end

  -- Push new snapshot into interpolation buffer
  table.insert(rv.snapshots, {
    pos = decoded.pos,
    rot = decoded.rot,
    vel = decoded.vel,
    time = decoded.time,
    received = os.clock(),
  })
  -- Keep only last 3 snapshots
  while #rv.snapshots > 3 do
    table.remove(rv.snapshots, 1)
  end
end

M.tick = function(dt)
  for key, rv in pairs(M.remoteVehicles) do
    if rv.gameVehicle and #rv.snapshots >= 2 then
      -- Interpolate between two most recent snapshots
      local s1 = rv.snapshots[#rv.snapshots - 1]
      local s2 = rv.snapshots[#rv.snapshots]
      local t = math.min(1.0, (os.clock() - s2.received) / (s2.received - s1.received))
      t = math.max(0, math.min(1, t))

      local pos = lerpVec3(s1.pos, s2.pos, t)
      local rot = slerpQuat(s1.rot, s2.rot, t)
      rv.gameVehicle:setPositionRotation(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
    end
  end
end
```

### 2.6 — Client: Vehicle Spawning

**Receiving a remote vehicle spawn:**
```lua
M.spawnRemote = function(playerId, vehicleId, configJson)
  -- Use BeamNG API to spawn a vehicle
  local config = jsonDecode(configJson)
  local spawnData = {
    model = config.model or "pickup",
    config = config.partConfig or "",
    pos = config.pos or {0, 0, 0},
    rot = config.rot or {0, 0, 0, 1},
  }

  -- Spawn via BeamNG API
  local vid = be:spawnVehicle(spawnData.model, spawnData.config,
    vec3(spawnData.pos[1], spawnData.pos[2], spawnData.pos[3]),
    quat(spawnData.rot[1], spawnData.rot[2], spawnData.rot[3], spawnData.rot[4])
  )

  local key = playerId .. "_" .. vehicleId
  M.remoteVehicles[key] = {
    playerId = playerId,
    vehicleId = vehicleId,
    gameVehicle = scenetree.findObjectById(vid),
    snapshots = {},
  }
end
```

> **Note:** The exact BeamNG spawn API may differ. Use `core_vehicles.spawnNewVehicle()` or similar from the BeamNG codebase. Test in BeamNG console first.

### 2.7 — Phase 2 Acceptance Tests

| Test | How | Expected Result |
|------|-----|-----------------|
| UDP binds | Client sends UdpBind after auth | Server logs "UDP bound for player X" |
| Binary encoding | Capture UDP packet, check size | Outgoing = 63 bytes, relayed = 65 bytes (no JSON) |
| Position sending | Client drives, monitor server | Server receives position updates at ~20Hz |
| Vehicle spawn relay | Player A spawns car | Player B sees the car appear |
| Position relay | Player A drives | Player B sees Player A's car moving smoothly |
| Vehicle delete | Player A removes car | Player B sees car disappear |
| Disconnect cleanup | Player A disconnects | All of Player A's vehicles removed from Player B's view |
| Interpolation | Player B observes Player A | Movement is smooth, no teleporting between updates |
| Multi-vehicle | Player A has 2 vehicles | Player B sees both vehicles correctly |
| World state on join | Player B joins after Player A | Player B sees Player A's existing vehicles |

**Commit:** `feat(server,client): vehicle sync with UDP position relay (v0.2.0)`

---

## Phase 3 — Chat, Mods & Auth (v0.3.0)

**Goal:** Full multiplayer experience with chat, mod distribution, and multiple auth modes.

### 3.1 — Chat System

**Server (`server/src/net/tcp.rs` handler additions):**
- On `ChatMessage` received: validate (rate limit, max length 500 chars), broadcast to all players
- Also dispatch to plugin event system (`onChatMessage`)

**Client (`chat.lua`):**
- `M.send(message)` → encode as `{type: "chat_message", message: text}`, send via TCP
- `M.receive(playerId, name, message)` → append to message buffer, trigger UI update via `guihooks.trigger`
- Display via HTML/JS UI app (`ui/modules/apps/HighBeam/`)

### 3.2 — Authentication Modes

**Add `argon2 = "0.5"` and update `server/src/session/auth.rs`:**

```rust
pub enum AuthMode {
    Open,
    Password { hash: String },
    Allowlist { entries: Vec<AllowlistEntry> },
}

pub struct AllowlistEntry {
    pub username: String,
    pub token_hash: Option<String>,
}

pub fn validate_auth(mode: &AuthMode, username: &str, password: Option<&str>) -> AuthResult {
    match mode {
        AuthMode::Open => AuthResult::Accept,
        AuthMode::Password { hash } => {
            match password {
                Some(pw) => {
                    if argon2::verify_encoded(hash, pw.as_bytes()).unwrap_or(false) {
                        AuthResult::Accept
                    } else {
                        AuthResult::Reject("Invalid password".into())
                    }
                }
                None => AuthResult::Reject("Password required".into()),
            }
        }
        AuthMode::Allowlist { entries } => {
            if entries.iter().any(|e| e.username == username) {
                AuthResult::Accept
            } else {
                AuthResult::Reject("Not on allowlist".into())
            }
        }
    }
}
```

**Password handling on first run:**
When `Mode = "password"` and the config contains a plaintext password, hash it with Argon2 and write the hash back to the config file. Log a message explaining the password was hashed.

### 3.3 — Mod Distribution

**Server-side:**
- On `Ready` received, check if client needs mods from `Resources/Client/`
- Send `ModInfo` packets: `{ type: "mod_info", name: "mod.zip", size: 12345, hash: "sha256..." }`
- Client responds with which mods it needs
- Server sends `ModData` packets: chunked binary (base64 in JSON for v0.3.0, raw TCP stream in v0.5.0)

**Client-side:**
- Compare mod hashes with locally cached mods
- Download missing mods, save to BeamNG mods directory
- Enable downloaded mods in BeamNG's mod system
- Show download progress in connection UI

### 3.4 — Rate Limiting

**Server-side (`server/src/session/auth.rs`):**

```rust
pub struct RateLimiter {
    attempts: DashMap<IpAddr, Vec<Instant>>,
    max_attempts: u32,
    window: Duration,
}

impl RateLimiter {
    pub fn check(&self, addr: IpAddr) -> bool {
        // Remove entries older than window, check count < max
    }
    pub fn record(&self, addr: IpAddr) { ... }
}
```

Apply to:
- Auth attempts (per IP)
- Chat messages (per player: max 5 per second)
- Vehicle spawns (per player: max 1 per second)

### 3.5 — Client UI

**Create `client/ui/modules/apps/HighBeam/app.html`:**
- Direct connect panel: host input, port input, username input, connect button
- Connection status display
- Chat messages list with input field
- Player list panel

**Communication with GELUA:**
```javascript
// Send to Lua
bngApi.engineLua('highbeam.connect("' + host + '", ' + port + ', "' + username + '")')

// Receive from Lua
$scope.$on('HighBeamChatMessage', function(event, data) {
    $scope.messages.push(data);
    $scope.$apply();
});
```

### 3.6 — Phase 3 Acceptance Tests

| Test | How | Expected Result |
|------|-----|-----------------|
| Chat works | Player A sends message | Player B sees it in chat UI |
| Password auth | Set Mode="password" | Client must enter correct password to connect |
| Wrong password | Enter incorrect password | Client gets "Invalid password" error, not connected |
| Allowlist | Set Mode="allowlist" | Only listed usernames can connect |
| Mod download | Server has mod in Resources/Client/ | Client downloads and enables mod on connect |
| Rate limit auth | Send 6 rapid auth attempts | 6th attempt blocked, IP temporarily banned |
| Rate limit chat | Send 10 messages in 1 second | Messages after 5th are dropped |
| Max players | Set MaxPlayers=2, connect 3 clients | 3rd client rejected with "Server full" |
| Max cars | Set MaxCarsPerPlayer=2, spawn 3 | 3rd spawn rejected |
| Reconnection | Kill and restart client | Client reconnects with backoff |

**Commit:** `feat(server,client): chat, auth modes, and mod distribution (v0.3.0)`

---

## Phase 4 — Plugin System (v0.4.0)

**Goal:** Server operators can run Lua plugins that hook into game events.

### 4.1 — Plugin Runtime

**Add `mlua = { version = "0.10", features = ["lua54", "serialize", "async"] }` to Cargo.toml.**

**Create `server/src/plugin/mod.rs`:**
```rust
pub mod runtime;
pub mod api;
pub mod events;
```

**Create `server/src/plugin/runtime.rs`:**

```rust
pub struct PluginManager {
    plugins: Vec<Plugin>,
}

pub struct Plugin {
    name: String,
    lua: mlua::Lua,
}

impl PluginManager {
    pub fn load_plugins(resource_path: &Path) -> Result<Self> {
        // Scan Resources/Server/*/
        // For each plugin directory:
        //   1. Read plugin.toml manifest (required)
        //   2. Create a new Lua state
        //   3. Register HB.* and Util.* APIs
        //   4. Load the entry_point file from plugin.toml
        //   5. Call OnInit if registered
        // Resolve load order from plugin.toml `depends` fields (topological sort)
    }

    pub fn fire_event(&self, event: &str, args: &[mlua::Value]) -> Vec<EventResult> {
        // Call the event handler in each plugin
        // Collect results (for cancellable events)
    }
}
```

### 4.2 — HB.* API

**Create `server/src/plugin/api.rs`:**

Register these functions in each plugin's Lua state:

```rust
fn register_api(lua: &Lua, sessions: Arc<SessionManager>, world: Arc<WorldState>) -> Result<()> {
    let hb = lua.create_table()?;

    // Player functions
    hb.set("GetPlayers", lua.create_function(|_, ()| { /* return table of {id, name} */ })?)?;
    hb.set("GetPlayerName", lua.create_function(|_, pid: u32| { /* lookup name */ })?)?;
    hb.set("GetPlayerVehicles", lua.create_function(|_, pid: u32| { /* return vehicle list */ })?)?;
    hb.set("SendChatMessage", lua.create_function(|_, (pid, msg): (i32, String)| { /* -1=all */ })?)?;
    hb.set("DropPlayer", lua.create_function(|_, (pid, reason): (u32, String)| { /* kick */ })?)?;

    // Event registration
    hb.set("RegisterEvent", lua.create_function(|_, (name, handler): (String, Function)| { ... })?)?;
    hb.set("CreateEventTimer", lua.create_function(|_, (name, ms): (String, u64)| { ... })?)?;

    // Logging
    let log = lua.create_table()?;
    log.set("Info", lua.create_function(|_, msg: String| { tracing::info!("{msg}"); Ok(()) })?)?;
    log.set("Warn", lua.create_function(|_, msg: String| { tracing::warn!("{msg}"); Ok(()) })?)?;
    hb.set("Log", log)?;

    lua.globals().set("HB", hb)?;
    Ok(())
}
```

### 4.3 — Event System

**Create `server/src/plugin/events.rs`:**

Built-in events fired from the server core into plugins:

```rust
pub enum GameEvent {
    OnInit,
    OnShutdown,
    OnPlayerAuth { name: String, identifiers: PlayerIdentifiers },
    OnPlayerJoin { player_id: u32 },
    OnPlayerDisconnect { player_id: u32 },
    OnChatMessage { player_id: u32, name: String, message: String },
    OnVehicleSpawn { player_id: u32, vehicle_id: u16, data: String },
    OnVehicleEdited { player_id: u32, vehicle_id: u16, data: String },
    OnVehicleDeleted { player_id: u32, vehicle_id: u16 },
    OnConsoleInput { input: String },
}

pub struct EventResult {
    pub cancelled: bool,
}
```

Cancellable events: `OnPlayerAuth`, `OnChatMessage`, `OnVehicleSpawn`, `OnVehicleEdited`.
If any plugin handler returns a cancel signal, the action is prevented and the originator is notified.

### 4.4 — Plugin Manifest (`plugin.toml`)

Every plugin MUST have a `plugin.toml` in its root directory. This replaces alphabetical file loading with explicit, predictable configuration.

**Create `server/plugins/example/plugin.toml`:**
```toml
[plugin]
name = "ExamplePlugin"
version = "1.0.0"
entry_point = "main.lua"   # File loaded first (required)
authors = ["Author Name"]
description = "An example HighBeam server plugin"

# Optional: declare dependencies on other plugins (loaded first)
# depends = ["SomeOtherPlugin"]
```

**Load order rules:**
1. Each plugin must have a `plugin.toml` with at least `name` and `entry_point`.
2. If `depends` is specified, those plugins are loaded first (topological sort).
3. Plugins without dependencies are loaded in directory-name order (deterministic but not relied upon).
4. Circular dependencies cause a startup error with a clear message.
5. If `plugin.toml` is missing, the plugin directory is skipped with a warning.

**Create `server/plugins/example/main.lua`:**
```lua
-- Example HighBeam server plugin
local pluginName = "ExamplePlugin"

HB.RegisterEvent("onPlayerJoin", function(playerId)
  local name = HB.GetPlayerName(playerId)
  HB.SendChatMessage(-1, "[Server] Welcome, " .. name .. "!")
  HB.Log.Info(pluginName .. ": " .. name .. " joined")
end)

HB.RegisterEvent("onChatMessage", function(playerId, name, message)
  if message == "!players" then
    local players = HB.GetPlayers()
    local list = "Online: "
    for _, p in ipairs(players) do
      list = list .. p.name .. ", "
    end
    HB.SendChatMessage(playerId, list)
    return 1  -- Cancel the original message (don't broadcast "!players" to all)
  end
end)
```

### 4.5 — Phase 4 Acceptance Tests

| Test | How | Expected Result |
|------|-----|-----------------|
| Plugin loads | Place plugin with plugin.toml in Resources/Server/ | Server logs "Loaded plugin: ExamplePlugin" |
| Missing manifest | Plugin dir without plugin.toml | Server logs warning, plugin skipped |
| Depends order | Plugin A depends on Plugin B | Plugin B loads before Plugin A |
| Circular deps | Plugin A depends B, B depends A | Server logs error, neither loads |
| onPlayerJoin | Player connects | All players see "Welcome, PlayerName!" in chat |
| onChatMessage | Player sends "!players" | Only the sender sees the player list |
| Event cancel | Plugin cancels chat message | Message is not broadcast to other players |
| HB.DropPlayer | Plugin calls DropPlayer | Player is kicked with reason shown |
| HB.GetPlayers | Plugin calls GetPlayers | Returns correct table of connected players |
| Plugin isolation | Two plugins loaded | One plugin's error doesn't crash the other |
| Hot reload | Modify plugin file, trigger reload | Plugin reloads without server restart |

**Commit:** `feat(server): Lua plugin system with HB.* API (v0.4.0)`

---

## Phase 5 — Polish & Performance (v0.5.0)

**Goal:** Production-quality stability and performance optimizations.

### 5.1 — Binary TCP Protocol

Replace JSON with a more efficient encoding for high-frequency TCP packets:
- Keep JSON for `server_hello` and `auth_*` (human-debuggable handshake)
- Switch vehicle spawn/edit/delete and other frequent packets to MessagePack
- Protocol version bump to 2
- Support both JSON (v1) and binary (v2) with negotiation in handshake

> **Note:** UDP position updates are already binary from Phase 2. This phase targets TCP.

### 5.2 — Advanced UDP Optimizations

Building on the binary UDP from Phase 2, add bandwidth intelligence:

**Priority Accumulator:**
- Each vehicle has a priority value that accumulates per tick
- Higher priority: vehicles near the player, recently spawned, recently collided
- Lower priority: distant vehicles, stationary vehicles
- Send the N highest-priority vehicles per packet, reset their accumulators

**At-Rest Optimization:**
- Detect stationary vehicles (velocity < threshold for N frames)
- Send a single "at rest" flag bit instead of full velocity
- Dramatically reduces bandwidth for parked vehicles

**Jitter Buffer:**
- Buffer incoming UDP packets for 2-3 frames before applying
- Smooth out network jitter for consistent interpolation

**Visual Smoothing:**
- Don't snap vehicle positions directly from network state
- Track position/rotation error offsets
- Reduce error offsets exponentially each frame (0.9 for small errors, 0.85 for large)
- Render at: simulation position + error offset

### 5.3 — Delta Compression

For vehicle configs (which are large JSON blobs):
- Track the last acknowledged config per vehicle per player
- Send only the diff between current and acknowledged config
- Fall back to full config if diff is larger than full

### 5.4 — Optional TLS

```rust
// Add rustls or native-tls
// If TLS is configured, wrap the TCP listener in a TLS acceptor
// Client detects TLS from server_hello or uses a "tls://" connect prefix
```

### 5.5 — Phase 5 Acceptance Tests

| Test | How | Expected Result |
|------|-----|-----------------|
| Binary TCP packets | Monitor bandwidth | Significant reduction vs JSON for vehicle events |
| Priority accumulator | 20 players, varying distances | Nearby vehicles update more frequently |
| At-rest savings | 10 parked vehicles | Bandwidth drops significantly |
| Jitter buffer | Simulate 5% packet loss | Remote vehicles are smooth, no teleporting |
| Visual smoothing | Trigger a correction pop | Pop is smoothed out over ~200ms |
| TLS connection | Enable TLS in config | Connection succeeds with encryption |
| Config delta | Edit a vehicle | Only changed parts are sent |
| 20-player load | Connect 20 clients | Server uses < 2Mbps total bandwidth |

**Commit:** `perf(server,client): binary protocol, delta compression, visual smoothing (v0.5.0)`

---

## Phase 6 — Discovery & Community (v0.6.0)

**Goal:** Players can find servers without needing to share IP addresses directly.

### 6.1 — Server Query Protocol

A lightweight, unauthenticated UDP query:
- Client sends a 4-byte magic number `0x48424D51` ("HBMQ") to the server port
- Server responds with JSON: `{ name, map, players, max_players, version }`
- No TCP connection needed — fast ping/info check

### 6.2 — Community Relay Registration

**Server-side:**
- Configurable relay URL in `ServerConfig.toml`: `RelayUrl = "https://relay.example.com"`
- Server periodically (every 30s) POSTs its info to the relay
- Relay maintains a list of active servers
- No authentication required for relay registration (spam prevention via rate limiting on relay side)

**Client-side:**
- Server browser fetches the relay's server list (GET request)
- Displays: name, map, players/max, ping
- Click to connect

### 6.3 — Favorites & Recent

**Client-side config persistence:**
```lua
M.favorites = {}     -- { {host, port, name}, ... }
M.recentServers = {} -- { {host, port, name, lastConnected}, ... }
```

### 6.4 — Phase 6 Acceptance Tests

| Test | How | Expected Result |
|------|-----|-----------------|
| Server query | Send magic packet to server | Receive JSON with server info |
| Relay registration | Enable relay URL | Server appears in relay's list |
| Server browser | Open browser UI | Shows servers from relay with ping times |
| Connect from browser | Click server in list | Connects successfully |
| Favorites | Star a server | Persists across game restarts |
| Recent servers | Connect and reconnect | Appears in recent list |

**Commit:** `feat(server,client): server discovery and community relay (v0.6.0)`

---

## Technical Decisions & Research Notes

### Why These Networking Choices?

**State Synchronization model** (per Glenn Fiedler's research):
- Each client is authoritative over its own vehicles (no prediction needed for local vehicles)
- Clients send state (position, rotation, velocity) to the server
- Server relays state to other clients
- Other clients interpolate between received snapshots

This is ideal for BeamNG because:
- BeamNG's physics runs at 2000Hz on a per-vehicle thread — too complex to replicate remotely
- Each player only controls their own vehicles (no shared world physics)
- Network state is purely visual — position, rotation, velocity for smooth rendering

**Update rate: 20Hz default** (not 30Hz or 60Hz):
- 20Hz provides good visual quality with interpolation
- Keeps bandwidth manageable (40 bytes × 20Hz = 800 B/s per vehicle)
- At 20pps with 3-snapshot buffer, interpolation delay is ~150ms (acceptable)
- Higher rates can be configured if bandwidth allows

**Snapshot interpolation** (not extrapolation):
- Extrapolation is unreliable for vehicles that turn, brake, or collide
- Interpolation with a small buffer (2-3 snapshots) gives smooth, accurate results
- The ~150ms visual delay is imperceptible while driving

**LuaSocket for client networking:**
- BeamNG's LuaJIT runtime should include or support LuaSocket
- Non-blocking mode (`settimeout(0)`) prevents game freezes
- Polling in `onUpdate` integrates naturally with BeamNG's frame loop
- If LuaSocket is unavailable, LuaJIT FFI can call OS socket APIs directly

### BeamNG VM Architecture (Confirmed)

From official BeamNG documentation:
- **GELUA** (Game Engine Lua): Main thread, runs at graphics framerate. This is where HighBeam's networking lives.
- **VLUA** (Vehicle Lua): Separate thread per vehicle, runs at physics rate (2000Hz). We do NOT network from here.
- **Communication**: GELUA ↔ VLUA via async queues (`obj:queueGameEngineLua()`, `be:getPlayerVehicle():queueLuaCommand()`) and mailboxes.

HighBeam runs entirely in GELUA. We:
1. Read vehicle positions from GELUA using `be:getPlayerVehicle(n)` APIs
2. Network in GELUA's `onUpdate` (non-blocking sockets)
3. Apply remote vehicle positions directly in GELUA

### Port 18860

- Karl Benz patented the first automobile on January 29, **1886**
- Port 18860 is unassigned in the IANA port registry
- Avoids any conflict with BeamMP's port 30814
- Memorable and historically significant for a car game mod

---

## Summary Checklist

| Phase | Version | Core Deliverable | Key Files |
|-------|---------|-----------------|-----------|
| 0 | — | Project scaffolding | `Cargo.toml`, `main.rs`, `config.rs`, `highbeam.lua`, stubs |
| 1 | v0.1.0 | TCP handshake + auth | `tcp.rs`, `packet.rs`, `manager.rs`, `connection.lua` |
| 2 | v0.2.0 | Vehicle sync (UDP) | `udp.rs`, `vehicle.rs`, `world.rs`, `vehicles.lua`, `state.lua` |
| 3 | v0.3.0 | Chat, mods, auth modes | `auth.rs`, `chat.lua`, UI apps, mod distribution |
| 4 | v0.4.0 | Plugin system | `runtime.rs`, `api.rs`, `events.rs`, example plugin |
| 5 | v0.5.0 | Performance + TLS | Binary protocol, delta compression, jitter buffer |
| 6 | v0.6.0 | Server discovery | Query protocol, relay registration, server browser |
