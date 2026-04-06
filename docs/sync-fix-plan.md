# HighBeam Vehicle Sync: Root Cause Analysis & Fix Plan

> Researched 2026-04-06. Based on deep analysis of the HighBeam codebase and
> comparison with the BeamMP reference implementation.

---

## Executive Summary

Five critical bugs and three secondary issues collectively cause the reported symptoms:
vehicles not visibly moving, only updating position on reset, cars sticking inside each
other with no collision response, and damage not reflecting on remote clients. All fixes
use standard BeamNG.drive APIs and general game-networking techniques—no BeamMP code
is copied or adapted.

---

## CRITICAL BUG #1 — Remote Vehicles Don't Move (Only Update on Reset)

**Files:** `client/lua/ge/extensions/highbeam/vehicles.lua` (lines 114–123),  
`client/lua/vehicle/extensions/highbeam/highbeamPositionVE.lua` (lines 75–152)

### Root Cause — Dual-path conflict

HighBeam has two mutually exclusive paths for positioning remote vehicles:

**Path A — VE active (`rv._hasVE = true`):**  
GE interpolation is entirely skipped at line 1123–1124 (`goto skip_ge_interpolation`).
The VE force controller in `highbeamPositionVE.lua` uses a PD spring controller with
`posCorrectMul=5`, `posForceMul=5`. This produces an effective spring constant of 25,
with a natural frequency of ≈0.8 Hz. It takes 0.5–1.0 s to converge on each new target.
Since new targets arrive at 20–45 Hz, the vehicle is perpetually behind and appears
frozen/barely moving. The forces are also clamped at `maxPosForce=100 m/s²`, which
further limits responsiveness.

**Path B — VE not active (`rv._hasVE = false`):**  
`_applyPosRot()` (line 115) calls `veh:setPositionRotation()`, which hard-teleports the
vehicle **and resets its internal velocity to zero**. Since velocity is never set after
the teleport, the vehicle jumps between positions with no momentum, appearing jerky.
Between updates (50–200 ms gaps) the vehicle sits motionless.

**On reset:**  
`resetRemote()` (line 651) calls `setPositionRotation()` directly, which successfully
moves the vehicle. This is why reset is the only visible update.

### Fix — Replace both paths with cluster-based positioning

1. **In `highbeamPositionVE.lua`:** Replace the PD spring controller with a direct
   approach:
   - Use `obj:setClusterPosRelRot(refNodeId, px, py, pz, rx, ry, rz, rw)` to directly
     reposition the vehicle cluster to the interpolated/predicted target position each
     physics step. This API moves connected nodes together while preserving their
     relative positions and does **not** reset physics state.
   - After positioning, use `obj:applyClusterVelocityScaleAdd(refNodeId, 0, vx, vy, vz)`
     to set the correct velocity. A scale factor of `0` zeros existing velocity and then
     adds the target velocity vector.

2. **In `vehicles.lua`:** Remove the `_applyPosRot()` path that calls
   `setPositionRotation()` for continuous updates. Have the GE tick send interpolated
   targets to the VE via `queueLuaCommand` (as `updateRemote()` already does at line
   532), and let the VE handle all positioning.

3. **Keep `setPositionRotation()` ONLY for reset and initial spawn** (where a hard
   physics reset is intentional).

4. **In the GE tick (line 1121–1125):** When VE is active, still compute interpolation
   targets in GE (for time offset and snapshot management), but send them to the VE as
   targets instead of applying via `setPositionRotation()`. Remove the
   `goto skip_ge_interpolation` branch.

---

## CRITICAL BUG #2 — Cars Sticking Inside Each Other (No Collision Response)

**Files:** `vehicles.lua` (line 115), `highbeamPositionVE.lua`

### Root Cause

`setPositionRotation()` from the GE context overrides all physics responses including
collision separation. When two vehicles overlap:
1. Physics engine detects overlap and applies separation forces.
2. Next frame: `setPositionRotation()` teleports the remote vehicle back to the
   overlapping target position.
3. Physics engine re-separates, but the teleport fights back → vehicles oscillate inside
   each other.

### Fix — Velocity-relative correction with collision-aware thresholds

1. In the new VE controller, use a **prediction-correction** model instead of
   hard-setting position every physics frame:
   - Predict where the vehicle should be based on received velocity + elapsed time.
   - Measure position error between actual and predicted.
   - Apply corrective acceleration proportional to error, **clamped below collision
     separation forces** (≈5–15 m/s² for cars vs. physics collision forces of
     50–200+ m/s²).
   - When error is small (< ≈0.5 m), use acceleration corrections only — let physics
     handle collisions.
   - When error is large (> ≈1–3 m speed-dependent threshold), use
     `setClusterPosRelRot()` to hard-correct.

2. Add a **teleport delay timer** (similar to the existing one in
   `highbeamPositionVE.lua` lines 104–118, but tuned for BeamNG collision physics):
   - Only teleport if error exceeds threshold continuously for
     `> 0.3 s + 0.1 s × speed`.
   - Instant teleport only for very large errors (`> 1.0 m + 0.5 m × speed`).
   - This ensures physics has time to resolve collisions naturally before the sync
     system overrides.

3. **Separate connected and disconnected node groups** in `highbeamVelocityVE.lua`:
   - When applying velocity corrections, only apply to connected nodes (not detached
     parts).
   - Apply counter-forces to disconnected nodes to prevent them from flying off.
   - Track connectivity changes from `onBeamBroke`.

---

## CRITICAL BUG #3 — Damage Not Reflected / Constantly Resetting

**Files:** `state.lua` (lines 559–677), `vehicles.lua` (lines 679–774)

Three separate sub-issues contribute.

### 3a — Damage hash not cleared on reset (`state.lua` line 670)

When a vehicle resets, all beams return to their original state. The subsequent damage
poll produces empty or different JSON. If `_lastDamageHashes[gameVid]` still holds a
stale value from before the reset, the behavior after reset is inconsistent: new minor
damage may match stale hashes and be silently dropped, or the reset-to-undamaged state
is never forwarded.

**Fix:** Call `state.clearDamageHash(gameVid)` (expose this function from `state.lua`)
from `highbeam.lua::onVehicleResetted`, immediately after the reset packet is sent.

### 3b — Damage sync sends beam lengths but not node positions

HighBeam only syncs `{ broken: [beamIds], deform: { beamId: [deformation, restLength] } }`.
On receive, `obj:breakBeam(id)` and `obj:setBeamLength(id, restLen)` are called.
However, `setBeamLength()` only changes the beam's **rest length** — it does not move
the nodes. The physics engine relaxes toward the new rest length over time, but the
resulting visual deformation will not match the sender's actual deformed shape. BeamNG's
soft-body physics needs actual **node positions** to accurately reproduce damage.

**Fix:**
- **Sender (`state.lua::_pollDamage`):** In addition to beam breaks and deformations,
  collect `obj:getNodePosition(i)` for nodes connected to damaged beams. Only include
  nodes whose position differs from original by > 0.01 m (delta encode). Add a `"nodes"`
  field: `"nodes": { nodeId: [x, y, z], ... }`.
- **Receiver (`vehicles.lua::applyDamage`):** After breaking beams and setting beam
  lengths, call `obj:setNodePosition(nodeId, float3(x, y, z))` for each received node
  position. This directly moves the nodes to match the sender's deformed shape.
- Call `beamstate.beamDeformed(beamCid, deformation)` after `setBeamLength()` where the
  API is available to register deformation with the beamstate system.

### 3c — Only `onBeamBroke` triggers damage polling — misses deformation

Light collisions that deform beams without breaking them don't fire `onBeamBroke`, so
`M._damageDirty[gameVid]` is never set, and the 1-second damage poll at line 564 skips
these vehicles. The fallback poll runs every 8 seconds — far too slow.

**Fix:**
- Reduce fallback damage poll interval from 8 s to 1–2 s.
- In `highbeamDamageVE.lua`, add a lightweight deformation check in `updateGFX` that
  tests a small batch of beams (≈10 per call, round-robin) every ≈200 ms using
  `obj:getBeamDeformation(i)`. If deformation exceeds a threshold, call back to GE to
  mark the vehicle dirty.

---

## CRITICAL BUG #4 — Velocity Never Set on Remote Vehicles (GE Path)

**File:** `vehicles.lua` (lines 114–123)

### Root Cause

`_applyPosRot()` calls `setPositionRotation()` which resets all velocity to zero. The
comment at lines 118–122 explicitly acknowledges this:

> *"obj:setVelocity() and obj:setAngularVelocity() do not exist in BeamNG's vlua
> context … a force-based velocity system can be added later."*

Without velocity:
- Remote vehicles sit motionless between position updates (50–200 ms gaps).
- Vehicles cannot maintain momentum through collisions.
- Motion appears as teleportation rather than driving.

### Fix

Resolved by the Critical Bug #1 fix (move all positioning to VE with cluster-based
velocity setting). Additionally:
- `setTarget()` already receives target velocity (line 534–535 in `updateRemote()`).
- The VE should apply target velocity after positioning using
  `applyClusterVelocityScaleAdd(refNodeId, 0, vx, vy, vz)` — scale `0` zeros existing
  velocity then adds the target vector.

---

## CRITICAL BUG #5 — Rotation Error Correction Fights Angular Velocity

**File:** `highbeamPositionVE.lua` (lines 143–151)

### Root Cause

The angular velocity correction (lines 148–150) applies `targetAngVel × rScale × d`
where `d = dtSim`. But `addAngularVelocity` in the velocity module already multiplies by
`physicsFps` (line 143 in `highbeamVelocityVE.lua`). The effective angular acceleration
applied per step is therefore:

```
targetAngVel × rScale × dtSim × physicsFps = targetAngVel × rScale
```

The full target angular velocity is applied **as acceleration** every physics step,
causing the vehicle to spin increasingly fast.

Additionally, only angular velocity is set — **rotation error** (the quaternion
difference between current and target orientation) is never corrected. Orientation drifts
continuously.

### Fix

- Compute rotation error as the quaternion difference between current and target
  orientations, convert to an axis-angle angular velocity correction.
- Blend target angular velocity with the rotation error correction signal.
- Apply rotation using `setClusterPosRelRot()` (handles rotation directly) instead of
  accumulating forces.

---

## SECONDARY ISSUE #1 — Triple Quaternion Normalization

**Files:** `state.lua` (line 363), `protocol.lua` (lines 88–94, 186–191)

Quaternions are normalized three separate times: in `state.lua` before encoding, in
`protocol.lua` during encoding, and again during decoding. Each pass introduces
floating-point error (≈1 × 10⁻⁷). Accumulated over many frames, this causes orientation
drift.

**Fix:** Normalize once, at decode time only. Remove normalization from `state.lua`
line 363 and from `protocol.lua` lines 88–94 (encode path). Keep only the decode
normalization at lines 186–191.

---

## SECONDARY ISSUE #2 — Float16 Clips Large Angular Velocities

**File:** `protocol.lua` (lines 29–37)

`f32_to_f16()` scales by 16384 and clamps to `[-32768, 32767]`, giving a range of
approximately ±2.0 rad/s (≈114°/s). During fast spins (e.g., a vehicle tumbling after a
crash), angular velocities easily exceed 10 rad/s, saturating the encoding silently.

**Fix:** Use full `f32` (4 bytes) for angular velocity components, or change the scale
factor (e.g., 1024 → range ±32 rad/s). Since angular velocity is already optional in the
packet format, switching to `f32` is the cleanest approach and adds only 12 bytes per
packet.

---

## SECONDARY ISSUE #3 — Reset Debounce Drops Events

**File:** `highbeam.lua` (lines 283–295)

The 750 ms debounce silently drops reset events that occur within the window. If a player
presses reset twice quickly, the second reset is lost and clients become desynced.

**Fix:** Instead of dropping, record a `pendingReset` flag and the latest reset position
per vehicle. Send the queued reset after the debounce window expires, ensuring the final
reset position is always transmitted.

---

## Implementation Order (Priority)

| Priority | Bug | Rationale |
|---|---|---|
| 1 | Bug #1 + #4 (Position + Velocity) | Makes remote vehicles visibly move |
| 2 | Bug #2 (Collision) | Prevents embedding; partially fixed by #1 |
| 3 | Bug #3 (Damage) | Adds node positions, clears hash on reset, deformation polling |
| 4 | Bug #5 (Rotation) | Naturally solved by cluster-based approach from #1 |
| 5 | Secondary #1 #2 #3 | Cleanup: normalization, encoding, debounce |

---

## Specific File Changes

### `highbeamPositionVE.lua` — Rewrite `onPhysicsStep`

1. Compute predicted target position using received velocity + elapsed time.
2. Compute target rotation from received quaternion.
3. Use `obj:setClusterPosRelRot(refNodeId, ...)` to set position and rotation.
4. Use velocity module's `addVelocity()` / new `setVelocity()` to correct velocity
   toward target.
5. Retain speed-dependent teleport threshold with delay timer (tune thresholds for
   collision awareness).
6. Clamp corrective acceleration below estimated collision separation forces when error
   is small.

### `highbeamVelocityVE.lua` — Add `setVelocity` method

Add `setVelocity(vx, vy, vz)` using `applyClusterVelocityScaleAdd(refNodeId, 0, vx, vy, vz)`.
Keep existing `addVelocity` and `addAngularVelocity` for incremental corrections.

### `vehicles.lua` — Route all continuous positioning through VE

- Modify `_applyPosRot()` to dispatch to VE via `queueLuaCommand` instead of calling
  `setPositionRotation()`.
- Retain `setPositionRotation()` as fallback only for the brief window before VE
  bootstraps (`_hasVE = false`).
- In the interpolation tick, always compute interpolation targets and send them to VE.
- Remove `goto skip_ge_interpolation`; instead always compute and forward to VE.

### `vehicles.lua::applyDamage` — Add node position support

- Parse and apply `"nodes"` field from damage JSON using `obj:setNodePosition()`.
- Call `beamstate.beamDeformed()` after `setBeamLength()` where the API is available.

### `state.lua::_pollDamage` — Include node positions in damage data

- Collect `obj:getNodePosition(i)` for nodes connected to damaged beams.
- Add `"nodes": { nodeId: [x,y,z], ... }` to the damage JSON.
- Only include nodes displaced > 0.01 m from original.

### `state.lua` — Expose `clearDamageHash`

- Add `M.clearDamageHash = function(gameVid) _lastDamageHashes[gameVid] = nil end`.

### `highbeam.lua::onVehicleResetted` — Clear damage hash

- After sending the reset packet, call `state.clearDamageHash(gameVehicleId)`.
- Change debounce logic from drop-silently to queue-and-send-after-cooldown.

### `highbeamDamageVE.lua` — Add deformation polling

- In `updateGFX`, iterate over a rolling batch of ≈10 beams per call.
- If any beam's deformation exceeds a threshold, call back to GE to mark dirty.

### `protocol.lua` — Fix encoding

- Change angular velocity encoding from `f32_to_f16` to `write_f32_le`.
- Update decode to match.
- Remove redundant quaternion normalization from the encode path.

---

## Performance Considerations

- **Cluster operations** (`setClusterPosRelRot`, `applyClusterVelocityScaleAdd`) run at
  physics tick rate (≈2000 Hz) but are native C++ calls — minimal overhead.
- **Node position damage sync** only includes damaged nodes (typically 50–200 bytes), not
  all nodes (which can exceed 2 KB). Delta encoding keeps bandwidth manageable.
- **Deformation polling** uses round-robin batching (10 beams/call) to avoid frame
  spikes; full vehicle scan takes ≈10 frames at 60 FPS.
- **GE ↔ VE communication** uses `queueLuaCommand`, BeamNG's standard inter-context
  mechanism — already used throughout the codebase.

## Licensing

- All fixes use **standard BeamNG.drive Lua API functions** documented in BeamNG's
  modding API (`setClusterPosRelRot`, `applyClusterVelocityScaleAdd`, `getNodePosition`,
  `setNodePosition`, `applyForceVector`, etc.).
- The techniques used — cluster-relative positioning, velocity correction, node-based
  damage sync, PD control, delta encoding — are standard game-networking patterns
  documented in academic literature and GDC talks.
- No code is copied from BeamMP. All implementations must be written from scratch
  following these architectural patterns.
- The packet format remains HighBeam's own binary UDP protocol, distinct from BeamMP's
  text-based JSON protocol.
