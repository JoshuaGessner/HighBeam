# Sync Optimization Plan — v0.8.2-dev.8

> **Created:** 2025-07-19 (from v0.8.2-dev.7)
> **Status:** Plan complete — awaiting approval before implementation
> **Goal:** Fix all visual sync artifacts (rotation, jitter, rewind, steering) and improve performance
> **Approach:** Incremental, non-breaking changes with debug instrumentation at each phase

---

## Current Architecture Summary

After deep-diving the full codebase, here's what we have:

| Component | File | Lines | Status |
|-----------|------|-------|--------|
| UDP protocol (binary) | `protocol.lua` | 180 | ✅ Solid — 0x10/0x11 formats, f16 inputs |
| Interpolation | `vehicles.lua` + `math.lua` | ~200 | ⚠️ Hermite spline exists but several issues |
| Position application | `vehicles.lua` `_applyPosRot` | ~30 | ⚠️ Missing angular velocity, physics fighting |
| Input sync | `state.lua` `_pollInputs` | ~20 | ⚠️ 100ms polling + vlua roundtrip adds latency |
| Delta gating | `vehicles.lua` `_shouldApplyPosRot` | ~15 | ✅ Reasonable thresholds |
| Damage sync | `state.lua` + `vehicles.lua` | ~80 | ⚠️ Full beam iteration every 1s — CPU heavy |
| Electrics sync | `state.lua` + `vehicles.lua` | ~40 | ✅ Delta-based, 500ms polling |
| Server UDP relay | `udp.rs` | 290 | ✅ Solid — tick_rate throttling, NaN rejection, LOD relay |
| Launcher proxy | `proxy.rs` | 400 | ✅ Solid — NAT hairpin detection, diagnostics |
| Overlay | `overlay.lua` | 270 | ⚠️ No debug metrics for sync |

---

## Issues Identified (Root Cause Analysis)

### Issue 1: Rotation appears wrong / vehicles sideways or upside down

**Root cause analysis:**

The quaternion pipeline is actually consistent end-to-end:
- **Capture:** `veh:getRotation()` → `{rot.x, rot.y, rot.z, rot.w}` → XYZW
- **Encode:** `protocol.encodePositionUpdate` → f32 × 4 in XYZW order
- **Decode:** `protocol.decodePositionUpdate` → `{r1, r2, r3, r4}` → XYZW  
- **Apply:** `setPositionRotation(px, py, pz, rot[1], rot[2], rot[3], rot[4])` → XYZW
- BeamNG's `setPositionRotation(x,y,z, rx,ry,rz,rw)` expects XYZW ✅

**However**, the quaternion is **never normalized** before sending or after interpolation. Small floating-point drift in the NLERP used by `slerpQuat` could accumulate, and if the physics engine receives a non-unit quaternion, behavior is undefined. More critically:

1. **`setPositionRotation` fights the physics engine.** The call sets the rigid-body transform, but BeamNG's soft-body physics immediately recomputes orientation from wheel contact, suspension, gravity, and the existing angular velocity. Position "sticks" because we inject linear velocity (`obj:setVelocity`), but **we zero angular velocity** which completely stops the vehicle's inherent rotation instead of matching the remote's angular velocity.

2. **The interpolation delay is too low (50ms default).** At 20 Hz update rate (50ms intervals), a 50ms interpolation buffer means we're always interpolating between the two most recent snapshots with almost no buffer. Any network jitter pushes us into extrapolation immediately.

3. **Nlerp instead of proper slerp.** The `slerpQuat` function actually does normalized linear interpolation (nlerp). This is fine for small angular differences but produces incorrect intermediate orientations for large rotations (>90°), which happens when vehicles are spinning or flipping.

**Fixes needed:** Proper quaternion normalization, angular velocity injection based on remote data, increased interpolation buffer, true slerp for large angular differences.

---

### Issue 2: Frame drops when multiple vehicles are active

**Root cause analysis:**

1. **Damage polling iterates ALL beams every 1 second.** Each call to `_pollDamage` injects a multi-line Lua string via `queueLuaCommand` that loops `obj:getBeamCount()` times (typically 2000-5000 beams). For N vehicles, this is N × 5000 iterations per second, all on the main thread in vlua context.

2. **No adaptive send rate.** Every local vehicle sends UDP at `updateRate` (default 20Hz) regardless of whether it's moving or stationary. A parked car generates the same traffic as one at full speed.

3. **Config polling every 2s.** `_pollConfigChange` calls `veh:getField('partConfig', '0')` which triggers a full JBeam tree serialization. This is expensive and blocks the main thread.

4. **JSON encoding in damage reports.** The vlua callback serializes the full damage state with `jsonEncode` which allocates a new string every time, even when nothing changed.

5. **`queueLuaCommand` string concatenation.** Multiple `queueLuaCommand` calls per frame build Lua strings via `..` concatenation with `tostring()`, which is O(N) string allocation per vehicle per frame.

6. **Interpolation runs every frame for every remote vehicle.** The `vehicles.tick()` function iterates all remote vehicles and does snapshot lookup + Hermite calculation + `setPositionRotation` every single frame. For 10 remote vehicles at 60 FPS, that's 600 transform-set calls per second plus the physics fighting overhead.

**Fixes needed:** Throttle damage polling cadence, adaptive send rate, cache expensive operations, batch queueLuaCommand calls, LOD-based update frequency for remote vehicles.

---

### Issue 3: Visual jitter and snapping

**Root cause analysis:**

1. **Interpolation timeline uses sender timestamps with EMA offset.** The `timeOffset` EMA (alpha=0.1) converges slowly. During the first ~30 packets, the offset is unstable, causing render time to oscillate between interpolation and extrapolation. This manifests as jitter during the first ~1.5 seconds after a vehicle appears.

2. **Snapshot buffer too small.** Default `jitterBufferSnapshots = 5` at 20Hz = 250ms of history. With 50ms interpolation delay, we only search the last 250ms of data. If one packet is late, the buffer has no older data to fall back on — it snaps to direct application.

3. **Extrapolation is straight-line only.** When packets are delayed, the vehicle extrapolates in a straight line using the last velocity. Any turning vehicle "straightens out" during packet gaps, then snaps to the correct position when the next packet arrives. This creates the classic "rubber-banding" artifact.

4. **No smoothing on correction.** When the interpolated position diverges from the server position (due to extrapolation), the code immediately teleports to the correct position. There's no blending/correction smoothing. The `_shouldApplyPosRot` delta gate helps avoid micro-teleports but doesn't help with macro corrections.

5. **`os.clock()` precision.** The interpolation uses `os.clock()` which may have coarse resolution on some platforms. Combined with the EMA offset, this introduces timeline noise.

**Fixes needed:** Higher snapshot buffer, increased interpolation delay, smooth correction blending, improved extrapolation using inputs, faster timeOffset convergence.

---

### Issue 4: False "rewind" artifacts (vehicles jumping backward)

**Root cause analysis:**

1. **Out-of-order rejection is timestamp-based only.** The `lastSeqTime` check in `updateRemote` compares `decoded.time` (sender's `os.clock()`). But `os.clock()` on the sender is not monotonic — it can wrap, drift, or reset. If the sender restarts or their clock adjusts, the receiver may reject all subsequent packets as "stale" until the sender's clock exceeds the stored `lastSeqTime`.

2. **Extrapolation overshoots then corrects backward.** When packets are delayed, the vehicle extrapolates forward. When the delayed packet arrives with a position behind the extrapolated position, the vehicle "rewinds" to the correct position. With no smoothing, this is a visible teleport backward.

3. **No sequence number in the UDP protocol.** The protocol relies entirely on sender timestamps for ordering. A proper monotonic sequence counter would be more reliable than timestamps.

**Fixes needed:** Add monotonic sequence counter to UDP packets, smooth correction instead of teleport, adaptive extrapolation limits.

---

### Issue 5: Steering and component sync incorrect

**Root cause analysis:**

1. **Input polling latency.** The current flow is: vlua electrics → `queueGameEngineLua` callback → `M._cachedInputs` → next UDP send. This is a minimum 2-frame roundtrip (one frame for the vlua command to execute, one frame for the GE callback). At 60 FPS, that's ~33ms of input latency before the data even enters the UDP pipeline.

2. **Steering input threshold too aggressive.** The `math.abs(newSteer - lastSteer) > 0.01` threshold skips small steering corrections. Real-world steering is continuous — a 0.01 threshold means micro-adjustments to keep a car straight are dropped, making remote vehicles drift in lanes.

3. **Steering applied via `input.event` which may not reach hydro actuators.** The comment in the code notes this. BeamNG's `input.event("steering", val, 1)` goes through the input filter pipeline, which may clamp, smooth, or remap the value. For remote vehicles, we want to set the steering angle directly, bypassing the filter.

4. **No gear/handbrake/parking brake sync.** The current input packet only carries steer/throttle/brake. Missing gear state means remote vehicles may appear to accelerate indefinitely or behave incorrectly in reverse.

**Fixes needed:** Direct steering application, lower input thresholds, add gear/handbrake to input packet, reduce input polling latency.

---

### Issue 6: Angular velocity causes physics fighting (from SYNC_FIX_PLAN.md F4)

**Current state:** The code zeroes angular velocity after every `setPositionRotation`:

```lua
rv.gameVehicle:queueLuaCommand('obj:setAngularVelocity(float3(0,0,0))')
```

This is **better than nothing** (prevents the physics engine from spinning the vehicle randomly) but it means:
- A vehicle mid-turn will visually "snap" to each new orientation instead of rotating smoothly
- The physics engine and the sync system are constantly fighting: we set a rotation, physics says "but the wheels are turned", and next frame it tries to rotate the body again

**Proper fix:** Compute angular velocity from the quaternion rate of change between snapshots and inject that, so the physics engine's simulation *agrees* with the sync trajectory.

---

## Fix Plan — Phased Approach

### Phase 0: Debug Instrumentation (no gameplay changes)

**Goal:** Add debug overlays and logging so we can see exactly what's happening in real-time during testing. No functional changes to sync behavior.

#### P0.1: Sync Debug Overlay

**File:** `client/lua/ge/extensions/highbeam/overlay.lua`

Add a collapsible "Debug" section to the existing ImGui overlay showing:

```
── Sync Debug ──────────────────────────────
Ping:           42 ms
UDP Rx Rate:    20 pkt/s
UDP Tx Rate:    20 pkt/s
Interp Delay:   50 ms
Buffer Depth:   3/5 snapshots
Extrapolating:  No

Per-Vehicle:
  1_1: pos_delta=0.02m rot_delta=0.001 interp_t=0.63 state=INTERP
  2_1: pos_delta=1.50m rot_delta=0.300 interp_t=1.20 state=EXTRAP
```

**Implementation:**
- Add counters to `vehicles.lua` tick loop: per-vehicle interpolation state, t value, delta magnitude
- Expose via `M.getDebugStats()` function
- Render in overlay when debug mode is enabled (`config.get("debugOverlay")`)

#### P0.2: Correction Magnitude Logging

**File:** `client/lua/ge/extensions/highbeam/vehicles.lua`

Add per-vehicle logging when correction exceeds thresholds:

```lua
-- In _applyPosRot, compute correction magnitude for debug
if rv._lastAppliedPos then
  local cx = pos[1] - rv._lastAppliedPos[1]
  local cy = pos[2] - rv._lastAppliedPos[2]
  local cz = pos[3] - rv._lastAppliedPos[3]
  local corrMag = math.sqrt(cx*cx + cy*cy + cz*cz)
  if corrMag > 0.5 then  -- Log corrections > 0.5m
    log('W', logTag, 'Large correction: ' .. key .. ' mag=' .. string.format('%.3f', corrMag) .. 'm')
  end
  rv._debugLastCorrectionMag = corrMag
end
```

#### P0.3: Packet Rate Counters

**File:** `client/lua/ge/extensions/highbeam/connection.lua`

Already has good diagnostics. Add:
- Per-second sliding window for UDP rx/tx rate (not just cumulative count)
- Track interpolation vs extrapolation ratio per 5s diagnostic window

---

### Phase 1: Fix Rotation & Physics Fighting (CRITICAL)

**Goal:** Make rotation visually correct and stop physics from fighting the sync system.

#### P1.1: Quaternion Normalization

**File:** `client/lua/ge/extensions/highbeam/protocol.lua`

Normalize quaternion before encoding:

```lua
-- In encodePositionUpdate, before writing rot values:
if rot then
  local len = math.sqrt(rot[1]*rot[1] + rot[2]*rot[2] + rot[3]*rot[3] + rot[4]*rot[4])
  if len > 0.0001 then
    rot = { rot[1]/len, rot[2]/len, rot[3]/len, rot[4]/len }
  end
end
```

**File:** `client/lua/ge/extensions/highbeam/math.lua`

The `slerpQuat` already normalizes. Add a standalone normalize function for use elsewhere.

#### P1.2: Angular Velocity from Quaternion Delta

**File:** `client/lua/ge/extensions/highbeam/vehicles.lua`

Instead of zeroing angular velocity, compute it from the rotation difference between interpolation endpoints:

```lua
-- Compute angular velocity from quaternion delta between s1 and s2
-- deltaQ = s2.rot * inverse(s1.rot)
-- angVel ≈ 2 * deltaQ.xyz / dt  (small angle approximation)
local function _computeAngularVelocity(rotA, rotB, dt)
  if dt < 0.0001 then return {0, 0, 0} end
  -- q_delta = rotB * conj(rotA)
  -- conj(q) = {-x, -y, -z, w}
  local ax, ay, az, aw = rotA[1], rotA[2], rotA[3], rotA[4]
  local bx, by, bz, bw = rotB[1], rotB[2], rotB[3], rotB[4]
  -- Hamilton product: rotB * conj(rotA)
  local caw = aw  -- conjugate a
  local cax, cay, caz = -ax, -ay, -az
  local dw = bw*caw - bx*cax - by*cay - bz*caz
  local dx = bw*cax + bx*caw + by*caz - bz*cay
  local dy = bw*cay - bx*caz + by*caw + bz*cax
  local dz = bw*caz + bx*cay - by*cax + bz*caw
  -- Ensure shortest path
  if dw < 0 then dx, dy, dz, dw = -dx, -dy, -dz, -dw end
  -- Small angle: angVel ≈ 2 * (dx, dy, dz) / dt
  return { 2*dx/dt, 2*dy/dt, 2*dz/dt }
end
```

Then in `_applyPosRot`:

```lua
if angVel then
  local avx, avy, avz = angVel[1] or 0, angVel[2] or 0, angVel[3] or 0
  local avMag = avx*avx + avy*avy + avz*avz
  if avMag > 0.0001 and avMag < 400 then  -- Sanity clamp (~20 rad/s max)
    pcall(function()
      rv.gameVehicle:queueLuaCommand(
        'obj:setAngularVelocity(float3(' .. tostring(avx) .. ',' .. tostring(avy) .. ',' .. tostring(avz) .. '))'
      )
    end)
  else
    pcall(function()
      rv.gameVehicle:queueLuaCommand('obj:setAngularVelocity(float3(0,0,0))')
    end)
  end
end
```

#### P1.3: True Slerp for Large Angles

**File:** `client/lua/ge/extensions/highbeam/math.lua`

Replace nlerp with proper slerp that falls back to nlerp for small angles:

```lua
M.slerpQuat = function(a, b, t)
  t = clamp01(t)
  local dot = a[1]*b[1] + a[2]*b[2] + a[3]*b[3] + a[4]*b[4]
  local b1, b2, b3, b4 = b[1], b[2], b[3], b[4]
  if dot < 0 then
    b1, b2, b3, b4 = -b1, -b2, -b3, -b4
    dot = -dot
  end
  
  -- For small angles (dot > 0.9995), use normalized lerp for stability
  if dot > 0.9995 then
    local r = {
      a[1] + (b1 - a[1]) * t,
      a[2] + (b2 - a[2]) * t,
      a[3] + (b3 - a[3]) * t,
      a[4] + (b4 - a[4]) * t,
    }
    local len = math.sqrt(r[1]*r[1] + r[2]*r[2] + r[3]*r[3] + r[4]*r[4])
    if len > 0.0001 then
      r[1], r[2], r[3], r[4] = r[1]/len, r[2]/len, r[3]/len, r[4]/len
    end
    return r
  end
  
  -- True spherical interpolation
  local theta = math.acos(math.min(1, math.max(-1, dot)))
  local sinTheta = math.sin(theta)
  if sinTheta < 0.0001 then
    -- Degenerate: just lerp
    return { a[1], a[2], a[3], a[4] }
  end
  local wa = math.sin((1 - t) * theta) / sinTheta
  local wb = math.sin(t * theta) / sinTheta
  return {
    wa * a[1] + wb * b1,
    wa * a[2] + wb * b2,
    wa * a[3] + wb * b3,
    wa * a[4] + wb * b4,
  }
end
```

**Risk:** Low — this is a drop-in replacement. The existing nlerp produces correct results for small angles. True slerp only kicks in for >~3° differences.

---

### Phase 2: Fix Jitter & Rewind (Interpolation Buffer Overhaul)

**Goal:** Eliminate jitter and rewind artifacts by implementing a proper interpolation buffer with smooth correction.

#### P2.1: Increase Default Interpolation Delay

**File:** `client/lua/ge/extensions/highbeam/config.lua`

```lua
M.defaults = {
  ...
  interpolationDelayMs = 100,  -- was 50; 100ms = 2 packets at 20Hz
  jitterBufferSnapshots = 8,    -- was 5; 8 snapshots = 400ms at 20Hz
  ...
}
```

**Rationale:** At 20Hz, each packet is 50ms apart. A 100ms buffer means we always have the current packet AND the next one for interpolation. The 50ms default was too tight — any jitter pushed us into extrapolation.

**Risk:** Adds 50ms of visual latency. For a driving game at normal speeds (30+ m/s), this is ~1.5m of visual delay — barely perceptible. Configurable via settings for players who want lower latency.

#### P2.2: Smooth Correction Blending

**File:** `client/lua/ge/extensions/highbeam/vehicles.lua`

Instead of teleporting to the interpolated position, blend toward it:

```lua
-- Per-vehicle correction state
rv._correctionPos = nil   -- Current correction offset {x, y, z}
rv._correctionRot = nil   -- Current correction quaternion offset

local function _blendedApply(rv, targetPos, targetRot, vel, angVel, dt)
  -- If no previous position, teleport directly
  if not rv._lastAppliedPos then
    _applyPosRot(rv, targetPos, targetRot, vel, angVel)
    return
  end
  
  local dx = targetPos[1] - rv._lastAppliedPos[1]
  local dy = targetPos[2] - rv._lastAppliedPos[2]
  local dz = targetPos[3] - rv._lastAppliedPos[3]
  local distSq = dx*dx + dy*dy + dz*dz
  
  -- Teleport threshold: 10m (100 sq) — something went very wrong, just teleport
  if distSq > 100 then
    _applyPosRot(rv, targetPos, targetRot, vel, angVel)
    return
  end
  
  -- Smooth correction: blend toward target position at rate proportional to error 
  -- This eliminates rewind artifacts and jitter from late packets
  local blendFactor = 0.15  -- 15% correction per frame (~60 FPS → ~90% corrected in 0.15s)
  if distSq < 0.01 then  -- <0.1m error: snap (it's close enough)
    _applyPosRot(rv, targetPos, targetRot, vel, angVel)
  else
    local blendedPos = {
      rv._lastAppliedPos[1] + dx * blendFactor,
      rv._lastAppliedPos[2] + dy * blendFactor,
      rv._lastAppliedPos[3] + dz * blendFactor,
    }
    -- Rotation: always use slerp target directly (rotation blending is harder to perceive)
    _applyPosRot(rv, blendedPos, targetRot, vel, angVel)
  end
end
```

**Risk:** Medium — this changes how all corrections are applied. The 0.15 blend factor and 10m teleport threshold need tuning. We'll add config knobs for these during Phase 0 debug instrumentation so we can tune in real-time.

#### P2.3: Improved Time Offset Convergence

**File:** `client/lua/ge/extensions/highbeam/vehicles.lua`

Replace the slow EMA with a faster convergence approach for the first N packets:

```lua
-- In updateRemote:
local recvTime = os.clock()
if decoded.time then
  local instantOffset = recvTime - decoded.time
  if not rv.timeOffset then
    rv.timeOffset = instantOffset
    rv._timeOffsetSamples = 1
  else
    -- Fast convergence for first 10 samples, then slow EMA
    rv._timeOffsetSamples = (rv._timeOffsetSamples or 0) + 1
    local alpha = rv._timeOffsetSamples < 10 and 0.3 or 0.05
    rv.timeOffset = rv.timeOffset + alpha * (instantOffset - rv.timeOffset)
  end
end
```

#### P2.4: Monotonic Sequence Counter (Protocol Enhancement)

**This requires a protocol change. Deferring to Phase 5 unless rewind issues persist after P2.2.**

Add a 2-byte monotonic sequence counter to the UDP packet, wrapping at 65535. Use this for out-of-order rejection instead of (or in addition to) timestamps.

---

### Phase 3: Reduce CPU Load & Improve Performance

**Goal:** Cut per-frame CPU cost for both sending and receiving sync data.

#### P3.1: Adaptive Send Rate

**File:** `client/lua/ge/extensions/highbeam/state.lua`

Reduce UDP send rate for slow/stationary vehicles:

```lua
-- In M.tick, before the send loop:
-- Compute per-vehicle speed and select appropriate send interval
local vel = veh:getVelocity()
local speed = math.sqrt(vel.x*vel.x + vel.y*vel.y + vel.z*vel.z)
local adaptiveInterval
if speed < 1.0 then
  adaptiveInterval = 1.0 / 10   -- 10 Hz for near-stationary
elseif speed < 10.0 then
  adaptiveInterval = 1.0 / 15   -- 15 Hz for slow
elseif speed < 30.0 then
  adaptiveInterval = 1.0 / 20   -- 20 Hz for medium (default)
else
  adaptiveInterval = 1.0 / 30   -- 30 Hz for fast
end
```

Track per-vehicle send timers instead of a global timer.

**Bandwidth savings:** Parked vehicles go from 20 pkt/s to 10 pkt/s. Fast vehicles get higher update rate. Net bandwidth is roughly neutral for two moving vehicles, significantly lower for sessions with idling vehicles.

#### P3.2: Throttle Damage Polling

**File:** `client/lua/ge/extensions/highbeam/state.lua`

Current: Full beam iteration every 1s, always.  
Proposed: Only poll damage when the vehicle has experienced a collision recently.

```lua
-- Track last collision time per vehicle (hook into onVehicleCollision)
-- Only poll damage within 5s of last collision
-- Reduce beam iteration cadence to 2s outside of active collision window
```

BeamNG fires `onBeamBroken` or similar events we could hook into instead of polling. Research whether `obj:onBeamBroken` callback exists — if so, we can switch to event-driven damage reporting.

#### P3.3: Batch queueLuaCommand Calls

**File:** `client/lua/ge/extensions/highbeam/vehicles.lua`

Current: Each vehicle gets separate `queueLuaCommand` calls for velocity, angular velocity, and inputs. These can be batched into a single string:

```lua
-- Instead of 3 separate queueLuaCommand calls:
rv.gameVehicle:queueLuaCommand(
  'obj:setVelocity(float3(' .. vx .. ',' .. vy .. ',' .. vz .. ')) '
  .. 'obj:setAngularVelocity(float3(' .. avx .. ',' .. avy .. ',' .. avz .. ')) '
  .. 'input.event("steering",' .. steer .. ',1) '
  .. 'input.event("throttle",' .. throttle .. ',1) '
  .. 'input.event("brake",' .. brake .. ',1)'
)
-- One call instead of up to 5
```

#### P3.4: LOD-Based Remote Vehicle Update Frequency

**File:** `client/lua/ge/extensions/highbeam/vehicles.lua`

For remote vehicles far from the camera, reduce interpolation update frequency:

```lua
-- Skip expensive interpolation for far-away vehicles
local camPos = _localPos()  -- from overlay code
if camPos and rv._lastAppliedPos then
  local dx = camPos[1] - rv._lastAppliedPos[1]
  local dy = camPos[2] - rv._lastAppliedPos[2]
  local dz = camPos[3] - rv._lastAppliedPos[3]
  local distSq = dx*dx + dy*dy + dz*dz
  if distSq > 250000 then  -- >500m: update at 5Hz
    rv._lodSkipCounter = (rv._lodSkipCounter or 0) + 1
    if rv._lodSkipCounter < 12 then goto continue end  -- ~60FPS/12 = 5Hz
    rv._lodSkipCounter = 0
  elseif distSq > 40000 then  -- >200m: update at 15Hz
    rv._lodSkipCounter = (rv._lodSkipCounter or 0) + 1
    if rv._lodSkipCounter < 4 then goto continue end
    rv._lodSkipCounter = 0
  end
  -- <200m: full framerate
end
```

---

### Phase 4: Fix Steering & Component Sync

**Goal:** Make steering, lights, and other visual components appear correct on remote vehicles.

#### P4.1: Direct Steering Application

**File:** `client/lua/ge/extensions/highbeam/vehicles.lua`

Replace `input.event("steering", ...)` with direct hydro input:

```lua
-- Try direct electrics value first (fastest path, no input filter)
rv.gameVehicle:queueLuaCommand(
  'electrics.values.steering_input = ' .. tostring(steer)
  .. ' electrics.values.steering = ' .. tostring(steer)
)
```

If this doesn't drive the visual wheel angle correctly, fall back to the hydro system:

```lua
-- Alternative: direct hydro command
rv.gameVehicle:queueLuaCommand(
  'hydros.set("steering", ' .. tostring(steer) .. ')'
)
```

Need to test both approaches. The current `input.event` goes through the input filter which adds its own smoothing — bad for remote vehicles where we want exact reproduction.

#### P4.2: Lower Input Thresholds

**File:** `client/lua/ge/extensions/highbeam/vehicles.lua`

Current threshold: `0.01` — too aggressive, drops micro-corrections.

```lua
-- Reduce threshold to 0.002 (effectively always applies changes)
if not lastSteer or math.abs(newSteer - lastSteer) > 0.002 then
```

#### P4.3: Add Gear/Handbrake to Input Packet

**Requires Protocol Version 3.** Defer to Phase 5.

For now, we can send gear/handbrake via existing TCP electrics polling with lower interval (250ms instead of 500ms) and add gear to the electrics state:

```lua
-- In _pollElectrics, add:
.. 's.gear = e.gear_M or 0 '
.. 's.parkingbrake = (e.parkingbrake and e.parkingbrake > 0.5) and 1 or 0 '
```

Receive side applies:
```lua
if elec.gear then
  veh:queueLuaCommand('controller.mainController.shiftToGearIndex(' .. tostring(elec.gear) .. ')')
end
if elec.parkingbrake ~= nil then
  veh:queueLuaCommand('input.event("parkingbrake", ' .. tostring(elec.parkingbrake) .. ', 1)')
end
```

---

### Phase 5: Protocol Enhancements (Future — requires protocol v3)

These changes require bumping `PROTOCOL_VERSION` to 3 and are not needed for the initial sync fix. Documenting them here for the roadmap.

#### P5.1: Sequence Counter in UDP

Add 2-byte wrapping sequence counter after the vehicle_id field. Total size: 0x10 → 65B, 0x11 → 73B (from 63/69).

#### P5.2: Angular Velocity in UDP Packet

Add 3×f16 angular velocity to the packet (6 bytes). This lets the receiver know the vehicle's actual angular velocity from the sender's physics engine, rather than computing it from quaternion deltas.

#### P5.3: Quantized Quaternion Compression

Current: 4×f32 = 16 bytes for quaternion.
Possible: "Smallest three" encoding = 1 bit (largest index) + 3×f16 = 7 bytes.
Savings: 9 bytes per packet × 20 Hz × N vehicles.

#### P5.4: Delta Compression for Position

Send full position on keyframes (every ~1s) and delta-compressed position on intermediate frames. Delta encoding with 16-bit fixed-point:
- Full: 12 bytes (3×f32)
- Delta: 6 bytes (3×f16, ±32m range at 0.001m precision)

---

## Implementation Priority & Dependency Order

```
Phase 0: Debug Instrumentation (P0.1, P0.2, P0.3)
   │  No functional changes. Safe to deploy immediately.
   │  Gives us real-time visibility into what's happening.
   ▼
Phase 1: Fix Rotation (P1.1, P1.2, P1.3)
   │  Fixes vehicles appearing sideways/upside down.
   │  P1.2 (angular velocity) is the biggest visual improvement.
   ▼
Phase 2: Fix Jitter & Rewind (P2.1, P2.2, P2.3)
   │  P2.1 is a config change — instant improvement.
   │  P2.2 (smooth correction) eliminates snap artifacts.
   │  P2.3 (time offset) fixes first-second jitter.
   ▼
Phase 3: Performance (P3.1, P3.2, P3.3, P3.4)
   │  Reduces CPU/bandwidth overhead.
   │  P3.1 (adaptive rate) and P3.3 (batching) are highest impact.
   ▼
Phase 4: Steering & Components (P4.1, P4.2, P4.3)
   │  Fixes visual components on remote vehicles.
   │  P4.1 and P4.2 are quick wins.
   ▼
Phase 5: Protocol v3 (Future)
   Not needed for v0.8.2 — roadmap items.
```

---

## Risk Assessment

| Change | Risk | Mitigation |
|--------|------|------------|
| P1.2: Angular velocity injection | Medium — could cause spinning if computed wrong | Magnitude clamp (20 rad/s), fallback to zero on NaN |
| P1.3: True slerp | Low — nlerp fallback for small angles | A/B testable via config flag |
| P2.1: Higher interp delay | Low — adds 50ms visual latency | Configurable, user can lower |
| P2.2: Smooth correction | Medium — changes how all positions applied | Teleport threshold at 10m, blend at 15%/frame |
| P3.1: Adaptive send rate | Low — only changes frequency, not data | Fall back to fixed rate if speed detection fails |
| P3.4: LOD skip | Low — only affects distant vehicles | Camera position fallback |
| P4.1: Direct steering | Medium — may not work on all vehicle types | Test with pickup, etk, bus; fall back to input.event |

---

## Files Modified (Summary)

| Phase | Files | Type of Change |
|-------|-------|----------------|
| P0 | `overlay.lua`, `vehicles.lua`, `connection.lua` | Debug logging/display only |
| P1 | `protocol.lua`, `math.lua`, `vehicles.lua` | Rotation handling |
| P2 | `config.lua`, `vehicles.lua` | Interpolation buffer & correction |
| P3 | `state.lua`, `vehicles.lua` | Performance optimization |
| P4 | `vehicles.lua`, `state.lua` | Input/steering handling |

**No server-side Rust changes required for Phases 0-4.**
**No launcher changes required for Phases 0-4.**
**No protocol version bump required for Phases 0-4.**

---

## Integration with SYNC_FIX_PLAN.md

The existing SYNC_FIX_PLAN.md addresses RC1 (remote vehicle never spawns) and RC2 (NAT hairpin). Those are **separate issues** from this optimization plan:

- **RC1** is about the vehicle not appearing at all — this plan assumes the vehicle exists and focuses on how it looks/moves
- **RC2** is about UDP not working at all for the host player — this plan assumes UDP is functional
- **RC3** (physics override of rotation) is directly addressed by **P1.2** in this plan

This plan and SYNC_FIX_PLAN.md are complementary. F1/F2/F3 from SYNC_FIX_PLAN should be implemented first (or in parallel) since they address hard blockers. This plan addresses the visual quality once sync data is actually flowing.

---

## Test Plan

After each phase:

1. **Two-player LAN test:** Player 1 drives, Player 2 observes. Check:
   - Vehicle orientation (not sideways/upside down)
   - Smooth motion (no jitter/snapping)
   - No rewind artifacts
   - Steering wheel matches driving direction
   - Headlights/signals visible

2. **Performance check:** Monitor with debug overlay:
   - Frame time should not exceed 16ms (60 FPS target)
   - UDP packet rate matches expected send rate
   - Interpolation state should show INTERP (not EXTRAP) >90% of the time

3. **Stress test:** Multiple vehicles (4+), mixed stationary and moving:
   - Frame rate should remain above 45 FPS
   - Stationary vehicles should have lower packet rate (P3.1)
   - Distant vehicles should update less frequently (P3.4)

4. **Collision test:** Ram vehicles together, check:
   - Damage appears on both clients within ~1s
   - No phantom physics artifacts from the sync system

---

## Estimated Config Additions

```lua
-- New config entries (all optional, with defaults)
debugOverlay = false,           -- P0: Show sync debug panel
correctionBlendFactor = 0.15,   -- P2: How fast to correct position errors
correctionTeleportDist = 10.0,  -- P2: Distance threshold for instant teleport
adaptiveSendRate = true,        -- P3: Enable speed-based send rate
lodDistanceNear = 200,          -- P3: Full-rate update distance
lodDistanceFar = 500,           -- P3: Reduced-rate update distance
directSteering = true,          -- P4: Use direct electrics instead of input.event
```
