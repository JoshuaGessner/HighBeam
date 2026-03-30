# HighBeam

**Decentralized multiplayer framework for BeamNG.drive.**

HighBeam is an open-source multiplayer mod and server for BeamNG.drive that lets you host and join multiplayer sessions without third-party accounts, server lists, or always-running background software.

---

## Key Features

- **No auth keys** — Servers are fully self-contained. No third-party accounts or API keys required.
- **Lightweight launcher** — A small Rust binary syncs mods, installs the client mod, launches the game, and exits. No always-running proxy.
- **Direct connect** — Connect to any server by IP:port from the in-game UI. No traffic routed through a third party.
- **Server-side plugins** — Lua 5.4 scripting for server customization (chat commands, game modes, economy, custom events).
- **Server browser** — Optional community relay for discovering servers — no centralized authority required. *(Coming in v0.6.0)*
- **Open protocol** — The network protocol is fully documented and versioned.

---

## Current Status

**v0.4.1** — Core multiplayer, chat, mod sync via launcher, and server-side Lua plugin system all implemented. Production hardening applied across server and client.

| Feature | Status |
|---------|--------|
| TCP connection & authentication | ✅ Done |
| Real-time vehicle sync (UDP) | ✅ Done |
| Production hardening (timeouts, rate limiting, input validation, file logging) | ✅ Done |
| Chat & mod distribution via launcher | ✅ Done |
| Server-side Lua plugins | ✅ Done |
| Server management GUI | ⏳ Planned (v0.5.0) |
| Server browser / discovery | ⏳ Planned (v0.6.0) |
| Stable v1.0.0 release | 🔭 Target |

---

## Getting Started

> **Note:** HighBeam is in active early development. The steps below reflect the current build. A packaged release will be available once the server GUI is complete (v0.5.0).

### Requirements

- **Rust toolchain** (stable) — [rustup.rs](https://rustup.rs)
- **BeamNG.drive** (for the client mod)

### Running the Server

```bash
cd server
cargo build --release
./target/release/highbeam-server
```

The server listens on port **18860** by default. A `ServerConfig.toml` is created on first run — edit it to set your server name, max players, and auth mode (`open`, `password`, or `allowlist`).

> **Tip:** Linux is the recommended platform for dedicated servers. The server binary is identical across all platforms.

### Connecting as a Client

1. Run the HighBeam launcher and point it at your server:
   ```bash
   ./highbeam-launcher --server <server-ip>:18860
   ```
2. The launcher syncs required mods, installs the client mod, and launches BeamNG.drive.
3. Use the HighBeam in-game UI to connect and start driving.

> **Note:** The launcher can also be built from source (`cd launcher && cargo build --release`).

---

## Platform Support

| Component | Platform | Status |
|-----------|----------|--------|
| Server | Windows (x86_64) | ✅ Supported |
| Server | Linux (x86_64, aarch64) | ✅ Supported |
| Server | macOS (x86_64, aarch64) | ✅ Supported |
| Launcher | Windows (x86_64) | ✅ Supported |
| Launcher | Linux (x86_64, aarch64) | ✅ Supported |
| Launcher | macOS (x86_64, aarch64) | ✅ Supported |
| Client mod | Windows (BeamNG.drive) | ✅ Supported |

The server is pure Rust with no platform-specific code and compiles identically on all three operating systems.

---

## Technical Specifications

| Component | Technology |
|-----------|-----------|
| Server | Rust |
| Launcher | Rust (CLI) |
| Client mod | Lua (LuaJIT, via BeamNG) |
| Server plugins | Lua 5.4 |
| Reliable channel | TCP (length-prefixed JSON packets) |
| Fast sync channel | UDP (binary, 63–65 bytes per position update) |
| Default port | 18860 |

### Security

- **Rate limiting** — Auth attempts capped at 5/min per IP; chat at 10/10 s; vehicle spawns at 5/5 s per player.
- **Input validation** — Usernames, chat messages, vehicle configs, and all config values are validated before use. Oversized payloads (>1 MB) are rejected.
- **Session tokens** — 64-byte random tokens with nanosecond-precision timestamp prefix and collision detection.
- **Config validation** — Server refuses to start if `ServerConfig.toml` contains invalid values (bad auth mode, missing password, etc.).
- **Idle timeouts** — Connections with no activity for 60 seconds are closed automatically.
- **Graceful shutdown** — SIGTERM/SIGINT handlers ensure clean disconnects and log flushing.

---

## Roadmap

| Version | Milestone | Status |
|---------|-----------|--------|
| v0.1.0 | TCP handshake + auth | ✅ Done |
| v0.2.0 | Real-time vehicle sync | ✅ Done |
| v0.3.0 | Chat, mod distribution, launcher | ✅ Done |
| v0.4.1 | Server-side Lua plugin system | ✅ Done |
| v0.5.0 | Server management GUI | ⏳ Next |
| v0.6.0 | Server browser & discovery | 📋 Planned |
| v1.0.0 | Stable release | 🔭 Target |

---

## Contributing

Contributions are welcome. Before opening a PR, please read the architecture docs and follow conventional commit message style (`feat:`, `fix:`, `chore:`, etc.).

---

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
