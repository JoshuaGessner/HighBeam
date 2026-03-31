# HighBeam Version Plan

> **Last updated:** 2026-03-30
> **Versioning scheme:** [Semantic Versioning 2.0.0](https://semver.org/)
> **Current version:** v0.5.0 (protocol v2)
> **Status:** v0.5.0 Complete — Stability & deployment foundation ready

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

**Current protocol version:** 2 (bumped from 1 when PingPong heartbeat was added)

---

## Versioning Documentation Policy

`VERSION_PLAN.md` is the single source of truth for version planning, release history, and milestone status.

- Do not create or maintain separate versioning docs (for example, dedicated changelog or per-release notes files).
- Record completed work by updating milestone checkboxes in this file.
- Append release summaries under the "Recent Release Notes" section in this file.

---

## Roadmap

> **Implementation details for each phase are in [BUILD_GUIDE.md](../BUILD_GUIDE.md).**
> The VERSION_PLAN defines *what* ships in each version. The BUILD_GUIDE defines *how* to build it.

### v0.1.0 — Foundation (Pre-Alpha) ✅

**Status:** Complete — commit `abf7d44`  
**Goal:** Establish the core connection loop — one player can connect to a server, spawn a vehicle, and see it exist on the server.

**Server:**
- [x] TCP listener accepts connections
- [x] Handshake: ServerHello → AuthRequest → AuthResponse
- [x] Session management (create, track, cleanup)
- [x] Basic auth: `open` mode (no password)
- [x] TOML config loading
- [x] Structured logging

**Client:**
- [x] GE extension loads in BeamNG
- [x] TCP connection to server
- [x] Handshake flow (send AuthRequest, receive AuthResponse)
- [x] Connect/disconnect UI (direct connect only)

**Protocol:**
- [x] Define TCP packet format (length-prefixed JSON)
- [x] ServerHello, AuthRequest, AuthResponse, Ready packets
- [x] Protocol version 1

**Deliverable:** Connect to server, authenticate, see "Player connected" in server log.

**Acceptance Criteria:**
- [x] Server starts on port 18860 and logs readiness
- [x] Client connects via direct IP, completes handshake, enters CONNECTED state
- [x] Server tracks connected players by ID and session token
- [x] Multiple clients can connect simultaneously with unique IDs
- [x] Clean disconnect removes the session from the server
- [x] Oversized packets (>1MB) are rejected

---

### v0.2.0 — Vehicle Sync (Alpha) ✅

**Status:** Complete — commit `cfcbbb3`  
**Goal:** Multiple players can see each other's vehicles moving in real-time.

**Server:**
- [x] UDP receiver bound to same port
- [x] Vehicle state tracking (spawn, edit, delete)
- [x] Position relay: receive UDP from one client, broadcast to others
- [x] World state snapshot on player join
- [x] Player disconnect cleanup (remove vehicles, notify others)

**Client:**
- [x] UDP socket binding with session token
- [x] Send local vehicle position at 20 Hz (configurable)
- [x] Receive and apply remote vehicle positions
- [x] Spawn remote vehicles on world_state
- [x] Remove remote vehicles on player disconnect
- [x] Basic interpolation (lerp position, slerp rotation) with 2-3 snapshot buffer

**Protocol:**
- [x] UDP packet format (binary, 63-65 bytes per update)
- [x] VehicleSpawn, VehicleEdit, VehicleDelete, VehicleReset (TCP)
- [x] PositionUpdate (UDP)
- [x] WorldState packet
- [x] PlayerJoin, PlayerLeave notifications

**Deliverable:** Two players on the same map can see each other driving around.

**Acceptance Criteria:**
- [x] UDP binds successfully after TCP auth
- [x] Position updates sent at ~20Hz, received and relayed by server
- [x] Remote vehicles spawn correctly with the right model/config
- [x] Interpolation provides smooth movement (no teleporting)
- [x] Player disconnect removes all their vehicles from other clients' views
- [x] World state sent on join shows all existing vehicles

---

### v0.3.0 — Chat, Mods & Auth (Alpha) ⏳

**Status:** Complete — v0.3.0-alpha.1  
**Goal:** Complete the core multiplayer experience with chat, mod sync via launcher, and proper auth.

**Server:**
- [x] Chat message relay
- [x] Password auth mode
- [x] Allowlist auth mode
- [x] Mod file serving from Resources/Client/ (raw binary TCP to launcher)
- [x] `mod_list` endpoint — SHA-256 manifest of available mods
- [x] Raw binary file transfer for mod data (no base64)
- [x] MaxPlayers enforcement
- [x] MaxCarsPerPlayer enforcement
- [x] Rate limiting on auth attempts

**Launcher:**
- [x] Scaffold Rust binary (Cargo project under `launcher/`)
- [x] TOML config loading (`LauncherConfig.toml`)
- [x] Connect to server, request `mod_list`
- [x] Compare mod hashes against local cache (`~/.highbeam/cache/`)
- [x] Download missing mods via raw binary TCP transfer
- [x] SHA-256 verification of downloaded files
- [x] Install mods into BeamNG userfolder (`mods/`)
- [x] Install/update HighBeam client mod
- [x] Launch BeamNG.drive process (wait for exit, handle exit codes)
- [x] CLI interface (`--server`, `--no-launch`, `--clear-cache`)

**Client:**
- [x] Chat UI (send/receive messages)
- [x] Player list display
- [x] Connection status indicators
- [x] Reconnection with backoff
- [x] *(Mods pre-synced by launcher before game starts)*

**Protocol:**
- [x] ChatMessage packets
- [x] Launcher mod transfer protocol (mod_list / mod_request JSON + raw binary stream)
- [x] Kick packet
- [x] ServerMessage packet

**Hardening (applied during v0.3.0 development):**

The following production hardening was implemented alongside v0.3.0 feature work.
As of 2026-03-30, historical hardening notes were merged into this plan.

*Server hardening:*
- [x] TCP keepalive & 60s idle timeout enforcement
- [x] Graceful shutdown with SIGTERM/SIGINT signal handlers
- [x] Input validation module (`validation.rs`): username, password, chat, vehicle ID, config size
- [x] Rate limiting: auth (5/60s per IP), chat (10/10s), spawn (5/5s)
- [x] Vehicle ownership & ID bounds validation
- [x] Session token collision safety (64-byte entropy + timestamp)
- [x] Config validation at startup (rejects invalid settings)
- [x] File logging with daily rotation (`tracing-appender`)
- [x] Chat logging when `LogChat=true` (structured `highbeam::chat` target)
- [x] Username emptiness runtime check in `add_player()`

*Client hardening:*
- [x] 5-second connect timeout
- [x] Heartbeat/ping-pong protocol (20s ping, 30s pong timeout) — bumped protocol to v2
- [x] Packet parsing validation with pcall wrappers
- [x] Lua error handling: all callbacks and requires wrapped in pcall
- [x] Vehicle interpolation: 50ms buffer, lerp/slerp math helpers (`math.lua`)
- [x] Connection state machine with transition guards and stack-trace logging

**Post-hardening verification backlog (tracked here, not in a separate roadmap):**
- [ ] Manual verification pass for v0.3.0 hardening behavior (timeouts, rate limits, validation, log rotation)
- [ ] Add malformed-packet fuzzing corpus to automated tests
- [ ] Run rapid connect/disconnect stress cycle validation
- [ ] Add explicit bad-JSON recovery test scenario for client error handling

**Deliverable:** Full multiplayer session with chat, modded vehicles, and password-protected servers. Launcher handles mod sync before game launch.

**Remaining for v0.3.0 release:**
- [x] Password auth enforcement (server rejects wrong password)
- [x] Allowlist auth enforcement (server rejects unlisted users)
- [x] MaxPlayers enforcement (reject connection when full)
- [x] MaxCarsPerPlayer enforcement (reject spawn when at limit)
- [x] Reconnection with exponential backoff (client)
- [x] Player list UI with names (client)
- [x] Connection status indicator UI (client)
- [x] ServerMessage packet type
- [x] HighBeam client mod auto-install via launcher (complete bundle creation)
- [x] Launch process management (wait for exit, handle errors)

**Acceptance Criteria:**
- [x] Chat messages relay between all connected players
- [x] Password mode rejects incorrect passwords, allowlist mode rejects unlisted users
- [x] Launcher downloads mods from server via raw binary TCP before launching the game
- [x] Mod cache deduplicates files by SHA-256 across servers
- [x] Rate limiting blocks auth brute force and chat spam
- [x] MaxPlayers and MaxCarsPerPlayer limits are enforced

---

### v0.4.2 — Plugin System, Auto-Update & Auto-Detection (Beta)

**Status:** Complete — plugin runtime, auto-update, BeamNG auto-detection, and CI release pipeline implemented

**Goal:** Server operators can customize their servers with Lua plugins. Both binaries self-update. Launcher auto-detects BeamNG.drive.

**Server:**
- [x] Lua 5.4 plugin runtime (isolated states per plugin)
- [x] `HB.*` API namespace (player, vehicle, chat, event functions)
- [x] Plugin event system (OnPlayerAuth, OnVehicleSpawn, OnChatMessage)
- [x] Event cancellation support
- [x] `Util.*` helper functions (random, logging)
- [x] `FS.*` filesystem functions
- [x] Plugin hot reload
- [x] Server console with `lua <plugin>` injection
- [x] Auto-update from GitHub Releases (`[Updates] AutoUpdate = true`)

**Launcher:**
- [x] Auto-update from GitHub Releases (`--no-update` to skip)
- [x] BeamNG.drive auto-detection via Steam library discovery
- [x] User data folder auto-detection (`%LOCALAPPDATA%/BeamNG.drive`)

**Client:**
- [x] Handle custom plugin events (TriggerClientEvent)
- [x] Send custom events to server

**Deliverable:** Server operators can write Lua plugins to customize gameplay (kick/ban, economy, custom rules). Zero-config launcher experience for Steam users.

**Acceptance Criteria:**
- Plugins load from Resources/Server/<PluginName>/
- HB.* API functions work correctly (GetPlayers, SendChatMessage, DropPlayer, etc.)
- Event handlers fire in correct order (dependencies respected)
- Cancellable events prevent the action when cancelled
- Plugin errors are isolated — one plugin crash doesn't affect others
- Hot reload works without server restart

---

### v0.5.0 — Stability & Deployment Polish (Beta)

**Status:** Complete — All core stability, metrics, logging, and deployment features implemented  
**Goal:** Production-quality stability and reliable deployment infrastructure. Foundation for optional GUI in v0.6.0.

**Server — Operational Stability:**
- [x] Graceful shutdown — SIGTERM/SIGINT signal handlers with clean disconnect
- [x] TCP keepalive & 60s idle timeout enforcement
- [x] Bandwidth throttling — tick-rate-based UDP relay throttling
- [x] Memory cleanup — stale rate limiter record pruning
- [x] Connection state validation and error recovery
- [x] Rate limiting enforcement (auth, chat, vehicle spawn)

**Server — Observability & Logging:**
- [x] Periodic runtime metrics logging (player count, vehicle count, network packets, memory)
- [x] Log rotation policy — configurable max size (MB) and retention (days)
- [x] Metrics collection at configurable intervals (MetricsIntervalSec)
- [x] Memory usage monitoring (per-process RSS via sysinfo)
- [x] Structured logging with configurable levels
- [x] Chat logging when enabled (LogChat=true)

**Server — Security & TLS:**
- [x] Optional TLS for TCP channel (certificate loading from files)
- [x] Configuration-based TLS control (Enabled flag, cert/key paths)
- [x] Input validation for all user-facing operations
- [x] Session token collision safety (64-byte entropy + timestamp)

**Server — Configuration & Deployment:**
- [x] `--headless` CLI flag for Docker / systemd (disables future GUI features)
- [x] `--config` flag for custom config file path
- [x] Configurable tick rate (applied to UDP relay throttling)
- [x] Systemd service file template for Linux (highbeam-server.service)
- [x] Dockerfile + docker-compose for containerized deployment
- [x] Auto-update from GitHub Releases (with --no-update override)
- [x] Config validation at startup

**Client:**
- [x] Connection quality via heartbeat/ping-pong (20s ping, 30s timeout)
- [x] Stable vehicle interpolation with lerp/slerp math
- [x] Error state recovery and reconnection

**Deliverable:** Server is stable, observable, and easily deployable. Operators can monitor via logs and metrics. Ready for production with 10-20 player communities. TLS support for secure connections.

**Acceptance Criteria:**
- [x] Server starts and responds to clients
- [x] `--headless` flag works correctly
- [x] Metrics logged at intervals to stdout/file
- [x] Log rotation works (files are rotated and old archives cleaned)
- [x] Graceful shutdown on SIGTERM/SIGINT
- [x] 20-player server uses < 2Mbps total bandwidth
- [x] Remote vehicle movement is smooth (20Hz sync rate)
- [x] TLS can be enabled/disabled via config
- [x] Memory stable over test duration (no memory leaks)
- [x] Systemd service file deploys cleanly
- [x] Docker image builds and runs
- [x] Auto-update fetches releases correctly

---

### v0.6.0 — Server GUI & Discovery (Beta)

**Goal:** Graphical server management interface and optional server discovery without centralized dependency.

**Server — GUI:**
- [ ] Server GUI (egui/eframe) with tabbed panel layout
- [ ] Dashboard panel (player count, uptime, tick rate, bandwidth)
- [ ] Player management panel (kick, ban, persistence toggle)
- [ ] Map management panel (select active map from available maps)
- [ ] Mod management panel (add/remove mods from Resources/Client/)
- [ ] Plugin management panel (view, reload, error status)
- [ ] Console panel (live log viewer, Lua command injection)
- [ ] Settings panel (edit ServerConfig.toml values at runtime)
- [ ] System tray integration (minimize-to-tray, tray context menu)
- [ ] State save on shutdown (vehicle positions, player data persistence)

**Client:**
- [ ] Advanced interpolation (extrapolation with velocity)
- [ ] Jitter buffer tuning
- [ ] Connection quality indicator UI
- [ ] Settings UI (update rate, interpolation toggle)

**Server Discovery:**
- [ ] Optional registration with community relay servers
- [ ] Server query protocol (unauthenticated info endpoint)

**Client Discovery:**
- [ ] Server browser with community relay support
- [ ] Server favorites / recent connections
- [ ] Server info preview (name, map, players, ping)

**Deliverable:** Server operators have a desktop GUI for managing their server. Players can discover servers through a community-run index.

**Acceptance Criteria:**
- GUI launches by default when not in headless mode, all panels functional
- Maps and mods can be added/removed from the GUI
- Settings changes apply at runtime without restart
- Minimize-to-tray works on Windows and Linux
- Server responds to UDP query packets with info
- Server browser shows servers with name, map, player count, and ping
- Favorites and recent servers persist across game restarts

---

### v0.7.0 — Protocol Optimization (Beta)

**Goal:** Reduce bandwidth overhead and improve performance at scale.

**Server & Client:**
- [ ] Binary TCP packet format (replace JSON with MessagePack or custom proto)
- [ ] Delta compression for vehicle config updates
- [ ] Adaptive update rates based on distance/visibility
- [ ] State save on shutdown with recovery on restart

**Performance Targets:**
- [ ] Binary protocol reduces per-packet overhead by >50% vs JSON
- [ ] 50-player server uses < 5Mbps total bandwidth
- [ ] Memory stable with 50+ players (< 1GB RSS)

---

### v1.0.0 — Stable Release

**Goal:** Feature-complete, documented, stable multiplayer framework.

**Requirements for 1.0.0:**
- All v0.x features stable and tested (v0.1–v0.5 minimum required; v0.6+ optional)
- Protocol version finalized (breaking changes require major version bump after this)
- Plugin API stable (HB.* namespace frozen)
- Security audit: all input validation, rate limiting, and auth paths reviewed
- Documentation complete
- Server builds for Windows and Linux
- Client mod packaged and installable
- Performance validated at 20+ players
- Graceful shutdown and error recovery tested
- TLS connections working reliably
- Metrics and logging tested at scale

**Test Suites Required:**

*Unit Tests:*
- [ ] Validation functions (all inputs)
- [ ] Rate limiter logic (boundary conditions)
- [ ] Session token generation (entropy distribution)

*Integration Tests:*
- [ ] Full connect → auth → ready → disconnect cycle
- [ ] Multiple players joining/leaving
- [ ] Chat broadcast to all players
- [ ] Vehicle spawn/edit/delete propagation

*Stress Tests:*
- [ ] 50 concurrent players connecting
- [ ] 100 messages/second chat flood
- [ ] Vehicle position updates at max rate for 5 minutes
- [ ] Rapid connect/disconnect cycles

*Network Simulation:*
- [ ] Packet loss scenarios
- [ ] High latency (500ms+)
- [ ] Connection resets mid-game
- [ ] UDP packet drops

**Acceptance Criteria:**
- All unit + integration tests pass
- 50-player load test completes without crashes
- Memory usage stays under 500MB
- No memory leaks detected
- Recovery from network failures works

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
- **Web dashboard** — Optional browser-based remote admin panel (separate from local GUI)

---

## Recent Release Notes

### v0.5.0 — 2026-03-30
- Stability and deployment polish release completed.
- Added graceful shutdown, runtime metrics, memory monitoring, log rotation, optional TLS, and deployment assets.
- Server and launcher version bumped to `0.5.0`; protocol remains `v2`.

### v0.4.3 — 2026-03-30
- Consolidated auto-detection and auto-update release continuity.

### v0.4.2 — 2026-03-30
- Added auto-update for server/launcher and BeamNG auto-detection in launcher.

---

## Release Process

### Pre-Release Checklist

1. All tests pass
2. VERSION_PLAN.md updated with milestone checkbox status and a release summary in "Recent Release Notes"
3. Version bumped in:
   - `server/Cargo.toml`
   - `launcher/Cargo.toml`
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
