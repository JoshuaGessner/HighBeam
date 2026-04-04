# HighBeam Documentation Index

> **This is the master index for all HighBeam project documentation.**
> Always consult this file first when seeking project context, architectural guidance, or development procedures.

---

## How to Use This Index

### For Developers
1. **Before starting any work**, read the relevant architecture doc for the component you're touching.
2. **Before opening a PR**, consult [VERSION_PLAN.md](versioning/VERSION_PLAN.md) to ensure your work aligns with the current milestone.
3. **When adding features**, check [PROTOCOL.md](architecture/PROTOCOL.md) to ensure protocol compatibility.
4. **When logging changes**, update [VERSION_PLAN.md](versioning/VERSION_PLAN.md) milestone checkboxes and Recent Release Notes.

### For Copilot / AI Assistants
1. **Always read this INDEX.md first** when the user asks about project structure, architecture, or development procedures.
2. **Before generating code**, read the architecture doc for the relevant component:
   - Client mod work → [CLIENT.md](architecture/CLIENT.md)
   - Server binary work → [SERVER.md](architecture/SERVER.md)
   - Network/protocol work → [PROTOCOL.md](architecture/PROTOCOL.md)
3. **Before suggesting version bumps or release steps**, read [VERSION_PLAN.md](versioning/VERSION_PLAN.md).
4. **For BeamNG modding context**, read [BEAMNG_MODDING.md](reference/BEAMNG_MODDING.md).
5. **After completing work**, remind the developer to update [VERSION_PLAN.md](versioning/VERSION_PLAN.md).

---

## Document Map

### Architecture (`docs/architecture/`)

| Document | Purpose | Read When... |
|----------|---------|-------------|
| [OVERVIEW.md](architecture/OVERVIEW.md) | High-level system architecture, component relationships, design philosophy | Starting the project, onboarding, or making cross-cutting decisions |
| [LAUNCHER.md](architecture/LAUNCHER.md) | Launcher architecture, mod sync protocol, file transfer, caching | Writing or modifying launcher code, mod distribution |
| [CLIENT.md](architecture/CLIENT.md) | Client-side BeamNG mod architecture (Lua) | Writing or modifying client mod code |
| [SERVER.md](architecture/SERVER.md) | Server binary architecture (Rust) | Writing or modifying server code |
| [PROTOCOL.md](architecture/PROTOCOL.md) | Network protocol specification (TCP/UDP) | Adding new packet types, debugging networking, or working on client-server communication |
| [RELAY.md](architecture/RELAY.md) | Community relay server list architecture | Working on server discovery, relay hosting, or community node integration |

### Implementation (`docs/`)

| Document | Purpose | Read When... |
|----------|---------|-------------|
| [BUILD_GUIDE.md](BUILD_GUIDE.md) | Step-by-step implementation blueprint for every phase | Building any component — this is the master build plan |
| [EXTENSION_BOOTSTRAP_FIX.md](EXTENSION_BOOTSTRAP_FIX.md) | Historical fix: how the client mod bootstrap issue was diagnosed and resolved | Debugging client mod loading issues in BeamNG |

### Versioning (`docs/versioning/`)

| Document | Purpose | Read When... |
|----------|---------|-------------|
| [VERSION_PLAN.md](versioning/VERSION_PLAN.md) | Version roadmap, milestone definitions, SemVer policy, release process | Planning work, cutting releases, deciding what goes in which version |

### Reference (`docs/reference/`)

| Document | Purpose | Read When... |
|----------|---------|-------------|
| [BEAMNG_MODDING.md](reference/BEAMNG_MODDING.md) | BeamNG.drive modding reference: Lua scripting, extensions, UI apps | Writing client-side code that interfaces with BeamNG |

---

## Quick Reference: Key Design Decisions

| Decision | Choice | Rationale | Doc |
|----------|--------|-----------|-----|
| Server language | Rust | Memory safety, performance, cross-platform, async networking | [SERVER.md](architecture/SERVER.md) |
| Client language | Lua (LuaJIT) | Required by BeamNG.drive's extension system | [CLIENT.md](architecture/CLIENT.md) |
| Auth model | Decentralized (server-issued tokens) | No dependency on centralized auth servers | [OVERVIEW.md](architecture/OVERVIEW.md) |
| Transport | TCP (reliable) + UDP (state sync) | TCP for events/config, UDP for high-frequency position updates | [PROTOCOL.md](architecture/PROTOCOL.md) |
| Default port | 18860 (TCP + UDP) | 1886 = birth of the automobile; unassigned in IANA | [PROTOCOL.md](architecture/PROTOCOL.md) |
| Update rate | 20 Hz (configurable) | Balances visual quality with bandwidth | [BUILD_GUIDE.md](BUILD_GUIDE.md) |
| Versioning | SemVer 2.0.0 | Industry standard, clear compatibility signals | [VERSION_PLAN.md](versioning/VERSION_PLAN.md) |
| Server discovery | Direct connect + optional community relay | No enforced centralized server list | [OVERVIEW.md](architecture/OVERVIEW.md) |

---

## Project Directory Layout

```
HighBeam/
├── .github/                    # GitHub templates and CI
│   └── PULL_REQUEST_TEMPLATE.md
├── client/                     # BeamNG.drive mod (Lua)
│   ├── lua/ge/extensions/      # BeamNG extension scripts
│   ├── scripts/                # Mod loader scripts
│   └── ui/                     # UI apps (HTML/JS/CSS)
├── launcher/                   # Launcher binary (Rust)
│   ├── src/                    # Rust source code
│   ├── payload/                # Client mod zip payload
│   └── Cargo.toml              # Rust project manifest
├── server/                     # Server binary (Rust)
│   ├── src/                    # Rust source code
│   ├── Resources/              # Server/client mod resources
│   └── Cargo.toml              # Rust project manifest
├── docs/                       # All documentation
│   ├── INDEX.md                # ← YOU ARE HERE
│   ├── architecture/           # System design docs
│   ├── versioning/             # Version planning and changelog
│   └── reference/              # Research and external references
├── .copilot-instructions.md    # AI coding assistant instructions
├── .gitignore                  # Git ignore rules
├── LICENSE                     # Project license
└── README.md                   # Project overview
```

---

## Maintenance Rules

1. **Keep this index current.** When adding a new doc, add it to the Document Map table above.
2. **One truth per topic.** Don't duplicate information across docs — link to the canonical source instead.
3. **Date your research.** Reference docs should note when they were last verified.
4. **Version your architecture.** When an architecture doc changes significantly, note the version it applies to.
