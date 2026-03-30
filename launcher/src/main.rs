use std::path::PathBuf;

use anyhow::Result;

mod config;
mod detect;
mod game;
mod installer;
mod mod_cache;
mod mod_sync;
#[allow(dead_code)]
mod transfer;
mod updater;

struct CliArgs {
    server: Option<String>,
    config: PathBuf,
    no_launch: bool,
    clear_cache: bool,
    no_update: bool,
}

fn parse_args() -> CliArgs {
    let mut server = None;
    let mut config = PathBuf::from("LauncherConfig.toml");
    let mut no_launch = false;
    let mut clear_cache = false;
    let mut no_update = false;

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--server" => {
                if let Some(v) = args.next() {
                    server = Some(v);
                }
            }
            "--config" => {
                if let Some(v) = args.next() {
                    config = PathBuf::from(v);
                }
            }
            "--no-launch" => no_launch = true,
            "--clear-cache" => clear_cache = true,
            "--no-update" => no_update = true,
            _ => {}
        }
    }

    CliArgs {
        server,
        config,
        no_launch,
        clear_cache,
        no_update,
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

fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();

    let args = parse_args();

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

    let mut cfg = config::LauncherConfig::load(&args.config)?;

    if let Some(server) = args.server {
        cfg.server_addr = server;
    }

    let cache_dir = expand_tilde(&cfg.cache_dir);
    mod_cache::ensure_cache_dir(&cache_dir)?;

    if args.clear_cache {
        mod_cache::clear_cache(&cache_dir)?;
        tracing::info!(cache_dir = %cache_dir.display(), "Cache cleared");
    }

    let mut cache_index = mod_cache::load_index(&cache_dir)?;
    let report = mod_sync::sync_mods(
        &cfg.server_addr,
        cfg.mod_sync_addr.as_deref(),
        cfg.connect_timeout_sec,
        &cache_dir,
        &mut cache_index,
    )?;
    tracing::info!(
        total_server_mods = report.total_server_mods,
        missing_mods = report.missing_mods,
        downloaded_mods = report.downloaded_mods,
        "Mod sync completed"
    );

    let workspace_root = std::env::current_dir()?;
    let install_report = installer::install_all(
        cfg.beamng_userfolder.as_deref(),
        &cache_dir,
        &cache_index,
        &report.server_mods,
        &workspace_root,
    )?;
    tracing::info!(
        installed_server_mods = install_report.installed_server_mods,
        installed_client_mod = install_report.installed_client_mod,
        mods_dir = %install_report.mods_dir.display(),
        "Mod installation completed"
    );

    mod_cache::save_index(&cache_dir, &cache_index)?;

    if args.no_launch {
        tracing::info!("--no-launch specified; exiting after sync");
        return Ok(());
    }

    game::launch_game(cfg.beamng_exe.as_deref())?;
    tracing::info!("BeamNG launched successfully");
    Ok(())
}
