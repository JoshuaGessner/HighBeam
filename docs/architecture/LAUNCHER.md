# HighBeam Launcher Architecture

> **Last updated:** 2026-08-24
> **Applies to:** v0.8.2-dev.54
> **Parent doc:** [OVERVIEW.md](OVERVIEW.md)

---

## Overview

The HighBeam Launcher is a lightweight Rust desktop/CLI companion that handles mod
management, game launching, join IPC, and the active session's localhost TCP/UDP
proxy. It auto-detects BeamNG.drive installations from Steam and self-updates from
GitHub Releases. It remains alive until the game exits so it can service in-game join
requests, report readiness, route network traffic, and clean up staged mods.

```
┌──────────────────────────────────────────────────┐
│            HighBeam Launcher (Rust CLI)           │
│                                                  │
│  On every startup:                               │
│    1. Recover / clean up stale session mods      │
│    2. Self-update check (--no-update to skip)    │
│                                                  │
│  When --server <addr> is provided (join intent): │
│    3. Install/update HighBeam client mod         │
│    4. Connect to server (TCP mod-transfer port)  │
│    5. Query required mods (mod_list handshake)   │
│    6. Compare SHA-256 hashes with local cache    │
│    7. Download missing mods (raw binary TCP)     │
│    8. Stage mods into BeamNG mods dir            │
│       (prefix: highbeam-session-*)              │
│    9. Write session manifest JSON                │
│   10. Start localhost TCP/UDP proxy + IPC        │
│   11. Launch and monitor BeamNG.drive            │
│   12. Service join-sync/readiness during play    │
│   13. Stop proxy and clean staged session mods   │
│   14. Exit                                       │
└──────────────────────────────────────────────────┘
```

### Why a Launcher?

BeamNG's GE Lua runtime does not provide reliable filesystem write access. The in-game Lua environment is sandboxed — `io.open` and similar calls may not work for writing arbitrary files to the mods directory. A native binary is required to:

- Write `.zip` files to `%LOCALAPPDATA%/BeamNG.drive/mods/`
- Perform efficient binary TCP downloads without per-frame polling limitations
- Provide download progress UI outside the game

### Design Rationale

| Aspect | HighBeam Launcher |
|--------|-------------------|
| **Role** | Mod sync, game launch/monitoring, join IPC, proxy relay, and cleanup |
| **Network proxy** | Yes — session-scoped localhost TCP/UDP relay to the selected server |
| **Authentication** | No auth role — server-local auth handled by client mod |
| **Mod injection** | Writes client mod to mods directory (standard BeamNG mod loading) |
| **Lifetime** | Stays running during session for IPC and proxy relay, cleans up on exit |
| **Language** | Rust (same toolchain as server) |

---

## Directory Structure

```
launcher/
├── src/
│   ├── main.rs             # Entry point, CLI argument parsing, join-gated sync flow
│   ├── config.rs           # Launcher configuration (server address, BeamNG path)
│   ├── detect.rs           # BeamNG.drive auto-detection (Steam libraries, userfolder)
│   ├── installer.rs        # Mod installation, session staging manifest, cleanup
│   ├── ipc.rs              # In-game IPC bridge (localhost TCP for join-sync handshake)
│   ├── proxy.rs            # Session-scoped localhost TCP/UDP relay to remote server
│   ├── mod_sync.rs         # Mod download: mod_list handshake + raw binary TCP download
│   ├── mod_cache.rs        # Local cache management (SHA-256 hashes, file tracking)
│   ├── discovery.rs        # Server query (UDP 0x7A) and relay HTTP browsing
│   ├── transfer.rs         # Raw binary TCP mod transfer framing protocol
│   ├── updater.rs          # Self-update from GitHub Releases
│   └── game.rs             # BeamNG.drive detection and launch
├── Cargo.toml
└── LauncherConfig.toml     # User configuration
```

---

## Mod Sync Flow

### 1. Pre-flight

```
Launcher                              Server
  │                                      │
  │──── TCP Connect ────────────────────►│
  │                                      │
  │◄──── ModList ──────────────────────│
  │      [{name, size, hash}, ...]       │
  │                                      │
  │  [Compare hashes with local cache]   │
  │                                      │
  │──── ModRequest ────────────────────►│
  │     [names of mods needed]           │
  │                                      │
```

### 2. Binary Transfer

For each requested mod, the server streams the file over TCP using a simple binary framing protocol:

```
┌───────────────────┬────────────────┬────────────────────────────┐
│  Name length (2B) │  Name (UTF-8)  │  File size (8B, u64 LE)    │
│  uint16 LE        │  variable      │                            │
├───────────────────┴────────────────┴────────────────────────────┤
│                Raw file bytes (streamed)                         │
└─────────────────────────────────────────────────────────────────┘
```

- No base64 encoding — raw bytes for zero overhead
- Streamed in chunks — the launcher writes directly to a temp file as data arrives
- After the full file is received, SHA-256 hash is verified against the expected hash
- On success, the file is moved to the BeamNG mods directory and the cache is updated
- On hash mismatch, the download is discarded and retried once

### 3. Post-sync & Session Staging

Before launching the game:
1. Each downloaded mod zip is run through the **mod sandbox scanner** (v0.9.0): ZIP content validation (path traversal, file type whitelist, zip bomb detection, compression ratio checks) and Lua static analysis (regex-based detection of dangerous APIs like `os.execute`, `io.popen`, `ffi.cdef`, `loadstring`, etc.). Mods that fail the scan are NOT installed and the user is warned.
2. Server mods that pass the scan are copied from cache into BeamNG's mods directory with a `highbeam-session-{original_name}` filename prefix.
2. A session manifest (`highbeam-session-manifest.json`) is written alongside the staged files, listing all staged filenames.
3. The HighBeam client mod zip is installed if missing or outdated.
4. BeamNG.drive is launched.
5. After the game exits, the launcher reads the session manifest and removes all staged files, then deletes the manifest.
6. The launcher cache is **not** touched on cleanup — cached files remain for future sessions.

> **Stale session recovery:** If the launcher crashed or was killed mid-session, the next startup detects an existing `highbeam-session-manifest.json` and runs cleanup before proceeding. This ensures no orphaned server mods persist in BeamNG's mods directory.

---

## Mod Cache

The launcher maintains a local mod cache to avoid re-downloading mods that haven't changed.

**Cache location:** `~/.highbeam/cache/` (or `%LOCALAPPDATA%/HighBeam/cache/` on Windows)

**Cache index file:** `cache_index.json`
```json
{
  "mods": {
    "cool_map.zip": {
      "hash": "sha256:abc123...",
      "size": 524288000,
      "last_server": "192.168.1.100:18860",
      "downloaded_at": "2026-03-29T12:00:00Z"
    }
  }
}
```

**Cache behavior:**
- Before downloading, check if the mod exists in cache with a matching hash
- If cached, copy or symlink from cache to mods directory (instant)
- If not cached, download from server, save to both cache and mods directory
- Cache entries are per-hash (same mod from different servers shares a cache entry if same hash)
- Old cache entries can be pruned manually or via `highbeam-launcher cache clean`

---

## Configuration

### LauncherConfig.toml

```toml
server_addr = "127.0.0.1:18860"
mod_sync_addr = ""
cache_dir = "~/.highbeam/cache"

# Leave empty to auto-detect BeamNG from Steam.
beamng_exe = ""
beamng_userfolder = ""

# BeamNG 0.39 Windows default. BeamNG falls back to D3D11 when D3D12 is
# unavailable. Troubleshooting overrides: "dx11", "vulkan", or "auto".
graphics_api = "d3d12"

query_timeout_ms = 1500
connect_timeout_sec = 10
max_cache_size_mb = 2048
```

`graphics_api = "auto"` is the only mode that omits the `-gfx` argument and
therefore permits BeamNG's existing persisted renderer selection. HighBeam's Windows
default is explicit `-gfx d3d12` so an old Vulkan preference cannot silently carry
forward when the BeamNG launcher screen is bypassed.

### CLI Usage

```
highbeam-launcher [OPTIONS]

OPTIONS:
    --server <HOST:PORT>            Join a server: sync mods, launch game
    --beamng <PATH>                 Path to BeamNG.drive executable
    --no-launch                     Sync mods but don't launch the game
    --cache-clean                   Remove old cache entries
    --no-update                     Skip self-update check
    --query-server <HOST:PORT>      Query a server's info (name, map, players) and exit
    --browse-relay <URL>            Fetch and print the server list from a relay URL (see docs/architecture/RELAY.md)
    --favorite-add <HOST:PORT>      Add a server to favorites
    --favorite-remove <HOST:PORT>   Remove a server from favorites
    --favorites                     List saved favorite servers
    --recent                        List recently connected servers
    --config <PATH>                 Path to config file (default: LauncherConfig.toml)
    --version                       Print version and exit
```

---

## Transfer Efficiency

| Metric | HighBeam |
|--------|----------|
| **Encoding** | Raw binary TCP stream — zero encoding overhead |
| **Download path** | Launcher connects directly to server's mod transfer port |
| **Throughput** | Limited only by network bandwidth |
| **Large mods (500MB+)** | Direct TCP stream, writes to disk as it arrives |
| **Caching** | SHA-256 cache with cross-server deduplication |
| **Resume** | Planned: byte-range resume for interrupted downloads |

---

## Security

- Mod files are verified via SHA-256 hash after download — corrupted or tampered files are discarded
- **Mod sandbox scanning** (v0.9.0): Before installation, every mod zip is run through a multi-layer scanner:
  - **ZIP content validation:** path traversal checks, symlink rejection, file extension whitelist (blocks `.exe`, `.dll`, `.sh`, `.bat`, etc.), zip bomb detection (entry count, uncompressed size, compression ratio), OS-reserved filename rejection
  - **Lua static analysis:** regex-based scanning of all `.lua` files for dangerous API calls (`os.execute`, `io.popen`, `ffi.cdef`, `loadstring`, `debug.*`, etc.), obfuscation detection (non-ASCII ratio, hex string chains, `string.char` abuse)
  - Mods that fail the scan are NOT installed; the user is warned with specific violation details
- **Mod manifest signing** (v0.9.0): Server signs the mod manifest with an Ed25519 key; launcher verifies signature using a trust-on-first-use (TOFU) model stored in `~/.highbeam/known_servers.json`
- **TLS enforcement** (v0.9.0): `RequireTlsForMods = true` (default) refuses plaintext mod downloads to prevent MITM injection
- The launcher only connects to servers the user explicitly specifies (no auto-discovery)
- Downloaded mod zips are written to BeamNG's standard mods directory — no code injection or process manipulation
- The launcher does not have elevated privileges and does not modify the game binary

---

## Session Staging & Cleanup

Server mods are never permanently installed — they are staged per session and cleaned up afterward:

| Stage | Location | Naming | Lifetime |
|-------|----------|--------|----------|
| Launcher cache | `~/.highbeam/cache/` | `<sha256>.zip` | Persistent (reused across sessions) |
| BeamNG mods (staged) | `%LOCALAPPDATA%/BeamNG.drive/mods/` | `highbeam-session-<original>.zip` | Active join session only |
| Session manifest | BeamNG mods dir | `highbeam-session-manifest.json` | Active join session only |

This ensures:
- Deleting a mod from `Resources/Client/` on the server does not cause the cached copy to be reinstalled without an explicit join.
- A player joining server B does not have server A's unrelated mods left behind in their BeamNG folder.
- BeamNG's mods directory is clean after every session.

---
