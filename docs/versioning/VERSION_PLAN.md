# HighBeam Version Plan

> **Last updated:** 2026-03-29
> **Versioning scheme:** [Semantic Versioning 2.0.0](https://semver.org/)

---

## SemVer Policy

HighBeam follows **Semantic Versioning 2.0.0**: `MAJOR.MINOR.PATCH`

| Component | Incremented When... |
|-----------|-------------------|
| **MAJOR** | Breaking protocol changes, incompatible API changes, or config format changes that require migration |
| **MINOR** | New features added in a backward-compatible manner |
| **PATCH** | Backward-compatible bug fixes |

### Pre-release Versions

During initial development (before 1.0.0), the rules are relaxed:
- `0.x.y` — The API is unstable; minor versions may include breaking changes
- Pre-release tags: `-alpha.1`, `-beta.1`, `-rc.1`

### Protocol Versioning

The network protocol has its own integer version (independent of SemVer). Protocol version bumps happen when:
- Packet formats change
- New required packet types are added
- Handshake flow changes

The server and client negotiate protocol version during the handshake. Mismatches result in a clean disconnect with an error message.

---

## Roadmap

> **Implementation details for each phase are in [BUILD_GUIDE.md](../BUILD_GUIDE.md).**
> The VERSION_PLAN defines *what* ships in each version. The BUILD_GUIDE defines *how* to build it.

### v0.1.0 — Foundation (Pre-Alpha)

**Goal:** Establish the core connection loop — one player can connect to a server, spawn a vehicle, and see it exist on the server.

**Server:**
- [ ] TCP listener accepts connections
- [ ] Handshake: ServerHello → AuthRequest → AuthResponse
- [ ] Session management (create, track, cleanup)
- [ ] Basic auth: `open` mode (no password)
- [ ] TOML config loading
- [ ] Structured logging

**Client:**
- [ ] GE extension loads in BeamNG
- [ ] TCP connection to server
- [ ] Handshake flow (send AuthRequest, receive AuthResponse)
- [ ] Connect/disconnect UI (direct connect only)

**Protocol:**
- [ ] Define TCP packet format (length-prefixed JSON)
- [ ] ServerHello, AuthRequest, AuthResponse, Ready packets
- [ ] Protocol version 1

**Deliverable:** Connect to server, authenticate, see "Player connected" in server log.

**Acceptance Criteria:**
- Server starts on port 18860 and logs readiness
- Client connects via direct IP, completes handshake, enters CONNECTED state
- Server tracks connected players by ID and session token
- Multiple clients can connect simultaneously with unique IDs
- Clean disconnect removes the session from the server
- Oversized packets (>1MB) are rejected

---

### v0.2.0 — Vehicle Sync (Alpha)

**Goal:** Multiple players can see each other's vehicles moving in real-time.

**Server:**
- [ ] UDP receiver bound to same port
- [ ] Vehicle state tracking (spawn, edit, delete)
- [ ] Position relay: receive UDP from one client, broadcast to others
- [ ] World state snapshot on player join
- [ ] Player disconnect cleanup (remove vehicles, notify others)

**Client:**
- [ ] UDP socket binding with session token
- [ ] Send local vehicle position at 20 Hz (configurable)
- [ ] Receive and apply remote vehicle positions
- [ ] Spawn remote vehicles on world_state
- [ ] Remove remote vehicles on player disconnect
- [ ] Basic interpolation (lerp position, slerp rotation) with 2-3 snapshot buffer

**Protocol:**
- [ ] UDP packet format (binary, 63-65 bytes per update)
- [ ] VehicleSpawn, VehicleEdit, VehicleDelete, VehicleReset (TCP)
- [ ] PositionUpdate (UDP)
- [ ] WorldState packet
- [ ] PlayerJoin, PlayerLeave notifications

**Deliverable:** Two players on the same map can see each other driving around.

**Acceptance Criteria:**
- UDP binds successfully after TCP auth
- Position updates sent at ~20Hz, received and relayed by server
- Remote vehicles spawn correctly with the right model/config
- Interpolation provides smooth movement (no teleporting)
- Player disconnect removes all their vehicles from other clients' views
- World state sent on join shows all existing vehicles

---

### v0.3.0 — Chat, Mods & Auth (Alpha)

**Goal:** Complete the core multiplayer experience with chat, mod sync, and proper auth.

**Server:**
- [ ] Chat message relay
- [ ] Password auth mode
- [ ] Allowlist auth mode
- [ ] Mod file serving from Resources/Client/
- [ ] MaxPlayers enforcement
- [ ] MaxCarsPerPlayer enforcement
- [ ] Rate limiting on auth attempts

**Client:**
- [ ] Chat UI (send/receive messages)
- [ ] Player list display
- [ ] Mod download on connect
- [ ] Connection status indicators
- [ ] Reconnection with backoff

**Protocol:**
- [ ] ChatMessage packets
- [ ] ModInfo, ModData packets
- [ ] Kick packet
- [ ] ServerMessage packet

**Deliverable:** Full multiplayer session with chat, modded vehicles, and password-protected servers.

**Acceptance Criteria:**
- Chat messages relay between all connected players
- Password mode rejects incorrect passwords, allowlist mode rejects unlisted users
- Mods from Resources/Client/ are served to connecting clients
- Rate limiting blocks auth brute force and chat spam
- MaxPlayers and MaxCarsPerPlayer limits are enforced

---

### v0.4.0 — Plugin System (Beta)

**Goal:** Server operators can customize their servers with Lua plugins.

**Server:**
- [ ] Lua 5.4 plugin runtime (isolated states per plugin)
- [ ] `HB.*` API namespace (player, vehicle, chat, event functions)
- [ ] Plugin event system (onPlayerAuth, onVehicleSpawn, etc.)
- [ ] Event cancellation support
- [ ] `Util.*` helper functions (JSON, random, logging)
- [ ] `FS.*` filesystem functions
- [ ] Plugin hot reload
- [ ] Server console with `lua <plugin>` injection

**Client:**
- [ ] Handle custom plugin events (TriggerClientEvent)
- [ ] Send custom events to server

**Deliverable:** Server operators can write Lua plugins to customize gameplay (kick/ban, economy, custom rules).

**Acceptance Criteria:**
- Plugins load from Resources/Server/<PluginName>/
- HB.* API functions work correctly (GetPlayers, SendChatMessage, DropPlayer, etc.)
- Event handlers fire in correct order (dependencies respected)
- Cancellable events prevent the action when cancelled
- Plugin errors are isolated — one plugin crash doesn't affect others
- Hot reload works without server restart

---

### v0.5.0 — Polish & Performance (Beta)

**Goal:** Production-quality stability, performance, and error handling.

**Server:**
- [ ] Optional TLS for TCP channel
- [ ] Binary TCP packet format (replace JSON with MessagePack or custom)
- [ ] Delta compression for vehicle config updates
- [ ] Graceful shutdown with save state
- [ ] Memory usage monitoring
- [ ] Configurable tick rate

**Client:**
- [ ] Advanced interpolation (extrapolation with velocity)
- [ ] Jitter buffer tuning
- [ ] Connection quality indicator
- [ ] Settings UI (update rate, interpolation toggle)

**Deliverable:** Stable enough for community servers with 10-20 players.

**Acceptance Criteria:**
- 20-player server uses < 2Mbps total bandwidth
- Remote vehicle movement is smooth under 5% packet loss
- TLS connection works when configured
- Binary protocol reduces per-packet overhead by >50% vs JSON
- Jitter buffer eliminates visual hitches from network jitter

---

### v0.6.0 — Discovery & Community (Beta)

**Goal:** Optional server discovery without centralized dependency.

**Server:**
- [ ] Optional registration with community relay servers
- [ ] Server query protocol (unauthenticated info endpoint)

**Client:**
- [ ] Server browser with community relay support
- [ ] Server favorites / recent connections
- [ ] Server info preview (name, map, players, ping)

**Deliverable:** Players can find servers through a community-run index without any centralized authority.

**Acceptance Criteria:**
- Server responds to UDP query packets with info (no auth required)
- Relay registration works with configurable relay URL
- Server browser shows servers with name, map, player count, and ping
- Favorites and recent servers persist across game restarts

---

### v1.0.0 — Stable Release

**Goal:** Feature-complete, documented, stable multiplayer framework.

**Requirements for 1.0.0:**
- All v0.x features stable and tested
- Protocol version finalized (breaking changes require major version bump after this)
- Plugin API stable (HB.* namespace frozen)
- Documentation complete
- Server builds for Windows and Linux
- Client mod packaged and installable
- At least one community relay running
- Performance validated at 20+ players

---

### Future (Post-1.0.0)

Ideas for future development (not committed):

- **Voice chat** — UDP Opus codec channel
- **Spectator mode** — Watch without spawning
- **Replay system** — Record and playback sessions
- **Headless mode** — Server without console for Docker/systemd
- **ARM support** — Compile for ARM64 (Raspberry Pi, etc.)
- **Map voting** — Plugin + client UI for map rotation
- **Vehicle permissions** — Per-player vehicle restrictions
- **Bandwidth optimization** — Adaptive update rates based on distance/visibility

---

## Release Process

### Pre-Release Checklist

1. All tests pass
2. CHANGELOG.md updated with all changes
3. Version bumped in:
   - `server/Cargo.toml`
   - Client mod `info.json`
   - Protocol version (if changed)
4. Documentation updated for new features
5. Git tag created: `v0.X.Y`

### Creating a Release

```bash
# Ensure main is clean
git checkout main
git pull origin main

# Tag the release
git tag -a v0.2.0 -m "v0.2.0 — Vehicle Sync"
git push origin v0.2.0

# GitHub Actions will build and attach binaries (when CI is set up)
```

### Hotfix Process

For critical bug fixes on a released version:

```bash
git checkout -b hotfix/v0.2.1 v0.2.0
# ... apply fix ...
git tag -a v0.2.1 -m "v0.2.1 — Fix crash on disconnect"
git push origin hotfix/v0.2.1 v0.2.1
```
