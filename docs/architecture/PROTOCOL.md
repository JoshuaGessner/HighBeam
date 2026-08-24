# HighBeam Network Protocol Specification

> **Last updated:** 2026-08-24
> **Protocol version:** 3
> **Applies to:** v0.8.2-dev.54
> **Parent doc:** [OVERVIEW.md](OVERVIEW.md)

---

## Overview

HighBeam uses a dual-channel protocol:

| Channel | Transport | Purpose |
|---------|-----------|---------|
| **Reliable** | TCP | Authentication, vehicle lifecycle, structural damage, component state, chat, plugin events |
| **Fast** | UDP | Position/rotation/velocity updates (high frequency) |

Both channels share the same server port (default `18860`).

> **Why 18860?** Karl Benz patented the first true automobile on January 29, **1886**. Port 18860 pays tribute to the birth of driving.

---

## Packet Format

### TCP Packets (Reliable Channel)

All TCP packets use a length-prefixed JSON format for simplicity and debuggability. Binary TCP encoding (MessagePack) is planned for v0.5.0.

UDP packets use a **compact binary format from day one** (no JSON overhead).

```
┌──────────────┬──────────────────────────────────┐
│  Length (4B)  │         JSON Payload             │
│  uint32 LE   │    (UTF-8, length bytes)         │
└──────────────┴──────────────────────────────────┘
```

- **Length**: 4-byte unsigned integer, little-endian. Size of the JSON payload in bytes.
- **Payload**: UTF-8 JSON object.

Every JSON payload has a `type` field:

```json
{
  "type": "packet_type",
  ...
}
```

### UDP Packets (Fast Channel)

UDP packets use a compact binary format for minimal overhead:

```
┌──────────────┬──────────────┬──────────────────────────────┐
│ Session (16B)│  Type (1B)   │       Payload (variable)     │
│  token hash  │  packet type │                              │
└──────────────┴──────────────┴──────────────────────────────┘
```

- **Session**: 16-byte truncated SHA-256 hash of session token (for authentication without full token exposure).
- **Type**: Single byte identifying the packet type.
- **Payload**: Type-specific binary data.

---

## Connection Flow

### 1. TCP Handshake

```
Client                                  Server
  │                                       │
  │──── TCP Connect ─────────────────────►│
  │                                       │
  │◄──── ServerHello ────────────────────│
  │      {type: "server_hello",           │
  │       version: 2,                     │
  │       name: "My Server",              │
  │       map: "/levels/gridmap_v2/...",  │
  │       players: 5,                     │
  │       max_players: 20,                │
  │       max_cars: 3}                    │
  │                                       │
  │──── AuthRequest ────────────────────►│
  │     {type: "auth_request",            │
  │      username: "Player1",             │
  │      password: "..." (optional)}      │
  │                                       │
  │◄──── AuthResponse ──────────────────│
  │      {type: "auth_response",          │
  │       success: true,                  │
  │       player_id: 3,                   │
  │       session_token: "abc123..."}     │
  │                                       │
  │  [Mods already synced by launcher]    │
  │                                       │
  │──── Ready ──────────────────────────►│
  │     {type: "ready"}                   │
  │                                       │
  │◄──── WorldState ────────────────────│
  │      {type: "world_state",            │
  │       players: [...],                 │
  │       vehicles: [...]}                │
```

### 2. UDP Binding

After TCP auth succeeds and client sends `Ready`:

```
Client                                  Server
  │                                       │
  │──── UdpBind (UDP) ─────────────────►│
  │     [16B session hash] [0x01]         │
  │                                       │
  │◄──── UdpAck (UDP) ─────────────────│
  │     [16B session hash] [0x02]         │
  │                                       │
  │  [UDP channel now active]             │
```

---

## Packet Types — TCP (Reliable)

### Server → Client

| Type | Description | Payload Fields |
|------|-------------|---------------|
| `server_hello` | Server identity and info | `version`, `name`, `map`, `players`, `max_players`, `max_cars` |
| `auth_response` | Auth result | `success`, `player_id`, `session_token`, `error` (if failed) |
| `world_state` | Full world snapshot on join | `players[]`, `vehicles[]` |
| `player_join` | Another player joined | `player_id`, `name` |
| `player_leave` | Another player left | `player_id` |
| `vehicle_spawn` | Remote vehicle spawned | `player_id`, `vehicle_id`, `data` (config JSON) |
| `vehicle_edit` | Remote vehicle edited | `player_id`, `vehicle_id`, `data` (config JSON) |
| `vehicle_delete` | Remote vehicle deleted | `player_id`, `vehicle_id` |
| `vehicle_reset` | Remote vehicle reset/order barrier | `player_id`, `vehicle_id`, `data` (pose, `motionEpoch`, `damageEpoch`) |
| `vehicle_damage` | Authoritative structural damage snapshot | `player_id`, `vehicle_id`, `data` (damage envelope JSON) |
| `vehicle_inputs` | Complete desired input state | `player_id`, `vehicle_id`, `data` (`l/s/t/b/p/c/k/g` state string) |
| `vehicle_electrics` | Safe visual/control electrics state | `player_id`, `vehicle_id`, `data` (JSON) |
| `vehicle_powertrain` | Powertrain/device state | `player_id`, `vehicle_id`, `data` (JSON) |
| `vehicle_coupling` | Coupler attach/detach state | source/target vehicle and node IDs, `coupled` |
| `chat_broadcast` | Chat message broadcast | `player_id`, `player_name`, `text` |
| `server_message` | System message | `text` |
| `trigger_client_event` | Custom plugin event sent to client | `name`, `payload` |
| `kick` | Player is being kicked | `reason` |
| `ping_pong` | Heartbeat probe/response | `seq` |
| `mod_list` | Mod manifest (launcher pre-sync, separate TCP port) | `mods[]` (each: `name`, `size`, `hash`) |

### Client → Server

| Type | Description | Payload Fields |
|------|-------------|---------------|
| `auth_request` | Authentication | `username`, `password` (optional) |
| `ready` | Client ready (mods pre-synced by launcher) | (none) |
| `vehicle_spawn` | Local vehicle spawned | `vehicle_id`, `data` (config JSON) |
| `vehicle_edit` | Local vehicle edited | `vehicle_id`, `data` (config JSON) |
| `vehicle_delete` | Local vehicle deleted | `vehicle_id` |
| `vehicle_reset` | Local vehicle reset/order barrier | `vehicle_id`, `data` (pose, `motionEpoch`, `damageEpoch`) |
| `vehicle_pose` | TCP fallback local pose update | `vehicle_id`, `data` (pose JSON) |
| `vehicle_damage` | Structural damage snapshot | `vehicle_id`, `data` (damage envelope JSON) |
| `vehicle_inputs` | Complete desired input state | `vehicle_id`, `data` (`l/s/t/b/p/c/k/g` state string) |
| `vehicle_electrics` | Safe visual/control electrics state | `vehicle_id`, `data` (JSON) |
| `vehicle_powertrain` | Powertrain/device state | `vehicle_id`, `data` (JSON) |
| `vehicle_coupling` | Coupler attach/detach state | source/target vehicle and node IDs, `coupled` |
| `chat_message` | Chat message | `text` |
| `trigger_server_event` | Custom plugin event sent to server | `name`, `payload` |
| `ping_pong` | Heartbeat response | `seq` |

---

## Packet Types — UDP (Fast)

### Position Update (Client → Server, Server → Client)

Type bytes: `0x10` for the legacy base pose, `0x11` for the legacy input-augmented
pose, and `0x12` for the protocol-v3 motion stream.

```
┌──────────────┬──────┬──────────┬────────────────┬────────────────┬────────────────┬──────┐
│ Session (16B)│ 0x10 │ vid (2B) │  pos (12B)     │  rot (16B)     │  vel (12B)     │ time │
│              │      │ uint16LE │ 3x float32 LE  │ 4x float32 LE  │ 3x float32 LE  │ (4B) │
└──────────────┴──────┴──────────┴────────────────┴────────────────┴────────────────┴──────┘
```

Total: 16 + 1 + 2 + 12 + 16 + 12 + 4 = **63 bytes per update**

The extended `0x11` packet appends compact steering, throttle, brake, gear, and handbrake fields (five 16-bit values). When angular velocity is available, three additional `f32` values are appended after the inputs.

The canonical protocol-v3 `0x12` packet always appends:

```
epoch:u32LE | sequence:u32LE | steeringLock:u16LE |
steer:i16 fixed | throttle:i16 fixed | brake:i16 fixed | gear:i16 fixed | handbrake:i16 fixed |
angularVelocity:3xf32LE
```

`epoch` identifies the sender/controller lifetime and is non-zero. `sequence`
is monotonic within that epoch. A receiver atomically clears interpolation,
prediction, and clock state when a newer epoch arrives, rejects duplicate or
older sequences, and retains timer-backward-jump detection only for legacy
packets. `steeringLock` is in degrees. Steering retains HighBeam's 450-degree
reference representation; the v3 steering fixed point covers ±8 so 900° and
1080° full-lock values are lossless at the protocol's input precision.

Exact client→server datagram sizes are validated by the server (other lengths are
dropped, not relayed):

| Type | Inputs | Angular velocity | Size |
|------|--------|------------------|------|
| `0x10` | no | no | 63 bytes |
| `0x10` | no | yes | 75 bytes |
| `0x11` | yes | no | 73 bytes |
| `0x11` | yes | yes | 85 bytes |
| `0x12` | yes + epoch/sequence/lock | yes | 95 bytes |

Receiving clients apply the `0x11`/`0x12` inputs (steering/throttle/brake/handbrake) to
remote vehicles for smoother animation; discrete gear changes are delivered over
the reliable TCP input channel rather than UDP.

When server relays to other clients, it prepends the player_id:

```
┌──────────────┬──────┬──────────┬──────────┬────────────────┬────────────────┬────────────────┬──────┐
│ Session (16B)│ 0x10 │ pid (2B) │ vid (2B) │  pos (12B)     │  rot (16B)     │  vel (12B)     │ time │
│              │      │ uint16LE │ uint16LE │ 3x float32 LE  │ 4x float32 LE  │ 3x float32 LE  │ (4B) │
└──────────────┴──────┴──────────┴──────────┴────────────────┴────────────────┴────────────────┴──────┘
```

The server inserts the two-byte player ID without rewriting the motion payload.
Relayed sizes are therefore client size + 2 bytes: **65/77**, **75/87**, and
**97 bytes** for the canonical `0x12` packet.

### Position Fields

| Field | Type | Description |
|-------|------|-------------|
| `pos` | 3x f32 | World position (x, y, z) |
| `rot` | 4x f32 | Rotation quaternion (x, y, z, w) |
| `vel` | 3x f32 | Linear velocity (x, y, z) |
| `time` | f32 | Simulation time since vehicle spawn |
| `epoch` | u32 | Non-zero vehicle/controller motion lifetime (`0x12`) |
| `sequence` | u32 | Monotonic packet order within the epoch (`0x12`) |
| `steeringLock` | u16 | Sender steering-wheel lock in degrees (`0x12`) |

### TCP Pose Fallback

Clients continue to send a reliable `vehicle_pose` packet while the UDP bind is pending or when the client cannot compute the 16-byte UDP session hash. The fallback payload mirrors the UDP pose fields as JSON:

```json
{
  "pos": [0.0, 0.0, 0.0],
  "rot": [0.0, 0.0, 0.0, 1.0],
  "vel": [0.0, 0.0, 0.0],
  "time": 0.0,
  "sampleDelta": 0.016,
  "motionEpoch": 3,
  "motionSequence": 42,
  "steeringLock": 1080,
  "inputs": {
    "steer": 0.0,
    "throttle": 0.0,
    "brake": 0.0,
    "gear": 0.0,
    "handbrake": 0.0
  },
  "angVel": [0.0, 0.0, 0.0]
}
```

The server validates vehicle ownership exactly as it does for other vehicle packets, then relays the pose to peers over the reliable channel. Once UDP is bound and the session hash is available, UDP remains the preferred high-frequency path.

### Structural Damage and Topology Barriers

Damage is a retained full structural snapshot, not transient node pose data:

```json
{
  "schemaVersion": 1,
  "epoch": 3,
  "revision": 12,
  "configRevision": 2,
  "state": {
    "broken": [14, 15],
    "breakGroups": ["bumper_F"],
    "deform": {"21": [0.034, 0.982]}
  }
}
```

- `epoch` changes on repair/reset and invalidates all older damage.
- `revision` is monotonic within an epoch; duplicates and older snapshots are ignored.
- `configRevision` binds beam IDs to a specific vehicle topology. Topology edits are accepted only in exact monotonic order and carry the new `damageEpoch`.
- `state.broken` and `state.deform` are applied incrementally and acknowledged by vehicle Lua. Transient node coordinates are rejected because replaying suspension/wheel travel would fight the remote vehicle's local physics.
- Reset payloads include `motionEpoch` and `damageEpoch`; duplicate delivery is
  idempotent and delayed poses/damage from the prior lifetimes are rejected.

Critical lifecycle packets (spawn, edit, delete, reset, damage, coupling, and player membership changes) use bounded reliable fanout. A peer that cannot accept one within the delivery window is disconnected so it cannot continue with permanently divergent world state. High-rate pose, inputs, electrics, and powertrain updates remain best-effort/coalesced state.

### Replaceable Component Snapshots

Electrics and powertrain packets carry complete desired state and may replace an
older queued value for the same vehicle. The server retains the newest validated
snapshot in `VehicleInfo.electrics` and `VehicleInfo.powertrain`, so late joiners
and rebuilt puppets start from the same state as existing peers.

Hydraulic-cylinder targets are a backward-compatible nested powertrain field:

```json
{
  "ignLevel": 2,
  "hydraulics": {
    "arm_left": 1.245,
    "bucket_tilt": 0.812
  }
}
```

Keys identify JBeam beam tags discovered from `v.data.powertrainHydros`; values
are finite target rest lengths. Receivers apply them with bounded
`obj:actuateBeam` calls. Transbrake is carried as an electrics scalar and is
applied through the vehicle's `transbrake` controller, including explicit zero.

---

## Launcher Mod Transfer Protocol

Mod transfers happen **before the game launches**, between the HighBeam Launcher and the server. This uses a dedicated TCP connection separate from the in-game protocol.

### Connection Flow

```
Launcher                                Server
  │                                       │
  │──── TCP Connect ─────────────────────►│
  │                                       │
  │◄──── ModList ────────────────────────│
  │      {type: "mod_list",               │
  │       mods: [                         │
  │         {name, size, hash}, ...       │
  │       ]}                              │
  │                                       │
  │──── ModRequest ──────────────────────►│
  │     {type: "mod_request",             │
  │      names: ["map.zip", "car.zip"]}   │
  │                                       │
  │◄──── Raw binary stream ──────────────│
  │      (per-file framing, see below)    │
  │                                       │
```

### Binary File Transfer Frame

For each requested mod, the server sends a binary frame followed by the raw file data:

```
┌───────────────────┬────────────────┬────────────────────────────┐
│  Name length (2B) │  Name (UTF-8)  │  File size (8B, u64 LE)    │
│  uint16 LE        │  variable      │                            │
├───────────────────┴────────────────┴────────────────────────────┤
│                  Raw file bytes (streamed)                       │
└─────────────────────────────────────────────────────────────────┘
```

- **No base64 or JSON encoding** — raw bytes, zero overhead
- The launcher writes directly to a temp file as data arrives (no memory buffering for large mods)
- After the full file is received, the launcher verifies the SHA-256 hash
- On hash mismatch, the file is discarded and the launcher reports an error
- Multiple files are sent sequentially in a single TCP stream

### Transfer Efficiency

| Approach | 500 MB map mod | Overhead |
|----------|---------------|----------|
| Base64-in-JSON (original plan) | ~665 MB on wire + JSON framing + Lua string allocation | ~33% |
| Raw binary TCP (current plan) | ~500 MB on wire + 10-byte header | ~0.002% |

---

## Bandwidth Estimation

The client send rate is **adaptive** (roughly 5–60 Hz depending on motion and
configuration), not a fixed 20 Hz. The server additionally throttles relays per
(player, vehicle) to its configured tick rate. Using 20 Hz purely as a worked
example:
- **Per vehicle sent**: 63 bytes × 20 = ~1.26 KB/s
- **Per vehicle received** (from server): 65 bytes × 20 = ~1.3 KB/s
- **20-player server, 1 car each**: each client sends 1.26 KB/s, receives 19 × 1.3 = ~24.7 KB/s
- **Total server bandwidth (20 players, 1 car)**: 20 × 19 × 1.3 = ~494 KB/s ≈ 3.95 Mbps

---

## Error Handling

### TCP Errors
- If a TCP connection drops, the server cleans up the session (removes vehicles, notifies others).
- Client should attempt reconnection with exponential backoff (max 30s).

### UDP Errors
- UDP packets from unknown session tokens are silently dropped.
- A UDP pose is only accepted and relayed if the sending player owns the vehicle
  it references; datagrams with an unexpected length for their type are dropped.
- Inbound poses are capped per (player, vehicle) to bound flooding.

### Liveness
Liveness is enforced over TCP, not UDP:
- The server pings each client over TCP roughly every 30 seconds and expects a pong.
- Vehicles whose pose has not updated for ~60 seconds are reaped (a `VehicleDelete`
  is broadcast), and idle TCP connections are closed after ~60 seconds.

### Trust Model
Like BeamMP, remote motion is **server-relayed and client-trusts-server**: the
server zeroes the session hash on relay and receiving clients do not authenticate
relayed poses. An attacker who can reach a client's UDP ip:port and guess a
`playerId`/`vehicleId` could inject fake remote motion. This is a known, accepted
limitation. Because the session token doubles as the UDP credential, running with
TLS disabled additionally exposes that token (and therefore the UDP session hash)
to on-path observers — enable TLS on untrusted networks.

### Protocol Version Mismatch
- The `server_hello` includes the protocol version.
- Protocol-v3 clients retain a legacy v1/v2 pose encoder for compatible older
  servers. Unsupported versions disconnect with an explicit error.

---

## Future Considerations

- **v0.7.0**: Binary TCP packet format (MessagePack) for vehicle spawn/edit/delete and other frequent packets
- **v0.7.0**: Delta compression for vehicle config updates
- **v0.7.0+**: Advanced UDP optimizations (priority accumulator, at-rest flags, jitter buffer, visual smoothing)
- **v1.0.0+**: Voice chat channel (UDP, Opus codec)
