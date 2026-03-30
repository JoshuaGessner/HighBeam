use std::path::PathBuf;

use anyhow::Result;

mod config;
mod game;
mod mod_cache;
mod mod_sync;
mod transfer;

struct CliArgs {
    server: Option<String>,
    config: PathBuf,
    no_launch: bool,
    clear_cache: bool,
}

fn parse_args() -> CliArgs {
    let mut server = None;
    let mut config = PathBuf::from("LauncherConfig.toml");
    let mut no_launch = false;
    let mut clear_cache = false;

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
            _ => {}
        }
    }

    CliArgs {
        server,
        config,
        no_launch,
        clear_cache,
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

    mod_cache::save_index(&cache_dir, &cache_index)?;

    if args.no_launch {
        tracing::info!("--no-launch specified; exiting after sync");
        return Ok(());
    }

    game::launch_game(cfg.beamng_exe.as_deref())?;
    tracing::info!("BeamNG launched successfully");
    Ok(())
}
