# HighBeam Production Roadmap

**Last Updated:** 2026-03-30  
**Current Phase:** Phase 2 (Error Handling & Client Stability) - ⏳ IN PROGRESS  
**Next Phase:** Phase 2 continued (7 tasks remaining)  
**Target Completion:** Phase 2 by 2026-03-31

---

## Overview

HighBeam production hardening follows a 4-phase plan:
- **Phase 1 ✅ IMPLEMENTED** - Critical server fixes (timeouts, validation, rate limiting, logging)
- **Phase 2 ⏳ PLANNED** - Client stability & error handling (up next)
- **Phase 3** - Resource management & monitoring  
- **Phase 4** - Testing & stress testing

This document tracks implementation status and provides a clear roadmap for reaching production readiness.

---

## Phase 1 ✅ - Critical Fixes (IMPLEMENTED)

**Status:** Code complete and compiled ✅ | Testing pending ⏳

All 8 critical production fixes have been implemented, committed, and pushed. Code compiles successfully with no errors. Awaiting manual testing of checklist items before moving to Phase 2.

### 1. TCP Socket Keepalive & Idle Timeout Enforcement ✅

**What was added:**
- TCP keepalive enabled on all client connections
- 60-second idle timeout enforced in receive loop
- 15-second read timeout per packet (prevents hanging)
- Automatic cleanup of idle connections

**Files modified:**
- `server/src/net/tcp.rs` - Added idle tracking and timeouts

**Impact:** Prevents zombie connections and detects dead clients

---

### 2. Graceful Shutdown with Signal Handlers ✅

**What was added:**
- SIGTERM and SIGINT handlers
- Broadcast shutdown channel (prepared for future graceful shutdown phases)
- Server logs shutdown initiation

**Files modified:**
- `server/src/main.rs` - Signal handler implementation

**Impact:** Server can be stopped cleanly with Ctrl+C or `systemctl stop`

---

### 3. Comprehensive Input Validation ✅

**What was added:**
- New `validation.rs` module with validation functions:
  - `validate_username()` - 1-32 chars, no control chars, no reserved names
  - `validate_password()` - max 256 chars
  - `validate_chat_message()` - 1-200 chars, limits control chars
  - `validate_vehicle_id()` - must be ≤ 10000
  - `validate_vehicle_config_size()` - max 1MB payload
  - `validate_server_config()` - validates port, player counts, tick rates, auth modes

**Validation applied to:**
- Username during auth (rejects invalid, sends error response)
- Chat messages (silent drop + warning log)
- Vehicle operations (silent drop + warning log)
- Config file at startup (fails to start with error)

**Files modified:**
- `server/src/validation.rs` (new)
- `server/src/main.rs` - Config validation at startup
- `server/src/net/tcp.rs` - Username validation in auth handler

**Impact:** Prevents malformed data, DOS attacks with huge payloads, invalid config deployments

---

### 4. Rate Limiter Enforcement ✅

**What was added:**
- Auth attempts: 5 per 60 seconds per IP address
- Chat messages: 10 per 10 seconds per player
- Vehicle spawns: 5 per 5 seconds per player
- All limits checked before processing (silent drop + warning)

**Files modified:**
- `server/src/net/tcp.rs` - Rate limiting checks integrated into TCP loop
- Rate limiter instantiated in TCP listener

**Impact:** Prevents spam, brute force attacks, and client-side DOS attempts

---

### 5. Vehicle Ownership Validation ✅

**What was added:**
- Validation on vehicle ID bounds before operation
- Existing ownership checks already in place (reinforced with logging)

**Files modified:**
- `server/src/net/tcp.rs` - Added ID validation before edit/delete/reset

**Impact:** Prevents vehicles with invalid IDs and improves error diagnostics

---

### 6. Session Token Collision Safety ✅

**What was added:**
- Token entropy increased from 32 bytes → 64 bytes
- Timestamp prepended to token (nano second precision)
- Explicit collision detection that retries on collision (paranoia safety)

**Files modified:**
- `server/src/session/manager.rs` - Enhanced token generation with entropy + timestamp

**Impact:** Practically eliminates session token collision risk

---

### 7. Config Validation at Startup ✅

**What was added:**
- Server refuses to start if:
  - MaxPlayers is 0 or > 1000
  - MaxCarsPerPlayer is 0 or > 100
  - Port is 0
  - TickRate is 0 or > 120 Hz
  - Auth mode is invalid (not "open", "password", or "allowlist")
  - Auth mode is "password" but no password configured
  - Auth mode is "allowlist" but allowlist is empty

**Files modified:**
- `server/src/validation.rs` - `validate_server_config()` function
- `server/src/main.rs` - Validation call before starting listeners

**Impact:** Prevents misconfigured servers from going live

---

### 8. File Logging ✅

**What was added:**
- Log file creation with daily rotation
- Configurable log level (from config or env var)
- Combined stderr + file logging
- Non-blocking file writes (won't block network I/O)

**Logging flow:**
- Config specifies log file name in `[Logging]` section
- If `LogFile` is empty, only console logging
- If `LogFile` is set (e.g., `"server.log"`), daily rotation with `server.log.2026-03-30` naming
- Log level from config or `RUST_LOG` env var

**Files modified:**
- `server/src/main.rs` - Logging initialization with file support
- `server/Cargo.toml` - Added `tracing-appender` dependency

**Impact:** Persistent logs for debugging, auditing, monitoring

---

## Dependency Changes

```toml
# Added dependencies:
tracing-appender = "0.2"       # File logging with rotation
```

---

## Testing Checklist for Phase 1

**Status: PENDING** - All features implemented, require manual verification

- [ ] **Server startup** - Starts without config (uses defaults)
- [ ] **Config validation** - Server refuses to start with invalid auth mode
- [ ] **Logging** - Server creates daily log files when configured
- [ ] **Connection timeouts** - Idle connections close after 60 seconds
- [ ] **Auth rate limit** - 6th attempt within 60s is rejected
- [ ] **Chat rate limit** - 11th message within 10s is dropped
- [ ] **Spawn rate limit** - 6th spawn within 5s is dropped
- [ ] **Username validation** - Invalid (empty, too long, reserved) rejected with error
- [ ] **Chat validation** - Invalid (empty, >200 chars, spam) silently dropped
- [ ] **Graceful shutdown** - Server shuts down cleanly on SIGTERM/SIGINT
- [ ] **Log rotation** - Log files created and rotated daily
- [ ] **Vehicle ID validation** - IDs > 10000 rejected
- [ ] **Vehicle config validation** - Configs > 1MB rejected
- [ ] **Config auth mode** - Invalid mode fails at startup
- [ ] **Config password mode** - Fails if password mode but no password

**Action:** Run manual tests or set up automated test suite before Phase 2

---

## Known Issues Addressed

1. **Connection Timeout Handling** - FIXED: Idle connections now close
2. **Input Validation** - FIXED: All inputs validated with size limits
3. **File Logging** - FIXED: Daily rotating logs implemented
4. **Graceful Shutdown** - FIXED: Signal handlers added
5. **Rate Limiting** - FIXED: Applied to auth/chat/spawn
6. **Vehicle Ownership** - FIXED: ID bounds checked
7. **Session Tokens** - FIXED: Enhanced entropy + collision detection
8. **Config Validation** - FIXED: Validates all constraints at startup

---

## Phase 2 ⏳ - Error Handling & Client Stability (IN PROGRESS)

**Target Effort:** 3-4 hours  
**Priority:** HIGH - Prevents crashes and improves user experience  
**Status:** Specification complete, 2/8 tasks implemented (server-side heartbeat done, client pending)

**Tasks Completed:** 1/8
- [x] 2.1: Client connect timeout (0.5h) ✅ DONE

### 2.1 Client-Side Connection Timeout (Lua)

**Problem:** Lua client has no timeout when connecting to unreachable servers; hangs indefinitely  

**Solution:**
- Add 5-second connect timeout to `connection.lua`
**Tasks:**
- [x] Add `CONNECT_TIMEOUT = 5` constant to connection module
**Files to modify:** `client/lua/ge/extensions/highbeam/connection.lua`

**Status:** ✅ IMPLEMENTED (commit a59dc07)

---
### 2.2 Heartbeat/Ping-Pong Protocol

**Problem:** Dead connections aren't detected until timeout (60s is too long)  

**Solution:**

**Server side (Rust):**
**Client side (Lua):**
**Tasks:**

*Server tasks:*
 [x] Add `PingPong { seq: u32 }` packet variant to `packet.rs` ✅
 [x] Update protocol version to 2 ✅
 [x] Add ping tracking to `Player` struct (last_pong_time) ✅
### 2.3 Packet Parsing Validation

**Problem:** Malformed JSON packets crash the game or cause silent failures  

**Solution:**
- Validate packet structure before use
- Check required fields exist and have correct types
- Provide error messages instead of crashes

**Tasks:**
- [ ] Add `serde` validation errors (already integrated)
- [ ] Wrap all packet parsing in Try/Catch in Lua
- [ ] Log parse errors with hex dump of bad packet
- [ ] Gracefully disconnect on parse error
- [ ] Add fuzzing test corpus of malformed packets

**Files to modify:**
- `server/src/net/tcp.rs` - Better error messages on parse failure
- `client/lua/ge/extensions/highbeam/connection.lua` - JSON parse error handling
- `client/lua/ge/extensions/highbeam/protocol.lua` - Validation layer

---

### 2.4 Lua Error Handling with pcall Wrappers

**Problem:** Lua errors in callbacks crash the extension instead of logging gracefully  

**Solution:**
- Wrap all network callbacks in `pcall()`
- Log errors instead of crashing
- Continue running even if one subsystem fails

**Tasks:**
- [ ] Wrap `_processBuffer()` in pcall
- [ ] Wrap `_onPacket()` dispatch in pcall per packet type
- [ ] Wrap all `require()` calls in pcall with fallback
- [ ] Add error callback to logging system
- [ ] Test by injecting bad JSON

**Files to modify:**
- `client/lua/ge/extensions/highbeam/connection.lua` - All callbacks
- `client/lua/ge/extensions/highbeam.lua` - Module loading

---

### 2.5 Vehicle Interpolation (Lerp/Slerp)

**Problem:** Remote vehicles teleport between position updates instead of moving smoothly  

**Solution:**
- Keep 2-3-frame buffer of position updates
- Interpolate between old and new position
- Use spherical linear interpolation (slerp) for rotation
- Target ~50ms interpolation window

**Tasks:**
- [ ] Add interpolation buffer to `vehicles.lua` (per vehicle)
- [ ] Implement `lerp(v1, v2, t)` for positions
- [ ] Implement `slerp(q1, q2, t)` for rotations
- [ ] Store update timestamps
- [ ] Calculate interpolation factor from frame delta time
- [ ] Apply interpolated transform each frame

**Files to modify:**
- `client/lua/ge/extensions/highbeam/vehicles.lua` - Interpolation logic
- `client/lua/ge/extensions/highbeam/math.lua` (new) - Lerp/slerp helpers

---

### 2.6 Connection State Machine Consistency

**Problem:** Connection state can become inconsistent if callbacks fail or race conditions occur  

**Solution:**
- Validate state transitions (only legal transitions allowed)
- Add state guard to critical operations
- Log state mismatches as warnings

**Tasks:**
- [ ] Add state transition validation
- [ ] Create state diagram in comments
- [ ] Add guards: "only in CONNECTED state" checks
- [ ] Log illegal transitions with stack trace
- [ ] Test rapid connect/disconnect cycles

**Files to modify:**
- `client/lua/ge/extensions/highbeam/connection.lua` - State validation

---

### 2.7 Chat Logging (When Enabled)

**Problem:** Chat messages aren't logged even when config flag is set  

**Solution:**
- If `LogChat` is true in config, write chat to server logs
- Format: `[CHAT] <player_name>: <text>`
- Include timestamp and player_id

**Tasks:**
- [ ] Check `config.logging.log_chat` flag in TCP loop
- [ ] Format and log ChatMessage packets
- [ ] Create separate `chat.log` file or mix into `server.log`
- [ ] Test with different log levels

**Files to modify:**
- `server/src/net/tcp.rs` - Log chat when flag set

---

### 2.8 Username Emptiness Check at Session Creation

**Problem:** Session can be created with empty username (already validated at auth, but double-check)  

**Solution:**
- Add runtime check in `add_player()` before creating session
- Reject if name is empty/whitespace only

**Tasks:**
- [ ] Add check in `SessionManager::add_player()`
- [ ] Return error instead of panicking
- [ ] Log rejected usernames

**Files to modify:**
- `server/src/session/manager.rs` - Add runtime check

---

### Phase 2 Summary Table

| Task | File | Effort | Priority | Status |
|------|------|--------|----------|--------|
| Client connect timeout | connection.lua | 0.5h | HIGH | ✅ DONE |
| Heartbeat protocol | packet.rs, tcp.rs, connection.lua | 1.5h | HIGH | ⏳ IN PROGRESS (server ✅) |
| Packet parse validation | tcp.rs, connection.lua, protocol.lua | 0.5h | HIGH | 📋 TODO |
| Lua error handling | connection.lua, highbeam.lua | 0.5h | MEDIUM | 📋 TODO |
| Vehicle interpolation | vehicles.lua, math.lua | 1h | HIGH | 📋 TODO |
| Connection state validation | connection.lua | 0.5h | MEDIUM | 📋 TODO |
| Chat logging | tcp.rs | 0.25h | LOW | 📋 TODO |
| Username check | manager.rs | 0.25h | LOW | 📋 TODO |
| **TOTAL** | | **4.5h** | | **2/8 ✅** |

**Server Implementation Details (Commit 55a530a):**
- Added `PROTOCOL_VERSION = 2` constant in `packet.rs`
- Added `PingPong { seq: u32 }` packet enum variant
- Added `last_pong_time: Instant` field to Player struct in `player.rs`
- Added `SessionManager::get_player_mut()` method for mutable player access in `manager.rs`
- Implemented ping task in `tcp.rs`: spawns background task that sends PingPong every 20s with sequence number
- Implemented pong timeout detection: closes connection if no pong within 30s
- Implemented PingPong handler in receive_loop that updates `last_pong_time` when pong received
- Properly aborts ping task during connection cleanup
- ✅ Server compiles cleanly with heartbeat protocol v2

**Status:** ✅ Server-side IMPLEMENTED (55a530a), ⏳ Client-side PENDING

*Client tasks (pending):*
 [ ] Add PingPong handler to receive buffer processing in `connection.lua`
 [ ] Send pong response immediately when ping received
 [ ] Track last ping received time
 [ ] Close connection if no ping within 30s (pong_timeout)

---

### Phase 2 Acceptance Criteria

- [ ] All 8 tasks implemented
- [ ] Code compiles with no errors
- [ ] Client handles 5-second timeout gracefully
- [ ] Heartbeat successfully detects dead connections within 30s
- [ ] Malformed packets logged without crashing
- [ ] Vehicle movement smooth (no teleporting)
- [ ] Chat logging works when flag enabled
- [ ] Integration tests pass (Phase 4)

## Phase 3 - Resource Management & Monitoring (PLANNED)

**Target Effort:** 2-3 hours  
**Priority:** MEDIUM - Deployment readiness  
**Status:** Design phase

### Key Improvements

- **Bandwidth throttling** - Limit position update frequency per player
- **Memory cleanup** - Clear old connection attempts, purge old vehicle cache
- **Metrics logging** - Player count, message rate, vehicle count per interval
- **Log rotation policy** - Configurable retention and compression
- **Systemd service file** - Template for Linux production deployments
- **Docker support** - Dockerfile + docker-compose for containerized deployment

### Phase 3 Acceptance Criteria

- [ ] Systemd service file works on Linux
- [ ] Docker image builds and runs
- [ ] Memory stable over 1-hour test with 10 players
- [ ] Metrics logged at 1-minute intervals
- [ ] Old logs archived and compressed

---

## Phase 4 - Testing & Stress Testing (PLANNED)

**Target Effort:** 3-4 hours  
**Priority:** HIGH - Validation before 1.0 release  
**Status:** Test plan in progress

### Test Suites

**Unit Tests:**
- Validation functions (all inputs)
- Rate limiter logic (boundary conditions)
- Session token generation (entropy distribution)

**Integration Tests:**
- Full connect → auth → ready → disconnect cycle
- Multiple players joining/leaving
- Chat broadcast to all players
- Vehicle spawn/edit/delete propagation

**Stress Tests:**
- 50 concurrent players connecting
- 100 messages/second chat flood
- Vehicle position updates at max rate for 5 minutes
- Rapid connect/disconnect cycles

**Network Simulation Tests:**
- Packet loss scenarios
- High latency (500ms+)
- Connection resets mid-game
- UDP packet drops

### Phase 4 Acceptance Criteria

- [ ] All unit tests pass
- [ ] All integration tests pass
- [ ] 50-player load test completes without crashes
- [ ] Memory usage stays under 500MB
- [ ] Log files rotate correctly
- [ ] Recovery from network failures works
- [ ] No memory leaks detected (valgrind)

---

## Next Steps & Action Items

### Immediate (Next 4-5 hours)

1. **Complete Phase 1 Testing**
   - [ ] Run manual tests from Phase 1 checklist
   - [ ] Fix any issues found
   - [ ] Document results

2. **Begin Phase 2 Implementation**
   - [ ] Start with client connect timeout (quickest win)
   - [ ] Then heartbeat protocol (most complex)
   - [ ] Vehicle interpolation (visible impact)

3. **Git Workflow**
   - [ ] Create `phase-2-dev` branch for work-in-progress
   - [ ] Commit each task as it completes
   - [ ] Keep commits small and focused

### Mid-term (Over next 1-2 days)

- Complete Phase 2 and test with multiple clients
- Set up automated test suite (Phase 4 prep)
- Deploy to staging environment
- Run basic load test scenarios

### Long-term (Week 2+)

- Phase 3 resource management
- Phase 4 comprehensive testing
- Performance profiling and optimization
- Prepare for v1.0 release

---

## Git Status

**Last commit:** f77c603  
**Branch:** main  
**Status:** ✅ Phase 1 pushed to origin

```bash
# To start Phase 2:
git checkout -b phase-2-dev
cargo build  # Verify no new issues
```

---

## Summary: Path to Production

| Phase | Status | Tests | Est. Hours | Blocker? |
|-------|--------|-------|-----------|----------|
| Phase 1 | ✅ Implemented | ⏳ Pending | 4 | Needs testing |
| Phase 2 | ⏳ Ready | Not started | 4 | Phase 1 tests |
| Phase 3 | 📋 Planned | Not started | 3 | Phase 2 done |
| Phase 4 | 📋 Planned | Not started | 4 | Phase 3 done |
| **Total** | **⏳ In Progress** | | **15** | |

**Projected Production Ready:** April 2, 2026 (if work starts immediately)

---
