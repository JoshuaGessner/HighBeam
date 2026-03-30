# HighBeam Server Architecture

> **Last updated:** 2026-03-29
> **Applies to:** v0.1.0 (pre-alpha)
> **Parent doc:** [OVERVIEW.md](OVERVIEW.md)

---

## Overview

The HighBeam server is a standalone Rust binary that manages multiplayer sessions for BeamNG.drive. It accepts connections from HighBeam client mods, relays vehicle state between players, and runs server-side Lua plugins.

### Platform Support

The server targets **Windows**, **Linux**, and **macOS**:

| Platform | Arch | Use Case | GUI | Headless |
|----------|------|----------|-----|----------|
| Windows x86_64 | x64 | Personal hosting, development | Yes | Yes |
| Linux x86_64 | x64 | Dedicated servers, VPS/cloud | Yes | Yes (primary) |
| Linux aarch64 | ARM64 | ARM cloud instances (AWS Graviton, etc.) | Yes | Yes |
| macOS x86_64 | x64 | Development | Yes | Yes |
| macOS aarch64 | ARM64 | Development (Apple Silicon) | Yes | Yes |

All platform-specific behavior is handled by Rust's standard library and the `tokio` async runtime. No `#[cfg(target_os)]` conditional compilation is required for the networking or session management layers.

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
│   │   ├── persistence.rs      # Vehicle persistence (SQLite storage)
│   │   └── world.rs            # World state (all players, vehicles)
│   ├── gui/
│   │   ├── mod.rs              # GUI module root
│   │   ├── app.rs              # Main application window (eframe/egui)
│   │   ├── panels/
│   │   │   ├── mod.rs           # Panel module root
│   │   │   ├── dashboard.rs    # Server status dashboard (players, uptime, tick rate)
│   │   │   ├── players.rs      # Player list and management
│   │   │   ├── maps.rs         # Map selection and management
│   │   │   ├── mods.rs         # Mod management (Resources/Client/)
│   │   │   ├── plugins.rs      # Plugin management (load, reload, status)
│   │   │   ├── console.rs      # Server console / log viewer
│   │   │   └── settings.rs     # Server configuration editor
│   │   └── tray.rs             # System tray integration (minimize-to-tray)
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
| `eframe` / `egui` | Immediate-mode GUI framework for the server management interface |
| `tray-icon` | System tray integration (minimize-to-tray, tray menu) |
| `rusqlite` | SQLite storage for vehicle persistence and plugin data |
| `image` | Icon loading for system tray and window icon |

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
  - Persistent flag (bool — whether the vehicle persists when owner disconnects)

#### Vehicle Persistence (`persistence.rs`)
- SQLite-backed storage for vehicles that persist across sessions
- Admins toggle persistence per player via commands or GUI (`HB.SetPersistence(pid, enabled)`)
- When a player with persistence enabled disconnects:
  - Their vehicles are **not** removed from the world
  - Vehicle positions are frozen (no physics simulation)
  - Vehicles remain visible to other players as static objects
  - On reconnect, the player regains ownership and vehicles resume live updates
- When persistence is disabled for a player, disconnect behaves normally (vehicles removed)
- Schema:
  - `persistent_players` table: `player_name TEXT PRIMARY KEY, enabled INTEGER`
  - `persistent_vehicles` table: `id INTEGER PRIMARY KEY, player_name TEXT, config BLOB, pos_x REAL, pos_y REAL, pos_z REAL, rot_x REAL, rot_y REAL, rot_z REAL, rot_w REAL, map TEXT`
- Vehicles are scoped to the current map — changing maps clears active persistent vehicles
- Storage file: `server/data/persistence.db`

#### World (`world.rs`)
- Concurrent map of all players and their vehicles (including persistent vehicles from offline players)
- Broadcasts: method to send a packet to all players (or all except one)
- Query methods for plugins: get player by ID, get vehicles by player, etc
- Persistent vehicle query: returns all frozen vehicles for inclusion in WorldState on player join

### GUI Layer (`gui/`)

The server ships with a built-in graphical management interface using `egui` (via `eframe`). This provides operators with a windowed desktop application instead of a headless terminal-only experience.

#### Application (`app.rs`)
- Main `eframe::App` implementation
- Tab-based navigation between panels
- Communicates with server internals via `Arc`-shared state and `tokio::sync::mpsc` channels
- Supports a `--headless` CLI flag to disable the GUI and run as a pure terminal process (for Docker, systemd, etc.)

#### Panels (`panels/`)

| Panel | Purpose |
|-------|---------|
| **Dashboard** | Server status: player count, tick rate, uptime, bandwidth usage |
| **Players** | Connected player list with kick/ban buttons, persistence toggle per player |
| **Maps** | Select active map from available maps, preview map info |
| **Mods** | Manage `Resources/Client/` mods — add, remove, view installed |
| **Plugins** | View loaded plugins, reload individual plugins, see error state |
| **Console** | Live server log viewer with search/filter, Lua command injection |
| **Settings** | Edit `ServerConfig.toml` values at runtime (name, max players, auth mode, tick rate, etc.) |

#### System Tray (`tray.rs`)
- Uses `tray-icon` crate for cross-platform system tray support (Windows + Linux)
- Minimize-to-tray: closing the window hides it to the system tray instead of shutting down
- Tray icon context menu:
  - **Show** — restore the window
  - **Player count** — display label (e.g., "3/20 players")
  - **Quit** — graceful shutdown
- Tray icon reflects server state (e.g., green = running, yellow = no players)

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
| `HB.SetPersistence(pid, enabled)` | Toggle vehicle persistence for a player |
| `HB.GetPersistence(pid)` | Check if a player has persistence enabled |
| `HB.GetPersistentVehicles()` | Get all currently frozen persistent vehicles |

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
| `onPersistenceToggle` | player_id, enabled | Yes |
| `onVehiclePersisted` | player_id, vehicle_id | No |
| `onVehicleRestored` | player_id, vehicle_id | No |

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
Headless = false           # If true, skip GUI and run as terminal-only process

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

[Persistence]
Enabled = true             # Enable vehicle persistence system
DatabaseFile = "data/persistence.db"  # SQLite database path

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

---

## Security Protocol

> **Security is non-negotiable. Every layer of the server must enforce strict security practices.**

### Principles

1. **Never trust client input.** All data from clients is untrusted. Validate packet sizes, field ranges, string lengths, and JSON structure before processing. Reject malformed data immediately.
2. **Authenticate everything.** TCP packets are only processed from authenticated sessions. UDP packets are validated against session token hashes — unknown hashes are silently dropped.
3. **Rate limit aggressively.** Auth attempts, chat messages, vehicle spawns, and plugin events all have configurable rate limits. Exceeding limits results in temporary bans or disconnects.
4. **Isolate plugin execution.** Each Lua plugin runs in its own sandboxed state. Plugins cannot access the filesystem outside their own directory without explicit `FS.*` API calls. No `os.execute`, `io.popen`, or raw FFI access in plugin Lua states.
5. **Hash and salt credentials.** Server passwords are Argon2-hashed on disk. Session tokens are cryptographically random and short-lived.
6. **Enforce resource limits.** MaxPlayers, MaxCarsPerPlayer, max packet size (1MB), and per-player bandwidth caps prevent resource exhaustion.
7. **Graceful error handling.** Invalid packets, malformed JSON, and unexpected disconnects must never crash the server. All error paths log structured warnings and clean up state.
8. **Minimize attack surface.** The server exposes only port 18860 (TCP + UDP). No HTTP endpoints, no admin panels over the network. The GUI is local-only (rendered via egui, not a web server).
