# BeamMP Research Notes

> **Last verified:** 2026-03-29
> **Sources:** BeamMP GitHub repos, docs.beammp.com, wiki.beammp.com
> **Purpose:** Understand BeamMP's architecture so HighBeam can improve upon it.

---

## What Is BeamMP?

BeamMP is the dominant open-source multiplayer mod for BeamNG.drive. It consists of three components:

1. **Launcher** (`BeamMP-Launcher`) — A C++ binary that handles authentication, game launching, mod injection, and proxies network traffic between the game and the server.
2. **Client mod** (`BeamMP`) — A Lua mod running inside BeamNG.drive that handles vehicle sync, chat, UI, and communication with the launcher.
3. **Server** (`BeamMP-Server`) — A C++ binary with embedded Lua 5.3 that manages player sessions, relays vehicle data, and runs server-side plugins.

### License

All three components are licensed under **AGPL-3.0**.

---

## Architecture Overview

### The Launcher Problem

BeamMP requires a **separate launcher binary** that sits between the game and the server:

```
BeamNG.drive ←→ BeamMP Launcher ←→ BeamMP Server
     (game)       (C++ proxy)        (C++ binary)
```

The launcher:
- Authenticates the player with BeamMP's centralized backend (via Discord OAuth)
- Injects the client mod into BeamNG.drive
- Creates a local TCP proxy that the in-game Lua mod connects to
- Forwards traffic between the in-game mod and the remote server

**HighBeam eliminates the launcher entirely** — the client mod connects directly to the server from within BeamNG.drive.

### Centralized Authentication

BeamMP uses a **centralized auth system** called the "Keymaster":

1. Server operators must **log in with Discord** at `beammp.com/keymaster`
2. They receive an **AuthKey** (format: `xxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`)
3. This key is placed in `ServerConfig.toml` under `AuthKey`
4. The server contacts BeamMP's backend to validate the key on startup
5. Players authenticate through the launcher, which contacts BeamMP's backend
6. The backend validates the player and returns identity info to the server

**Limitations of this model:**
- **Single point of failure** — If BeamMP's backend goes down, no new servers can start and no new players can join
- **Dependency on Discord** — Both server operators and players need Discord accounts
- **Key scarcity** — Free users get limited keys; more keys require Patreon support
- **No offline/LAN play** — Authentication requires internet access
- **Privacy concerns** — All player identity flows through BeamMP's servers

**HighBeam replaces this with server-local auth** — no external service dependency.

### Guest System

BeamMP has a centralized guest system:
- Players who don't authenticate can join as "guest" + random number
- Guest status is determined by BeamMP's backend
- Server operators can toggle `AllowGuests = true/false`
- `MP.IsPlayerGuest(pid)` checks guest status

**HighBeam equivalent:** Server operators configure their own auth policy (`open`, `password`, or `allowlist`).

---

## Server Architecture

### Technology Stack

| Component | Choice |
|-----------|--------|
| Language | C++ (modern) |
| Lua runtime | Lua 5.3 (via sol2 bindings, recently changed to 5.3.5) |
| Build system | CMake |
| Package manager | vcpkg |
| Networking | Custom TCP/UDP |
| Config | TOML (via toml11) |
| License | AGPL-3.0 |

### Configuration (`ServerConfig.toml`)

```toml
[General]
Port = 30814
AuthKey = "your-key-here"
AllowGuests = false
LogChat = false
Debug = false
IP = "::"
Private = true
InformationPacket = true
Name = "Server Name"
Tags = "Freeroam,Modded"
MaxCars = 2
MaxPlayers = 10
Map = "/levels/gridmap_v2/info.json"
Description = "Server description"
ResourceFolder = "Resources"
```

Key differences from HighBeam:
- `AuthKey` is **required** for public servers (HighBeam has no AuthKey concept)
- `AllowGuests` ties into centralized guest system (HighBeam has server-local auth modes)
- `InformationPacket` allows unauthenticated clients to query server info

### Default Port

BeamMP uses **port 30814** (TCP + UDP on the same port). HighBeam uses **port 18860** to avoid conflicts (1886 = year of the first automobile patent).

### Resource Directory Structure

```
Resources/
├── Client/          # Mod .zip files sent to connecting players
│   └── some_mod.zip
└── Server/          # Server-side Lua plugins
    ├── MyPlugin/
    │   └── main.lua
    └── OtherPlugin/
        └── main.lua
```

HighBeam mirrors this structure for familiarity.

---

## Server Plugin API (v3.x)

### Plugin Loading

- Plugins live in `Resources/Server/<PluginName>/`
- All `.lua` files in the plugin root are loaded alphabetically
- Lua files in subdirectories are ignored but can be `require()`-ed
- Each plugin gets its own Lua state (isolation)
- Hot reload: file changes in plugin root trigger state reload (v3.1.0+)

### MP.* Namespace

BeamMP exposes server functionality through the `MP.*` namespace:

#### Player Functions
| Function | Description |
|----------|-------------|
| `MP.GetPlayers()` | Returns `{id: name}` table of all connected players |
| `MP.GetPlayerName(pid)` | Get display name |
| `MP.GetPlayerCount()` | Number of connected players |
| `MP.IsPlayerConnected(pid)` | Whether player is connected with UDP |
| `MP.IsPlayerGuest(pid)` | Whether player is a guest |
| `MP.GetPlayerIdentifiers(pid)` | Returns `{ip, discord, beammp}` table |
| `MP.DropPlayer(pid, [reason])` | Kick a player |

#### Vehicle Functions
| Function | Description |
|----------|-------------|
| `MP.GetPlayerVehicles(pid)` | Returns `{vid: data_json}` table |
| `MP.GetPositionRaw(pid, vid)` | Returns position/rotation/velocity table |
| `MP.RemoveVehicle(pid, vid)` | Force-remove a vehicle |

#### Communication Functions
| Function | Description |
|----------|-------------|
| `MP.SendChatMessage(pid, msg)` | Send chat (-1 for broadcast) |
| `MP.TriggerClientEvent(pid, event, data)` | Send custom event to client |
| `MP.TriggerClientEventJson(pid, event, table)` | Same but auto-encodes table to JSON |

#### Event Functions
| Function | Description |
|----------|-------------|
| `MP.RegisterEvent(name, handler_name)` | Register event handler |
| `MP.CreateEventTimer(name, interval_ms)` | Create recurring timer event |
| `MP.CancelEventTimer(name)` | Cancel a timer |
| `MP.TriggerLocalEvent(name, ...)` | Trigger event in this plugin (sync) |
| `MP.TriggerGlobalEvent(name, ...)` | Trigger event in all plugins (async) |

#### Config Functions
| Function | Description |
|----------|-------------|
| `MP.Set(setting, value)` | Change ServerConfig at runtime |
| `MP.Settings` | Table mapping setting names to IDs |

### Util.* Namespace (v3.1.0+)

- `Util.JsonEncode/Decode/Prettify/Minify/Flatten/Unflatten/Diff/DiffApply`
- `Util.Random/RandomIntRange/RandomRange`
- `Util.LogInfo/LogWarn/LogError/LogDebug` (v3.3.0+)
- `Util.DebugExecutionTime()` — profiling data for event handlers

### FS.* Namespace

Filesystem functions: `CreateDirectory`, `Remove`, `Rename`, `Copy`, `Exists`, `IsFile`, `IsDirectory`, `ListFiles`, `ListDirectories`, `GetFilename`, `GetExtension`, `GetParentFolder`, `ConcatPaths`.

### Built-in Events

#### Player Lifecycle (triggered in this order)
1. `onPlayerAuth(name, role, is_guest, identifiers)` — **Cancellable**
2. `onPlayerConnecting(pid)` — Not cancellable
3. `onPlayerJoining(pid)` — Not cancellable (after mod download)
4. `onPlayerJoin(pid)` — Not cancellable

#### Other Events
| Event | Arguments | Cancellable |
|-------|-----------|-------------|
| `onPlayerDisconnect` | `pid` | No |
| `onChatMessage` | `pid, name, message` | **Yes** |
| `onVehicleSpawn` | `pid, vid, data` | **Yes** |
| `onVehicleEdited` | `pid, vid, data` | **Yes** |
| `onVehicleDeleted` | `pid, vid` | No |
| `onVehicleReset` | `pid, vid, data` | No |
| `onInit` | (none) | No |
| `onShutdown` | (none) | No |
| `onConsoleInput` | `input` | No |
| `onFileChanged` | `path` | No (v3.1.0+) |

---

## Client Mod Architecture

### Client Scripting API

The in-game Lua mod has a minimal API:

| Function | Description |
|----------|-------------|
| `TriggerServerEvent(event, data)` | Send custom event to server |
| `TriggerClientEvent(event, data)` | Trigger local event (inter-plugin) |
| `AddEventHandler(event, function)` | Register handler for incoming events |

Built-in events include `ChatMessageReceived`.

### Communication Flow

```
In-game Lua mod ←→ BeamMP Launcher (local proxy) ←→ BeamMP Server
```

The launcher acts as a TCP proxy on localhost. The in-game mod connects to the launcher, not directly to the server.

**HighBeam eliminates this proxy** — the in-game Lua mod connects directly to the server via TCP + UDP sockets.

---

## Protocol Details

### What We Know

- Default port: **30814** (TCP + UDP) — HighBeam uses **18860** to avoid conflicts
- The launcher proxies between game and server
- Vehicle data is sent as JSON strings
- Position data includes: pos (xyz), rot (quaternion xyzw), vel (xyz), time, ping
- Vehicle config includes: parts, paints, partConfigFilename, vars, mainPartName

### What BeamMP Doesn't Document

- The wire protocol format is not publicly documented
- Binary packet structure is internal to the C++ launcher/server
- No protocol versioning system is documented
- Authentication handshake details are opaque

**HighBeam advantage:** Fully documented, versioned protocol from day one.

---

## Known Limitations & Pain Points

### For Server Operators
1. **Auth key dependency** — Can't run a server without a key from keymaster
2. **Limited keys** — Free tier has limited keys; more require Patreon
3. **Centralized server list** — Private servers still need auth keys
4. **No LAN/offline support** — Internet required for auth
5. **VPN incompatibility** — Hamachi, RadminVPN etc. often don't work (UDP issues)
6. **IPv4 only** — No IPv6 support yet

### For Players
1. **Discord required** — Must have a Discord account to play (non-guest)
2. **Launcher required** — Separate binary must run alongside the game
3. **No direct mod integration** — Launcher injects the mod, can't just drop a zip in mods folder

### For Plugin Developers
1. **Lua 5.3 only** — No LuaJIT, limited performance
2. **No async I/O in Lua** — Network/file operations block the plugin
3. **Limited client API** — Only 3 functions available client-side
4. **Sleep warning** — `MP.Sleep` > 500ms can lock up the server

---

## What HighBeam Improves

| Limitation | HighBeam Solution |
|-----------|-------------------|
| Centralized auth | Server-local auth (open/password/allowlist) |
| Auth key requirement | No auth keys — servers are self-contained |
| Discord dependency | No account requirements |
| Launcher proxy | Direct game-to-server connection |
| Undocumented protocol | Fully documented, versioned protocol |
| C++ server | Rust server (memory safety, async) |
| Lua 5.3 server plugins | Lua 5.4 with broader API |
| Limited client API | Extended client extension API |
| Centralized server list | Optional community relay + direct connect |
| No LAN support | Full LAN/offline support |

---

## Compatibility Considerations

### Plugin API Compatibility

HighBeam's `HB.*` namespace is designed to be familiar to BeamMP plugin developers:

| BeamMP | HighBeam | Notes |
|--------|----------|-------|
| `MP.GetPlayers()` | `HB.GetPlayers()` | Same behavior |
| `MP.GetPlayerName(pid)` | `HB.GetPlayerName(pid)` | Same behavior |
| `MP.SendChatMessage(pid, msg)` | `HB.SendChatMessage(pid, msg)` | Same behavior |
| `MP.RegisterEvent(name, fn)` | `HB.RegisterEvent(name, fn)` | Same behavior |
| `MP.TriggerClientEvent(pid, e, d)` | `HB.TriggerClientEvent(pid, e, d)` | Same behavior |
| `MP.GetPlayerIdentifiers(pid)` | `HB.GetPlayerIdentifiers(pid)` | No `beammp` or `discord` fields |
| `MP.IsPlayerGuest(pid)` | N/A | No centralized guest concept |

### Resource Structure Compatibility

HighBeam mirrors BeamMP's `Resources/Client` and `Resources/Server` layout so server operators familiar with BeamMP can transition easily.

### Plugin System Differences

While both projects use a `Resources/Server/<PluginName>/` layout, HighBeam's plugin system differs from BeamMP's:

| Aspect | BeamMP | HighBeam |
|--------|--------|----------|
| Manifest | None — alphabetical .lua loading | `plugin.toml` with explicit entry point |
| Dependencies | Naming hacks (prefix with `A_`) | Declared in `plugin.toml` `depends` field |
| Load order | Alphabetical by filename | Topological sort from dependency graph |
| Lua version | 5.3 | 5.4 |
| API namespace | `MP.*` | `HB.*` |

---

## References

- BeamMP Server GitHub: https://github.com/BeamMP/BeamMP-Server
- BeamMP Launcher GitHub: https://github.com/BeamMP/BeamMP-Launcher
- BeamMP Client Mod GitHub: https://github.com/BeamMP/BeamMP
- BeamMP Docs: https://docs.beammp.com/
- Server Scripting Reference (v3.x): https://docs.beammp.com/scripting/server/latest-server-reference/
- Client Scripting Reference: https://docs.beammp.com/scripting/mod-reference/
- Server Installation Guide: https://docs.beammp.com/server/create-a-server/
- Server Maintenance Guide: https://docs.beammp.com/server/server-maintenance/
