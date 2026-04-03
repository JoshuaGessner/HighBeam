# HighBeam Community Relay — Server List Architecture

> **Last updated:** 2026-04-03
> **Applies to:** v0.8.0-dev.4
> **Parent doc:** [OVERVIEW.md](OVERVIEW.md)

---

## Overview

HighBeam's community server list is a **fully decentralized, opt-in relay system**. There is no central HighBeam-operated service that servers must register with. Instead, any community member can run a relay — a simple HTTP service that aggregates server announcements and exposes a server list that players can browse from inside the game.

```
┌──────────────────────────────────────────────────────────────────────┐
│  HighBeam Server (opt-in)                                            │
│    discovery_relay.rs — periodic HTTP POST every 30 s ──────────────┼──► Community Relay
└──────────────────────────────────────────────────────────────────────┘         │
                                                                                  │ HTTP GET /servers
┌──────────────────────────────────────────────────────────────────────┐         │
│  BeamNG.drive (in-game client)                                       │ ◄────────┘
│    browser.lua — "Browse Servers" tab fetches relay, pings servers   │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│  HighBeam Launcher (CLI)                                             │
│    discovery.rs — --browse-relay <URL> prints the relay list         │
└──────────────────────────────────────────────────────────────────────┘
```

Key design choices:

- **No central authority.** HighBeam itself does not run or endorse any relay. Multiple independent relays can exist, run by different community members.
- **Opt-in only.** Servers never appear in any public list unless the operator explicitly enables relay registration in `ServerConfig.toml`.
- **Open relay API.** The relay protocol is a simple JSON-over-HTTP contract that anyone can implement. The relay is stateless from the server's perspective — it is just a POST endpoint that stores entries and a GET endpoint that returns them.
- **No relay dependency for play.** Players can always use Direct Connect without involving any relay.

---

## How It Works — End to End

### 1. Server Registration (server → relay)

When `EnableRelay = true` in `ServerConfig.toml`, the server spawns a background task (`discovery_relay.rs`) that wakes up every `RegistrationIntervalSec` seconds (default 30 s) and POSTs a JSON registration payload to each configured relay URL:

```
POST <relay_url>
Content-Type: application/json

{
  "name":             "My HighBeam Server",
  "description":      "A HighBeam server",
  "map":              "/levels/gridmap_v2/info.json",
  "players":          3,
  "max_players":      16,
  "port":             18860,
  "protocol_version": 2
}
```

The relay is responsible for recording the source IP of the POST and associating it with the port field to build the `addr` that clients will use to connect. Entries that have not been refreshed within a TTL window (recommended: 2–3× the registration interval) should be expired by the relay.

### 2. Client Browsing (relay → client)

From the in-game **Browse Servers** tab (`browser.lua`), the player enters a relay URL and clicks **Refresh**. The client performs a plain HTTP GET:

```
GET <relay_url>/servers    (path /servers appended when no explicit path is in the URL)
```

The relay responds with a JSON body in one of two accepted formats:

**Wrapped format:**
```json
{
  "servers": [
    {
      "addr":        "203.0.113.42:18860",
      "name":        "My HighBeam Server",
      "map":         "/levels/gridmap_v2/info.json",
      "players":     3,
      "max_players": 16
    }
  ]
}
```

**Bare array format:**
```json
[
  {
    "addr":        "203.0.113.42:18860",
    "name":        "My HighBeam Server",
    "map":         "/levels/gridmap_v2/info.json",
    "players":     3,
    "max_players": 16
  }
]
```

Both formats are accepted by the client and by `fetch_relay_servers()` in the launcher. The `name`, `map`, `players`, and `max_players` fields are all optional — the client falls back to sensible defaults if they are absent.

After parsing the server list, the client sends a **UDP 0x7A discovery ping** to each listed server (up to 8 servers to avoid freezing the game thread) and colour-codes the latency:

| Latency | Colour |
|---------|--------|
| ≤ 80 ms | Green |
| ≤ 150 ms | Yellow |
| > 150 ms | Red |
| No response | Grey (no ping displayed) |

### 3. Launcher CLI Browsing (relay → launcher)

The launcher supports relay browsing without launching the game:

```bash
highbeam-launcher --browse-relay http://relay.example.com
```

This calls `fetch_relay_servers()` in `launcher/src/discovery.rs`, which performs the same HTTP GET as the in-game client and prints the server list to stdout.

---

## Relay JSON API Contract

### Registration endpoint — `POST <relay_url>`

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | Yes | Human-readable server name |
| `description` | string | No | Short description |
| `map` | string | No | Active map path |
| `players` | integer | No | Current connected player count |
| `max_players` | integer | No | Maximum player capacity |
| `port` | integer | Yes | Game port (TCP + UDP) |
| `protocol_version` | integer | No | HighBeam protocol version |

Expected responses: `200 OK` or `204 No Content` on success. Any 4xx/5xx is logged as a warning by the server but does not affect gameplay.

### Server list endpoint — `GET <relay_url>/servers`

The relay must respond with `Content-Type: application/json` and either the wrapped or bare array format described above. Each entry in the list must include at minimum an `addr` field (`"host:port"` string). All other fields are optional but strongly recommended for a useful UI.

| Field | Type | Description |
|-------|------|-------------|
| `addr` | string | `"host:port"` — required; entries with an empty addr are dropped by the client |
| `name` | string | Server display name |
| `map` | string | Active map path |
| `players` | integer | Current connected players |
| `max_players` | integer | Maximum players |

---

## Server Configuration

To register a server with a community relay, add the `[Discovery]` section to `ServerConfig.toml`:

```toml
[Discovery]
EnableRelay              = true
RelayUrls                = ["http://relay.example.com"]
RegistrationIntervalSec  = 30
```

Multiple relay URLs are supported — the server will POST to all of them on each interval:

```toml
[Discovery]
EnableRelay = true
RelayUrls   = [
  "http://relay.example.com",
  "http://another-relay.example.org",
]
RegistrationIntervalSec = 30
```

`RegistrationIntervalSec` must be at least 5 seconds (values lower than 5 are silently clamped to 5). The relay's TTL expiry should be set to at least 2–3× this interval to tolerate occasional missed heartbeats.

---

## Running a Community Relay

A relay is any HTTP service that:

1. **Accepts `POST /`** with the registration JSON body, extracts the sender's IP, builds an `addr` from `<sender-ip>:<port>`, stores the entry, and resets a TTL timer for that addr.
2. **Serves `GET /servers`** with a JSON body containing all non-expired entries in the wrapped or bare array format.
3. **Expires entries** whose TTL has elapsed (recommended TTL: 2× `RegistrationIntervalSec`, e.g. 60–90 s for the default 30 s interval).

The relay does not need to be aware of HighBeam beyond these two endpoints. Any language and framework can be used. An example minimal relay using Node.js/Express would look like:

```js
const express = require('express');
const app = express();
app.use(express.json());

const servers = new Map(); // addr -> { entry, expiresAt }
const TTL_MS = 90_000;

app.post('/', (req, res) => {
  const ip = req.headers['x-forwarded-for']?.split(',')[0] ?? req.socket.remoteAddress;
  const port = req.body.port ?? 18860;
  const addr = `${ip}:${port}`;
  servers.set(addr, {
    entry: { addr, ...req.body },
    expiresAt: Date.now() + TTL_MS,
  });
  res.sendStatus(204);
});

app.get('/servers', (_req, res) => {
  const now = Date.now();
  const list = [...servers.values()]
    .filter(v => v.expiresAt > now)
    .map(v => v.entry);
  res.json({ servers: list });
});

app.listen(80);
```

This is an illustrative example only. A production relay should add rate limiting and abuse protection.

---

## Security Considerations

- **No trust relationship.** The relay is a third-party service. Neither the HighBeam server nor the client trusts the relay for anything beyond discovery. The relay cannot forge connections, modify game traffic, or authenticate players.
- **IP exposure.** Registering with a relay makes the server's IP address public. Operators who wish to keep their IP private should not use relay registration.
- **Relay abuse.** Relay operators should rate-limit POST registrations by source IP to prevent relay flooding. The relay list is purely informational — a malicious entry can at most cause players to attempt connecting to a non-existent address.
- **Plain HTTP only.** The client-side relay fetch uses a plain HTTP GET implemented over a raw TCP socket. HTTPS relays are not currently supported by the in-game browser. Use plain HTTP for any relay you intend to make browsable in-game.
- **No relay authentication.** There is no shared secret between the server and relay. Any host can POST to a public relay. Relay operators may choose to implement their own allowlist.

---

## Component Summary

| Component | File | Role |
|-----------|------|------|
| Server registration task | `server/src/discovery_relay.rs` | Periodic HTTP POST to relay URLs |
| Server config | `server/ServerConfig.default.toml` `[Discovery]` | Opt-in relay URLs and interval |
| In-game server browser | `client/lua/ge/extensions/highbeam/browser.lua` | HTTP GET fetch + UDP ping |
| Launcher relay CLI | `launcher/src/discovery.rs` `fetch_relay_servers()` | HTTP GET for CLI listing |
| Launcher relay command | `launcher/src/main.rs` `--browse-relay` | CLI entry point |
