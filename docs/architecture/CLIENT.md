# HighBeam Client Architecture

> **Last updated:** 2026-03-29
> **Applies to:** v0.1.0 (pre-alpha)
> **Parent doc:** [OVERVIEW.md](OVERVIEW.md)

---

## Overview

The HighBeam client is a BeamNG.drive mod written in Lua. It runs inside BeamNG's LuaJIT runtime as a GE (Game Engine) extension. The client handles:

- Connecting to a HighBeam server (TCP + UDP)
- Sending/receiving vehicle state (position, rotation, velocity, configuration)
- Spawning, updating, and removing remote player vehicles
- Chat, player list, and connection UI
- Downloading server-required mods

---

## Directory Structure

```
client/
├── lua/
│   └── ge/
│       └── extensions/
│           ├── highbeam.lua            # Main extension entry point
│           ├── highbeam/
│           │   ├── connection.lua      # TCP + UDP connection management
│           │   ├── protocol.lua        # Packet encoding/decoding
│           │   ├── vehicles.lua        # Remote vehicle lifecycle
│           │   ├── state.lua           # Local state tracking
│           │   ├── chat.lua            # Chat message handling
│           │   └── config.lua          # Client configuration
│           └── lib/
│               └── (shared utilities)
├── scripts/
│   └── highbeam/
│       └── modScript.lua               # BeamNG mod loader script
└── ui/
    └── modules/
        └── apps/
            └── HighBeam/
                ├── app.html            # Server browser / connection UI
                ├── app.js              # UI logic
                └── app.css             # UI styling
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
```lua
local M = {}

-- Called by BeamNG when extension loads
M.onExtensionLoaded = function()
    -- Initialize subsystems
end

-- Called by BeamNG when extension unloads
M.onExtensionUnloaded = function()
    -- Clean disconnect, teardown
end

-- Called every frame by BeamNG
M.onUpdate = function(dtReal, dtSim, dtRaw)
    -- Process incoming packets, send position updates
end

return M
```

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

Manages the TCP and UDP sockets to the server.

**Responsibilities:**
- Establish TCP connection on `connect(host, port)`
- Perform authentication handshake
- Bind UDP socket with session token
- Handle reconnection logic
- Expose `send(channel, data)` and `receive()` interfaces

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
│   └── config.lua
├── scripts/highbeam/modScript.lua
└── ui/modules/apps/HighBeam/
    ├── app.html
    ├── app.js
    └── app.css
```

This zip is what gets committed under `client/` in the repo and can be installed by dropping into `%APPDATA%/Local/BeamNG.drive/mods/` or served by a HighBeam server.
