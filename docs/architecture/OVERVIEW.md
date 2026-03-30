# HighBeam Architecture Overview

> **Last updated:** 2026-03-29
> **Applies to:** v0.1.0 (pre-alpha)

---

## What Is HighBeam?

HighBeam is an open-source multiplayer framework for BeamNG.drive that provides:

1. **A client mod** — A Lua-based BeamNG.drive mod that handles in-game multiplayer UI, vehicle synchronization, and communication with the server.
2. **A server binary** — A standalone Rust application that manages player connections, game state, vehicle data relay, and server-side Lua plugins.

### Core Philosophy

HighBeam is designed as a **decentralized alternative** to existing multiplayer solutions. Key principles:

- **No centralized authentication** — Servers issue their own tokens. No auth keys from a central authority.
- **No enforced server list** — Players connect via direct IP or optional community-run relay/discovery services.
- **Self-contained servers** — A server binary runs independently with zero external service dependencies.
- **Extensible by default** — Both client and server expose plugin APIs for community customization.
- **Protocol transparency** — The network protocol is fully documented and versioned.

---

## System Architecture

```
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
│  └─────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────┘
```

---

## Component Breakdown

### Client Mod (`client/`)

The client mod runs inside BeamNG.drive using its Lua extension system. It is responsible for:

| Responsibility | Description |
|---------------|-------------|
| **Connection management** | Establishes TCP + UDP connections to a HighBeam server |
| **Vehicle sync** | Sends local vehicle state (position, rotation, velocity, config) and applies remote vehicle state |
| **Event bridge** | Routes events between server and local game (chat, spawns, edits, deletions) |
| **UI** | Server browser (direct connect), chat, player list, connection status |
| **Mod distribution** | Downloads server-required mods on connect |

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
| **Configuration** | TOML-based server config |

See [SERVER.md](SERVER.md) for full details.

### Network Protocol

The protocol uses **two channels**:

| Channel | Transport | Purpose | Examples |
|---------|-----------|---------|----------|
| **Reliable** | TCP | Events, auth, config, chat, vehicle spawn/edit/delete | Player join, chat message, vehicle config change |
| **Fast** | UDP | High-frequency state sync | Position, rotation, velocity updates (10-60 Hz) |

See [PROTOCOL.md](PROTOCOL.md) for the full protocol specification.

---

## Key Architectural Differences from BeamMP

| Aspect | BeamMP | HighBeam |
|--------|--------|----------|
| **Authentication** | Centralized — requires auth key from BeamMP Keymaster (Discord login) | Decentralized — server issues its own tokens, optional password protection |
| **Server list** | Centralized — servers must register with BeamMP backend to appear in list | Optional — community relay for discovery, or direct IP connect |
| **Launcher** | Separate C++ launcher binary that bridges game ↔ server | No separate launcher — client mod connects directly from within BeamNG |
| **Server binary** | C++ with embedded Lua 5.3 | Rust with embedded Lua 5.4 |
| **Protocol** | Undocumented binary protocol through launcher proxy | Fully documented, versioned protocol with direct game connection |
| **Plugin API** | Lua plugin system with MP.* functions | Compatible Lua plugin system with extended HB.* API namespace |
| **Guest support** | Centralized guest system via BeamMP backend | Server-local guest policy (configurable per-server) |
| **Mod sync** | Mods served from Resources/Client via launcher | Mods served directly from server to client mod |

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
     │   (pos,rot,vel @30Hz)  │── PosUpdate (UDP) ──►│
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
|-----------|-----------|-----------|
| Server binary | Rust | Memory safety without GC, excellent async networking (tokio), cross-platform |
| Server plugins | Lua 5.4 (via mlua) | Familiar to BeamNG modders, sandboxed execution, hot-reloadable |
| Client mod | Lua (LuaJIT via BeamNG) | Required by BeamNG.drive's extension system |
| Client UI | HTML/JS/CSS (BeamNG UI apps) | BeamNG's native UI app framework |
| Network | TCP + UDP (custom protocol) | TCP for reliability, UDP for performance |
| Config | TOML | Human-readable, well-supported in Rust ecosystem |
| Storage | SQLite (optional) | Lightweight persistent storage for plugins |
| Build system | Cargo (Rust), zip (client mod) | Standard tooling for each ecosystem |
