# Sync Fix Plan - HighBeam

> Created: 2025-07-18
> Last updated: 2026-04-05
> Current version under test: v0.8.2-dev.12
> Status: Core fixes implemented in dev.11/dev.12; this document now tracks validation outcomes.

---

## Executive Summary

The previous Phase 2 conclusion that "P2 never received UDP for the entire session" was incorrect.

After deeper log review with your clarification:

1. Both players eventually had working UDP and could see each other's movement/rotation.
2. The "second truck" issue is real and has a clearer root cause:
   - the same local game vehicle is registered twice with the server,
   - creating two server vehicle IDs,
   - but only the newest server vehicle ID gets outgoing position updates,
   - leaving the older one as a static ghost truck.
3. The strange startup blackout is still real, but it is a separate issue from the ghost vehicle.

This plan has been rewritten to prioritize those realities.

---

## What The Logs Now Show

## Confirmed Facts

1. P1 receives world state with 2 vehicles and spawns both:
   - `Spawned remote vehicle: 3_7` in [/Users/josh/Downloads/p1.log](/Users/josh/Downloads/p1.log)
   - `Spawned remote vehicle: 3_6` in [/Users/josh/Downloads/p1.log](/Users/josh/Downloads/p1.log)
2. P1 later gets first UDP for only one of them:
   - `First UDP snapshot for remote vehicle 3_7` in [/Users/josh/Downloads/p1.log](/Users/josh/Downloads/p1.log)
   - no matching first snapshot for `3_6`
3. Symmetric behavior on P2:
   - spawned `4_8` and `4_9`
   - first UDP snapshot logged for `4_9` only
4. Both players eventually report `UDP bind confirmed` after long retries:
   - P1 confirms at retry 44
   - P2 confirms at retry 61
5. Server confirms duplicate server-side vehicle registrations and growth:
   - `vehicle_count=5` during first 2-player window
   - later `vehicle_count=6`
   - repeated `MaxCarsPerPlayer limit reached` warnings
   in [/Users/josh/Downloads/server.log](/Users/josh/Downloads/server.log)

## Core Duplicate-Mapping Evidence

P2 local mapping in [/Users/josh/Downloads/p2.log](/Users/josh/Downloads/p2.log):

- `Local vehicle spawned: gameVid=32775`
- `Re-registering local vehicle after reconnect: gameVid=32775`
- `Local vehicle mapped: game=32775 server=6 reqId=1`
- `Local vehicle mapped: game=32775 server=7 reqId=2`

P1 local mapping in [/Users/josh/Downloads/p1.log](/Users/josh/Downloads/p1.log):

- `Local vehicle spawned: gameVid=32777`
- `Re-registering local vehicle after reconnect: gameVid=32777`
- `Local vehicle mapped: game=32777 server=8 reqId=1`
- `Local vehicle mapped: game=32777 server=9 reqId=2`

This means one game vehicle got two server vehicles.

---

## Updated Root Cause Model

## RC-A (Critical): Duplicate local vehicle registration creates ghost vehicles

Files involved:
- [client/lua/ge/extensions/highbeam.lua](client/lua/ge/extensions/highbeam.lua)
- [client/lua/ge/extensions/highbeam/connection.lua](client/lua/ge/extensions/highbeam/connection.lua)
- [client/lua/ge/extensions/highbeam/state.lua](client/lua/ge/extensions/highbeam/state.lua)

Mechanism:

1. `onVehicleSpawned` in [client/lua/ge/extensions/highbeam.lua](client/lua/ge/extensions/highbeam.lua) immediately calls `state.requestSpawn(gameVehicleId, configData)`.
2. WorldState handling then calls `_reRegisterLocalVehicles()` in [client/lua/ge/extensions/highbeam/connection.lua](client/lua/ge/extensions/highbeam/connection.lua), which also calls `state.requestSpawn(...)` if `state.localVehicles[gameVid]` is still empty.
3. Spawn acks arrive for both requests.
4. `state.onLocalVehicleSpawned` in [client/lua/ge/extensions/highbeam/state.lua](client/lua/ge/extensions/highbeam/state.lua) overwrites:
   - `M.localVehicles[gameVid] = serverVehicleId`
   with the latest ID.
5. Old server vehicle remains alive server-side and on peers, but local sender now transmits only for the latest server vehicle ID.
6. Result: one moving truck + one static truck that never disappears.

Why this exactly matches your observation:
- P1 sees two trucks from P2 when P2 joins.
- One truck moves (the actively updated server vehicle ID).
- The other stays frozen (orphaned earlier server vehicle ID).

## RC-B (Major): Initial UDP blackout / delayed bind confirmation

Still real, but separate from ghosting.

- P1 bind confirm delayed to retry 44.
- P2 bind confirm delayed to retry 61.
- During this interval movement sync is absent or sparse.

After confirmation, movement and rotation sync works.

## RC-C (Major): Per-player UDP throttling causes stutter under load

In [server/src/net/udp.rs](server/src/net/udp.rs), relay throttle key is `player_id` not `(player_id, vehicle_id)`.

When a player has multiple vehicles, all share one relay budget, causing dropped updates and uneven per-vehicle smoothness.

---

## BeamNG Lifecycle Expectations (Why This Matters)

1. BeamNG can trigger vehicle spawn lifecycle hooks in cases beyond "new user intentionally spawned a new car" (loading, reconnect flow, internal recreate/reset patterns).
2. A multiplayer mod should treat local vehicle registration as idempotent per game vehicle ID.
3. If duplicate spawn confirmations occur for the same local game vehicle, superseded server vehicle IDs must be explicitly deleted.
4. Multiple vehicles per player can be valid in BeamNG-style multiplayer, but duplicate IDs for one game vehicle are not valid and will produce ghosts.

---

## Implemented Fix Plan

## P0 - Eliminate Ghost Truck Creation

### F1 - Single-flight spawn registration per local game vehicle

Files:
- [client/lua/ge/extensions/highbeam/state.lua](client/lua/ge/extensions/highbeam/state.lua)
- [client/lua/ge/extensions/highbeam/connection.lua](client/lua/ge/extensions/highbeam/connection.lua)
- [client/lua/ge/extensions/highbeam.lua](client/lua/ge/extensions/highbeam.lua)

Implemented:
1. Add `inflightByGameVid` map in state.
2. In `requestSpawn`, do not send another spawn for same `gameVid` while in flight.
3. In `_reRegisterLocalVehicles`, skip if already mapped OR in flight.
4. In `onVehicleSpawned`, skip if already mapped OR in flight.

Outcome:
- Stops reqId double-send pattern (`reqId=1`, `reqId=2` for same gameVid).

### F2 - Superseded mapping cleanup

File:
- [client/lua/ge/extensions/highbeam/state.lua](client/lua/ge/extensions/highbeam/state.lua)

Implemented:
1. In `onLocalVehicleSpawned`, if `gameVid` is already mapped to a different `serverVehicleId`, send `vehicle_delete` for old server ID.
2. Then update map to new server ID.

Outcome:
- Even if duplicate confirmations happen, old ghost server vehicle is actively deleted.

### F3 - Strong lifecycle diagnostics for mapping

Files:
- [client/lua/ge/extensions/highbeam/state.lua](client/lua/ge/extensions/highbeam/state.lua)
- [client/lua/ge/extensions/highbeam/connection.lua](client/lua/ge/extensions/highbeam/connection.lua)

Implemented:
1. Log every spawn request with gameVid + reqId + reason (`spawn_hook` vs `reregister`).
2. Log map transitions `gameVid -> serverVid` with old/new values.
3. Log explicit superseded delete packets.

Outcome:
- Future logs can prove dedupe behavior in one pass.

## P1 - Reduce Startup Blackout

### F4 - Make UDP bind confirmation explicit and faster

Files:
- [launcher/src/proxy.rs](launcher/src/proxy.rs)
- [server/src/net/udp.rs](server/src/net/udp.rs)
- [client/lua/ge/extensions/highbeam/connection.lua](client/lua/ge/extensions/highbeam/connection.lua)

Implemented:
1. Server sends lightweight UDP bind-ack packet on UdpBind (0x01) receive.
2. Client marks UDP bound on bind-ack, not only on first position packet.
3. Keep periodic bind retries until ack, then stop.

Outcome:
- Removes long blind window and makes bind state deterministic.

### F5 - Proxy keepalive diagnostics

File:
- [launcher/src/proxy.rs](launcher/src/proxy.rs)

Implemented:
1. Add periodic s2c/c2s counters and first-packet timestamps.
2. Optional low-rate keepalive from proxy server socket to maintain NAT mapping in hostile networks.

Outcome:
- Better WAN robustness and clearer triage when UDP is delayed.

## P2 - Improve Multi-vehicle Smoothness

### F6 - Per-vehicle rate limiting

File:
- [server/src/net/udp.rs](server/src/net/udp.rs)

Implemented:
- Change throttle key from `player_id` to `(player_id, vehicle_id)`.

Outcome:
- One vehicle no longer starves another.

### F7 - Client-side cap awareness for spawn attempts

Files:
- [client/lua/ge/extensions/highbeam/state.lua](client/lua/ge/extensions/highbeam/state.lua)
- [client/lua/ge/extensions/highbeam/connection.lua](client/lua/ge/extensions/highbeam/connection.lua)

Implemented:
- Respect `max_cars_per_player` client-side to avoid endless rejected spawn attempts and log spam.

Outcome:
- Cleaner session behavior and less server noise.

---

## Test Matrix For Next Validation Pass

1. Single join test:
   - P2 joins P1 once.
   - Expect exactly one moving truck per actual vehicle, no frozen duplicate.
2. Mapping audit:
   - Assert no duplicate `Local vehicle mapped` lines for same gameVid with different server IDs.
3. UDP bind latency:
   - Record retry counts to confirmation for both players.
4. Reconnect test:
   - P2 disconnect/reconnect.
   - Ensure old player vehicles are removed and no stale copies remain.
5. Multi-vehicle stress:
   - Spawn multiple vehicles intentionally and verify per-vehicle updates remain smooth.
6. Max cars behavior:
   - Confirm client suppresses excess spawn attempts once cap reached.

---

## Notes Replacing Prior Assumption

Retired assumption:
- "P2 had udpRx=0 for the full session"

Corrected conclusion:
- P2 experienced a long initial blackout, then confirmed UDP and received movement updates.
- The persistent second truck behavior is primarily caused by duplicate registration / stale server vehicle IDs, not continuous UDP receive failure.
