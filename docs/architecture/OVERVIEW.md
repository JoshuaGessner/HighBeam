# HighBeam Architecture Overview

> **Last updated:** 2026-04-03
> **Applies to:** v0.8.0-dev.4

---

## What Is HighBeam?

HighBeam is an open-source multiplayer framework for BeamNG.drive that provides:

1. **A launcher** — A lightweight Rust CLI that installs/updates the client mod, downloads server-required mods, and launches BeamNG.drive.
2. **A client mod** — A Lua-based BeamNG.drive mod that handles in-game multiplayer UI, vehicle synchronization, and communication with the server.
3. **A server binary** — A standalone Rust application that manages player connections, game state, vehicle data relay, and server-side Lua plugins.

### Core Philosophy

HighBeam is designed as a **decentralized alternative** to existing multiplayer solutions. Key principles:

- **No centralized authentication** — Servers issue their own tokens. No auth keys from a central authority.
- **No enforced server list** — Players connect via direct IP or optional community-run relay/discovery services.
- **Self-contained servers** — A server binary runs independently with zero external service dependencies.
- **Lightweight launcher** — Unlike BeamMP's always-running proxy, HighBeam's launcher only handles mod management and game launch — it exits once the game is running. Mods are synced only for the specific server being joined and cleaned up after the session ends.
- **Extensible by default** — Both client and server expose plugin APIs for community customization.
- **Protocol transparency** — The network protocol is fully documented and versioned.
- **Cross-platform server** — The server binary runs on Windows, Linux, and macOS.

---

## Platform Targets

| Component | Supported Platforms | Notes |
|-----------|-------------------|-------|
| **Launcher** | Windows (x86_64) | Runs alongside BeamNG.drive. Linux/Proton support possible in future. |
| **Server binary** | Windows (x86_64), Linux (x86_64, aarch64), macOS (x86_64, aarch64) | Primary targets: Windows and Linux. macOS supported for development. |
| **Client mod** | Windows (via BeamNG.drive) | BeamNG.drive is a Windows application. Linux users can run it via Proton/Wine. |

The server is designed to be hosted on **dedicated Linux servers** (headless mode) or **personal Windows/macOS machines** (GUI mode). All server dependencies are pure Rust or have cross-platform C bindings and compile on all three platforms without conditional code.

---

## System Architecture

```
┌─────────────────────────────────────────────────────────┐
│                 HighBeam Launcher (Rust CLI)             │
│  ┌─────────────────────────────────────────────────┐    │
│  │  Install/update client mod → BeamNG mods dir    │    │
│  │  Connect to server → download required mods     │    │
│  │  Launch BeamNG.drive → exit                     │    │
│  └─────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘
          │ (runs once, exits after game launch)
          ▼
┌─────────────────────────────────────────────────────────┐
│                    BeamNG.drive                          │
│  ┌───────────────────────────────────────────────────┐  │
│  │              HighBeam Client Mod                   │  │
│  │  ┌─────────────┐  ┌──────────────┐  ┌─────────┐  │  │
│  │  │  Extension   │  │  Net Manager │  │   UI    │  │  │
│  │  │  (Lua/GE)    │  │  (TCP + UDP) │  │  Apps   │  │  │
│  │  └──────┬───────┘  └──────┬───────┘  └────┬────┘  │  │
│  │         │                 │                │       │  │
│  │         └────────┬────────┘                │       │  │
│  │                  │                         │       │  │
│  │           ┌──────┴──────┐                  │       │  │
│  │           │ Event Bridge │◄─────────────────┘       │  │
│  │           └──────┬──────┘                          │  │
│  └──────────────────┼────────────────────────────────┘  │
└─────────────────────┼───────────────────────────────────┘
                      │
          TCP (reliable)  +  UDP (state sync)
          (direct connection — no proxy)
                      │
┌─────────────────────┼───────────────────────────────────┐
│            HighBeam Server Binary                        │
│  ┌──────────────────┴──────────────────────────────┐    │
│  │              Connection Manager                  │    │
│  │         (TCP listener + UDP receiver)            │    │
│  └──────┬──────────────────────────┬───────────────┘    │
│         │                          │                     │
│  ┌──────┴──────┐            ┌──────┴──────┐              │
│  │   Session   │            │    State    │              │
│  │   Manager   │            │   Manager   │              │
│  │ (auth, ids) │            │ (vehicles,  │              │
│  └──────┬──────┘            │  positions) │              │
│         │                   └──────┬──────┘              │
│  ┌──────┴──────────────────────────┴───────────────┐    │
│  │                Plugin Runtime                    │    │
│  │              (Lua 5.3/5.4 states)                │    │
│  └─────────────────────────────────────────────────┘    │
│                                                          │
│  ┌─────────────────────────────────────────────────┐    │
│  │              Config & Storage                    │    │
│  │           (TOML config, SQLite/JSON)             │    │
│  └─────────────────────────────────────────────────┘    ││                                                          │
│  ┌───────────────────────────────────────────────────┐    │
│  │             Management GUI (egui)                 │    │
│  │   (Dashboard, Players, Maps, Mods, Settings)     │    │
│  │            + System Tray Integration              │    │
│  └───────────────────────────────────────────────────┘    │└──────────────────────────────────────────────────────────┘
```

---

## Component Breakdown

### Launcher (`launcher/`)

The launcher is a lightweight Rust CLI that runs **before** BeamNG.drive launches. Unlike BeamMP’s launcher, it is **not a network proxy** and does **not stay running** during gameplay.

| Responsibility | Description |
|---------------|-------------|
| **Client mod install** | Installs or updates the HighBeam client mod zip into BeamNG’s mods directory |
| **Mod sync** | Connects to the target server only when an explicit join is requested, queries required mods, downloads missing ones via raw binary TCP |
| **Session staging** | Stages server-required mods into BeamNG mods folder under a `highbeam-session-*` prefix; records staged files in a session manifest |
| **Session cleanup** | Removes staged server mods from BeamNG mods folder after the game exits; stale sessions from crashed launcher runs are recovered on next startup |
| **Mod caching** | Maintains a local cache with SHA-256 hashes to skip re-downloading unchanged mods across sessions |
| **Game launch** | Launches BeamNG.drive with the correct mod configuration, then exits |

The launcher is the **only component that writes to the filesystem** outside the game. The in-game client mod has no file I/O responsibilities for mod management.

See [LAUNCHER.md](LAUNCHER.md) for full details.

### Client Mod (`client/`)

The client mod runs inside BeamNG.drive using its Lua extension system. It is responsible for:

| Responsibility | Description |
|---------------|-------------|
| **Connection management** | Establishes TCP + UDP connections to a HighBeam server |
| **Vehicle sync** | Sends local vehicle state (position, rotation, velocity, config) and applies remote vehicle state |
| **Event bridge** | Routes events between server and local game (chat, spawns, edits, deletions) |
| **UI** | Server browser (direct connect), chat, player list, connection status |

See [CLIENT.md](CLIENT.md) for full details.

### Server Binary (`server/`)

The server is a standalone Rust binary. It is responsible for:

| Responsibility | Description |
|---------------|-------------|
| **Connection handling** | Accepts TCP + UDP connections, manages handshake and keepalive |
| **Authentication** | Self-contained token-based auth (no external auth server) |
| **State management** | Tracks all connected players, their vehicles, positions, and metadata |
| **Packet relay** | Forwards vehicle state and events between connected clients |
| **Plugin runtime** | Embeds Lua 5.4 for server-side scripting/plugins |
| **Mod hosting** | Serves client mods from `Resources/Client/` to connecting players |
| **Vehicle persistence** | SQLite-backed storage for vehicles that persist when owners disconnect (admin-toggled per player) |
| **Management GUI** | Built-in desktop interface (egui) for managing maps, mods, plugins, players, and settings |
| **System tray** | Minimize-to-tray support with status icon and context menu |
| **Configuration** | TOML-based server config, editable at runtime via GUI |

See [SERVER.md](SERVER.md) for full details.

### Network Protocol

The protocol uses **two channels**:

| Channel | Transport | Purpose | Examples |
|---------|-----------|---------|----------|
| **Reliable** | TCP | Events, auth, config, chat, vehicle spawn/edit/delete | Player join, chat message, vehicle config change |
| **Fast** | UDP | High-frequency state sync | Position, rotation, velocity updates (default 20 Hz, configurable) |

See [PROTOCOL.md](PROTOCOL.md) for the full protocol specification.

---

## Key Architectural Differences from BeamMP

| Aspect | BeamMP | HighBeam |
|--------|--------|----------|
| **Authentication** | Centralized — requires auth key from BeamMP Keymaster (Discord login) | Decentralized — server issues its own tokens, optional password protection |
| **Server list** | Centralized — servers must register with BeamMP backend to appear in list | Optional — community relay for discovery, or direct IP connect (see [RELAY.md](RELAY.md)) |
| **Launcher** | Separate C++ launcher binary that bridges game ↔ server (always-running proxy) | Lightweight Rust CLI — syncs mods, launches game, then exits (not a proxy) |
| **Server binary** | C++ with embedded Lua 5.3 | Rust with embedded Lua 5.4 |
| **Server management** | Terminal-only (headless console) | Built-in desktop GUI (egui) with system tray, plus headless mode |
| **Vehicle persistence** | Not supported natively | Admin-toggled per-player vehicle persistence (SQLite-backed) |
| **Protocol** | Undocumented binary protocol through launcher proxy | Fully documented, versioned protocol with direct game connection |
| **Plugin API** | Lua plugin system with MP.* functions | Compatible Lua plugin system with extended HB.* API namespace |
| **Guest support** | Centralized guest system via BeamMP backend | Server-local guest policy (configurable per-server) |
| **Mod sync** | Mods served from Resources/Client via launcher proxy | Launcher downloads mods via raw binary TCP before game launch; no in-game file I/O |

---

## Security Model

### Authentication Flow

```
Client                              Server
  │                                    │
  │──── TCP Connect ──────────────────►│
  │                                    │
  │◄─── Server Hello (version, name) ──│
  │                                    │
  │──── Auth Request ─────────────────►│
  │     (username, password/token)     │
  │                                    │
  │     [Server validates locally]     │
  │                                    │
  │◄─── Auth Response ────────────────│
  │     (session token, player ID)     │
  │                                    │
  │──── UDP Bind (session token) ─────►│
  │                                    │
  │◄─── Session Established ──────────│
```

- **No external auth dependency.** The server owns its auth entirely.
- **Session tokens** are short-lived, random, and tied to the TCP connection.
- **Passwords** are optional per-server. Server operators decide their auth policy.
- **Rate limiting** on auth attempts to prevent brute force.

### Network Security

- All TCP traffic can optionally be TLS-encrypted (planned for v0.3.0+).
- UDP packets are authenticated via session token hash to prevent spoofing.
- Server validates all client input — no trusting client-sent data blindly.

### Security Enforcement

> **Security is enforced strictly at every layer. There are no exceptions.**

- All input from clients is treated as untrusted. Packet sizes, field values, string lengths, and JSON structure are validated before processing.
- Rate limiting is applied to auth attempts, chat messages, vehicle spawns, and all other client-initiated actions.
- **Server plugin sandboxing** prevents access to `os.execute`, `io.popen`, and raw FFI. Plugins cannot escape their directory. FS operations have per-plugin storage quotas and file size limits (v0.9.0).
- **Client mod sandboxing** (v0.9.0) applies defense-in-depth: ZIP content scanning (path traversal, file type whitelist, zip bomb detection), Lua static analysis (regex-based dangerous API detection), and runtime environment hardening (dangerous globals neutered before server mods load).
- **Mod transfer integrity** (v0.9.0): Ed25519 manifest signing with TOFU key management, TLS enforcement for mod downloads, per-mod size limits.
- The server GUI is local-only (egui desktop rendering) — not a web server. No network-exposed admin surface.
- Session tokens are cryptographically random and short-lived. Passwords are Argon2-hashed.
- Resource limits (MaxPlayers, MaxCarsPerPlayer, max packet size) are always enforced.

---

## Data Flow: Vehicle Synchronization

```
Player A (Client)           Server              Player B (Client)
     │                        │                       │
     │  [Spawns vehicle]      │                       │
     │── VehicleSpawn ───────►│                       │
     │   (config JSON)        │── VehicleSpawn ──────►│
     │                        │   (config JSON)       │
     │                        │                       │  [Vehicle appears]
     │                        │                       │
     │  [Drives around]       │                       │
     │── PosUpdate (UDP) ────►│                       │
     │   (pos,rot,vel @20Hz)  │── PosUpdate (UDP) ──►│
     │                        │                       │  [Vehicle moves]
     │                        │                       │
     │  [Edits vehicle]       │                       │
     │── VehicleEdit ────────►│                       │
     │   (updated config)     │── VehicleEdit ───────►│
     │                        │                       │  [Config applied]
```

---

## Technology Stack Summary

| Component | Technology | Rationale |
|-----------|-----------|-----------|| Launcher | Rust | Same toolchain as server, native filesystem access, small binary size || Server binary | Rust | Memory safety without GC, excellent async networking (tokio), cross-platform |
| Server plugins | Lua 5.4 (via mlua) | Familiar to BeamNG modders, sandboxed execution, hot-reloadable |
| Client mod | Lua (LuaJIT via BeamNG) | Required by BeamNG.drive's extension system — runs in GELUA (main/graphics thread) |
| Client UI | HTML/JS/CSS (BeamNG UI apps) | BeamNG's native UI app framework |
| Server GUI | egui/eframe (Rust) | Immediate-mode GUI, cross-platform, no web server dependency |
| System tray | tray-icon (Rust) | Cross-platform tray integration for minimize-to-tray |
| Network | TCP + UDP (custom protocol) | TCP for reliability, UDP for performance |
| Config | TOML | Human-readable, well-supported in Rust ecosystem |
| Storage | SQLite (rusqlite) | Vehicle persistence and plugin data storage |
| Build system | Cargo (Rust), zip (client mod) | Standard tooling for each ecosystem |
