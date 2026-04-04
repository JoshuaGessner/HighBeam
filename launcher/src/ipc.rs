//! Launcher IPC server (Phase C).
//!
//! While BeamNG.drive is running, the launcher keeps a local TCP server bound
//! to `127.0.0.1:0` (OS-assigned port).  It writes the port number to a
//! well-known JSON file inside the BeamNG user-data folder so the in-game
//! HighBeam client mod can discover it.
//!
//! Protocol: newline-delimited JSON.
//!
//! Client → `{"type":"join_request","server":"host:port"}\n`
//! Server → `{"type":"sync_started","server":"…"}\n`
//! Server → `{"type":"sync_complete","server":"…"}\n`   OR
//!           `{"type":"sync_failed","server":"…","error":"…"}\n`

use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use std::time::Instant;

use anyhow::{Context, Result};
use serde::Serialize;

use crate::config::LauncherConfig;
use crate::installer;
use crate::mod_cache::{self, CacheIndex};
use crate::mod_sync;
use crate::proxy;

/// Filename written to the BeamNG user-data folder while the IPC server is up.
const IPC_STATE_FILE: &str = "highbeam-launcher.json";

/// How long to wait between failed/no-op `accept()` calls (milliseconds).
const POLL_SLEEP_MS: u64 = 100;
static IPC_JOIN_REQUEST_SEQ: AtomicU64 = AtomicU64::new(1);

// ─────────────────────────────── State file helpers ──────────────────────────

/// Content written to the IPC state file.
#[derive(Debug, Serialize)]
struct IpcStateFile {
    port: u16,
    pid: u32,
    version: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    proxy_tcp_port: Option<u16>,
    #[serde(skip_serializing_if = "Option::is_none")]
    proxy_udp_port: Option<u16>,
    #[serde(skip_serializing_if = "Option::is_none")]
    proxy_server: Option<String>,
}

/// Returns the path of the IPC state file inside the **version-specific**
/// BeamNG user-data directory.  BeamNG's VFS resolves `userdata/` relative
/// to the versioned folder (e.g. `0.38/userdata/`), NOT the userfolder root.
/// We derive it from `mods_dir` whose parent is the versioned directory.
pub fn ipc_state_file_path_from_mods_dir(mods_dir: &Path) -> PathBuf {
    mods_dir
        .parent()
        .unwrap_or(mods_dir)
        .join("userdata")
        .join(IPC_STATE_FILE)
}

/// Legacy helper: derive the IPC state file path from the resolved mods_dir.
/// Prefer `ipc_state_file_path_from_mods_dir` when the mods directory is known.
#[allow(dead_code)]
pub fn ipc_state_file_path(mods_dir: &Path) -> PathBuf {
    mods_dir
        .parent()
        .map(|p| p.join(IPC_STATE_FILE))
        .unwrap_or_else(|| mods_dir.join(IPC_STATE_FILE))
}

/// Write the IPC state file so the in-game client can discover the port.
#[allow(dead_code)]
pub fn write_state_file(path: &Path, port: u16) -> Result<()> {
    write_state_file_full(path, port, None, None, None)
}

/// Write the IPC state file with optional proxy port information.
pub fn write_state_file_full(
    path: &Path,
    port: u16,
    proxy_tcp_port: Option<u16>,
    proxy_udp_port: Option<u16>,
    proxy_server: Option<String>,
) -> Result<()> {
    tracing::info!(
        path = %path.display(),
        port,
        ?proxy_tcp_port,
        ?proxy_udp_port,
        pid = std::process::id(),
        "Writing IPC state file"
    );
    let state = IpcStateFile {
        port,
        pid: std::process::id(),
        version: env!("CARGO_PKG_VERSION"),
        proxy_tcp_port,
        proxy_udp_port,
        proxy_server,
    };
    let content = serde_json::to_string_pretty(&state).context("IPC state serialise")?;
    std::fs::write(path, &content)
        .with_context(|| format!("Failed to write IPC state file: {}", path.display()))
}

/// Remove the IPC state file if it exists.
pub fn cleanup_state_file(path: &Path) {
    if path.exists() {
        if let Err(e) = std::fs::remove_file(path) {
            tracing::warn!(
                error = %e,
                path  = %path.display(),
                "Failed to remove IPC state file"
            );
        }
    }
}

// ─────────────────────────────────── IPC loop ────────────────────────────────

/// Run the IPC server / game-monitoring loop.
///
/// Polls for game exit with `try_wait()` and accepts IPC connections in a
/// non-blocking loop.  Blocks until the game process exits.
pub fn run_ipc_loop(
    game_child: &mut std::process::Child,
    listener: &TcpListener,
    cfg: &LauncherConfig,
    cache_dir: &Path,
    active_proxy: &mut Option<proxy::ProxyHandle>,
) -> Result<()> {
    listener
        .set_nonblocking(true)
        .context("Failed to set IPC listener to non-blocking")?;

    tracing::info!("IPC server ready — listening for in-game join requests");

    loop {
        // ── Check whether the game has exited ────────────────────────────────
        match game_child.try_wait() {
            Ok(Some(status)) => {
                if status.success() {
                    tracing::info!("BeamNG.drive exited normally");
                } else {
                    tracing::warn!(
                        code = ?status.code(),
                        "BeamNG.drive exited with non-zero status"
                    );
                }
                break;
            }
            Ok(None) => {} // game still running
            Err(e) => {
                tracing::warn!(error = %e, "Failed to check game process status; exiting loop");
                break;
            }
        }

        // ── Accept an IPC connection (non-blocking) ───────────────────────
        match listener.accept() {
            Ok((stream, addr)) => {
                tracing::info!(%addr, "Accepted launcher IPC connection");
                if let Err(e) = handle_ipc_connection(stream, cfg, cache_dir, active_proxy) {
                    tracing::warn!(error = %e, "IPC connection error");
                }
            }
            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(POLL_SLEEP_MS));
            }
            Err(e) => {
                tracing::warn!(error = %e, "IPC accept error; retrying");
                std::thread::sleep(Duration::from_millis(POLL_SLEEP_MS));
            }
        }
    }

    Ok(())
}

// ─────────────────────────────── Request handling ────────────────────────────

fn handle_ipc_connection(
    mut stream: std::net::TcpStream,
    cfg: &LauncherConfig,
    cache_dir: &Path,
    active_proxy: &mut Option<proxy::ProxyHandle>,
) -> Result<()> {
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .context("Failed to set IPC stream read timeout")?;

    let mut line = String::new();
    BufReader::new(&stream)
        .read_line(&mut line)
        .context("Failed to read IPC request line")?;
    let line = line.trim();

    if line.is_empty() {
        return Ok(());
    }

    tracing::debug!(request = %line, "IPC request received");

    let value: serde_json::Value =
        serde_json::from_str(line).context("IPC request is not valid JSON")?;

    let req_type = value["type"].as_str().unwrap_or("");
    match req_type {
        "join_request" => handle_join_request(&mut stream, &value, cfg, cache_dir, active_proxy),
        other => {
            tracing::warn!(req_type = %other, "Unknown IPC request type; ignoring");
            Ok(())
        }
    }
}

fn handle_join_request(
    stream: &mut std::net::TcpStream,
    value: &serde_json::Value,
    cfg: &LauncherConfig,
    cache_dir: &Path,
    active_proxy: &mut Option<proxy::ProxyHandle>,
) -> Result<()> {
    let server = value["server"].as_str().unwrap_or("").to_string();
    if server.is_empty() {
        return send_response(
            stream,
            serde_json::json!({
                "type":  "sync_failed",
                "error": "join_request is missing the 'server' field"
            }),
        );
    }

    let join_req_id = IPC_JOIN_REQUEST_SEQ.fetch_add(1, Ordering::Relaxed);
    let join_started = Instant::now();
    tracing::info!(join_req_id, server = %server, "IPC: join request");

    // Acknowledge immediately so the client knows we got the request.
    send_response(
        stream,
        serde_json::json!({ "type": "sync_started", "server": &server }),
    )?;

    // Clean up any mods staged from a previous in-session join.
    if let Err(e) = installer::cleanup_staged_server_mods(cfg.beamng_userfolder.as_deref()) {
        tracing::warn!(error = %e, "Could not clean up previous staged mods before IPC sync");
    }

    // Load (or create) the cache index for this sync.
    let mut cache_index: CacheIndex = match mod_cache::load_index(cache_dir) {
        Ok(idx) => idx,
        Err(e) => {
            return send_response(
                stream,
                serde_json::json!({
                    "type":   "sync_failed",
                    "server": &server,
                    "error":  format!("Failed to load mod cache: {e}"),
                }),
            );
        }
    };

    // ----- Query server for mod sync capability -----
    let discovery_started = Instant::now();
    tracing::info!(
        join_req_id,
        server = %server,
        timeout_ms = cfg.query_timeout_ms,
        "IPC: querying server for mod sync capability"
    );
    let should_sync = match crate::discovery::query_server(&server, cfg.query_timeout_ms) {
        Ok(server_info) => {
            let discovery_ms = discovery_started.elapsed().as_millis();
            tracing::info!(
                join_req_id,
                server = %server,
                discovery_ms,
                mod_sync_port = ?server_info.mod_sync_port,
                name = %server_info.name,
                "IPC: server discovery succeeded"
            );
            if let Some(mod_sync_port) = server_info.mod_sync_port {
                let (host, _) = server.rsplit_once(':').unwrap_or((&server, "18860"));
                Some(format!("{host}:{mod_sync_port}"))
            } else {
                tracing::info!(server = %server, "Server has mod sync disabled; skipping mod download");
                if let Err(e) =
                    installer::cleanup_staged_server_mods(cfg.beamng_userfolder.as_deref())
                {
                    tracing::warn!(error = %e, "Failed to clean up staged mods");
                }
                None
            }
        }
        Err(e) => {
            let discovery_ms = discovery_started.elapsed().as_millis();
            tracing::warn!(
                join_req_id,
                error = %e,
                server = %server,
                discovery_ms,
                "Server discovery failed; falling back to default mod sync port"
            );
            let (host, _) = server.rsplit_once(':').unwrap_or((&server, "18860"));
            Some(format!("{host}:18861"))
        }
    };

    if let Some(mod_sync_endpoint) = should_sync {
        // ----- Mod sync -----
        let sync_result = mod_sync::sync_mods(
            &mod_sync_endpoint,
            cfg.connect_timeout_sec,
            cache_dir,
            &mut cache_index,
        );

        let report = match sync_result {
            Ok(r) => r,
            Err(e) => {
                tracing::warn!(error = %e, server = %server, "IPC-triggered mod sync failed");
                return send_response(
                    stream,
                    serde_json::json!({
                        "type":   "sync_failed",
                        "server": &server,
                        "error":  e.to_string(),
                    }),
                );
            }
        };

        tracing::info!(
            join_req_id,
            server            = %server,
            downloaded        = report.downloaded_mods,
            total_server_mods = report.total_server_mods,
            "IPC mod sync completed"
        );

        // ----- Stage mods into BeamNG mods dir -----
        match installer::install_all(
            cfg.beamng_userfolder.as_deref(),
            cache_dir,
            &cache_index,
            &report.server_mods,
        ) {
            Ok(_) => {
                mod_cache::evict_to_size(
                    cache_dir,
                    &mut cache_index,
                    cfg.max_cache_size_mb * 1024 * 1024,
                );
                let _ = mod_cache::save_index(cache_dir, &cache_index);
            }
            Err(e) => {
                tracing::warn!(error = %e, "IPC mod install failed");
                return send_response(
                    stream,
                    serde_json::json!({
                        "type":   "sync_failed",
                        "server": &server,
                        "error":  format!("Install failed: {e}"),
                    }),
                );
            }
        }

        let response = send_response(
            stream,
            start_proxy_and_build_response(active_proxy, &server),
        );
        if response.is_ok() {
            tracing::info!(
                join_req_id,
                server = %server,
                total_ms = join_started.elapsed().as_millis(),
                "IPC join request completed"
            );
        }
        response
    } else {
        // Mod sync was skipped (server has it disabled); still report success to client
        let response = send_response(
            stream,
            start_proxy_and_build_response(active_proxy, &server),
        );
        if response.is_ok() {
            tracing::info!(
                join_req_id,
                server = %server,
                total_ms = join_started.elapsed().as_millis(),
                "IPC join request completed (sync skipped)"
            );
        }
        response
    }
}

/// Shut down any existing proxy, start a new one for `server`, and build the
/// `sync_complete` JSON response including proxy port information.
fn start_proxy_and_build_response(
    active_proxy: &mut Option<proxy::ProxyHandle>,
    server: &str,
) -> serde_json::Value {
    // Tear down previous proxy if any.
    if let Some(old) = active_proxy.take() {
        tracing::info!("Shutting down previous proxy before starting new one");
        old.shutdown();
    }

    match proxy::start(server) {
        Ok(handle) => {
            let tcp_port = handle.tcp_port;
            let udp_port = handle.udp_port;
            tracing::info!(tcp_port, udp_port, server, "Proxy started for IPC join");
            *active_proxy = Some(handle);
            serde_json::json!({
                "type": "sync_complete",
                "server": server,
                "proxy_tcp_port": tcp_port,
                "proxy_udp_port": udp_port,
            })
        }
        Err(e) => {
            tracing::warn!(error = %e, server, "Failed to start proxy; sync_complete without proxy");
            serde_json::json!({
                "type": "sync_complete",
                "server": server,
                "error": format!("Proxy failed: {e}"),
            })
        }
    }
}

fn send_response(stream: &mut std::net::TcpStream, value: serde_json::Value) -> Result<()> {
    let json = serde_json::to_string(&value).context("Failed to serialise IPC response")?;
    stream.write_all(json.as_bytes())?;
    stream.write_all(b"\n")?;
    stream.flush()?;
    Ok(())
}
