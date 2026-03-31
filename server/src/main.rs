// Allow dead code for fields/methods scaffolded for upcoming phases.
// Remove this once Phase 2+ fills in usage.
#![allow(dead_code)]

use anyhow::Result;
use std::io::BufRead;
use std::sync::Arc;
use tokio::sync::broadcast;

mod cli;
mod config;
mod control;
mod discovery_relay;
mod gui;
mod log_rotation;
mod metrics;
mod mods;
mod net;
mod persistence;
mod plugin;
mod session;
mod state;
mod tls;
mod updater;
mod validation;

#[tokio::main]
async fn main() -> Result<()> {
    let cli = cli::CliArgs::parse()?;

    // Load config first (before complete logging setup)
    let config = config::ServerConfig::load_from_path(&cli.config_path)?;

    let env_filter = tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| {
        config
            .logging
            .level
            .parse()
            .unwrap_or_else(|_| "info".into())
    });

    // _guard must live for the entire program so the file writer flushes.
    let _guard;
    if !config.logging.log_file.is_empty() {
        let file_appender = tracing_appender::rolling::daily(".", &config.logging.log_file);
        let (non_blocking, guard) = tracing_appender::non_blocking(file_appender);
        _guard = Some(guard);

        use tracing_subscriber::layer::SubscriberExt;
        use tracing_subscriber::util::SubscriberInitExt;

        tracing_subscriber::registry()
            .with(env_filter)
            .with(
                tracing_subscriber::fmt::layer()
                    .with_writer(std::io::stdout)
                    .with_ansi(true),
            )
            .with(
                tracing_subscriber::fmt::layer()
                    .with_writer(non_blocking)
                    .with_ansi(false),
            )
            .init();
    } else {
        _guard = None;
        tracing_subscriber::fmt().with_env_filter(env_filter).init();
    }

    tracing::info!("HighBeam server v{}", env!("CARGO_PKG_VERSION"));
    tracing::info!(config_path = %cli.config_path, headless = cli.headless, "CLI arguments parsed");

    if cli.protocol_benchmark {
        let report = net::benchmark::run_json_baseline_benchmark(10_000)?;
        tracing::info!(
            iterations = report.iterations,
            corpus_size = report.corpus_size,
            total_packets = report.total_packets,
            total_bytes = report.total_bytes,
            elapsed_ms = report.elapsed_ms,
            packets_per_sec = report.packets_per_sec,
            mb_per_sec = report.mb_per_sec,
            avg_packet_bytes = report.avg_packet_bytes,
            "JSON protocol baseline benchmark"
        );
        return Ok(());
    }

    // Clean up leftover binary from a previous update
    updater::cleanup_previous_update();

    // Check for updates if enabled
    if config.updates.auto_update {
        match updater::check_and_update().await {
            Ok(true) => {
                tracing::info!("Server binary updated — please restart to run the new version");
            }
            Ok(false) => {}
            Err(e) => {
                tracing::warn!(error = %e, "Auto-update failed, continuing with current version")
            }
        }
    }

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
    let runtime_metrics = Arc::new(metrics::ServerMetrics::new());
    metrics::install_global(runtime_metrics);
    let plugins = Arc::new(plugin::runtime::PluginRuntime::load_from_resource(
        &config.general.resource_folder,
        sessions.clone(),
        world.clone(),
    )?);
    let control_plane = Arc::new(control::ControlPlane::new(
        config.clone(),
        sessions.clone(),
        world.clone(),
        Some(plugins.clone()),
    ));

    discovery_relay::spawn_registration_task(config.clone(), control_plane.clone());

    match persistence::load_state(&config.general.state_file, &control_plane, &world) {
        Ok(true) => {
            tracing::info!(state_file = %config.general.state_file, "Persistent state loaded")
        }
        Ok(false) => {
            tracing::info!(state_file = %config.general.state_file, "No persistent state loaded")
        }
        Err(e) => {
            tracing::warn!(error = %e, state_file = %config.general.state_file, "State load failed")
        }
    }

    if !cli.headless {
        gui::launch(control_plane.clone());
        tracing::info!("GUI shell launched (v0.6 scaffold)");
    }

    metrics::spawn_metrics_logger(
        config.logging.metrics_interval_sec,
        sessions.clone(),
        world.clone(),
        Some(log_rotation::LogRotationPolicy::new(
            config.logging.rotation_max_size_mb,
            config.logging.rotation_max_days,
        )),
    );

    tracing::info!(
        plugin_count = plugins.plugin_count(),
        resource_folder = %config.general.resource_folder,
        "Plugin runtime initialized"
    );

    // Poll plugin directory for changes and hot-reload plugin states.
    let plugins_for_reload = plugins.clone();
    tokio::spawn(async move {
        let interval = std::time::Duration::from_secs(2);
        loop {
            tokio::time::sleep(interval).await;
            match plugins_for_reload.refresh_if_changed() {
                Ok(true) => tracing::info!("Plugin files changed; runtime hot-reloaded"),
                Ok(false) => {}
                Err(e) => tracing::error!(error = %e, "Plugin hot-reload poll failed"),
            }
        }
    });

    // Local admin console for control-plane commands.
    let control_for_console = control_plane.clone();
    tokio::task::spawn_blocking(move || {
        let stdin = std::io::stdin();
        for line in stdin.lock().lines() {
            let Ok(line) = line else {
                continue;
            };
            match control_for_console.execute_console_line(&line) {
                Ok(output) if !output.is_empty() => {
                    tracing::info!(command = %line.trim(), output = %output, "Console command processed");
                }
                Ok(_) => {}
                Err(e) => {
                    tracing::warn!(command = %line.trim(), error = %e, "Console command failed");
                }
            }
        }
    });

    // Build mod manifest once at startup (Phase 3 groundwork for launcher sync).
    let mod_manifest = Arc::new(mods::build_manifest(&config.general.resource_folder)?);
    tracing::info!(
        mod_count = mod_manifest.len(),
        resource_folder = %config.general.resource_folder,
        "Mod manifest loaded"
    );

    // Periodic autosave for persistent server state.
    let autosave_control = control_plane.clone();
    let autosave_world = world.clone();
    let autosave_path = config.general.state_file.clone();
    tokio::spawn(async move {
        let interval = std::time::Duration::from_secs(30);
        loop {
            tokio::time::sleep(interval).await;
            if let Err(e) =
                persistence::save_state(&autosave_path, &autosave_control, &autosave_world)
            {
                tracing::warn!(error = %e, state_file = %autosave_path, "Autosave failed");
            }
        }
    });

    // Graceful shutdown signal
    let (shutdown_tx, _) = broadcast::channel::<()>(1);
    let shutdown_tx_clone = shutdown_tx.clone();
    let signal_control = control_plane.clone();
    let signal_world = world.clone();
    let signal_state_path = config.general.state_file.clone();

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

        if let Err(e) = persistence::save_state(&signal_state_path, &signal_control, &signal_world)
        {
            tracing::warn!(error = %e, state_file = %signal_state_path, "Save on shutdown signal failed");
        } else {
            tracing::info!(state_file = %signal_state_path, "State saved on shutdown signal");
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
    let udp_control = control_plane.clone();
    let udp_port = config.general.port;
    let udp_config = config.clone();
    tokio::spawn(async move {
        if let Err(e) = net::udp::start_udp(
            udp_port,
            udp_config.network.tick_rate,
            udp_control,
            udp_sessions,
            udp_world,
        )
        .await
        {
            tracing::error!(error = %e, "UDP socket error");
        }
    });

    // Start TCP listener (blocks until shutdown signal)
    // Start TCP listener (blocks forever, accepting connections)
    let final_state_path = config.general.state_file.clone();
    net::tcp::start_listener(
        config,
        control_plane.clone(),
        sessions,
        world.clone(),
        plugins,
    )
    .await?;

    if let Err(e) = persistence::save_state(&final_state_path, &control_plane, &world) {
        tracing::warn!(
            error = %e,
            state_file = %final_state_path,
            "Final state save on shutdown failed"
        );
    }

    tracing::info!("Server shut down complete");
    Ok(())
}
