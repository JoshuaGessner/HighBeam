# HighBeam Version Plan

> **Last updated:** 2026-04-03
> **Versioning scheme:** [Semantic Versioning 2.0.0](https://semver.org/)
> **Current version:** v0.8.0-dev.2 (protocol v2)
> **Status:** v0.8.0-dev.2 — Community Node Discovery Mesh

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

### Dev Release Workflow

Dev releases are used for internal testing iterations before a public-facing release.
They use SemVer pre-release suffixes and are published as **GitHub draft releases**
(invisible to the public — only visible to repo collaborators).

- **Dev iteration:** `0.6.80-dev.1`, `0.6.80-dev.2`, … → GitHub **draft** release
- **Public release:** `0.6.80` → GitHub **full** release (marked Latest)

SemVer ordering guarantees `0.6.80-dev.N < 0.6.80`, so the public release
always sorts higher than any dev iteration.

To promote a dev build to public: drop the `-dev.N` suffix, update all version
references, tag, and create a full (non-draft) GitHub release.

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

### Active Implementation Queue

- [x] PR1: v0.3 hardening closeout tests
   - Added malformed-packet decode corpus tests (server).
   - Added rapid connect/disconnect stress validation tests (server).
   - Added explicit bad-JSON recovery scenario helper (client).
- [x] PR2: v0.3 manual verification run
   - Execute timeout, rate-limit, validation, and log-rotation manual pass.
   - Captured results and edge cases in this file.
- [x] PR3: v0.6 backend control plane foundation
   - Introduce server admin command/snapshot interfaces for future GUI wiring.
   - Keep headless path unchanged.
   - Delivered `ControlPlane` backend module with:
     - Runtime snapshot API (`ServerSnapshot`)
     - Admin command API (`GetSnapshot`, `BroadcastServerMessage`, `KickPlayer`, `ReloadPlugins`)
     - Console command routing (`status`, `say`, `kick`, `plugins reload`, `lua`)
- [x] PR4: v0.6 GUI shell
   - Add egui/eframe application shell with dashboard tab and status metrics.
   - Delivered desktop GUI scaffold with tabbed layout and live dashboard snapshot:
     - Tabs: Dashboard, Players, Plugins, Console, Settings
     - Live status from `ControlPlane::snapshot()` (players, vehicles, plugins, uptime, map, port)
     - Non-headless launch path integrated while preserving `--headless` behavior
- [x] PR5: v0.6 discovery protocol slice
   - Add unauthenticated server query endpoint and basic client discovery model.
   - Delivered unauthenticated UDP discovery query endpoint on server.
   - Delivered launcher discovery query client (`--query-server host:port`).
- [x] PR6: v0.7 protocol optimization prep
   - Add JSON baseline benchmark harness and dual-format migration plan.
   - Delivered server benchmark mode: `--protocol-benchmark`.
   - Added benchmark harness (`net::benchmark`) with representative packet corpus and throughput/size reporting.
   - Migration plan (dual-format):
     1. Introduce protocol v3 with explicit transport format negotiation in handshake.
     2. Support JSON (v2/v3 compatibility mode) and binary codec (v3 preferred) in parallel decode path.
     3. Keep JSON encode for legacy clients until adoption threshold.
     4. Flip default encode to binary for v3-capable clients.
     5. Remove JSON encode path in a future major after deprecation window.
- [x] PR7: v0.6.1 in-game client UX
   - Add IMGUI server browser window to client mod GE extension.
   - Direct Connect tab: host / port / username / password fields, values persisted to config JSON.
   - Browse Servers tab: relay URL input, Refresh button, live server table (name, map, players, ping).
   - Favorites tab: saved servers with one-click connect and remove buttons.
   - Recent tab: last 10 connections with timestamps, quick reconnect, and favorite-toggle.
   - Favorites list persists to `userdata/highbeam/favorites.json` in BeamNG user folder.
   - Recent list persists to `userdata/highbeam/recents.json`.
   - Relay fetch via plain HTTP GET over LuaSocket TCP; UDP 0x7A ping for per-server latency.
   - Config save/load: username, last host/port, and relay URL are remembered between sessions.
   - Browser auto-opens when HighBeam loads and user is not connected; closes on successful connect.
   - Reopenable from GE Lua console: `extensions.highbeam.openBrowser()`.
- [x] PR8: v0.6.5 launcher join-scoped sync + GUI tray UX hardening (all phases complete)
   - [x] Remove launcher startup hardwire sync to configured server address.
   - [x] Trigger mod sync only when user joins a specific server (`--server` flag).
   - [x] Stage server mods per join-session (`highbeam-session-*` prefix + session manifest).
   - [x] Keep cache entries for reuse; clean staged BeamNG mods on session end and on stale-session recovery.
   - [x] Fix GUI close behavior to hide to tray reliably and keep Quit in tray as full exit path.
   - [x] Ensure Windows GUI mode does not show CLI console window (release build).
   - [x] Phase C: Wire in-game join action to launcher join-sync-ready handshake (IPC bridge).

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
- [x] Manual verification pass for v0.3.0 hardening behavior (timeouts, rate limits, validation, log rotation)
- [x] Add malformed-packet fuzzing corpus to automated tests
- [x] Run rapid connect/disconnect stress cycle validation
- [x] Add explicit bad-JSON recovery test scenario for client error handling

**Verification evidence (2026-03-30 local run):**
- Timeout behavior verified with temporary server config (`AuthTimeoutSec=2`): server logged `Auth timeout after 2s` on idle pre-auth connection.
- Auth rate limiting verified from repeated local connections: server logged `Auth rate limit exceeded` after max attempts.
- Validation checks verified via targeted tests: `cargo test validation::tests::` (7 passed).
- Log rotation behavior verified via targeted tests: `cargo test log_rotation::tests::` (5 passed).
- Runtime metrics and memory monitoring observed during verification run (`Runtime metrics ... memory_rss_mib=...`).

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

**Status:** Complete
**Goal:** Graphical server management interface and optional server discovery without centralized dependency.

**Current foundation progress (2026-03-30):**
- ControlPlane backend added for admin commands and runtime snapshots.
- GUI shell integrated for non-headless runs using egui/eframe.
- Tab scaffold in place: Dashboard, Players, Maps, Mods, Plugins, Console, Settings.
- Live dashboard snapshot wired (server/map/port, players, vehicles, plugins, uptime).
- Relay registration heartbeat and launcher discovery browser/favorites flows implemented.

**Server — GUI:**
- [x] Server GUI (egui/eframe) with tabbed panel layout
- [x] Dashboard panel (player count, uptime, tick rate, bandwidth)
- [x] Player management panel (kick, ban, persistence toggle)
- [x] Map management panel (select active map from available maps)
- [x] Mod management panel (add/remove mods from Resources/Client/)
- [x] Plugin management panel (view, reload, error status)
- [x] Console panel (live log viewer, Lua command injection)
- [x] Settings panel (edit ServerConfig.toml values at runtime)
- [x] System tray integration (minimize-to-tray, tray context menu)
- [x] State save on shutdown (vehicle positions, player data persistence)

**Client:**
- [x] Advanced interpolation (extrapolation with velocity)
- [x] Jitter buffer tuning
- [x] Connection quality indicator UI
- [x] Settings UI (update rate, interpolation toggle)

**Server Discovery:**
- [x] Optional registration with community relay servers
- [x] Server query protocol (unauthenticated info endpoint)

**Client Discovery:**
- [x] Server browser with community relay support
- [x] Server favorites / recent connections
- [x] Server info preview (name, map, players, ping)

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

### v0.6.1 — In-Game Client UX (Beta)

**Status:** Complete
**Goal:** Complete the in-game multiplayer interface so players can discover, connect, and manage servers entirely from within BeamNG without using the GE Lua console.

**Context:** v0.6.0 delivered discovery and server browser support at the launcher CLI level, but the in-game client mod had no user-facing join or browse UI. Connecting to a server required calling `require("highbeam/connection").connect(...)` manually from the BeamNG GE Lua console. v0.6.1 closes this gap with a fully self-contained IMGUI server browser embedded in the GE extension.

**Why IMGUI (not HTML/CEF):** The client mod runs as a BeamNG GE extension. IMGUI (`ui_imgui`) is the native, self-contained rendering path for GE extensions and does not require registering a CEF app module or managing a browser window lifecycle. The existing `chat.html` remains as the connected-state chat overlay; the server browser is a separate modal window.

**Client — Server Browser (IMGUI window):**
- [x] `browser.lua` GE extension module added with IMGUI window rendering
- [x] Window auto-opens when HighBeam loads if not already connected
- [x] Window closes automatically on successful connect; reopenable via `extensions.highbeam.openBrowser()` from GE console
- [x] **Direct Connect tab:** host, port, username, password fields; values saved to config JSON between sessions; one-click Connect button
- [x] **Browse Servers tab:** relay URL input field (remembered), Refresh button, live server table showing name / map / player count / ping; per-server Favorite toggle; per-server Connect button
- [x] **Favorites tab:** persisted saved servers with one-click connect and Remove button
- [x] **Recent tab:** last 10 connections with timestamps, quick reconnect button, and favorite toggle

**Client — Persistence:**
- [x] Favorites persist to `userdata/highbeam/favorites.json` via `FS:writeFile` / `FS:readFileToString` (io.open fallback)
- [x] Recents persist to `userdata/highbeam/recents.json`
- [x] Config save/load: `config.save()` and `config.load()` serialize the full config to `userdata/highbeam/config.json`

**Client — Relay & Discovery Integration:**
- [x] Relay HTTP fetch via plain TCP socket (no TLS dependency) — GET `<relayUrl>/servers` → JSON list
- [x] Relay response parses both `{ servers: [...] }` and bare array formats for compatibility
- [x] Per-server UDP 0x7A ping for real-time latency display; colours: green ≤80 ms, yellow ≤150 ms, red >150 ms
- [x] Relay URL configurable per-session and persisted to config

**Client — config.lua Enhancements:**
- [x] `relayUrl` added to config defaults
- [x] `config.save()` serializes current config to `userdata/highbeam/config.json`
- [x] `config.load()` reads saved config on startup, falling back to defaults for missing keys

**Deliverable:** Players can launch BeamNG, see the HighBeam browser window immediately, type a server address (or pick from the relay list / favorites / recents), enter their username, and connect — all without touching the Lua console.

**Acceptance Criteria:**
- [x] Player can join a server entirely within BeamNG without using the GE console
- [x] Server browser shows live relay list with name, map, player count, and colour-coded ping
- [x] Favorites and recents are preserved across BeamNG restarts
- [x] Username, last host/port, and relay URL are remembered between sessions
- [x] Connect from Browse / Favorites / Recent uses the username from the Direct Connect tab
- [x] Adding/removing favorites updates the Favorites tab immediately without restart

---

### v0.6.5 — Join-Scoped Launcher Flow & GUI Tray UX Hardening (Beta)

**Status:** Complete
**Goal:** Correct launcher/session behavior so mods are only synced for the server being actively joined, and harden server GUI tray/close UX for production use.

**Problem Statement:**
- Launcher currently performs sync/install work from configured startup server context, which can recreate client-side mod artifacts even when users expect no sync to occur.
- Mod installation behavior is not explicitly session-scoped for per-server joins.
- Server GUI close/tray behavior is inconsistent with user expectations (close should hide to tray, Quit should fully exit).
- Windows GUI mode should not present a CLI console window to end users.

**Scope Boundaries:**
- This milestone is a behavior-correction and UX-hardening release; no protocol bump planned.
- Primary targets: launcher join flow, cache/install lifecycle, server GUI tray behavior, Windows packaging UX.
- Existing headless/server-service workflows must remain backward-compatible.

**Launcher — Join-Scoped Sync & Install Policy:**
- [x] Remove auto-sync from normal launcher startup path.
- [x] Deprecate hardwired startup dependency on configured `server_addr` for mod syncing.
- [x] Introduce explicit join-triggered sync path (`--server` join intent).
- [x] Sync only when user initiates join for a specific server.
- [x] Persist last-used server as convenience only (never as implicit sync trigger).

**Launcher — Session Staging & Cleanup Model:**
- [x] Stage server-required mods into BeamNG mods folder only for active join session.
- [x] Record staged files in session manifest for deterministic cleanup.
- [x] On session end/launcher close, remove staged server-session mods from BeamNG mods folder.
- [x] Preserve downloaded files in launcher cache for reuse across future joins.
- [x] Add stale-session recovery cleanup on next launcher startup.

**Launcher — Cache Behavior Corrections:**
   - [x] Track cache entries with server context metadata while preserving hash deduplication.
- [x] Prevent cross-server install bleed-through unless hash/version requirements match.
- [x] Ensure deleting server-side Resources does not trigger local cache reinstalls without explicit join.

**Launcher — UX/Diagnostics:**
- [x] Add clear lifecycle logs: join requested, sync started, sync complete, staged mod count, cleanup result.
- [x] Add dry-run diagnostics mode to validate resolved paths and planned actions without launching game.
   - [x] Improve user-visible messaging so launcher close behavior is explicit and expected.

**Client/Join Orchestration:**
   - [x] Wire in-game join action to launcher join workflow (join request first, then connect when ready).
   - [x] If launcher bridge is unavailable, show explicit join failure reason instead of silent fallback behavior.
**Server GUI — Tray & Close Semantics:**
- [x] Closing server GUI window in non-headless mode should hide to tray, not terminate server.
- [x] Tray Show/Hide should restore/focus or hide window consistently (not taskbar-minimize ambiguity).
- [x] Tray Quit should always perform full graceful server shutdown path.
- [x] Document expected close/quit behavior in Settings tab and operator docs.

**Server GUI — Windows No-CLI UX:**
- [x] Ensure GUI mode on Windows runs without visible CLI console (release build).
- [x] Preserve headless/console operation for service/admin workflows.
- [x] Keep tray-based exit available when GUI window is hidden.

**Implementation Phases:**
- [x] **Phase A (Behavior Stopgap):** Disable startup auto-sync; gate sync strictly behind explicit join action.
- [x] **Phase B (Session Lifecycle):** Add staging manifest + cleanup-on-close + stale-session recovery.
- [x] **Phase C (Join Integration):** Connect in-game join UI to launcher join-sync-ready handshake (IPC bridge on localhost TCP; state file at `{beamng_userfolder}/highbeam-launcher.json`).
- [x] **Phase D (Server UX Hardening):** Close-to-tray semantics, tray Quit graceful shutdown, Windows GUI no-CLI path.
- [x] **Phase E (Validation & Release):** Code-level validation complete (fmt, clippy, compile, launcher tests).

**Deliverable:**
- Launcher only downloads/installs mods when user joins a specific server.
- Session-scoped mod staging is cleaned up on close while cache remains reusable.
- Server GUI hides to tray on close, supports reliable tray Quit, and Windows GUI usage has no visible CLI.

**Acceptance Criteria:**
- [x] Starting launcher without joining a server performs no mod sync/download/install.
- [x] Joining server A syncs and stages only A-required mods.
- [x] Exiting session removes staged mods from BeamNG mods folder while keeping cache entries.
- [x] Joining server B does not reinstall unrelated server A mods unless required by hash match.
- [x] Deleting server Resources does not recreate local client mods unless user initiates join.
- [x] In GUI mode, closing server window hides to tray and server remains running.
- [x] Tray Quit exits server process cleanly and persists final state.
- [x] On Windows GUI mode, no CLI console window is shown to end users (release build).

**Milestone complete.** All phases delivered.

---

### v0.7.0 — Protocol Optimization (Beta)

**Goal:** Reduce bandwidth overhead and improve performance at scale.

**Server & Client:**
- [ ] Binary TCP packet format (replace JSON with MessagePack or custom proto)
- [ ] Delta compression for vehicle config updates
- [ ] Adaptive update rates based on distance/visibility
- [x] State save on shutdown with recovery on restart

**Performance Targets:**
- [ ] Binary protocol reduces per-packet overhead by >50% vs JSON
- [ ] 50-player server uses < 5Mbps total bandwidth
- [ ] Memory stable with 50+ players (< 1GB RSS)

---

### v0.8.0 — Community Node Discovery Mesh (Beta)

**Status:** In progress (v0.8.0-dev.2)
**Goal:** Decentralized, P2P server discovery mesh built into every HighBeam server. Server operators opt in via the GUI to make their server discoverable. Players browse and connect to servers entirely in-game without knowing any IP addresses. No central relay infrastructure required.

**Problem Statement:**
- The Browse Servers tab is useless unless both server operator and player independently know the same relay URL.
- No official relay exists, and standing one up creates a central point of failure and ongoing hosting cost.
- IP addresses are currently exposed in the server browser, which is a privacy concern.
- Enabling discovery requires editing `ServerConfig.toml` — not user-friendly.

**Design Principles:**
- **P2P gossip mesh:** Every server that opts in IS a relay node. Nodes exchange server lists with each other, so any single node knows about every server in the mesh. No central infrastructure.
- **Bootstrap via seeds:** Operators enter 1+ seed node addresses (shared via Discord, website, etc.) to join the mesh. Once connected, they discover all other nodes organically through gossip. Seeds are only needed for initial entry.
- **IP privacy:** Server browser shows server names, maps, player counts, mods, and latency — never IP addresses. IPs are resolved internally at connect time only. Same privacy model as Discord voice / Steam matchmaking.
- **All setup in GUI:** No config file editing. Community Node is enabled, configured, and monitored entirely from the server GUI "Community" tab (or console commands for headless).
- **No new crate dependencies:** Built on existing `tokio` (TCP listener), `serde_json`, `reqwest` (outbound gossip), `rand` (ID generation).

**Architecture Overview:**

Every community node:
1. Registers itself in the mesh as a discoverable game server.
2. Runs a lightweight HTTP listener (default: gameplay port + 2, i.e., `18862`) serving the aggregated server list to clients and exchanging data with peer nodes.
3. Gossips with peers every 30 seconds, exchanging peer lists and server lists so full mesh state propagates organically.
4. Prunes stale entries — servers not heartbeated in 90s, peers unresponsive for 5 minutes.
5. Persists state to `community_node.json` (separate from `ServerConfig.toml`) for seamless restarts.

**Server ID System:**
- Each server gets a unique `server_id` (format: `hb-` + 6 random hex chars, e.g., `hb-7f3a9c`).
- Generated once on first enable, persisted across restarts.
- Used as the stable identifier for favorites/recents (survives IP changes).
- Never displayed raw to users — used internally for resolve lookups.

**Community Node HTTP API (server/src/community_node.rs):**

| Method | Path | Response | Consumers |
|--------|------|----------|-----------|
| `GET /servers` | Server list with IDs + metadata, **no `addr` field** | Clients (browser) |
| `GET /resolve/{id}` | `{"addr": "ip:port"}` for the game server | Clients at connect time |
| `GET /peers` | Known peer list | Other nodes |
| `POST /gossip` | Exchange full state (peers + servers with addrs) | Other nodes |
| `GET /health` | `{"ok": true, "peers": N, "servers": N}` | Monitoring |

**IP Privacy Split:**
- `/servers` response: contains `id`, `name`, `description`, `map`, `players`, `max_players`, `region`, `tags`, `auth_mode`, `mods` — NO `addr` field.
- `/gossip` request/response: contains full `addr` fields (node-to-node only, clients never call this).
- `/resolve/{id}`: returns a single server's `addr` on demand, rate-limited (10/min per source IP).
- Client uses resolved IP internally for `connection.connect()` — never displays it in UI.

**Server List Entry (what `/servers` returns per server):**
```json
{
  "id": "hb-7f3a9c",
  "name": "Drift Paradise",
  "description": "Open drift server",
  "map": "/levels/west_coast_usa/info.json",
  "players": 5,
  "max_players": 20,
  "region": "NA",
  "tags": ["drift"],
  "auth_mode": "open",
  "mods": [{"name": "traffic_pack.zip", "size_bytes": 4200000}]
}
```

**Gossip Protocol (node-to-node `POST /gossip`):**
- Request and response share the same shape: `{from, peers[], servers[]}`.
- Servers in gossip include `addr` and `node_addr` (game port and HTTP port respectively).
- Merge logic: for duplicate `server_id`, keep the entry with newer `last_seen`. For duplicate peer `addr`, keep newer `last_seen`.
- Caps: max 500 servers, max 200 peers. Excess evicted by oldest `last_seen`.

**Gossip Loop Behavior:**
- Every 30 seconds: update own entry, pick up to 3 random peers (always including ≥1 seed to resist eclipse attacks), POST `/gossip`, merge responses.
- Exponential backoff on repeated failures to a peer (30s → 60s → 120s → 300s cap), reset on success.
- Prune server entries older than 90s, peer entries older than 5 min.
- If `known_peers` is empty, fall back to seed nodes as gossip targets.

**Latency Measurement:**
- Client times the `GET /servers` HTTP round-trip and displays it as approximate latency (`~Xms`).
- Since each game server IS a node, HTTP latency to the node ≈ game latency to that server.
- Avoids mass-resolving IPs for per-server UDP ping (which would defeat privacy goal).

**Persistence (`community_node.json`):**
```json
{
  "enabled": true,
  "server_id": "hb-7f3a9c",
  "listen_port": 18862,
  "region": "NA",
  "tags": ["drift", "racing"],
  "seed_nodes": ["relay1.example.com:18862"],
  "known_peers": ["203.0.113.10:18862", "198.51.100.5:18862"]
}
```
- Written on clean shutdown and on Apply from GUI.
- Loaded on startup — if enabled, node starts automatically.
- `known_peers` persisted so mesh survives restarts without re-seeding.
- NOT stored in `ServerConfig.toml` — fully managed by application.

**Security Design:**

| Threat | Mitigation |
|--------|-----------|
| IP exposure in browse list | `/servers` omits `addr`. Only `/resolve/{id}` returns it, one at a time. |
| Mass IP harvesting via `/resolve` | Rate limit: 10 `/resolve` requests per minute per source IP. |
| Gossip contains IPs | Gossip is node-to-node only. `/gossip` validates caller context. |
| Password leak | Only `auth_mode` label sent. Password never leaves the server. |
| Malicious gossip entries | All incoming entries validated: server_id format, string lengths, numeric bounds, tag format, address format. Invalid entries silently dropped. |
| Eclipse attack | Seeds always included in gossip target selection. Seeds never evicted from peer list. |
| Stale/ghost servers | 90-second TTL. Entries expire within ~2 gossip rounds after node dies. |
| HTTP abuse | Rate limit: 30 req/min per IP across all endpoints. Max request body: 256 KB. Connection closed after response (no keep-alive). |
| Server ID collision | 6 hex chars = 16.7M possibilities. On collision, newer `last_seen` wins. Displaced server reclaims on next heartbeat. |
| Memory exhaustion | Fixed caps on all lists + request body size limits. |

---

**Server — Community Node Core (`community_node.rs`, new file):**
- [x] `CommunityNodeState` struct with `Arc<RwLock<...>>` for thread-safe access
- [x] Server ID generation (`hb-` + 6 random hex chars) on first enable
- [x] HTTP listener on configurable port (default: gameplay port + 2) using `tokio::net::TcpListener`
- [x] Minimal hand-built HTTP request parser (method + path routing, `Content-Length` body reads)
- [x] `GET /servers` handler — returns aggregated server list WITHOUT `addr` fields
- [x] `GET /resolve/{id}` handler — returns `{"addr": "ip:port"}` for a single server, rate-limited
- [x] `GET /peers` handler — returns known peer list
- [x] `POST /gossip` handler — receives peer+server lists, merges, returns own state
- [x] `GET /health` handler — returns peer/server counts
- [x] Gossip loop (tokio task): 30s interval, pick ≤3 peers, POST `/gossip`, merge responses
- [x] Self-registration: update own server entry each gossip round (player count, map, mod list from control plane)
- [x] Merge logic: newer `last_seen` wins for duplicate `server_id` or peer `addr`
- [x] Pruning: server entries >90s stale, peer entries >5min stale
- [x] Caps: max 500 servers, max 200 peers
- [x] Exponential backoff on peer failures (30s → 60s → 120s → 300s cap)
- [x] Seed node resilience: always include ≥1 seed in gossip target selection
- [x] Rate limiting: 30 req/min per IP (all endpoints), 10 `/resolve` per min per IP
- [x] Max request body: 256 KB
- [x] Persistence: load `community_node.json` on startup, save on shutdown and on Apply
- [x] `start()` function: loads state, spawns HTTP listener + gossip loop if enabled; no-op if disabled
- [x] Hot-start/stop: GUI can enable/disable without restarting game server

**Server — Validation (`validation.rs`):**
- [x] `validate_community_node_settings()`: tags (max 5, 1-20 chars, `[a-z0-9-]`), region (empty or known code), seed addresses (valid `host:port`, not private/loopback), port (1024-65535), server ID format

**Server — Startup Integration (`main.rs`):**
- [x] Add `mod community_node;` declaration
- [x] Call `community_node::start(config, control_plane, mod_manifest)` in `run_server()` after discovery relay
- [x] Pass returned `Arc<CommunityNodeState>` to GUI

**Server — GUI Community Tab (`gui.rs`):**
- [x] Add `Tab::Community` variant to tab enum
- [x] Add "Community" tab to tab selector bar
- [x] Enable/disable checkbox with Apply button (writes `community_node.json`, hot-starts/stops node)
- [x] Display server ID (read-only)
- [x] Node port input field
- [x] Region dropdown (NA, EU, AP, SA, OC, AF, or empty)
- [x] Tags text input (comma-separated, validated on Apply)
- [x] Seed node management: list with Remove buttons, Add input with validation
- [x] Live status display: peer count, server count, last gossip time, health indicators

**Server — Console Commands (`control.rs`):**
- [x] `community enable` — enable and start the node
- [x] `community disable` — stop the node
- [x] `community status` — show peer/server counts, listening port, server ID
- [x] `community port <port>` — set node HTTP port
- [x] `community region <code>` — set region
- [x] `community tags <a,b,c>` — set tags (comma-separated)
- [x] `community add-seed <addr>` — add a seed node address
- [x] `community remove-seed <addr>` — remove a seed node address

**Server — Config Comment (`ServerConfig.default.toml`):**
- [x] Add comment block explaining Community Node is managed via GUI/console, not this file

**Client — Browser Rewrite (`browser.lua`):**
- [x] Replace single `relayUrl` config key with `communityNodes` list (persisted to `userdata/highbeam/community_nodes.json`)
- [x] `fetchCommunityServers()`: try `GET /servers` against each known node until one succeeds; merge returned `nodes` into stored list for redundancy
- [x] Auto-fetch on Browse tab open if nodes are configured and servers not yet fetched this session
- [x] `resolveAndConnect(serverId)`: call `GET /resolve/{id}` on last successful node, then pass returned `addr` to `connection.connect()` — IP never displayed
- [x] Browse tab UI: Name, Map, Players, Mods, Ping (~Xms from HTTP round-trip), Actions (Connect button)
- [x] Mods column: show mod count, tooltip with full mod list on hover
- [x] Password servers: show lock icon, prompt for password on Connect
- [x] Favorites/Recents: store by `server_id` instead of `host:port`; resolve on connect
- [x] "Add node" input field with validation (replaces relay URL field)
- [x] Node management: show configured node count, allow add/remove
- [x] Keep Direct Connect tab unchanged (host:port manual entry still works)

**Client — Config (`config.lua`):**
- [x] Replace `relayUrl = ""` default with `communityNodes = {}` in `M.defaults`

**Existing Systems — No Changes:**
- `discovery_relay.rs` — private relay infrastructure remains untouched (complementary system)
- `config.rs` — no TOML config struct additions (community node uses its own JSON state file)
- Connection protocol — `connection.connect(host, port, ...)` unchanged; resolve step just provides the address
- Direct Connect tab — still available for players who know an IP:port

---

**Implementation Phases:**
- [x] **Phase A (Server Node Core):** `community_node.rs` — state structs, HTTP listener, gossip loop, merge logic, persistence, validation. All unit-testable without network.
- [x] **Phase B (Server GUI + Console):** Community tab in `gui.rs`, console commands in `control.rs`, hot-start/stop wiring.
- [x] **Phase C (Client Browser):** Rewrite `browser.lua` Browse tab to use community nodes, add resolve-on-connect, favorites/recents by server_id.
- [ ] **Phase D (Integration & Testing):** Two-node gossip convergence test, client fetch→resolve→connect end-to-end, security validation (rate limits, input validation, no IP leaks in `/servers`).

**Deliverable:**
- Server operators enable Community Node from the GUI, enter a seed address, and their server becomes discoverable to all players in the mesh.
- Players open the Browse Servers tab and see a populated server list with names, maps, player counts, mods, and latency — no IP addresses visible, no relay URL to configure.
- Clicking Connect resolves the server address internally and connects directly.
- The mesh is self-sustaining: seed a few initial nodes, community takes over as more servers join.

**Acceptance Criteria:**
- [ ] Enabling Community Node from GUI starts the HTTP listener and gossip loop without server restart
- [ ] Disabling Community Node from GUI stops the node cleanly
- [ ] Server ID is generated once and persists across restarts
- [ ] Two nodes with each other as seeds discover each other and converge server lists within 60s
- [ ] `GET /servers` response contains NO `addr` fields (verified by unit test)
- [ ] `GET /resolve/{id}` returns correct game server address for known servers
- [ ] `GET /resolve/{id}` returns 404 for unknown server IDs
- [ ] `/resolve` endpoint is rate-limited (10/min per source IP)
- [ ] Gossip merge keeps entry with newer `last_seen`; stale entries pruned within 90s
- [ ] Client Browse tab auto-fetches server list from configured community nodes on open
- [ ] Client can connect to a server by clicking Connect — no IP visible in UI at any point
- [ ] Browser shows server name, map, player count, mod list, approximate latency, and auth mode
- [ ] Favorites and recents work by server_id and survive server IP changes
- [ ] Community node state persists to `community_node.json` and resumes on restart
- [ ] Headless servers can manage community node via console commands
- [ ] Max 500 servers, 200 peers enforced; request bodies capped at 256 KB
- [ ] All validation passes: tags, region, seed addresses, server ID format
- [ ] Existing discovery relay (`[Discovery]` config) continues to work independently

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

### v0.8.0-dev.2 — 2026-04-03 (draft)
- **CI hardening follow-up:** fixed strict clippy violations (`cloned_ref_to_slice_refs`) in community seed validation call sites.
- **Formatting normalization:** applied `cargo fmt` updates in server sources to match GitHub Actions `cargo fmt --check` output.
- **No behavior changes:** code path changes are mechanical/idiomatic only.
- Version bumped to `0.8.0-dev.2`.

### v0.8.0-dev.1 — 2026-04-04 (draft)
- **Community Node Discovery Mesh:** Decentralized P2P server discovery built into every HighBeam server. Server operators enable via GUI or console to join the mesh. Players browse and connect without knowing any IP addresses.
- **`community_node.rs`:** New module — HTTP listener, gossip loop (30s), merge logic, rate limiting (30/min all, 10/min /resolve), TTL pruning (servers 90s, peers 5min), caps (500 servers, 200 peers), persistence to `community_node.json`.
- **GUI Community tab:** Enable/disable, server ID display, port, region, tags, seed node management, live status (peer/server counts, last gossip, health).
- **Console commands:** `community enable/disable/status/port/region/tags/add-seed/remove-seed`.
- **browser.lua rewrite:** Community-node-based server browser replacing relay URL; sequential node fallback; serverId-aware favorites/recents; password modal; mod tooltip; ping color coding.
- **config.lua:** `relayUrl` → `communityNodes`.
- Version bumped to `0.8.0-dev.1`.

### v0.6.80-dev.1 — 2026-04-03 (draft)
- **JSON fallback fix (critical):** client Lua now checks BeamNG global `jsonEncode`/`jsonDecode` as the primary JSON encoder/decoder, fixing "JSON encode failed — no encoder available" that prevented all connections.
- **Bootstrap cleanup:** `scripts/modScript.lua` uses `rawget` to avoid false "extension unavailable" log errors; duplicate `scripts/highbeam/modScript.lua` replaced with no-op guard.
- Adopted dev-release workflow: internal test builds use `-dev.N` suffix and GitHub draft releases.

### v0.6.79 — 2026-04-03
- **Cargo fmt / clippy fixes:** resolved all formatting and lint warnings introduced in v0.6.78.
- Server and launcher versions bumped to `0.6.79`; protocol remains `v2`.

### v0.6.78 — 2026-04-02
- **Direct connect hardening:** browser now stays visible until a confirmed connection succeeds; bridge/direct-connect path guards missing connection subsystem access and surfaces connection/auth failure details back into the UI.
- **Config I/O hardening:** client config/browser directory creation fallbacks are now guarded so restricted BeamNG environments do not throw during save attempts.
- **Server map catalog refresh:** server now discovers both BeamNG default maps and mod maps on startup, keeps a unified canonical map catalog, and normalizes legacy aliases like `GridMap` and `ORV`.
- **GUI map UX:** server dashboard and other GUI map surfaces now show display names instead of raw `/levels/.../info.json` paths by default.
- **Maps/Mods tab cleanup:** Maps tab keeps the scrollable selection list but removes free-text map entry; Mods tab now reflects auto-discovered client mods without a source-path text field; redundant map control removed from Settings.
- **Discovery/relay polish:** discovery-facing map labels now use display names while preserving canonical internal map paths for protocol/state.
- Rebuilt `launcher/payload/highbeam.zip` with the latest client fixes.
- Server and launcher versions bumped to `0.6.78`; protocol remains `v2`.

### v0.6.77 — 2026-04-02
- **Critical bug fix:** `_connection` and `_config` local variables were declared after the bridge functions that reference them, causing `attempt to index global '_connection' (a nil value)` on Direct Connect. Moved all local variable declarations (`_connection`, `_config`, `_im`, `_ffi`, `_bufs`) above the bridge code block.
- **Windows directory creation fix:** `_ensureDir()` in both `browser.lua` and `config.lua` now detects Windows via `package.config` path separator and uses `mkdir` (no `-p` flag) with backslash paths. Falls back through `FS:directoryCreate` → `lfs.mkdir` → OS-specific `mkdir`.
- Rebuilt `launcher/payload/highbeam.zip` with all fixes.
- Launcher version bumped to `0.6.77`; server remains `0.6.4`; protocol remains `v2`.

### v0.6.76 — 2026-04-02
- **Payload zip rebuild:** Rebuilt `launcher/payload/highbeam.zip` with all v0.6.75 client fixes. Previous release edited source files but did not repackage the zip, so BeamNG was still running stale code.
- **Agent instructions update:** Added "Client Mod Deployment" section to `.copilot-instructions.md` requiring payload zip rebuild after every client edit.
- Launcher version bumped to `0.6.76`; server remains `0.6.4`; protocol remains `v2`.

### v0.6.75 — 2026-04-02
- **Critical bug fix:** `_readFile` was defined after its first call site in `browser.lua`, causing a nil-call crash on Direct Connect. Moved file I/O helpers (`_readFile`, `_writeFile`, `_ensureDir`) above the launcher IPC bridge code.
- **Config save hardening:** `config.lua` and `browser.lua` file I/O now guards `FS` method access, adds BeamNG global `readFile`/`writeFile` fallbacks, and uses `mkdir -p` fallback for directory creation. Fixes "Failed to save config" warning.
- **Extension loader fix:** `modScript.lua` (both copies) now uses `rawget(_G, 'setExtensionUnloadMode')` instead of a bare global access, preventing BeamNG from trying to auto-load a non-existent extension.
- **Quick access menu fix:** `highbeam.lua` menu registration now tries the single-arg `addEntry(entry)` form first (with `id` in the table), avoiding the "Menu item needs at least a title and an onSelect" warning.
- Launcher version bumped to `0.6.75`; server remains `0.6.4`; protocol remains `v2`.

### v0.6.5 — 2026-03-31
- **Launcher IPC bridge (Phase C):** launcher now starts a local TCP server (`127.0.0.1:0`) while BeamNG is running; writes port to `{beamng_userfolder}/highbeam-launcher.json`. In-game browser reads this file and sends a `join_request` before connecting, triggering per-server mod sync from within the running session.
- **In-game sync feedback:** browser shows "Syncing mods with launcher…" status while IPC sync is in progress; "mod sync failed" state offers an explicit "Connect anyway" button.
- **`--dry-run` mode:** new launcher flag prints resolved exe path, mods dir, and pending sync actions without downloading or launching the game.
- **Cache metadata enrichment:** `CacheEntry` now records `last_server` and `downloaded_at` (Unix timestamp) for diagnostics.
- **Critical bug fix:** `connection.lua` and `vehicles.lua` were calling `require("highbeam/lib/json")` which does not exist in the BeamNG mod environment. Both now use `Engine.JSONEncode/JSONDecode` with a `require("json")` fallback — packet encoding and remote vehicle spawning now work correctly.
- **Minor fix:** duplicate suffix in Recents tab IMGUI row ID removed.
- Launcher version bumped to `0.6.5`; server remains `0.6.4`; protocol remains `v2`.
- All 13 launcher tests + 55 server tests passing; zero clippy warnings at `-D warnings`.

### v0.6.1 — 2026-03-30
- Added in-game server browser (IMGUI, 4 tabs: Direct Connect / Browse Servers / Favorites / Recent).
- Server browser auto-opens on extension load; closes automatically on successful connect.
- Relay HTTP fetch, per-server UDP ping, favorites/recents persisted to `userdata/highbeam/` JSON files.
- Config save/load (`config.json`) — username, last host/port, relay URL remembered between sessions.
- Bug fixes (hardening sweep): HTTP partial-body truncation, URL normalization, blocking ping timeout (2 s → 0.5 s, capped to 8 servers), connect-while-connected guard, IMGUI row ID uniqueness, server name propagation to favorites and recents.
- CI/release workflow fixes: added `libdbus-1-dev` install step for Linux builds (tray-item dependency); fixed `TrayItem::new` second argument to use `IconSource::Resource` (tray-item 0.10 API change).
- Server and launcher version bumped to `0.6.1`; protocol remains `v2`.

### v0.6.0 — 2026-03-30
- Server GUI and discovery release completed.
- Added egui/eframe desktop GUI with 7-tab layout (Dashboard, Players, Maps, Mods, Plugins, Console, Settings).
- Added ControlPlane admin abstraction, persistence (state save/restore on shutdown/startup), and discovery relay registration.
- Added UDP discovery query endpoint (0x7A) and launcher-side relay fetch and favorites/recents CLI flows.
- Added JSON protocol benchmark harness (`--protocol-benchmark` mode).
- Server and launcher version: `0.6.0`; protocol remains `v2`.
- **Note:** In-game client join UI was not delivered in v0.6.0 — connecting requires a manual GE Lua console call. This gap is addressed in v0.6.1.

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
