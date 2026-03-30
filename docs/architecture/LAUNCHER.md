# HighBeam Launcher Architecture

> **Last updated:** 2026-03-29
> **Applies to:** v0.3.0 (planned)
> **Parent doc:** [OVERVIEW.md](OVERVIEW.md)

---

## Overview

The HighBeam Launcher is a lightweight Rust CLI that handles mod management and game launching. Unlike BeamMP's launcher, it is **not a network proxy** — it performs setup work, launches the game, and exits.

```
┌──────────────────────────────────────────────────┐
│            HighBeam Launcher (Rust CLI)           │
│                                                  │
│  1. Install/update HighBeam client mod           │
│  2. Connect to target server (TCP)               │
│  3. Query required mods (mod_list handshake)     │
│  4. Compare SHA-256 hashes with local cache      │
│  5. Download missing mods (raw binary TCP)       │
│  6. Write mod .zips to BeamNG mods directory     │
│  7. Launch BeamNG.drive                          │
│  8. Exit                                         │
└──────────────────────────────────────────────────┘
```

### Why a Launcher?

BeamNG's GE Lua runtime does not provide reliable filesystem write access. The in-game Lua environment is sandboxed — `io.open` and similar calls may not work for writing arbitrary files to the mods directory. A native binary is required to:

- Write `.zip` files to `%LOCALAPPDATA%/BeamNG.drive/mods/`
- Perform efficient binary TCP downloads without per-frame polling limitations
- Provide download progress UI outside the game

### How It Differs from BeamMP's Launcher

| Aspect | BeamMP Launcher | HighBeam Launcher |
|--------|----------------|-------------------|
| **Role** | Always-running network proxy between game and server | One-shot mod sync + game launch, then exits |
| **Network proxy** | Yes — all game traffic routed through launcher | No — client mod connects directly to server |
| **Authentication** | Handles Discord OAuth with centralized backend | No auth role — server-local auth handled by client mod |
| **Mod injection** | Injects client mod into game at runtime | Writes client mod to mods directory (standard BeamNG mod loading) |
| **Lifetime** | Runs for entire play session | Exits after launching the game |
| **Language** | C++ | Rust (same toolchain as server) |

---

## Directory Structure

```
launcher/
├── src/
│   ├── main.rs             # Entry point, CLI argument parsing
│   ├── config.rs           # Launcher configuration (server address, BeamNG path)
│   ├── mod_sync.rs         # Mod download and caching logic
│   ├── mod_cache.rs        # Local cache management (hashes, file tracking)
│   ├── transfer.rs         # Raw binary TCP mod transfer protocol
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

### 3. Post-sync

After all mods are synced:
1. Launcher writes the HighBeam client mod zip (bundled in the launcher binary or from a known path) to the mods directory if it's missing or outdated
2. Launcher starts BeamNG.drive (auto-detected or user-configured path)
3. Launcher exits — it does not stay running

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
[General]
# Path to BeamNG.drive (auto-detected if not set)
# BeamNGPath = "C:/Program Files (x86)/Steam/steamapps/common/BeamNG.drive"

# Where to cache downloaded mods
CacheDir = "~/.highbeam/cache"

# Maximum concurrent mod downloads (future)
# MaxConcurrentDownloads = 2

[Server]
# Default server to connect to (can be overridden via CLI)
Host = ""
Port = 18860
```

### CLI Usage

```
highbeam-launcher [OPTIONS]

OPTIONS:
    --server <HOST:PORT>    Server to sync mods from and connect to
    --beamng <PATH>         Path to BeamNG.drive executable
    --no-launch             Sync mods but don't launch the game
    --cache-clean           Remove old cache entries
    --version               Print version and exit
```

---

## Transfer Efficiency vs BeamMP

| Metric | BeamMP | HighBeam |
|--------|--------|----------|
| **Encoding** | Binary through C++ launcher proxy | Raw binary TCP stream — zero encoding overhead |
| **Download path** | Launcher proxy relays from server | Launcher connects directly to server's mod transfer port |
| **Throughput** | Bottlenecked by proxy overhead | Limited only by network bandwidth |
| **Large mods (500MB+)** | Works but slow through proxy | Direct TCP stream, writes to disk as it arrives |
| **Caching** | Launcher caches in its own directory | SHA-256 cache with cross-server deduplication |
| **Resume** | No resume support | Planned: byte-range resume for interrupted downloads |

---

## Security

- Mod files are verified via SHA-256 hash after download — corrupted or tampered files are discarded
- The launcher only connects to servers the user explicitly specifies (no auto-discovery)
- Downloaded mod zips are written to BeamNG's standard mods directory — no code injection or process manipulation
- The launcher does not have elevated privileges and does not modify the game binary

---

## Future Enhancements

- **Download resume**: Track bytes received; on reconnect, request remaining bytes from offset
- **Parallel downloads**: Download multiple mods simultaneously
- **Auto-update**: Launcher checks for newer versions of itself on startup
- **GUI mode**: Optional GUI wrapper for less technical users (egui, consistent with server GUI)
- **Mod management UI**: Show installed mods, cache usage, clean up old mods
