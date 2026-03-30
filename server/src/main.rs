use anyhow::Result;
use std::sync::Arc;

mod config;
mod net;
mod session;

#[tokio::main]
async fn main() -> Result<()> {
    // Initialize logging
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info".into()),
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

    // Start TCP listener (blocks forever, accepting connections)
    net::tcp::start_listener(config, sessions).await?;

    Ok(())
}
