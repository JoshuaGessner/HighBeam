# Changelog

All notable changes to the HighBeam project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

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
