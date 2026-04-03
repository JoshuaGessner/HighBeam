# HighBeam

**Decentralized multiplayer for BeamNG.drive.**

HighBeam lets you host and join real-time multiplayer sessions in BeamNG.drive — no third-party accounts, no always-running background software, no central authority.

---

## What You Get

- **In-game server browser** — Browse public servers, save favorites, and reconnect to recent sessions from an in-game menu. No launcher interaction needed after initial setup.
- **Direct connect** — Type any server IP and port and hit Connect. No accounts or keys.
- **Mod sync** — The launcher downloads required mods from the server automatically before the game starts.
- **Password & allowlist auth** — Server operators can run open, password-protected, or allowlist-only servers.
- **Server-side plugins** — Server operators can customize gameplay with Lua 5.4 scripts (chat commands, game modes, custom events).
- **Server management GUI** — Desktop window with live dashboard, player/map/mod/plugin management, and console.
- **Optional public server listing** — Servers can optionally register with community relay URLs to appear in the in-game browser. No central service required.

---

## Current Status — v0.6.79 (In Progress)

| Feature | Status |
|---------|--------|
| TCP connection & authentication | ✅ Done |
| Real-time vehicle sync (UDP, 20 Hz) | ✅ Done |
| Chat | ✅ Done |
| Mod distribution via launcher | ✅ Done |
| Password & allowlist auth | ✅ Done |
| Server-side Lua plugins | ✅ Done |
| Auto-update (server & launcher) | ✅ Done |
| BeamNG.drive auto-detection (Steam) | ✅ Done |
| Server management GUI (egui) | ✅ Done |
| Optional TLS | ✅ Done |
| Docker & systemd deployment | ✅ Done |
| In-game server browser (Direct Connect, Browse, Favorites, Recent) | ✅ Done |
| Community relay server listing | ✅ Done |
| More menu button (in-game quick access) | ✅ Done |
| Join-scoped mod sync (session staging & cleanup) | ✅ Done |
| Server GUI close-to-tray & graceful quit | ✅ Done |
| Binary protocol (bandwidth optimization) | 📋 v0.7.0 |
| Stable v1.0.0 release | 🔭 Target |

---

## Quick Start

### Playing on a Server

1. Download the latest **launcher** from the [Releases page](https://github.com/JoshuaGessner/HighBeam/releases/latest) and unzip it.
2. Run the launcher with your server’s address:
   ```
   highbeam-launcher.exe --server <server-ip>:18860
   ```
3. The launcher downloads only the mods required by that specific server, installs them as a temporary session, and launches BeamNG.drive.
4. The **HighBeam Multiplayer** browser window opens in-game. Enter your username and the server address, then click **Connect**.
5. When the game exits, the launcher automatically removes the session-staged server mods from your BeamNG mods folder (downloaded files stay in the launcher cache for future joins).

> If BeamNG.drive is not on Steam, set `beamng_exe` in `LauncherConfig.toml` to the full path of the BeamNG.drive executable.

### In-Game Browser

Once in BeamNG, the HighBeam window opens automatically with four tabs:

| Tab | What it does |
|-----|--------------|
| **Direct Connect** | Type a host, port, username, and optional password and connect directly |
| **Browse Servers** | Enter a relay URL and click Refresh to see public servers with live ping |
| **Favorites** | One-click connect to saved servers |
| **Recent** | Reconnect to previously visited servers |

Your username, last server address, and relay URL are remembered between sessions.

The browser can be reopened any time from the BeamNG **More** menu (look for **HighBeam Multiplayer** in the quick-access list), or from the GE console:
```lua
extensions.highbeam.openBrowser()
```

### Hosting a Server

1. Download the latest **server** from the [Releases page](https://github.com/JoshuaGessner/HighBeam/releases/latest).
2. Edit `ServerConfig.toml` to set your server name, max players, and auth mode.
3. Run `highbeam-server` (or `highbeam-server.exe` on Windows).
   - Add `--headless` for Docker/systemd deployments.

The server opens a GUI window by default. **Closing the window hides it to the system tray** — the server keeps running. Right-click the tray icon and choose **Quit** to stop the server fully. On Windows, the release build suppresses the CLI console window entirely. Port **18860** (TCP + UDP) must be open in your firewall.

#### Key config options

```toml
[Server]
Name        = "My HighBeam Server"
Port        = 18860
MaxPlayers  = 16
AuthMode    = "open"      # open | password | allowlist
Password    = ""
Map         = "/levels/gridmap_v2/info.json"
```

For Linux servers, a `highbeam-server.service` systemd unit and a `docker-compose.yml` are included in the release archive.

---

## Platform Support

| Component | Windows | Linux | macOS |
|-----------|---------|-------|-------|
| Server | ✅ | ✅ | ✅ |
| Launcher | ✅ | ✅ | ✅ |
| Client mod | ✅ (BeamNG.drive) | — | — |

> BeamNG.drive is Windows-only, so the client mod only runs on Windows. The server and launcher run on all three platforms.

---

## Roadmap

| Version | Milestone | Status |
|---------|-----------|--------|
| v0.1.0 | TCP handshake + auth | ✅ Done |
| v0.2.0 | Real-time vehicle sync | ✅ Done |
| v0.3.0 | Chat, mod distribution, launcher | ✅ Done |
| v0.4.x | Server-side Lua plugins, auto-update, auto-detection | ✅ Done |
| v0.5.0 | Stability & deployment polish | ✅ Done |
| v0.6.x | Server GUI, discovery, in-game browser, join-scoped mod sync | 🔧 In Progress (v0.6.79) |
| v0.7.0 | Binary protocol (bandwidth optimization) | 📋 Next |
| v1.0.0 | Stable release | 🔭 Target |

---

## License

GNU GPLv3 — see [LICENSE](LICENSE).
