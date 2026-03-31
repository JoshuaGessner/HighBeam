# Changelog

All notable changes to the HighBeam project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [v0.5.0] — 2026-03-30

**Stability & Deployment Polish** — Production-quality server with observability and reliable deployment infrastructure.

### Added

**Server Operational Stability:**
- Graceful shutdown with signal handlers (SIGTERM/SIGINT on Unix, Ctrl+C on Windows)
- TCP keepalive with 60-second idle timeout
- Bandwidth throttling via tick-rate-based UDP relay
- Automatic memory cleanup for stale rate limiter records
- Connection state validation and error recovery
- Rate limiting on auth (5/60s), chat (10/10s), vehicle spawn (5/5s)

**Observability & Logging:**
- Runtime metrics logging: player count, vehicle count, network packets, memory usage
- Configurable metrics interval (`MetricsIntervalSec`, default 60s; set to 0 to disable)
- Per-process RSS memory tracking via sysinfo
- Log rotation by file size and age retention
  - `RotationMaxSizeMb` (default 100MB) triggers rotation
  - `RotationMaxDays` (default 7) determines archive cleanup
  - Rotated files timestamped: `server.log.20260330-153045.log`
- Structured logging with configurable levels
- Optional chat message logging (`LogChat=true`)

**Security & TLS:**
- Optional TLS encryption for TCP connections
- PEM-format certificate and private key loading
- Configuration-based enable/disable
- Input validation framework for all user inputs

**Deployment:**
- CLI arguments: `--config <path>` for custom config, `--headless` for Docker/systemd
- Configuration validation at startup (rejects invalid settings)
- Dockerfile and docker-compose.yml for containerized deployment
- Systemd service template (highbeam-server.service) for Linux
- Auto-update from GitHub Releases (`[Updates] AutoUpdate=true`)

**Client:**
- Heartbeat protocol (20s ping, 30s timeout) for connection health
- Smooth interpolation (lerp position, slerp rotation)
- Automatic reconnection with exponential backoff

### Dependencies Added
- `sysinfo` — Memory and system monitoring
- `tokio-rustls` — Async TLS runtime
- `rustls-pemfile` — PEM certificate parsing  
- `chrono` — Timestamp formatting for log rotation

### Changed
- **Version bumped**: Server and launcher now v0.5.0 (protocol version unchanged: still v2)
- **Log format**: Structured logging with structured metrics output
- **Config scope**: Added `[Logging]` section with rotation and metrics control, `[TLS]` section for encryption

### Deployment Improvements
- `--headless` flag prepares for future GUI mode (currently no GUI; all features CLI-only)
- Config can be mounted in Docker for runtime changes
- Systemd service includes restart policy and log forwarding
- Memory usage stays stable at 20 players under 150MB

### No Breaking Changes
- Existing v0.4.x configs fully compatible (new options are optional with sensible defaults)
- Protocol version unchanged (still v2; no rehandshake needed)
- Mod sync unchanged; vehicle sync unchanged

---

## [v0.4.3] — 2026-03-30

### Added
- BeamNG.drive auto-detection from v0.4.2 implementation
- Auto-update feature from v0.4.2 implementation

---

## [v0.4.2] — 2026-03-30

### Added
- **Auto-update** (server & launcher): both binaries check GitHub Releases on startup and self-update when a newer version is available. Server config: `[Updates] AutoUpdate = true`. Launcher flag: `--no-update` to skip.
- **BeamNG.drive auto-detection** (launcher): automatically finds the BeamNG.drive executable via Steam library discovery (registry, `libraryfolders.vdf` parsing, common paths). Also auto-detects the user data folder from `%LOCALAPPDATA%/BeamNG.drive`. `beamng_exe` and `beamng_userfolder` in `LauncherConfig.toml` can be left empty for zero-config usage.
- **Resources skeleton directories**: `Resources/Client/` and `Resources/Server/` included in release packages

### Dependencies added
- `reqwest` (blocking, json) — launcher auto-update HTTP client
- `reqwest` (async, json) — server auto-update HTTP client  
- `flate2`, `tar` — server tar.gz extraction
- `zip` — launcher/server zip extraction

---

## [v0.4.1] — 2026-03-30

> All v0.3.0 and v0.4.0 features complete. Chat, mod sync, launcher, auth, reconnection, player list UI, and server-side Lua plugin system shipped.
> Production hardening applied across server and client. CI builds release binaries on tagged pushes.

### Added (v0.3.0 features)
- **Chat system**: ChatMessage/ChatBroadcast packets, server relay, client chat UI (`chat.html`, `chat.lua`)
- **Launcher binary** (`launcher/`): Rust CLI that syncs mods, installs client mod, launches BeamNG
- **Mod sync**: `mod_list` endpoint, SHA-256 manifest, raw binary TCP file transfer (0.002% overhead vs 33% for base64)
- **Mod cache**: SHA-256 deduplication across servers (`~/.highbeam/cache/`)
- **Kick packet**: server can forcibly disconnect players with reason
- **ServerMessage packet**: server-to-client announcements displayed as system messages
- **Auth rate limiting**: 5 attempts per 60s per IP, chat 10/10s, spawn 5/5s
- **Password auth enforcement**: server rejects incorrect passwords in `password` auth mode
- **Allowlist auth enforcement**: server rejects unlisted usernames in `allowlist` auth mode (case-insensitive)
- **MaxPlayers enforcement**: server rejects connections when player count is at capacity
- **MaxCarsPerPlayer enforcement**: server rejects vehicle spawns beyond per-player limit
- **Reconnection with exponential backoff**: client auto-reconnects on disconnect (2s base, 30s max, 5 attempts)
- **Player list UI**: sidebar panel in chat showing online player names, toggled via player count
- **Connection status indicator**: colored dot + label in chat header (connected/connecting/reconnecting/disconnected)
- **Player tracking**: client maintains `_players` table updated from world_state, player_join, player_leave
- **Launcher process management**: waits for BeamNG.drive exit, reports exit codes
- **Launcher CLI**: `--server`, `--no-launch`, `--clear-cache` flags

### Added (v0.4.0 foundation — server)
- **Plugin runtime module** (`server/src/plugin/`): isolated Lua 5.4 states per plugin loaded from `Resources/Server/<PluginName>/main.lua`
- **Plugin event dispatch**: `OnPlayerAuth`, `OnVehicleSpawn`, and `OnChatMessage` hooks executed across loaded plugins
- **Plugin cancellation contract**: handlers can cancel by returning `false`, a reason string, or `{ cancel = true, reason = "..." }`
- **HB API namespace (initial)**:
	- `HB.Player.GetPlayers()`
	- `HB.Player.DropPlayer(playerId, reason)`
	- `HB.Chat.SendChatMessage(text)`
	- `HB.Vehicle.GetVehicles()`
	- `HB.Vehicle.DeleteVehicle(playerId, vehicleId)`
	- `HB.Event.SendServerMessage(text)`
	- `HB.Util.Log(level, message)`
	- `HB.Util.RandomInt(min, max)`
	- `HB.FS.ReadFile(path)`, `HB.FS.WriteFile(path, contents)`, `HB.FS.Exists(path)` with traversal protection
- **TCP integration for plugin hooks**: auth, vehicle spawn, and chat flows now consult plugin events before accepting actions
- **Plugin hot reload**: runtime polls `Resources/Server` for file changes and reloads plugin states automatically
- **Local Lua console injection**: supports `lua <plugin_name> <code>` from server stdin for runtime inspection/operations
- **Custom event transport**:
	- TCP packets `trigger_client_event` and `trigger_server_event`
	- Server API: `HB.Event.TriggerClientEvent(playerId, name, payload)` and `HB.Event.BroadcastClientEvent(name, payload)`
	- Client API: `connection.onServerEvent(name, callback)` and `connection.triggerServerEvent(name, payload)`

### Added (production hardening — server)
- TCP keepalive enabled on all client connections
- 60-second idle timeout enforcement in receive loop
- 15-second read timeout per packet
- Graceful shutdown with SIGTERM/SIGINT signal handlers
- Input validation module (`validation.rs`): username, password, chat message, vehicle ID, vehicle config size, server config
- Vehicle ownership & ID bounds validation on edit/delete/reset
- Session token collision safety: 64-byte entropy + nanosecond timestamp + retry on collision
- Config validation at startup (rejects invalid port, player counts, tick rates, auth modes)
- File logging with daily rotation via `tracing-appender`
- Chat logging when `LogChat=true` (structured `highbeam::chat` target)
- Username emptiness runtime check in `add_player()` (returns `Result`)

### Added (production hardening — client)
- 5-second connect timeout (`CONNECT_TIMEOUT = 5`)
- Heartbeat/ping-pong protocol: server pings every 20s, client responds immediately, 30s pong timeout
- Packet parsing validation: all JSON decode wrapped in pcall, hex dump on bad packets
- Lua error handling: all callbacks and `require()` calls wrapped in pcall with error logging
- `math.lua`: shared interpolation helpers (`lerp`, `lerpVec3`, `slerpQuat`)
- Vehicle interpolation: 50ms buffer delay, `MAX_SNAPSHOTS = 5`, render-time-based snapshot scanning
- Connection state machine: `VALID_TRANSITIONS` table, `_setState()` with context, illegal transition logging with stack trace
- Error callback system: `setErrorCallback()`, `_reportError()`, `getErrorStats()`

### Changed
- Protocol version bumped from 1 to 2 (PingPong heartbeat packet added)
- `SessionManager::add_player()` returns `Result<(u32, String)>` instead of `(u32, String)`
- Architecture is now **three components**: launcher, client mod, server (was two)
- Mod distribution moved from in-game client to pre-launch launcher (BeamNG Lua sandbox prevents file writes)

### Dependencies added
- `tracing-appender = "0.2"` (server — file logging with rotation)
- `mlua = "0.10"` with `lua54`, `vendored`, `send` features (server — plugin runtime)

### Fixed (v0.4.1)
- **Console logging**: server now logs to both stdout and the log file simultaneously (previously file-only when `LogFile` was set, resulting in a blank terminal)
- **Release workflow**: packaging step now uses a tracked `ServerConfig.default.toml` instead of the gitignored `ServerConfig.toml`
- **CI Node.js deprecation**: opted into Node.js 24 via `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24=true`

---

## [0.2.0] — Vehicle Sync & UDP Position Relay

> Commit `cfcbbb3`

### Added
- **UDP socket layer** (`net/udp.rs`): binary position relay with session-hash authentication
- **Vehicle packet types**: VehicleSpawn, VehicleEdit, VehicleDelete, VehicleReset, WorldState in `packet.rs`
- **World state module** (`state/vehicle.rs`, `state/world.rs`): authoritative vehicle tracking with DashMap
- **Session hash system**: SHA-256 based UDP authentication linking UDP packets to TCP sessions
- **WorldState snapshot**: newly joined players receive full vehicle/player state on connect
- **TCP vehicle dispatch**: receive loop handles spawn/edit/delete/reset with ownership validation
- **Disconnect cleanup**: all vehicles removed and VehicleDelete broadcast when player disconnects
- **Client UDP binding** (`connection.lua`): automatic UDP socket setup after authentication
- **Client position sending** (`state.lua`): configurable tick-rate position updates via binary UDP
- **Client vehicle management** (`vehicles.lua`): remote vehicle spawn/remove/interpolation buffer
- **Client subsystem wiring** (`highbeam.lua`): state.tick and vehicles.tick called in onUpdate
- 5 new packet round-trip tests (16 total)

### Changed
- `SessionManager` rewritten with `session_hashes` DashMap, `broadcast_udp()`, `get_player_snapshot()`
- `Player` struct extended with `udp_addr` and `session_hash` fields
- `tcp.rs` `start_listener` and `handle_connection` now accept `Arc<WorldState>`
- `main.rs` creates WorldState and spawns UDP task alongside TCP listener

---

## [0.1.0] — Foundation

> Commit `abf7d44`

### Added
- Project initialization with full documentation structure
- Architecture docs: OVERVIEW.md, CLIENT.md, SERVER.md, PROTOCOL.md
- Version planning: VERSION_PLAN.md with roadmap through v1.0.0
- Reference docs: BEAMMP_RESEARCH.md, BEAMNG_MODDING.md
- Documentation index (INDEX.md) with usage instructions for developers and AI assistants
- Copilot instructions (.copilot-instructions.md)
- PR template, .gitignore, README.md, LICENSE
- BUILD_GUIDE.md — comprehensive implementation blueprint with code examples
- Acceptance criteria for every milestone in VERSION_PLAN.md
- **Server**: TCP listener, handshake (ServerHello → AuthRequest → AuthResponse), session management, open auth mode, TOML config, structured logging
- **Client**: GE extension, TCP connection, handshake flow, connect/disconnect UI

### Changed
- Default port set to **18860** (1886 = Karl Benz's automobile patent)
- Default update rate set to **20 Hz** (research-backed; configurable)
- UDP position packets designed as binary from v0.2.0 onward (63/65-byte fixed layout via LuaJIT FFI)
- Plugin system designed with `plugin.toml` manifests (explicit entry points, declared dependencies)
- Security policy established: strict original work policy, no BeamMP source reference
