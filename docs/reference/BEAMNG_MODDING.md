# BeamNG.drive Modding Reference

> **Last verified:** 2026-03-29
> **Sources:** BeamNG Wiki, community modding guides
> **Purpose:** Reference for HighBeam client mod development within BeamNG.drive.

---

## Overview

BeamNG.drive uses a **Lua scripting engine** (LuaJIT) for game logic, extensions, UI apps, and mod scripting. HighBeam's client mod runs as a GE (Game Engine) extension within this system.

---

## Lua Runtime Contexts

BeamNG has multiple Lua virtual machines running simultaneously:

| Context | Abbreviation | Scope | Use |
|---------|-------------|-------|-----|
| Game Engine | GE | Global, one instance | Extensions, game-wide logic, UI |
| Vehicle | V | Per-vehicle instance | Vehicle physics, controls, damage |
| Gameplay | GPL | Game scenarios | Scenario logic, missions |

**HighBeam primarily runs in the GE context**, which has access to all vehicles, the game world, and UI systems.

---

## Extension System

### How Extensions Work

Extensions are Lua modules loaded by BeamNG's engine. They live in:

```
lua/ge/extensions/
```

An extension is a Lua module that returns a table `M` with hook functions:

```lua
local M = {}

M.onExtensionLoaded = function()
    -- Called when extension is loaded
end

M.onExtensionUnloaded = function()
    -- Called when extension is unloaded
end

M.onUpdate = function(dtReal, dtSim, dtRaw)
    -- Called every frame
    -- dtReal = real-time delta (seconds)
    -- dtSim = simulation-time delta (accounts for slowmo/pause)
    -- dtRaw = raw frame delta
end

return M
```

### Loading Extensions

Extensions are loaded via `modScript.lua` in the mod's scripts directory:

```lua
-- scripts/highbeam/modScript.lua
load('highbeam')
setExtensionUnloadMode('highbeam', 'manual')
```

- `load('name')` loads `lua/ge/extensions/name.lua`
- `setExtensionUnloadMode('name', 'manual')` prevents BeamNG from auto-unloading the extension

### Extension Communication

Extensions can call each other:

```lua
-- From any GE Lua context:
extensions.highbeam_someModule.someFunction()

-- Or use the hook system:
extensions.hook('onMyCustomEvent', arg1, arg2)
```

---

## Key GE Hooks

These are the engine hooks HighBeam's client extension will use:

### Frame/Lifecycle Hooks

| Hook | Frequency | Arguments | Use |
|------|-----------|-----------|-----|
| `onExtensionLoaded` | Once | (none) | Initialize subsystems |
| `onExtensionUnloaded` | Once | (none) | Cleanup, disconnect |
| `onUpdate` | Every frame | `dtReal, dtSim, dtRaw` | Network I/O, position updates |
| `onPreRender` | Every frame (before render) | `dtReal, dtSim, dtRaw` | Interpolation updates |
| `onWorldReadyState` | On world load | `state` (0-2) | Map change detection |
| `onClientStartMission` | On mission start | `levelPath` | Map loaded |
| `onClientEndMission` | On mission end | `levelPath` | Map unloaded |

### Vehicle Hooks

| Hook | Arguments | Use |
|------|-----------|-----|
| `onVehicleSpawned` | `vehicleId` | Detect local vehicle spawn |
| `onVehicleDestroyed` | `vehicleId` | Detect local vehicle removal |
| `onVehicleResetted` | `vehicleId` | Detect vehicle reset (R key) |
| `onVehicleSwitched` | `oldId, newId` | Track active vehicle |

### Input Hooks

| Hook | Arguments | Use |
|------|-----------|-----|
| `onChatMessage` | `message` | Intercept chat input |

---

## Vehicle API

### Getting Vehicle Data

```lua
-- Get all vehicles
local vehicles = getAllVehicles()  -- returns table of vehicle objects

-- Get specific vehicle by ID
local veh = be:getObjectByID(vehicleId)

-- Get active player vehicle
local playerVeh = be:getPlayerVehicle(0) -- 0 = player index

-- Vehicle position (vec3)
local pos = veh:getPosition()  -- returns vec3

-- Vehicle rotation (quaternion)
-- WARNING: veh:getRotation() returns the SceneObject transform rotation,
-- which is STALE for soft-body vehicles (does not track physics orientation).
-- For accurate physics rotation, poll from vlua instead:
--   quatFromDir(-vec3(obj:getDirectionVector()), vec3(obj:getDirectionVectorUp()))
local rot = veh:getRotation()  -- returns quat (STALE for soft-body vehicles!)

-- Vehicle velocity
local vel = veh:getVelocity()  -- returns vec3

-- Vehicle data table
local data = core_vehicle_manager.getVehicleData(vehicleId)
```

### Spawning Vehicles

```lua
-- Spawn a vehicle from config
local vehicleData = {
    model = "pickup",
    config = "vehicles/pickup/base.pc",
    pos = vec3(0, 0, 0),
    rot = quat(0, 0, 0, 1),
}
local newId = core_vehicles.spawnNewVehicle(vehicleData.model, vehicleData)
```

### Editing Vehicles

```lua
-- Apply a parts config to a vehicle
local veh = be:getObjectByID(vehicleId)
veh:setField('partConfig', '', 'vehicles/pickup/sport.pc')

-- Apply raw JSON config
core_vehicle_partmgmt.setPartsConfig(serializedConfig)
```

### Removing Vehicles

```lua
-- Remove a vehicle
core_vehicles.removeCurrent() -- removes active vehicle
-- or
be:getObjectByID(vehicleId):delete()
```

---

## Networking in Lua

BeamNG's Lua environment supports TCP sockets through LuaJIT's FFI or through the `socket` library if available:

### Socket Library

```lua
-- TCP connection
local socket = require("socket")
local tcp = socket.tcp()
tcp:settimeout(0) -- non-blocking
tcp:connect(host, port)

-- Send data
tcp:send(data)

-- Receive data
local data, err, partial = tcp:receive('*l') -- line mode
local data, err, partial = tcp:receive(numBytes) -- byte count
```

### UDP

```lua
local udp = socket.udp()
udp:settimeout(0) -- non-blocking
udp:setpeername(host, port)
udp:send(data)
local data = udp:receive()
```

**Note:** BeamNG uses LuaJIT which supports FFI. If the socket library is unavailable, raw socket access through FFI is possible but more complex.

---

## UI System

BeamNG has two UI approaches:

### HTML/JS UI Apps (CEF)

BeamNG uses Chromium Embedded Framework (CEF) for its UI. Mods can create UI apps:

```
ui/modules/apps/AppName/
├── app.html    # HTML layout
├── app.js      # JavaScript logic
└── app.css     # Styling
```

#### Lua ↔ JS Communication

```lua
-- Lua side: send data to UI
guihooks.trigger('HighBeamUpdate', {players = playerList})

-- Lua side: receive from UI
local function onHighBeamUIEvent(data)
    -- handle UI callback
end
```

```javascript
// JS side: receive from Lua
angular.module('beamng.apps')
.directive('highbeam', function() {
    return {
        template: '<div>...</div>',
        link: function(scope) {
            scope.$on('HighBeamUpdate', function(event, data) {
                scope.players = data.players;
                scope.$apply();
            });

            // Send to Lua
            bngApi.engineLua('extensions.highbeam.onUIEvent(' + JSON.stringify(data) + ')');
        }
    };
});
```

### IMGUI (Lua-side)

BeamNG also supports IMGUI for quick debug/dev UIs directly in Lua:

```lua
local im = ui_imgui

local function onUpdate()
    if im.Begin("HighBeam Debug") then
        im.Text("Connected: " .. tostring(isConnected))
        im.Text("Players: " .. playerCount)
        if im.Button("Disconnect") then
            disconnect()
        end
    end
    im.End()
end
```

---

## Mod Packaging

### Mod Structure

BeamNG mods are `.zip` files placed in the mods directory:

```
%LOCALAPPDATA%/BeamNG.drive/mods/
```

A mod zip can contain:

```
mymod.zip/
├── lua/ge/extensions/      # GE extensions
├── lua/vehicle/extensions/ # Vehicle extensions
├── scripts/mymod/          # Mod scripts
│   └── modScript.lua       # Mod loader
├── ui/modules/apps/        # UI apps
├── vehicles/               # Vehicle definitions
├── levels/                 # Maps/levels
└── art/                    # Textures, materials
```

### modScript.lua

The mod loader script that BeamNG executes when the mod is loaded:

```lua
-- Load GE extensions
load('highbeam')
setExtensionUnloadMode('highbeam', 'manual')

-- Load sub-extensions
load('highbeam/connection')
load('highbeam/vehicles')
load('highbeam/chat')
```

### Mod Info

Mods can include an `info.json` at the zip root:

```json
{
    "name": "HighBeam Multiplayer",
    "author": "HighBeam Team",
    "version": "0.1.0",
    "description": "Decentralized multiplayer for BeamNG.drive"
}
```

---

## Map System

### Map Paths

Maps are identified by their level path:

```
/levels/gridmap_v2/info.json
/levels/west_coast_usa/info.json
/levels/utah/info.json
```

### Vanilla Maps

| Path | Name |
|------|------|
| `/levels/gridmap_v2/info.json` | Grid Map V2 |
| `/levels/johnson_valley/info.json` | Johnson Valley |
| `/levels/automation_test_track/info.json` | Automation Test Track |
| `/levels/east_coast_usa/info.json` | East Coast USA |
| `/levels/hirochi_raceway/info.json` | Hirochi Raceway |
| `/levels/italy/info.json` | Italy |
| `/levels/jungle_rock_island/info.json` | Jungle Rock Island |
| `/levels/industrial/info.json` | Industrial |
| `/levels/small_island/info.json` | Small Island |
| `/levels/smallgrid/info.json` | Small Grid |
| `/levels/utah/info.json` | Utah |
| `/levels/west_coast_usa/info.json` | West Coast USA |
| `/levels/driver_training/info.json` | Driver Training |
| `/levels/derby/info.json` | Derby Arena |

### Getting Current Map

```lua
-- In GE Lua context:
local currentMap = getMissionFilename()
-- Returns something like "/levels/gridmap_v2/info.json"
```

---

## Useful GE APIs

| API | Description |
|-----|-------------|
| `be:getObjectByID(id)` | Get vehicle object by ID |
| `be:getPlayerVehicle(0)` | Get player's active vehicle |
| `getAllVehicles()` | Get all vehicle objects |
| `core_vehicles.spawnNewVehicle(model, opts)` | Spawn a vehicle |
| `core_vehicle_manager.getVehicleData(id)` | Get vehicle metadata |
| `core_vehicle_partmgmt.setPartsConfig(cfg)` | Set parts config |
| `getMissionFilename()` | Current map path |
| `guihooks.trigger(event, data)` | Send data to UI layer |
| `extensions.hook(name, ...)` | Call hook on all extensions |
| `vec3(x,y,z)` | Create 3D vector |
| `quat(x,y,z,w)` | Create quaternion |
| `serialize(table)` | Serialize Lua table to string |
| `deserialize(string)` | Deserialize string to Lua table |
| `jsonEncode(table)` | Encode table as JSON string |
| `jsonDecode(string)` | Decode JSON string to table |

---

## Vehicle Lua (vlua) vs GE Context

BeamNG has two separate Lua contexts for vehicles:

- **GE (Game Engine):** Global Lua VM where extensions run. Accesses vehicles as SceneObjects via `be:getObjectByID()`. Methods like `veh:getPosition()`, `veh:getVelocity()` work, but `veh:getRotation()` returns the **stale** SceneObject transform, not live physics orientation.
- **vlua (Vehicle Lua):** Per-vehicle Lua VM. Accessed from GE via `veh:queueLuaCommand(luaString)`. Has the `obj` global for per-node physics. Can send data back to GE via `obj:queueGameEngineLua(luaString)`.

### Correct vlua APIs (obj: methods)

| Method | Description |
|--------|-------------|
| `obj:getPosition()` | Vehicle center of mass position (vec3) |
| `obj:getVelocity()` | Vehicle velocity (float3) |
| `obj:getDirectionVector()` | Forward direction vector (float3, physics-accurate) |
| `obj:getDirectionVectorUp()` | Up direction vector (float3, physics-accurate) |
| `obj:getNodePosition(cid)` | Position of a specific node |
| `obj:getNodeMass(cid)` | Mass of a specific node |
| `obj:applyForceVector(cid, float3)` | Apply force to a node |
| `obj:setNodePosition(cid, float3)` | Set node position directly |
| `obj:breakBeam(cid)` | Break a beam by ID |
| `obj:setBeamLength(cid, length)` | Set beam rest length |
| `obj:beamIsBroken(cid)` | Check if beam is broken |
| `obj:getPhysicsFPS()` | Physics tick rate (typically 2000) |
| `obj:getID()` | Vehicle object ID |
| `obj:queueGameEngineLua(luaStr)` | Send data back to GE context |
| `obj:getPitchAngularVelocity()` | Pitch angular velocity (rad/s) |
| `obj:getRollAngularVelocity()` | Roll angular velocity (rad/s) |
| `obj:getYawAngularVelocity()` | Yaw angular velocity (rad/s) |

### NON-EXISTENT vlua methods (will throw FATAL LUA ERROR)

| Method | Notes |
|--------|-------|
| `obj:setVelocity()` | Does not exist. Use per-node `applyForceVector()` instead. |
| `obj:setAngularVelocity()` | Does not exist. Use per-node torque via `applyForceVector()`. |
| `beamstate.beamDeformed()` | Does not exist. Use `obj:setBeamLength()` instead. |

### Getting physics rotation from vlua

```lua
-- In vlua context: compute quaternion from direction vectors
local rot = quatFromDir(-vec3(obj:getDirectionVector()), vec3(obj:getDirectionVectorUp()))
-- Send back to GE:
obj:queueGameEngineLua("extensions.mymod.onRotation(" .. rot.x .. "," .. rot.y .. "," .. rot.z .. "," .. rot.w .. ")")
```

---

## Performance Considerations

- **Frame time budget:** `onUpdate` runs every frame. At 60 FPS, that's ~16.6 ms per frame total. HighBeam's per-frame work should stay under 1-2 ms.
- **Non-blocking sockets:** Always use `settimeout(0)` for network I/O to avoid stalling the game.
- **Batch updates:** Don't send position updates every frame. Cap at 20 Hz (every ~3 frames at 60 FPS).
- **LuaJIT FFI:** Available for performance-critical operations (binary packet encoding/decoding).
- **Avoid table churn:** Reuse tables for position/rotation data rather than allocating new ones every frame.

---

## References

- BeamNG Wiki: https://wiki.beamng.com/
- BeamNG Modding Documentation: https://documentation.beamng.com/
