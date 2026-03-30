// Allow dead code for fields/methods scaffolded for upcoming phases.
// Remove this once Phase 2+ fills in usage.
#![allow(dead_code)]

use anyhow::Result;
use std::sync::Arc;
use tokio::sync::broadcast;

mod config;
mod mods;
mod net;
mod session;
mod state;
mod validation;

#[tokio::main]
async fn main() -> Result<()> {
    // Load config first (before complete logging setup)
    let config = config::ServerConfig::load()?;
    if !config.logging.log_file.is_empty() {
        let file_appender = tracing_appender::rolling::daily(".", &config.logging.log_file);
        let (non_blocking, _guard) = tracing_appender::non_blocking(file_appender);

        let env_filter =
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| {
                config
                    .logging
                    .level
                    .parse()
                    .unwrap_or_else(|_| "info".into())
            });

        tracing_subscriber::fmt()
            .with_writer(non_blocking)
            .with_ansi(false)
            .with_env_filter(env_filter)
            .init();
    } else {
        // Console-only logging
        let env_filter =
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| {
                config
                    .logging
                    .level
                    .parse()
                    .unwrap_or_else(|_| "info".into())
            });

        tracing_subscriber::fmt().with_env_filter(env_filter).init();
    }

    tracing::info!("HighBeam server v{}", env!("CARGO_PKG_VERSION"));

    // Validate config parameters
    validation::validate_server_config(
        config.general.max_players,
        config.general.max_cars_per_player,
        &config.auth.mode,
        config.auth.password.as_deref(),
        config.auth.allowlist.as_ref(),
        config.general.port,
        config.network.tick_rate,
    )?;

    tracing::info!(
        name = %config.general.name,
        port = config.general.port,
        "Configuration loaded and validated"
    );

    let config = Arc::new(config);
    let sessions = Arc::new(session::manager::SessionManager::new());
    let world = Arc::new(state::world::WorldState::new());

    // Build mod manifest once at startup (Phase 3 groundwork for launcher sync).
    let mod_manifest = Arc::new(mods::build_manifest(&config.general.resource_folder)?);
    tracing::info!(
        mod_count = mod_manifest.len(),
        resource_folder = %config.general.resource_folder,
        "Mod manifest loaded"
    );

    // Graceful shutdown signal
    let (shutdown_tx, _) = broadcast::channel::<()>(1);
    let shutdown_tx_clone = shutdown_tx.clone();

    // Spawn signal handler task
    tokio::spawn(async move {
        #[cfg(unix)]
        {
            use tokio::signal::unix::{signal, SignalKind};
            let mut sigterm =
                signal(SignalKind::terminate()).expect("Failed to setup SIGTERM handler");
            let mut sigint =
                signal(SignalKind::interrupt()).expect("Failed to setup SIGINT handler");

            tokio::select! {
                _ = sigterm.recv() => {
                    tracing::info!("Received SIGTERM, shutting down gracefully");
                }
                _ = sigint.recv() => {
                    tracing::info!("Received SIGINT, shutting down gracefully");
                }
            }
        }

        #[cfg(windows)]
        {
            tokio::signal::ctrl_c()
                .await
                .expect("Failed to setup Ctrl+C handler");
            tracing::info!("Received Ctrl+C, shutting down gracefully");
        }

        let _ = shutdown_tx_clone.send(());
    });

    // Start launcher mod transfer endpoint (separate TCP listener).
    let mod_sync_port = config.network.resolved_mod_sync_port(config.general.port);
    let mod_resource_folder = Arc::new(config.general.resource_folder.clone());
    let mod_manifest_for_task = mod_manifest.clone();
    tokio::spawn(async move {
        if let Err(e) = net::mod_transfer::start_listener(
            mod_sync_port,
            mod_resource_folder,
            mod_manifest_for_task,
        )
        .await
        {
            tracing::error!(error = %e, port = mod_sync_port, "Mod transfer listener error");
        }
    });

    // Start UDP receiver in background
    let udp_sessions = sessions.clone();
    let udp_world = world.clone();
    let udp_port = config.general.port;
    tokio::spawn(async move {
        if let Err(e) = net::udp::start_udp(udp_port, udp_sessions, udp_world).await {
            tracing::error!(error = %e, "UDP socket error");
        }
    });

    // Start TCP listener (blocks forever, accepting connections)
    net::tcp::start_listener(config, sessions, world).await?;

    tracing::info!("Server shut down complete");
    Ok(())
}
