# HighBeam Server Architecture

> **Last updated:** 2026-03-31
> **Applies to:** v0.6.5 (beta)
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
│   ├── main.rs                 # Entry point, config loading, runtime/GUI orchestration
│   ├── cli.rs                  # CLI argument parsing (--headless, --config, --protocol-benchmark)
│   ├── config.rs               # TOML config parsing and runtime-editable settings
│   ├── control.rs              # ControlPlane: admin command API and runtime snapshot
│   ├── discovery_relay.rs      # Optional community relay registration heartbeat
│   ├── gui.rs                  # egui/eframe GUI shell with close-to-tray behavior
│   ├── log_rotation.rs         # Log file size/age rotation policy
│   ├── metrics.rs              # Periodic runtime metrics collection and logging
│   ├── mods.rs                 # Mod manifest building (SHA-256 hashes)
│   ├── persistence.rs          # SQLite-backed vehicle persistence
│   ├── tls.rs                  # Optional TLS certificate loading
│   ├── updater.rs              # Self-update from GitHub Releases
│   ├── validation.rs           # Input validation (username, chat, vehicle, config)
│   ├── net/
│   │   ├── mod.rs              # Network module root
│   │   ├── tcp.rs              # TCP listener; accept-error resilience; shutdown_rx
│   │   ├── udp.rs              # UDP receiver/sender; NaN/inf float validation
│   │   ├── packet.rs           # Packet serialization/deserialization
│   │   ├── mod_transfer.rs     # Launcher mod file transfer (bounded packet/request size)
│   │   └── benchmark.rs        # JSON protocol baseline benchmark harness
│   ├── session/
│   │   ├── mod.rs              # Session module root
│   │   ├── manager.rs          # Session lifecycle management
│   │   ├── player.rs           # Player state struct
│   │   └── rate_limiter.rs     # Per-IP/per-player rate limiting (token bucket)
│   ├── state/
│   │   ├── mod.rs              # Game state module root
│   │   ├── vehicle.rs          # Vehicle state tracking
│   │   └── world.rs            # World state (all players, vehicles; DashMap)
│   └── plugin/
│       ├── mod.rs              # Plugin runtime module root
│       ├── runtime.rs          # Lua state management, hot reload, console eval
│       ├── api.rs              # HB.* Lua API bindings
│       └── events.rs           # Event system for plugins
├── Cargo.toml                  # Rust project manifest
├── ServerConfig.toml           # Default server configuration
├── Dockerfile                  # Container image for deployment
├── docker-compose.yml          # Compose deployment example
└── highbeam-server.service     # systemd service unit template
```

---

## Core Dependencies (Rust Crates)

| Crate | Purpose |
|-------|---------|
| `tokio` | Async runtime for TCP/UDP networking |
| `mlua` | Lua 5.4 bindings for plugin runtime (vendored, send) |
| `serde` + `serde_json` | Packet serialization and config parsing |
| `toml` | TOML configuration file parsing |
| `tracing` + `tracing-subscriber` | Structured logging with env-filter |
| `tracing-appender` | File logging with daily rotation |
| `bytes` | Efficient byte buffer management for packets |
| `dashmap` | Concurrent hash map for player/vehicle state |
| `argon2` | Password hashing for server auth |
| `rand` | Session token generation, plugin utilities |
| `sha2` | SHA-256 for mod manifests and session hashes |
| `socket2` | Low-level socket options (TCP keepalive) |
| `eframe` + `egui` | Desktop GUI framework |
| `tray-item` | System tray icon and context menu |
| `anyhow` + `thiserror` | Error handling |

---

## Module Design

### Network Layer (`net/`)

#### TCP (`tcp.rs`)
- Listens on configured port (default `18860`)
- Spawns a task per client connection
- Handles the handshake and authentication exchange
- Receives reliable packets (chat, vehicle spawn/edit/delete, plugin events)
- Sends reliable packets to clients
- Integrates plugin hooks for auth, vehicle spawn, chat, and custom events

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
- Issues cryptographically random session tokens (64-byte entropy + timestamp)
- Maps session tokens → player IDs
- Maps truncated SHA-256 session hashes → player IDs (for UDP auth)
- Handles disconnect cleanup (remove vehicles, notify other players)
- Enforces max players limit
- Provides `broadcast()` and `send_to_player()` methods for packet delivery

#### Rate Limiter (`rate_limiter.rs`)
- Token-bucket rate limiting per IP (auth) and per player (chat, spawn)
- Configurable windows: auth 5/60s, chat 10/10s, spawn 5/5s

#### Authentication
- **No external auth service.** All auth is handled inline in `tcp.rs`.
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
  - Session hash (truncated SHA-256 for UDP auth)
  - TCP sender channel handle
  - UDP address (registered after auth)
  - Connection timestamp
  - Last activity timestamp
  - Last pong time (heartbeat tracking)

### State Layer (`state/`)

#### Vehicle (`vehicle.rs`)
- Struct per vehicle:
  - Vehicle ID (server-assigned)
  - Owner player ID
  - Configuration (JSON blob — parts, paint, tuning)
  - Last known position, rotation, velocity
  - Last update timestamp

#### World (`world.rs`)
- Concurrent map of all players and their vehicles (using DashMap)
- Vehicle spawn, edit, delete, reset tracking
- Vehicle count per player (for MaxCarsPerPlayer enforcement)
- Ownership validation (`is_owner()`)
- Query methods for plugins: `get_vehicle_snapshot()`, `vehicle_count_for_player()`
- Broadcasts: handled by SessionManager, not World directly

### Plugin Runtime (`plugin/`)

#### Runtime (`runtime.rs`)
- Each plugin gets its own Lua 5.4 state (isolation via `mlua`)
- Plugins loaded from `Resources/Server/<PluginName>/main.lua`
- Load order determined by alphabetical directory sort
- Only safe Lua stdlib exposed: `table`, `string`, `math`, `utf8`, `coroutine` (no OS/IO/debug/package)
- Hot reload: polls directory every 2s using file hash change detection, reloads all plugin states on change
- Console eval: `lua <plugin_name> <code>` from server stdin for runtime inspection
- Event dispatch: iterates loaded plugins in order, supports cancellation

#### API (`api.rs`)
- Exposes `HB.*` namespace to Lua (analogous to BeamMP's `MP.*`)
- API functions currently implemented:

| Function | Description |
|----------|-------------|
| `HB.Player.GetPlayers()` | Returns table of all connected players `{id, name}` |
| `HB.Player.DropPlayer(pid, reason?)` | Kick a player (sends Kick packet) |
| `HB.Chat.SendChatMessage(text)` | Broadcast a chat message as "Server" |
| `HB.Vehicle.GetVehicles()` | Returns table of all vehicles `{player_id, vehicle_id, data}` |
| `HB.Vehicle.DeleteVehicle(pid, vid)` | Force-remove a vehicle (validates ownership) |
| `HB.Event.SendServerMessage(text)` | Broadcast a server announcement |
| `HB.Event.TriggerClientEvent(pid, name, payload?)` | Send custom event to a specific client |
| `HB.Event.BroadcastClientEvent(name, payload?)` | Send custom event to all clients |
| `HB.Util.Log(level, message)` | Structured logging (trace/debug/info/warn/error) |
| `HB.Util.RandomInt(min, max)` | Generate random integer in range |
| `HB.FS.ReadFile(path)` | Read file relative to plugin dir (traversal-protected) |
| `HB.FS.WriteFile(path, contents)` | Write file relative to plugin dir (traversal-protected) |
| `HB.FS.Exists(path)` | Check file existence relative to plugin dir |

#### Events (`events.rs`)
- Built-in events matching game lifecycle:

| Event | Context Fields | Cancellable |
|-------|---------------|-------------|
| `OnPlayerAuth` | `username`, `addr` | Yes |
| `OnVehicleSpawn` | `player_id`, `data` | Yes |
| `OnChatMessage` | `player_id`, `text` | Yes |
| `OnClientEvent` | `player_id`, `name`, `payload` | Yes |

- Cancellation contract: handlers return `false`, a reason string, or `{ cancel = true, reason = "..." }` to block the action
- Plugin errors are isolated — one plugin crash is logged but doesn't affect others

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
Description = "A HighBeam server"
ResourceFolder = "Resources"

[Auth]
Mode = "open"              # "open", "password", or "allowlist"
# Password = ""            # Required if Mode = "password"
# Allowlist = ["Player1"]  # Required if Mode = "allowlist"
MaxAuthAttempts = 5        # Per IP, before temporary block
AuthTimeoutSec = 30        # Time limit for auth handshake

[Network]
TickRate = 20              # Server tick rate (Hz)
UdpBufferSize = 65535      # UDP receive buffer size
TcpKeepAliveSec = 15       # TCP keepalive interval
# ModSyncPort = 18861      # Optional separate port for launcher mod transfers (defaults to Port+1)

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
│   └── (mod .zip files served to connecting launchers)
└── Server/
    ├── MyPlugin/
    │   └── main.lua           # Plugin entry point (required)
    └── AnotherPlugin/
        ├── main.lua
        └── data/
            └── config.json    # Plugin data files (accessible via HB.FS.*)
```

Plugins are loaded alphabetically by directory name. Each plugin must have a `main.lua` entry point. The `HB.*` API namespace is available in all plugin scripts.

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
