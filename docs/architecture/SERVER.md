# HighBeam Server Architecture

> **Last updated:** 2026-03-29
> **Applies to:** v0.1.0 (pre-alpha)
> **Parent doc:** [OVERVIEW.md](OVERVIEW.md)

---

## Overview

The HighBeam server is a standalone Rust binary that manages multiplayer sessions for BeamNG.drive. It accepts connections from HighBeam client mods, relays vehicle state between players, and runs server-side Lua plugins.

---

## Directory Structure

```
server/
├── src/
│   ├── main.rs                 # Entry point, CLI, config loading
│   ├── config.rs               # TOML config parsing
│   ├── net/
│   │   ├── mod.rs              # Network module root
│   │   ├── tcp.rs              # TCP listener and connection handling
│   │   ├── udp.rs              # UDP receiver and sender
│   │   └── packet.rs           # Packet serialization/deserialization
│   ├── session/
│   │   ├── mod.rs              # Session module root
│   │   ├── manager.rs          # Session lifecycle management
│   │   ├── auth.rs             # Authentication logic
│   │   └── player.rs           # Player state struct
│   ├── state/
│   │   ├── mod.rs              # Game state module root
│   │   ├── vehicle.rs          # Vehicle state tracking
│   │   └── world.rs            # World state (all players, vehicles)
│   ├── plugin/
│   │   ├── mod.rs              # Plugin runtime module root
│   │   ├── runtime.rs          # Lua state management
│   │   ├── api.rs              # HB.* Lua API bindings
│   │   └── events.rs           # Event system for plugins
│   └── util/
│       ├── mod.rs              # Utility module root
│       └── logging.rs          # Structured logging setup
├── plugins/
│   └── example/
│       └── main.lua            # Example server plugin
├── Cargo.toml                  # Rust project manifest
└── ServerConfig.toml           # Default server configuration
```

---

## Core Dependencies (Rust Crates)

| Crate | Purpose |
|-------|---------|
| `tokio` | Async runtime for TCP/UDP networking |
| `mlua` | Lua 5.4 bindings for plugin runtime |
| `serde` + `toml` | Configuration parsing |
| `tracing` | Structured logging |
| `bytes` | Efficient byte buffer management for packets |
| `dashmap` | Concurrent hash map for player/vehicle state |
| `argon2` | Password hashing for server auth |
| `rand` | Session token generation |

---

## Module Design

### Network Layer (`net/`)

#### TCP (`tcp.rs`)
- Listens on configured port (default `18860`)
- Spawns a task per client connection
- Handles the handshake and authentication exchange
- Receives reliable packets (chat, vehicle spawn/edit/delete, plugin events)
- Sends reliable packets to clients

#### UDP (`udp.rs`)
- Single UDP socket bound to the same port
- Receives position updates from all clients
- Routes position updates to other connected clients
- Authenticates UDP packets via session token prefix

#### Packet (`packet.rs`)
- Defines packet types as Rust enums
- Serialization: Rust struct → binary wire format
- Deserialization: binary wire format → Rust struct
- Version field in every packet for forward compatibility

### Session Layer (`session/`)

#### Session Manager (`manager.rs`)
- Creates sessions on successful auth
- Issues cryptographically random session tokens
- Maps session tokens → player IDs
- Handles disconnect cleanup (remove vehicles, notify other players, trigger plugin events)
- Enforces max players limit

#### Authentication (`auth.rs`)
- **No external auth service.** All auth is local to the server.
- Supports multiple auth modes (configured in `ServerConfig.toml`):

| Mode | Description |
|------|-------------|
| `open` | Anyone can join, no credentials required |
| `password` | Server-wide password required to connect |
| `allowlist` | Only pre-approved usernames/tokens can connect |

- Passwords are never stored in plaintext — Argon2 hashed
- Rate limiting on failed auth attempts (configurable)

#### Player (`player.rs`)
- Struct holding all per-player state:
  - Player ID (server-assigned integer)
  - Display name
  - Session token
  - TCP writer handle
  - UDP address
  - Vehicle IDs owned by this player
  - Connection timestamp
  - Last activity timestamp

### State Layer (`state/`)

#### Vehicle (`vehicle.rs`)
- Struct per vehicle:
  - Vehicle ID (server-assigned)
  - Owner player ID
  - Configuration (JSON blob — parts, paint, tuning)
  - Last known position, rotation, velocity
  - Last update timestamp

#### World (`world.rs`)
- Concurrent map of all players and their vehicles
- Broadcasts: method to send a packet to all players (or all except one)
- Query methods for plugins: get player by ID, get vehicles by player, etc

### Plugin Runtime (`plugin/`)

#### Runtime (`runtime.rs`)
- Each plugin gets its own Lua 5.4 state (isolation)
- Plugins loaded from `Resources/Server/<PluginName>/`
- Each plugin must have a `plugin.toml` manifest declaring its `name`, `entry_point`, and optional `depends`
- Load order determined by dependency graph (topological sort), not filename order
- Lua files in subdirectories can be `require()`-ed from the entry point
- Hot reload: watch for file changes, reload plugin state

#### API (`api.rs`)
- Exposes `HB.*` namespace to Lua (analogous to BeamMP's `MP.*`)
- Core API functions:

| Function | Description |
|----------|-------------|
| `HB.GetPlayers()` | Returns table of all connected players |
| `HB.GetPlayerName(pid)` | Get player display name |
| `HB.GetPlayerVehicles(pid)` | Get all vehicles for a player |
| `HB.GetPositionRaw(pid, vid)` | Get vehicle position/rotation/velocity |
| `HB.SendChatMessage(pid, msg)` | Send chat message to player (-1 for all) |
| `HB.TriggerClientEvent(pid, event, data)` | Send custom event to client |
| `HB.RemoveVehicle(pid, vid)` | Force-remove a vehicle |
| `HB.DropPlayer(pid, reason)` | Kick a player |
| `HB.GetPlayerIdentifiers(pid)` | Get player IP, session info |
| `HB.RegisterEvent(name, handler)` | Register event handler |
| `HB.CreateEventTimer(name, ms)` | Create a recurring timer event |
| `HB.Set(setting, value)` | Change server config at runtime |
| `HB.Log.Info(...)` | Structured logging |

#### Events (`events.rs`)
- Built-in events matching game lifecycle:

| Event | Arguments | Cancellable |
|-------|-----------|-------------|
| `onInit` | (none) | No |
| `onShutdown` | (none) | No |
| `onPlayerAuth` | name, is_guest, identifiers | Yes |
| `onPlayerConnecting` | player_id | No |
| `onPlayerJoining` | player_id | No |
| `onPlayerJoin` | player_id | No |
| `onPlayerDisconnect` | player_id | No |
| `onChatMessage` | player_id, name, message | Yes |
| `onVehicleSpawn` | player_id, vehicle_id, data | Yes |
| `onVehicleEdited` | player_id, vehicle_id, data | Yes |
| `onVehicleDeleted` | player_id, vehicle_id | No |
| `onVehicleReset` | player_id, vehicle_id, data | No |
| `onConsoleInput` | input | No |

---

## Configuration

### ServerConfig.toml

```toml
[General]
Name = "My HighBeam Server"
Port = 18860
MaxPlayers = 20
MaxCarsPerPlayer = 3
Map = "/levels/gridmap_v2/info.json"
Private = false            # If true, not advertised to community relays
Description = "A HighBeam server"
ResourceFolder = "Resources"

[Auth]
Mode = "open"              # "open", "password", or "allowlist"
# Password = ""            # Required if Mode = "password" (hashed on first run)
# AllowlistFile = ""       # Required if Mode = "allowlist"
MaxAuthAttempts = 5        # Per IP, before temporary ban
AuthTimeoutSec = 30        # Time limit for auth handshake

[Network]
TickRate = 20              # Server tick rate (Hz) — 20Hz provides good quality with manageable bandwidth
UdpBufferSize = 65535      # UDP receive buffer size
TcpKeepAliveSec = 15       # TCP keepalive interval

[Logging]
Level = "info"             # "debug", "info", "warn", "error"
LogFile = "server.log"
LogChat = true
```

---

## Build & Run

```bash
# Development
cd server
cargo build

# Release
cargo build --release

# Run
./target/release/highbeam-server
# or with custom config:
./target/release/highbeam-server --config /path/to/ServerConfig.toml
```

---

## Resource Directory

```
Resources/
├── Client/
│   └── (mod .zip files served to connecting clients)
└── Server/
    ├── MyPlugin/
    │   └── main.lua
    └── AnotherPlugin/
        ├── main.lua
        └── data/
            └── config.json
```

This mirrors the BeamMP resource layout for familiarity, but plugins use the `HB.*` API namespace.
