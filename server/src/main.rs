// Allow dead code for fields/methods scaffolded for upcoming phases.
// Remove this once Phase 2+ fills in usage.
#![allow(dead_code)]

use anyhow::Result;
use std::sync::Arc;

mod config;
mod net;
mod session;
mod state;

#[tokio::main]
async fn main() -> Result<()> {
    // Initialize logging
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();

    tracing::info!("HighBeam server v{}", env!("CARGO_PKG_VERSION"));

    // Load config
    let config = config::ServerConfig::load()?;
    tracing::info!(
        name = %config.general.name,
        port = config.general.port,
        "Configuration loaded"
    );

    let config = Arc::new(config);
    let sessions = Arc::new(session::manager::SessionManager::new());
    let world = Arc::new(state::world::WorldState::new());

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

    Ok(())
}
