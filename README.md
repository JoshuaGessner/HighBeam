# HighBeam

**Decentralized multiplayer framework for BeamNG.drive.**

HighBeam is an open-source multiplayer mod and server for BeamNG.drive that enables peer-to-peer vehicle synchronization without centralized authentication or mandatory server lists.

---

## Key Features

- **No auth keys** — Servers are self-contained. No third-party accounts or API keys required.
- **No launcher** — The client mod runs directly inside BeamNG.drive. No external programs needed.
- **Direct connect** — Join any server by IP address, or browse optional community relays.
- **Server-side plugins** — Lua 5.4 scripting for server customization (chat commands, game modes, economy).
- **Documented protocol** — The network protocol is fully specified and versioned.

## Architecture

| Component | Technology | Directory |
|-----------|-----------|-----------|
| Client mod | Lua (LuaJIT, via BeamNG) | `client/` |
| Server binary | Rust | `server/` |
| Network | TCP (reliable) + UDP (fast sync) | — |
| Server plugins | Lua 5.4 | `server/plugins/` |

## Platform Support

| Component | Platform | Status |
|-----------|----------|--------|
| Server | Windows (x86_64) | Supported |
| Server | Linux (x86_64, aarch64) | Supported |
| Server | macOS (x86_64, aarch64) | Supported |
| Client mod | Windows (BeamNG.drive) | Supported |

The server is pure Rust with no platform-specific code — it compiles and runs identically on all three operating systems. Linux is the recommended platform for dedicated servers (`--headless` mode).

## Current Status

**Pre-alpha** — Core TCP handshake and auth implemented. Vehicle sync in progress. See [VERSION_PLAN.md](docs/versioning/VERSION_PLAN.md) for the roadmap.

## Documentation

All project docs live in `docs/`. Start with the index:

- **[docs/INDEX.md](docs/INDEX.md)** — Master documentation index and navigation guide

### Quick Links

| Doc | Content |
|-----|---------|
| [Architecture Overview](docs/architecture/OVERVIEW.md) | System design, components, security model |
| [Client Architecture](docs/architecture/CLIENT.md) | BeamNG mod structure, subsystems |
| [Server Architecture](docs/architecture/SERVER.md) | Rust server design, plugin API |
| [Protocol Spec](docs/architecture/PROTOCOL.md) | TCP/UDP packet formats, connection flow |
| [Version Plan](docs/versioning/VERSION_PLAN.md) | Roadmap, milestones, release process |
| [Changelog](docs/versioning/CHANGELOG.md) | Running change log |

## Getting Started

> **Note:** HighBeam is in early development. Build instructions will be added once the first working prototype is available.

### Server (Planned)

```bash
cd server
cargo build --release
./target/release/highbeam-server
```

### Client (Planned)

1. Build the client mod zip from `client/`
2. Place it in `%LOCALAPPDATA%/BeamNG.drive/mods/`
3. Launch BeamNG.drive
4. Use the HighBeam UI to connect to a server

## Contributing

1. Read [.copilot-instructions.md](.copilot-instructions.md) for coding standards
2. Read the architecture docs for the component you're working on
3. Branch from `develop`, follow the commit message format
4. Open a PR using the template

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
