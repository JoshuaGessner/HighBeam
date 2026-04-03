# HighBeam Network Protocol Specification

> **Last updated:** 2026-04-03
> **Protocol version:** 2
> **Applies to:** v0.8.0
> **Parent doc:** [OVERVIEW.md](OVERVIEW.md)

---

## Overview

HighBeam uses a dual-channel protocol:

| Channel | Transport | Purpose |
|---------|-----------|---------|
| **Reliable** | TCP | Authentication, vehicle spawn/edit/delete, chat, plugin events |
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
| `vehicle_reset` | Remote vehicle reset | `player_id`, `vehicle_id`, `data` (position JSON) |
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
| `vehicle_reset` | Local vehicle reset | `vehicle_id`, `data` (position JSON) |
| `chat_message` | Chat message | `text` |
| `trigger_server_event` | Custom plugin event sent to server | `name`, `payload` |
| `ping_pong` | Heartbeat response | `seq` |

---

## Packet Types — UDP (Fast)

### Position Update (Client → Server, Server → Client)

Type byte: `0x10`

```
┌──────────────┬──────┬──────────┬────────────────┬────────────────┬────────────────┬──────┐
│ Session (16B)│ 0x10 │ vid (2B) │  pos (12B)     │  rot (16B)     │  vel (12B)     │ time │
│              │      │ uint16LE │ 3x float32 LE  │ 4x float32 LE  │ 3x float32 LE  │ (4B) │
└──────────────┴──────┴──────────┴────────────────┴────────────────┴────────────────┴──────┘
```

Total: 16 + 1 + 2 + 12 + 16 + 12 + 4 = **63 bytes per update**

When server relays to other clients, it prepends the player_id:

```
┌──────────────┬──────┬──────────┬──────────┬────────────────┬────────────────┬────────────────┬──────┐
│ Session (16B)│ 0x10 │ pid (2B) │ vid (2B) │  pos (12B)     │  rot (16B)     │  vel (12B)     │ time │
│              │      │ uint16LE │ uint16LE │ 3x float32 LE  │ 4x float32 LE  │ 3x float32 LE  │ (4B) │
└──────────────┴──────┴──────────┴──────────┴────────────────┴────────────────┴────────────────┴──────┘
```

Total: 16 + 1 + 2 + 2 + 12 + 16 + 12 + 4 = **65 bytes per relayed update**

### Position Fields

| Field | Type | Description |
|-------|------|-------------|
| `pos` | 3x f32 | World position (x, y, z) |
| `rot` | 4x f32 | Rotation quaternion (x, y, z, w) |
| `vel` | 3x f32 | Linear velocity (x, y, z) |
| `time` | f32 | Simulation time since vehicle spawn |

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

At 20 Hz position updates:
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
- If no UDP packet received from a client for 10 seconds, server sends a TCP keepalive probe.
- If no response for 30 seconds, session is terminated.

### Protocol Version Mismatch
- The `server_hello` includes the protocol version.
- If client's protocol version does not match, client should disconnect and display an error.

---

## Future Considerations

- **v0.7.0**: Binary TCP packet format (MessagePack) for vehicle spawn/edit/delete and other frequent packets
- **v0.7.0**: Delta compression for vehicle config updates
- **v0.7.0+**: Advanced UDP optimizations (priority accumulator, at-rest flags, jitter buffer, visual smoothing)
- **v1.0.0+**: Voice chat channel (UDP, Opus codec)
