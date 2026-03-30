# Changelog

All notable changes to the HighBeam project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased] — v0.3.0-alpha.1

> Working toward v0.3.0. Chat, mod sync, and launcher features partially implemented.
> Production hardening applied across server and client.

### Added (v0.3.0 features)
- **Chat system**: ChatMessage/ChatBroadcast packets, server relay, client chat UI (`chat.html`, `chat.lua`)
- **Launcher binary** (`launcher/`): Rust CLI that syncs mods, installs client mod, launches BeamNG
- **Mod sync**: `mod_list` endpoint, SHA-256 manifest, raw binary TCP file transfer (0.002% overhead vs 33% for base64)
- **Mod cache**: SHA-256 deduplication across servers (`~/.highbeam/cache/`)
- **Kick packet**: server can forcibly disconnect players with reason
- **Auth rate limiting**: 5 attempts per 60s per IP, chat 10/10s, spawn 5/5s
- **Launcher CLI**: `--server`, `--no-launch`, `--clear-cache` flags

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
