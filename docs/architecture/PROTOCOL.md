# HighBeam Network Protocol Specification

> **Last updated:** 2026-03-29
> **Protocol version:** 1
> **Applies to:** v0.1.0 (pre-alpha)
> **Parent doc:** [OVERVIEW.md](OVERVIEW.md)

---

## Overview

HighBeam uses a dual-channel protocol:

| Channel | Transport | Purpose |
|---------|-----------|---------|
| **Reliable** | TCP | Authentication, vehicle spawn/edit/delete, chat, plugin events, mod sync |
| **Fast** | UDP | Position/rotation/velocity updates (high frequency) |

Both channels share the same server port (default `18860`).

> **Why 18860?** Karl Benz patented the first true automobile on January 29, **1886**. Port 18860 pays tribute to the birth of driving.

---

## Packet Format

### TCP Packets (Reliable Channel)

All TCP packets use a length-prefixed JSON format for simplicity and debuggability in early versions. Binary optimization is planned for v0.3.0+.

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
  "version": 1,
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
  │       version: 1,                     │
  │       name: "My Server",              │
  │       map: "/levels/gridmap_v2/...",  │
  │       players: 5,                     │
  │       max_players: 20,                │
  │       mods_required: [...]}           │
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
  │  [If mods_required, download mods]    │
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
| `server_hello` | Server identity and info | `version`, `name`, `map`, `players`, `max_players`, `max_cars`, `mods_required[]` |
| `auth_response` | Auth result | `success`, `player_id`, `session_token`, `error` (if failed) |
| `world_state` | Full world snapshot on join | `players[]`, `vehicles[]` |
| `player_join` | Another player joined | `player_id`, `name` |
| `player_leave` | Another player left | `player_id` |
| `vehicle_spawn` | Remote vehicle spawned | `player_id`, `vehicle_id`, `data` (config JSON) |
| `vehicle_edit` | Remote vehicle edited | `player_id`, `vehicle_id`, `data` (config JSON) |
| `vehicle_delete` | Remote vehicle deleted | `player_id`, `vehicle_id` |
| `vehicle_reset` | Remote vehicle reset | `player_id`, `vehicle_id`, `data` (position JSON) |
| `chat_message` | Chat message | `player_id`, `name`, `message` |
| `server_message` | System message | `message` |
| `plugin_event` | Custom plugin event | `event`, `data` |
| `kick` | Player is being kicked | `reason` |
| `mod_info` | Mod download info | `name`, `size`, `hash` |
| `mod_data` | Mod file chunk | `name`, `offset`, `data` (base64) |

### Client → Server

| Type | Description | Payload Fields |
|------|-------------|---------------|
| `auth_request` | Authentication | `username`, `password` (optional) |
| `ready` | Client ready after mod sync | (none) |
| `vehicle_spawn` | Local vehicle spawned | `vehicle_id`, `data` (config JSON) |
| `vehicle_edit` | Local vehicle edited | `vehicle_id`, `data` (config JSON) |
| `vehicle_delete` | Local vehicle deleted | `vehicle_id` |
| `vehicle_reset` | Local vehicle reset | `vehicle_id`, `data` (position JSON) |
| `chat_message` | Chat message | `message` |
| `plugin_event` | Custom plugin event | `event`, `data` |

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

- **v0.3.0+**: Optional TLS for TCP channel
- **v0.3.0+**: Binary TCP packet format (MessagePack or custom) for reduced overhead
- **v0.4.0+**: Delta compression for vehicle config updates
- **v0.5.0+**: Voice chat channel (UDP, Opus codec)
