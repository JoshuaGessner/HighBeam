use std::sync::Arc;

use serde::Serialize;

use crate::config::ServerConfig;
use crate::control::ControlPlane;
use crate::net::packet::PROTOCOL_VERSION;

#[derive(Debug, Clone, Serialize)]
struct RelayRegistrationPayload {
    name: String,
    description: String,
    map: String,
    players: usize,
    max_players: u32,
    port: u16,
    protocol_version: u32,
}

pub fn spawn_registration_task(config: Arc<ServerConfig>, control: Arc<ControlPlane>) {
    if !config.discovery.enable_relay {
        return;
    }

    if config.discovery.relay_urls.is_empty() {
        tracing::warn!("Discovery relay enabled, but no relay URLs configured");
        return;
    }

    let relay_urls: Vec<String> = config
        .discovery
        .relay_urls
        .iter()
        .filter(|url| !url.trim().is_empty())
        .cloned()
        .collect();

    if relay_urls.is_empty() {
        tracing::warn!("Discovery relay enabled, but relay URL list is effectively empty");
        return;
    }

    let interval_secs = config.discovery.registration_interval_sec.max(5);
    let config_for_task = config.clone();
    let control_for_task = control.clone();

    tokio::spawn(async move {
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(10))
            .build()
            .unwrap_or_else(|_| reqwest::Client::new());
        let interval = std::time::Duration::from_secs(interval_secs);

        loop {
            let snapshot = control_for_task.snapshot();
            let payload = RelayRegistrationPayload {
                name: snapshot.server_name,
                description: config_for_task.general.description.clone(),
                map: snapshot.map_display_name,
                players: snapshot.player_count,
                max_players: snapshot.max_players,
                port: snapshot.port,
                protocol_version: PROTOCOL_VERSION,
            };

            for relay_url in &relay_urls {
                match client.post(relay_url).json(&payload).send().await {
                    Ok(resp) if resp.status().is_success() => {
                        tracing::debug!(relay_url = %relay_url, "Relay registration succeeded");
                    }
                    Ok(resp) => {
                        tracing::warn!(
                            relay_url = %relay_url,
                            status = %resp.status(),
                            "Relay registration failed"
                        );
                    }
                    Err(e) => {
                        tracing::warn!(
                            relay_url = %relay_url,
                            error = %e,
                            "Relay registration request error"
                        );
                    }
                }
            }

            tokio::time::sleep(interval).await;
        }
    });
}
