# Sync Fix Plan — v0.8.2-dev.6 → dev.9

> **Created:** 2025-07-18
> **Last updated:** 2026-04-05
> **Status:** Fixes F1–F7 implemented. F4 revised in dev.9 (see below).
> **Affected version:** v0.8.2-dev.5 → v0.8.2-dev.6 (initial), dev.8/dev.9 (vlua fixes)
> **Symptom:** "Rotation not updating, only locations syncing. Damage, rotation, wheel spinning — none of this is syncing."

---

## Root Cause Summary

Three root causes identified through deep code + log analysis:

| # | Root Cause | Impact | Severity |
|---|-----------|--------|----------|
| **RC1** | Remote vehicle never spawns on the joining player | Player 2 never sees Player 1's vehicle — all sync data (position, rotation, damage, electrics) is dropped because there's no target vehicle | **Critical** |
| **RC2** | Host player never receives inbound UDP (NAT hairpin) | Player 1 (host) never sees Player 2 move — `udpBound=false`, `udpRx=0` for the entire session despite 42+ UdpBind retries | **Critical** |
| **RC3** | Even if the vehicle existed, `setPositionRotation` may not apply rotation durably (physics override) | Rotation appears to "not sync" because the physics engine overwrites it the next tick | **Medium** |

**RC1 and RC2 together explain why "nothing syncs":** Neither player sees the other's vehicle.

---

## Detailed Analysis

### RC1: Remote Vehicle Never Spawns

**Evidence (Player 2 log):**

```
42.07182|I| Spawning deferred world vehicles count=1 reason=map_ready
42.07185|I| UDP bind confirmed
42.07194|W| updateRemote: no remote vehicle for key=1_1 (drops=1)
```

- `_flushPendingWorldVehicles("map_ready")` fires with `count=1` — the vehicle list is non-empty.
- `_spawnWorldVehicles(pending)` is called, but **no "Spawned remote vehicle" or "Remote spawn failed" log appears**.
- Only 3 ms between the flush log and the next UDP log — `core_vehicles.spawnNewVehicle` takes ~100–500 ms. It never ran.
- `updateRemote: no remote vehicle for key=1_1` accumulates to **2750+ drops** — the `remoteVehicles` entry was **never created**, meaning `spawnRemote()` was never called.

**Root cause hypothesis (ranked by likelihood):**

1. **`vehicles` upvalue is nil** — The `_spawnWorldVehicles` guard `if not vehicles or not vehiclesList then return end` exits silently. The `modMgr.initDB()` call at `t=42.07158` (24 ms before the flush) may cause the connection module to be re-executed, producing a **new** module table with `vehicles = nil`. The old module table (stored in `highbeam.lua`) still works, but if `modMgr.initDB()` somehow triggers a re-require of connection.lua, the new instance's `vehicles` is nil.

2. **`vehiclesList` iteration yields 0 elements** — If the JSON decode for the world_state packet produces a table with non-integer keys (e.g., key `"0"` instead of `1`), `ipairs()` returns nothing. `#pending` would still report 1 (Lua's `#` operator behavior with non-sequential keys is undefined).

3. **`spawnRemoteFromSnapshot` receives `nil` vehicle** — If the ipairs element is somehow falsy (shouldn't happen with valid JSON decode), the `if not vehicle then return end` guard exits silently.

**Action items → Fix F1 (deep diagnostic logging) and Fix F2 (guard removal + explicit logging).**

---

### RC2: Host Player Never Receives UDP (NAT Hairpin)

**Evidence (Player 1 log):**

```
Sync diag udpRx=0 udpBound=false udpBindRetries=42 udpRecvErr=timeout
```

This persists for the **entire session** (100+ seconds after Player 2 joins).

**The proxy chain for Player 1 (host):**

```
BeamNG game (127.0.0.1:ephemeral)
  → Launcher proxy local socket (127.0.0.1:54943)
    → Launcher proxy server_sock (0.0.0.0:RANDOM)
      → Router NAT (LAN → WAN → LAN hairpin)
        → Server (192.168.1.254:18860)
```

Player 1 connects to `highbeam.anomalousinteractive.com:18860` (public DNS). The launcher proxy resolves this to the **public IP** and binds `server_sock` to `0.0.0.0:RANDOM`. Outbound UDP goes through the router's NAT to reach the server — even though the server is on the **same LAN** (192.168.1.254).

When the server relays packets **back** to Player 1, the reply must traverse:

```
Server (192.168.1.254:18860)
  → Player 1's registered addr (PUBLIC_IP:NAT_MAPPED_PORT)
    → Router NAT hairpin (WAN → LAN loopback)
      → Proxy server_sock (192.168.1.254:RANDOM)
```

**Many consumer routers silently drop NAT hairpin (loopback) UDP.** TCP hairpin may work because the connection is already established, but UDP is connectionless and each inbound datagram must be independently NAT-translated back.

**Result:** The proxy's `server_sock` never receives inbound datagrams. The s2c thread logs `timeouts=` incrementing forever. The game's UDP socket never gets data. `udpBound=false` persists.

**Action items → Fix F3 (detect same-host/same-LAN and use loopback address).**

---

### RC3: Physics Override of `setPositionRotation`

Even after RC1 and RC2 are fixed, rotation may still appear "laggy" or "stuck" because:

- `setPositionRotation(x, y, z, rx, ry, rz, rw)` sets the **rigid body transform**, but BeamNG's soft-body physics immediately recomputes the orientation from wheel contact, suspension, and gravity.
- ~~Position survives because the velocity injection (`obj:setVelocity`) pushes the vehicle in the right direction.~~ **REVISED in dev.9:** `obj:setVelocity()` does NOT exist in BeamNG's vlua context — it was throwing FATAL LUA ERROR on every call. Velocity injection never actually worked. BeamMP uses per-node `obj:applyForceVector()` in a dedicated `velocityVE` extension.
- ~~Rotation has no equivalent angular velocity injection — the physics engine "fights" the set orientation.~~ **REVISED in dev.9:** `obj:setAngularVelocity()` also does not exist in vlua. The dev.6 fix that "zeroed" angular velocity was silently failing.
- Additionally, `setPositionRotation` operates on the chassis, but visual elements (wheels, steering) are driven by electrics/input state, not transform.

### RC4: Stale Rotation Source (discovered in dev.8 testing)

`veh:getRotation()` in the GE context returns the **SceneObject transform rotation**, which does NOT track physics orientation for soft-body vehicles. Log analysis showed `avgRot=0.00000` across all diagnostic windows — the quaternion was constant. The correct approach (used by BeamMP) is to poll from vlua: `quatFromDir(-vec3(obj:getDirectionVector()), vec3(obj:getDirectionVectorUp()))`.

**Fixed in dev.9** — rotation is now polled from vlua via `queueLuaCommand` → `queueGameEngineLua` callback.

### RC5: Non-existent vlua API calls (discovered in dev.8 testing)

Three vlua API calls used in the client do not exist in BeamNG's vehicle Lua:

| Bad Call | Error | Fix (dev.9) |
|----------|-------|-------------|
| `obj:setVelocity()` | FATAL LUA ERROR: attempt to call method 'setVelocity' (a nil value) | Removed. Use GE-side `setPositionRotation()` only. |
| `obj:setAngularVelocity()` | FATAL LUA ERROR: attempt to call method 'setAngularVelocity' (a nil value) | Removed. Future: per-node `obj:applyForceVector()`. |
| `beamstate.beamDeformed()` | FATAL LUA ERROR: attempt to call field 'beamDeformed' (a nil value) | Removed. `obj:setBeamLength()` handles deformation. |

**Action items → ~~Fix F4 (angular velocity injection)~~ SUPERSEDED — see revised F4 below.**

---

## Fix Plan

### F1: Deep Diagnostic Logging in Vehicle Spawn Path

**File:** `client/lua/ge/extensions/highbeam/connection.lua`
**File:** `client/lua/ge/extensions/highbeam/vehicles.lua`

Add explicit logging at every decision point so the next log capture pinpoints exactly where the chain breaks.

**connection.lua — `_spawnWorldVehicles`:**

```lua
local function _spawnWorldVehicles(vehiclesList)
  log('I', logTag, '_spawnWorldVehicles called: vehicles=' .. tostring(vehicles ~= nil)
    .. ' vehiclesList=' .. tostring(vehiclesList ~= nil)
    .. ' listLen=' .. tostring(vehiclesList and #vehiclesList or 'N/A')
    .. ' listType=' .. type(vehiclesList))
  if not vehicles then
    log('E', logTag, '_spawnWorldVehicles: ABORT — vehicles subsystem is nil!')
    return
  end
  if not vehiclesList then
    log('E', logTag, '_spawnWorldVehicles: ABORT — vehiclesList is nil!')
    return
  end
  local iterCount = 0
  for _, v in ipairs(vehiclesList) do
    iterCount = iterCount + 1
    log('I', logTag, '_spawnWorldVehicles: spawning item #' .. iterCount
      .. ' player_id=' .. tostring(v.player_id)
      .. ' vehicle_id=' .. tostring(v.vehicle_id)
      .. ' hasData=' .. tostring(v.data ~= nil)
      .. ' hasPos=' .. tostring(v.position ~= nil)
      .. ' hasFn=' .. tostring(vehicles.spawnRemoteFromSnapshot ~= nil))
    if vehicles.spawnRemoteFromSnapshot then
      vehicles.spawnRemoteFromSnapshot(v)
    else
      vehicles.spawnRemote(v.player_id, v.vehicle_id, v.data)
    end
  end
  if iterCount == 0 then
    log('W', logTag, '_spawnWorldVehicles: ipairs yielded 0 iterations!'
      .. ' Dumping keys:')
    for k, _ in pairs(vehiclesList) do
      log('W', logTag, '  key=' .. tostring(k) .. ' type=' .. type(k))
    end
  end
  log('I', logTag, '_spawnWorldVehicles: done, iterated ' .. iterCount .. ' vehicles')
end
```

**vehicles.lua — `spawnRemoteFromSnapshot`:**

```lua
M.spawnRemoteFromSnapshot = function(vehicle)
  log('I', logTag, 'spawnRemoteFromSnapshot called: vehicle=' .. tostring(vehicle ~= nil)
    .. ' type=' .. type(vehicle))
  if not vehicle then
    log('E', logTag, 'spawnRemoteFromSnapshot: vehicle is nil/false!')
    return
  end
  log('I', logTag, 'spawnRemoteFromSnapshot: player_id=' .. tostring(vehicle.player_id)
    .. ' vehicle_id=' .. tostring(vehicle.vehicle_id)
    .. ' data=' .. tostring(vehicle.data and string.sub(vehicle.data, 1, 80) or 'nil'))
  M.spawnRemote(vehicle.player_id, vehicle.vehicle_id, vehicle.data, {
    position = vehicle.position,
    rotation = vehicle.rotation,
    velocity = vehicle.velocity,
    snapshotTimeMs = vehicle.snapshot_time_ms,
  })
end
```

**vehicles.lua — `_spawnGameVehicle` (entry/exit):**

Add log at the top:
```lua
log('I', logTag, '_spawnGameVehicle: model=' .. tostring(spec.model) .. ' pos=' .. tostring(spec.pos and spec.pos[1]))
```

And after each pcall:
```lua
log('I', logTag, '_spawnGameVehicle: pcall ok=' .. tostring(ok) .. ' vehObj=' .. tostring(vehObj) .. ' type=' .. type(vehObj))
```

---

### F2: Make Spawn Guards Explicit and Loud

**File:** `client/lua/ge/extensions/highbeam/connection.lua`

Instead of silently returning when `vehicles` is nil, log an error. This is already addressed by the F1 logging above — the guard now logs `ABORT` messages. No additional code change needed beyond F1.

---

### F3: Detect Same-Host / Same-LAN and Bypass NAT Hairpin

**File:** `launcher/src/proxy.rs` (or `launcher/src/ipc.rs` where the proxy is started)

**Problem:** When the game server is on the same machine (or same LAN), the proxy routes UDP through the public-facing DNS name, causing NAT hairpin. Many routers drop hairpin UDP.

**Fix approach:**

In the launcher, when starting the proxy, check if the resolved server address is a **loopback** or **LAN** address:

```rust
fn resolve_effective_addr(remote_addr: &str) -> SocketAddr {
    let resolved: SocketAddr = remote_addr.to_socket_addrs()...;
    
    // If the server resolves to a LAN address (same subnet) or localhost,
    // use it directly. Otherwise, use the resolved address.
    // This avoids NAT hairpin for same-host or same-LAN scenarios.
    resolved
}
```

Additionally, for the **same-host** case: detect if the server is running on localhost by checking if the resolved IP matches any local interface. If so, connect the proxy's `server_sock` to `127.0.0.1:port` instead of the public IP. This completely avoids the router.

**Alternative simpler fix:** Always try `127.0.0.1:port` first for the UDP server_sock connection. If that fails (connection refused / timeout), fall back to the resolved address. This handles the common case where player hosts their own server.

**Simpler immediate fix:** In the Lua client, when detecting that the IPC state file shows the proxy server matches the local machine, connect UDP directly to `127.0.0.1:server_port` instead of going through the proxy. This is a client-side workaround that doesn't require launcher changes.

**Recommended approach:** Launcher-side — detect if resolved address is on a local interface and use `127.0.0.1` for the server_sock bind target.

---

### F4: Angular Velocity Injection for Rotation Sync

**Status:** ~~Original plan~~ → **REVISED in dev.9**

**Original plan (dev.6):** Inject angular velocity via `obj:setAngularVelocity(float3(0,0,0))` in vlua.

**What actually happened:**
- dev.6: Added `obj:setAngularVelocity(float3(0,0,0))` — **silently failed** (method doesn't exist in vlua, threw FATAL LUA ERROR caught by pcall)
- dev.8: Added `obj:setVelocity()` and `obj:setAngularVelocity()` with actual values — **same FATAL errors**, now confirmed in log analysis
- dev.9: **Removed all broken vlua velocity calls.** `_applyPosRot` now uses only GE-side `setPositionRotation()`.

**Current state (dev.9):**
```lua
local function _applyPosRot(rv, pos, rot)
  rv.gameVehicle:setPositionRotation(pos[1], pos[2], pos[3], rot[1], rot[2], rot[3], rot[4])
  rv._lastAppliedPos = pos
  rv._lastAppliedRot = rot
  -- NOTE: obj:setVelocity() and obj:setAngularVelocity() do not exist in
  -- BeamNG's vlua context.  BeamMP works around this with per-node
  -- obj:applyForceVector() in a dedicated velocityVE extension.
end
```

**Future improvement:** Implement a force-based velocity system using per-node `obj:applyForceVector()`, similar to BeamMP's `velocityVE.lua`. This computes per-node forces to achieve a target velocity/angular velocity without using non-existent methods.

**Also fixed in dev.9:**
- **Rotation source:** Replaced `veh:getRotation()` (stale SceneObject transform) with vlua-sourced `quatFromDir(-obj:getDirectionVector(), obj:getDirectionVectorUp())` polled via callback
- **beamDeformed:** Removed non-existent `beamstate.beamDeformed()` calls; `obj:setBeamLength()` alone handles deformation

---

### F5: Extended Server Log for Two-Player Phase

**Operational — no code change.**

The server log provided only covers the single-player phase (ends before Player 2 connects). We need a server log that covers the two-player period to verify:

- `relay_targets=1` (not 0) when both players are connected
- `udp_tx_packets > 0` showing actual relay traffic
- Player 2's UDP address is correctly registered

**Action:** On next test, ensure the server log captures the full session including both players connected. The server already logs relay diagnostics every 5s — we just need a longer capture.

---

### F6: Verify `setPositionRotation` Quaternion Convention

**File:** `client/lua/ge/extensions/highbeam/vehicles.lua`

**Status:** VERIFIED — no change needed.

The encoding chain is consistent:
- **Capture:** `{rot.x, rot.y, rot.z, rot.w}` → XYZW
- **UDP encode:** `rot[1], rot[2], rot[3], rot[4]` → XYZW
- **UDP decode:** `r1, r2, r3, r4` → XYZW
- **Apply:** `setPositionRotation(px, py, pz, rot[1], rot[2], rot[3], rot[4])` → XYZW

BeamNG's `setPositionRotation(x, y, z, rx, ry, rz, rw)` expects XYZW. ✅

---

### F7: Damage/Electrics/Wheel Sync

**Status:** These are CONSEQUENCES of RC1/RC2, not independent bugs.

- **Damage:** TCP `vehicle_damage` packets are sent and received (confirmed in Player 2 log: `vehicle_damage=1`). The handler calls `vehicles.applyDamage(...)`, which looks up `remoteVehicles[key]`. Since the remote vehicle was never spawned (RC1), the lookup returns nil and the damage is silently dropped.

- **Electrics:** Same pattern. `vehicle_electrics` packets arrive but can't be applied because the target vehicle doesn't exist.

- **Wheel spinning:** Wheel motion is driven by `input.event("steering", ...)` and `input.event("throttle", ...)` in the tick loop. This requires the remote vehicle to exist AND receive UDP snapshots with input data (0x11 packets). Both fail due to RC1/RC2.

**No separate fix needed.** Fixing RC1 and RC2 will unblock damage, electrics, and wheel sync.

---

## Implementation Order

| Priority | Fix | Effort | Status |
|----------|-----|--------|--------|
| **P0** | F1 — Deep diagnostic logging | Small | ✅ Done (dev.6) |
| **P0** | F3 — NAT hairpin bypass | Medium | ✅ Done (dev.6) |
| **P1** | F2 — Loud spawn guards | Included in F1 | ✅ Done (dev.6) |
| **P1** | F4 — Angular velocity injection | Small | ✅ Revised in dev.9 — removed broken vlua calls, GE-only for now |
| **P2** | F5 — Extended server log | Operational | ✅ Done (dev.8 testing) |
| **P2** | F6 — Quaternion convention | None | ✅ Already verified |
| **P2** | F7 — Damage/electrics/wheels | None | ✅ Unblocked by RC1/RC2 fixes |
| **NEW** | Vlua rotation source fix | Small | ✅ Done (dev.9) — `getRotation()` → vlua `quatFromDir` |
| **NEW** | beamDeformed removal | Small | ✅ Done (dev.9) — removed non-existent vlua call |

---

## Prior Pending Fixes (from v0.8.2-dev.4 Session)

The "Remove All Vehicles" Fatal Lua Error 6-fix plan is still pending:

1. Handle remote vehicles in `onVehicleDestroyed`
2. Nil-guard in `_applyPosRot`
3. Liveness revalidation in tick loop
4. Harden `resetRemote`/`applyDamage`/`applyElectrics`
5. Bulk-clear hook

These should be implemented alongside or shortly after the sync fixes above.

---

## Test Plan

After deploying F1+F3:

1. **Player 1 hosts, Player 2 joins** — Check Player 2's log for the detailed spawn path. The new logging will show exactly which guard or function call fails.
2. **Check Player 1's UDP** — With F3 (NAT hairpin fix), Player 1 should show `udpBound=true` and `udpRx > 0`.
3. **Capture full server log** from start to finish (both players connected).
4. **Test rotation** — After both players see each other's vehicles, verify rotation updates by driving in circles and observing the remote vehicle on the other screen.
5. **Test damage** — Crash Player 1's vehicle, verify Player 2 sees deformation.
6. **Test electrics** — Turn on headlights, verify the other player sees them.
