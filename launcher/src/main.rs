use std::path::PathBuf;

use anyhow::Result;

mod config;
mod detect;
mod discovery;
mod game;
mod installer;
mod ipc;
mod mod_cache;
mod mod_sync;
#[allow(dead_code)]
mod transfer;
mod updater;

struct CliArgs {
    server: Option<String>,
    query_server: Option<String>,
    browse_relay: Option<String>,
    favorite_add: Option<String>,
    favorite_remove: Option<String>,
    list_favorites: bool,
    list_recent: bool,
    browse_favorites: bool,
    browse_recent: bool,
    config: PathBuf,
    no_launch: bool,
    clear_cache: bool,
    no_update: bool,
    dry_run: bool,
}

fn parse_args() -> CliArgs {
    parse_args_from(std::env::args().skip(1))
}

fn parse_args_from<I>(args: I) -> CliArgs
where
    I: IntoIterator<Item = String>,
{
    let mut server = None;
    let mut query_server = None;
    let mut browse_relay = None;
    let mut favorite_add = None;
    let mut favorite_remove = None;
    let mut list_favorites = false;
    let mut list_recent = false;
    let mut browse_favorites = false;
    let mut browse_recent = false;
    let mut config = PathBuf::from("LauncherConfig.toml");
    let mut no_launch = false;
    let mut clear_cache = false;
    let mut no_update = false;
    let mut dry_run = false;

    let mut args = args.into_iter();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--server" => {
                if let Some(v) = args.next() {
                    server = Some(v);
                }
            }
            "--query-server" => {
                if let Some(v) = args.next() {
                    query_server = Some(v);
                }
            }
            "--browse-relay" => {
                if let Some(v) = args.next() {
                    browse_relay = Some(v);
                }
            }
            "--favorite-add" => {
                if let Some(v) = args.next() {
                    favorite_add = Some(v);
                }
            }
            "--favorite-remove" => {
                if let Some(v) = args.next() {
                    favorite_remove = Some(v);
                }
            }
            "--favorites" => list_favorites = true,
            "--recent" => list_recent = true,
            "--browse-favorites" => browse_favorites = true,
            "--browse-recent" => browse_recent = true,
            "--config" => {
                if let Some(v) = args.next() {
                    config = PathBuf::from(v);
                }
            }
            "--no-launch" => no_launch = true,
            "--clear-cache" => clear_cache = true,
            "--no-update" => no_update = true,
            "--dry-run" => dry_run = true,
            _ => {}
        }
    }

    CliArgs {
        server,
        query_server,
        browse_relay,
        favorite_add,
        favorite_remove,
        list_favorites,
        list_recent,
        browse_favorites,
        browse_recent,
        config,
        no_launch,
        clear_cache,
        no_update,
        dry_run,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_args_does_not_enable_relay_browse_by_default() {
        let parsed = parse_args_from(vec![]);
        assert!(parsed.browse_relay.is_none());
    }

    #[test]
    fn parse_args_sets_browse_relay_only_when_flag_present() {
        let parsed = parse_args_from(vec![
            "--browse-relay".to_string(),
            "https://relay.example/servers".to_string(),
        ]);
        assert_eq!(
            parsed.browse_relay.as_deref(),
            Some("https://relay.example/servers")
        );
    }

    #[test]
    fn parse_args_allows_server_without_browse_relay() {
        let parsed = parse_args_from(vec!["--server".to_string(), "127.0.0.1:18860".to_string()]);
        assert_eq!(parsed.server.as_deref(), Some("127.0.0.1:18860"));
        assert!(parsed.browse_relay.is_none());
    }
}

fn expand_tilde(path: &str) -> PathBuf {
    if let Some(rest) = path.strip_prefix("~/") {
        if let Some(home) = std::env::var_os("HOME") {
            return PathBuf::from(home).join(rest);
        }
    }
    PathBuf::from(path)
}

fn resolve_client_source_root() -> Result<PathBuf> {
    let mut candidates = Vec::new();

    // 1) Current working directory (developer workflow)
    if let Ok(cwd) = std::env::current_dir() {
        candidates.push(cwd.join("client"));
    }

    // 2) Next to launcher executable (release archive workflow)
    if let Ok(exe) = std::env::current_exe() {
        if let Some(exe_dir) = exe.parent() {
            candidates.push(exe_dir.join("client"));
            candidates.push(exe_dir.join("..").join("client"));
        }
    }

    for candidate in &candidates {
        if candidate.exists() && candidate.is_dir() {
            tracing::info!(path = %candidate.display(), "Resolved HighBeam client source directory");
            return Ok(candidate.clone());
        }
    }

    let searched = candidates
        .iter()
        .map(|p| p.display().to_string())
        .collect::<Vec<_>>()
        .join(", ");

    Err(anyhow::anyhow!(
        "Could not locate HighBeam client directory. Searched: {}",
        searched
    ))
}

fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();

    let args = parse_args();
    let mut cfg = config::LauncherConfig::load(&args.config)?;

    if let Some(addr) = args.query_server.as_deref() {
        let started = std::time::Instant::now();
        let info = discovery::query_server(addr, cfg.query_timeout_ms)?;
        let ping_ms = started.elapsed().as_millis();
        println!(
            "{} | map={} | players={}/{} | protocol=v{} | port={} | ping={}ms",
            info.name,
            info.map,
            info.players,
            info.max_players,
            info.protocol_version,
            info.port,
            ping_ms
        );
        cfg.note_recent_server(addr);
        cfg.save(&args.config)?;
        return Ok(());
    }

    if let Some(addr) = args.favorite_add.as_deref() {
        if cfg.add_favorite_server(addr) {
            cfg.save(&args.config)?;
            println!("Added favorite server: {}", addr);
        } else {
            println!("Favorite already exists or invalid: {}", addr);
        }
        return Ok(());
    }

    if let Some(addr) = args.favorite_remove.as_deref() {
        if cfg.remove_favorite_server(addr) {
            cfg.save(&args.config)?;
            println!("Removed favorite server: {}", addr);
        } else {
            println!("Favorite not found: {}", addr);
        }
        return Ok(());
    }

    if args.list_favorites {
        if cfg.favorite_servers.is_empty() {
            println!("No favorite servers configured.");
        } else {
            println!("Favorite servers:");
            for server in &cfg.favorite_servers {
                println!("- {}", server);
            }
        }
        return Ok(());
    }

    if args.list_recent {
        if cfg.recent_servers.is_empty() {
            println!("No recent servers.");
        } else {
            println!("Recent servers:");
            for server in &cfg.recent_servers {
                println!("- {}", server);
            }
        }
        return Ok(());
    }

    if args.browse_favorites {
        if cfg.favorite_servers.is_empty() {
            println!("No favorite servers configured.");
            return Ok(());
        }

        println!("Favorite servers (live):");
        for addr in &cfg.favorite_servers {
            let started = std::time::Instant::now();
            match discovery::query_server(addr, cfg.query_timeout_ms) {
                Ok(info) => {
                    let ping_ms = started.elapsed().as_millis();
                    println!(
                        "- {} | {} | map={} | players={}/{} | ping={}ms",
                        addr, info.name, info.map, info.players, info.max_players, ping_ms
                    );
                }
                Err(e) => println!("- {} | unavailable ({})", addr, e),
            }
        }
        return Ok(());
    }

    if args.browse_recent {
        if cfg.recent_servers.is_empty() {
            println!("No recent servers.");
            return Ok(());
        }

        println!("Recent servers (live):");
        for addr in &cfg.recent_servers {
            let started = std::time::Instant::now();
            match discovery::query_server(addr, cfg.query_timeout_ms) {
                Ok(info) => {
                    let ping_ms = started.elapsed().as_millis();
                    println!(
                        "- {} | {} | map={} | players={}/{} | ping={}ms",
                        addr, info.name, info.map, info.players, info.max_players, ping_ms
                    );
                }
                Err(e) => println!("- {} | unavailable ({})", addr, e),
            }
        }
        return Ok(());
    }

    if let Some(relay_url) = args.browse_relay.as_deref() {
        let entries = discovery::fetch_relay_servers(relay_url, cfg.query_timeout_ms)?;
        if entries.is_empty() {
            println!("Relay returned no servers: {}", relay_url);
            return Ok(());
        }

        println!("Servers from relay {}:", relay_url);
        for entry in entries {
            let started = std::time::Instant::now();
            match discovery::query_server(&entry.addr, cfg.query_timeout_ms) {
                Ok(info) => {
                    let ping_ms = started.elapsed().as_millis();
                    println!(
                        "- {} | {} | map={} | players={}/{} | ping={}ms",
                        entry.addr, info.name, info.map, info.players, info.max_players, ping_ms
                    );
                }
                Err(e) => {
                    println!("- {} | unavailable ({})", entry.addr, e);
                }
            }
        }
        return Ok(());
    }

    // Clean up leftover binary from a previous update
    updater::cleanup_previous_update();

    // Check for updates unless --no-update is specified
    if !args.no_update {
        match updater::check_and_update() {
            Ok(true) => {
                tracing::info!("Launcher updated — restarting");
                let exe = std::env::current_exe()?;
                let status = std::process::Command::new(&exe)
                    .args(std::env::args().skip(1))
                    .arg("--no-update")
                    .status()?;
                std::process::exit(status.code().unwrap_or(0));
            }
            Ok(false) => {}
            Err(e) => {
                tracing::warn!(error = %e, "Auto-update failed, continuing with current version")
            }
        }
    }

    let join_server = args.server.clone();
    if let Some(server) = join_server.as_deref() {
        cfg.note_recent_server(server);
        cfg.server_addr = server.to_string();
        cfg.save(&args.config)?;
    }

    let cache_dir = expand_tilde(&cfg.cache_dir);
    mod_cache::ensure_cache_dir(&cache_dir)?;

    if args.clear_cache {
        mod_cache::clear_cache(&cache_dir)?;
        tracing::info!(cache_dir = %cache_dir.display(), "Cache cleared");
    }

    // ── Dry-run: print resolved paths and planned actions, then exit ─────────
    if args.dry_run {
        println!("=== HighBeam Launcher — Dry Run ===");
        println!("Config file : {}", args.config.display());
        println!("Cache dir   : {}", cache_dir.display());
        match detect::detect_beamng_exe() {
            Some(p) => println!("BeamNG exe  : {}", p.display()),
            None => println!("BeamNG exe  : NOT FOUND (set beamng_exe in LauncherConfig.toml)"),
        }
        match installer::resolve_mods_dir_pub(cfg.beamng_userfolder.as_deref()) {
            Ok(p) => println!("Mods dir    : {}", p.display()),
            Err(e) => println!("Mods dir    : UNRESOLVED ({})", e),
        }
        if let Some(server) = join_server.as_deref() {
            println!("Join server : {server}");
            match discovery::query_server(server, cfg.query_timeout_ms) {
                Ok(info) => println!(
                    "Server info : {} | map={} | players={}/{} | protocol=v{}",
                    info.name, info.map, info.players, info.max_players, info.protocol_version
                ),
                Err(e) => println!("Server info : query failed ({e})"),
            }
        } else {
            println!("Join server : none (pass --server <addr> to sync mods)");
        }
        return Ok(());
    }

    // Recover from prior interrupted sessions by removing staged join mods.
    match installer::cleanup_staged_server_mods(cfg.beamng_userfolder.as_deref()) {
        Ok(report) => {
            if report.removed_files > 0 || report.missing_files > 0 {
                tracing::info!(
                    removed_files = report.removed_files,
                    missing_files = report.missing_files,
                    mods_dir = %report.mods_dir.display(),
                    "Recovered stale staged mods from previous session"
                );
            }
        }
        Err(e) => {
            tracing::warn!(error = %e, "Failed stale staged-mod cleanup recovery; continuing");
        }
    }

    let mut joined_server = false;
    if let Some(server_addr) = join_server.as_deref() {
        joined_server = true;
        tracing::info!(server = %server_addr, "Join requested; starting server-scoped mod sync");

        let mut cache_index = mod_cache::load_index(&cache_dir)?;
        let report = mod_sync::sync_mods(
            server_addr,
            cfg.mod_sync_addr.as_deref(),
            cfg.connect_timeout_sec,
            &cache_dir,
            &mut cache_index,
        )?;
        tracing::info!(
            server = %server_addr,
            total_server_mods = report.total_server_mods,
            missing_mods = report.missing_mods,
            downloaded_mods = report.downloaded_mods,
            "Mod sync completed"
        );

        let client_source_root = resolve_client_source_root()?;
        let install_report = installer::install_all(
            cfg.beamng_userfolder.as_deref(),
            &cache_dir,
            &cache_index,
            &report.server_mods,
            &client_source_root,
        )?;
        tracing::info!(
            server = %server_addr,
            installed_server_mods = install_report.installed_server_mods,
            installed_client_mod = install_report.installed_client_mod,
            client_mod_zip = install_report
                .client_mod_zip_path
                .as_ref()
                .map(|p| p.display().to_string())
                .unwrap_or_else(|| "not-installed".to_string()),
            mods_dir = %install_report.mods_dir.display(),
            "Mod installation completed"
        );

        mod_cache::save_index(&cache_dir, &cache_index)?;
    } else {
        tracing::info!("No explicit join requested; skipping mod sync/install startup path");
    }

    if args.no_launch {
        tracing::info!("--no-launch specified; exiting after sync");
        return Ok(());
    }

    // ── Spawn the game (non-blocking) ────────────────────────────────────────
    let mut game_child = game::spawn_game(cfg.beamng_exe.as_deref())?;
    tracing::info!("BeamNG.drive launched");

    // ── Start the IPC server so in-game joins can trigger mod sync ───────────
    let ipc_state_path: Option<PathBuf> =
        match installer::resolve_mods_dir_pub(cfg.beamng_userfolder.as_deref()) {
            Ok(mods_dir) => Some(ipc::ipc_state_file_path(&mods_dir)),
            Err(e) => {
                tracing::warn!(error = %e, "Cannot determine mods dir; IPC state file disabled");
                None
            }
        };

    let ipc_listener = match std::net::TcpListener::bind("127.0.0.1:0") {
        Ok(listener) => {
            let port = listener.local_addr().map(|a| a.port()).unwrap_or(0);
            if let Some(ref path) = ipc_state_path {
                match ipc::write_state_file(path, port) {
                    Ok(()) => tracing::info!(
                        port,
                        path = %path.display(),
                        "IPC state file written; in-game mod sync enabled"
                    ),
                    Err(e) => tracing::warn!(
                        error = %e,
                        "Failed to write IPC state file; in-game mod sync disabled"
                    ),
                }
            }
            Some(listener)
        }
        Err(e) => {
            tracing::warn!(error = %e, "Failed to bind IPC listener; in-game mod sync disabled");
            None
        }
    };

    // Resolve client source root once; failures are non-fatal (IPC will skip client mod install).
    let client_source_root = resolve_client_source_root()
        .unwrap_or_else(|_| PathBuf::from("__client_source_not_found__"));

    // ── Main loop: monitor game + serve IPC connections ──────────────────────
    if let Some(ref listener) = ipc_listener {
        ipc::run_ipc_loop(
            &mut game_child,
            listener,
            &cfg,
            &cache_dir,
            &client_source_root,
        )?;
    } else {
        // No IPC; fall back to blocking wait.
        let _ = game_child.wait();
        tracing::info!("BeamNG.drive exited");
    }

    // ── Cleanup ───────────────────────────────────────────────────────────────
    if let Some(ref path) = ipc_state_path {
        ipc::cleanup_state_file(path);
    }

    if joined_server {
        let cleanup_report =
            installer::cleanup_staged_server_mods(cfg.beamng_userfolder.as_deref())?;
        tracing::info!(
            removed_files = cleanup_report.removed_files,
            missing_files = cleanup_report.missing_files,
            mods_dir = %cleanup_report.mods_dir.display(),
            "Cleaned up staged server mods after game exit"
        );
    }

    Ok(())
}
