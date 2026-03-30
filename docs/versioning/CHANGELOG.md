# Changelog

All notable changes to the HighBeam project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- **Launcher architecture** (`docs/architecture/LAUNCHER.md`): new component — lightweight Rust CLI that syncs mods via raw binary TCP, installs the client mod, launches BeamNG.drive, and exits
- Launcher mod transfer protocol: `mod_list`/`mod_request` JSON handshake + raw binary file stream (0.002% overhead vs 33% for base64)
- Mod cache design with SHA-256 deduplication across servers (`~/.highbeam/cache/`)
- Launcher added to VERSION_PLAN.md v0.3.0 milestone with full task list

### Changed
- Architecture is now **three components**: launcher, client mod, server (was two)
- Mod distribution moved from in-game client to pre-launch launcher (BeamNG Lua sandbox prevents file writes)
- PROTOCOL.md: removed `mod_data` packet, replaced `mod_info` with `mod_list`, added launcher transfer protocol section
- BUILD_GUIDE.md §3.3 rewritten for launcher-based mod distribution
- OVERVIEW.md, CLIENT.md, SERVER.md, README.md updated to reflect launcher
- BEAMMP_RESEARCH.md comparison table updated (lightweight launcher vs always-running proxy)

## [0.2.0] — Vehicle Sync & UDP Position Relay

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

### Added
- Project initialization with full documentation structure
- Architecture docs: OVERVIEW.md, CLIENT.md, SERVER.md, PROTOCOL.md
- Version planning: VERSION_PLAN.md with roadmap through v1.0.0
- Reference docs: BEAMMP_RESEARCH.md, BEAMNG_MODDING.md
- Documentation index (INDEX.md) with usage instructions for developers and AI assistants
- Copilot instructions (.copilot-instructions.md)
- PR template, .gitignore, README.md, LICENSE
- BUILD_GUIDE.md — comprehensive 6-phase implementation blueprint with code examples
- Acceptance criteria for every milestone in VERSION_PLAN.md

### Changed
- Default port changed from 30814 to **18860** (1886 = Karl Benz's automobile patent)
- Default update rate changed from 30 Hz to **20 Hz** (research-backed; configurable)
- Networking model refined: state synchronization with priority accumulator, jitter buffer, snapshot interpolation, visual smoothing, and delta compression (documented in BUILD_GUIDE.md)
- **UDP position packets are binary from Phase 2** (63/65-byte fixed layout via LuaJIT FFI; no JSON serialization overhead)
- **Plugin system uses `plugin.toml` manifests** instead of alphabetical file loading — explicit entry points, declared dependencies, topological load ordering
- Added **Original Work Policy** to BUILD_GUIDE.md and .copilot-instructions.md — strict rules against referencing AGPL-3.0 BeamMP source code
- **v0.4.0 expanded**: now includes vehicle persistence system alongside plugin system
- **v0.5.0 reworked**: "Server GUI & Performance" — includes built-in egui management interface with system tray
- **Security policy strengthened**: strict enforcement noted across SERVER.md, OVERVIEW.md, BUILD_GUIDE.md, and .copilot-instructions.md
- SERVER.md: added `gui/` module (app, panels, tray), `state/persistence.rs`, new crate dependencies (eframe, tray-icon, rusqlite, image)
- SERVER.md: added `[Persistence]` config section, `Headless` flag, persistence API functions and events
- SERVER.md: added Security Protocol section (8 principles)
- OVERVIEW.md: added GUI, persistence, and security enforcement to architecture diagram and tables
- PROTOCOL.md: added `vehicle_persist` and `vehicle_unpersist` TCP packet types, persistent vehicles in WorldState
- CLIENT.md: vehicles module handles frozen persistent vehicles with "(offline)" indicator
- VERSION_PLAN.md: v1.0.0 now requires security audit and GUI testing
- Tech stack: SQLite upgraded from "optional" to required (vehicle persistence)
