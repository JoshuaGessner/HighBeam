# HighBeam Client Architecture

> **Last updated:** 2026-04-03
> **Applies to:** v0.8.0-dev.4
> **Parent doc:** [OVERVIEW.md](OVERVIEW.md)

---

## Overview

The HighBeam client is a BeamNG.drive mod written in Lua. It runs inside BeamNG's LuaJIT runtime as a GE (Game Engine) extension. The client handles:

- Connecting to a HighBeam server (TCP + UDP)
- Sending/receiving vehicle state (position, rotation, velocity, configuration)
- Spawning, updating, and removing remote player vehicles
- Chat, player list, and connection UI

> **Note:** Mod downloading and installation is handled by the **HighBeam Launcher** before the game starts. The client mod has no file I/O responsibilities for mod management. See [LAUNCHER.md](LAUNCHER.md) for the launcher architecture.

---

## Directory Structure

```
client/
├── lua/
│   └── ge/
│       └── extensions/
│           ├── highbeam.lua            # Main extension entry point
│           └── highbeam/
│               ├── browser.lua         # IMGUI server browser window (Direct Connect, Browse, Favorites, Recent)
│               ├── connection.lua      # TCP + UDP connection management, custom event API
│               ├── protocol.lua        # Packet encoding/decoding (UDP binary format)
│               ├── vehicles.lua        # Remote vehicle lifecycle
│               ├── state.lua           # Local state tracking
│               ├── chat.lua            # Chat message handling
│               ├── config.lua          # Client configuration
│               └── math.lua            # Interpolation helpers (lerp, slerp)
├── scripts/
│   ├── modScript.lua               # Root-level BeamNG mod bootstrap script
│   └── highbeam/
│       └── modScript.lua               # BeamNG mod loader script
└── ui/
    └── chat.html                       # Chat UI overlay
```

---

## BeamNG Extension Model

BeamNG uses a Lua extension system. Extensions are loaded via `modScript.lua` and registered as GE extensions under `lua/ge/extensions/`.

### modScript.lua
```lua
load('highbeam')
setExtensionUnloadMode('highbeam', 'manual')
```

### Main Extension (`highbeam.lua`)
The main entry point. Responsibilities:
- Load all subsystems via `_safeRequire` with pcall-guarded error handling
- Register a **More menu** entry (`core_quickAccess` API with dual-signature fallback) so players can reopen the server browser from the in-game quick-access menu without the GE console
- Expose `openBrowser()` for programmatic access (`extensions.highbeam.openBrowser()`)
- Wire `onUpdate`, `onVehicleSpawned`, `onVehicleDestroyed`, `onVehicleResetted` hooks to subsystems

### Key BeamNG Hooks

| Hook | Frequency | Use |
|------|-----------|-----|
| `onExtensionLoaded` | Once | Initialize connection subsystem |
| `onExtensionUnloaded` | Once | Disconnect, cleanup |
| `onUpdate(dt)` | Every frame | Process network, send position updates |
| `onVehicleSpawned(vid)` | On spawn | Notify server of new local vehicle |
| `onVehicleDestroyed(vid)` | On destroy | Notify server of vehicle removal |
| `onVehicleResetted(vid)` | On reset | Send updated position to server |

---

## Subsystem Design

### Connection Manager (`connection.lua`)
### Server Browser (`browser.lua`)

IMGUI-based server browser window. Renders inside the BeamNG GE context (no CEF or HTML overlay needed).

**Responsibilities:**
- Render a tabbed IMGUI window with four tabs: Direct Connect, Browse Servers, Favorites, Recent
- Auto-open on extension load when not connected; close on successful connect
- Fetch server list from relay URL via plain TCP HTTP GET; parse both `{ servers: [...] }` and bare array responses
- Send UDP 0x7A ping to each listed server for real-time latency (colour-coded: green ≤80 ms, yellow ≤150 ms, red >150 ms)
- Persist favorites to `userdata/highbeam/favorites.json` and recents to `userdata/highbeam/recents.json`
- Save/load relay URL, username, and last host/port via `config.save()` / `config.load()`

See [RELAY.md](RELAY.md) for the relay JSON API format and the full community server list architecture.

---

### Connection Manager (`connection.lua`)

Manages the TCP and UDP sockets to the server.

**Responsibilities:**
- Establish TCP connection on `connect(host, port)`
- Perform authentication handshake
- Bind UDP socket with session token
- Handle reconnection logic with exponential backoff
- Expose `send(channel, data)` and `receive()` interfaces
- Custom event transport: `onServerEvent(name, callback)` and `triggerServerEvent(name, payload)`
- Player tracking: maintains `_players` table from world_state/join/leave packets

**State Machine:**
```
DISCONNECTED → CONNECTING → AUTHENTICATING → CONNECTED → DISCONNECTING → DISCONNECTED
```

### Protocol Handler (`protocol.lua`)

Encodes/decodes packets according to the HighBeam protocol specification.

**Responsibilities:**
- Serialize outgoing packets (Lua tables → binary/JSON wire format)
- Deserialize incoming packets (wire format → Lua tables)
- Validate packet structure and version compatibility

### Vehicle Manager (`vehicles.lua`)

Manages the lifecycle of remote player vehicles in the game world.

**Responsibilities:**
- Spawn remote vehicles when server notifies of new vehicle
- Apply position/rotation/velocity updates to remote vehicles each frame
- Apply vehicle config edits (parts, paint, tuning)
- Remove remote vehicles on disconnect or server command
- Interpolate/extrapolate positions between UDP updates for smooth rendering

**Interpolation Strategy:**
- Buffer 2-3 position snapshots
- Lerp position and slerp rotation between snapshots
- Extrapolate forward using velocity when packets are late

### State Tracker (`state.lua`)

Tracks local game state relevant to multiplayer.

**Responsibilities:**
- Track local player's vehicles (IDs, configs, positions)
- Detect vehicle spawns, edits, resets, and deletions
- Rate-limit position updates (target: 20 Hz default, configurable)
- Diff vehicle configs to only send changes

### Chat Handler (`chat.lua`)

Handles multiplayer chat messaging.

**Responsibilities:**
- Send chat messages to server
- Receive and display chat messages from other players
- Handle system messages from server

---

## Configuration

Client config stored in BeamNG's mod settings:

```lua
-- Default client configuration
local defaults = {
    updateRate = 20,          -- Position updates per second (Hz) — 20Hz balances quality and bandwidth
    interpolation = true,     -- Enable position interpolation
    directConnectHost = "",   -- Last used direct connect address
    directConnectPort = 18860,-- Last used direct connect port (1886 = birth of the automobile)
    username = "",            -- Player display name
    showChat = true,          -- Show chat window
}
```

---

## Packaging

The client mod is distributed as a `.zip` file placed in BeamNG's mod directory:

```
highbeam.zip/
├── lua/ge/extensions/highbeam.lua
├── lua/ge/extensions/highbeam/
│   ├── connection.lua
│   ├── protocol.lua
│   ├── vehicles.lua
│   ├── state.lua
│   ├── chat.lua
│   ├── config.lua
│   └── math.lua
├── scripts/highbeam/modScript.lua
└── ui/chat.html
```

This zip is what gets committed under `client/` in the repo. The **HighBeam Launcher** installs it into `%LOCALAPPDATA%/BeamNG.drive/mods/` automatically.
