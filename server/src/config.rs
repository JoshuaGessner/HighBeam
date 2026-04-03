use anyhow::{Context, Result};
use serde::Deserialize;
use std::path::Path;

#[derive(Debug, Clone, Deserialize)]
pub struct ServerConfig {
    #[serde(rename = "General")]
    pub general: GeneralConfig,
    #[serde(rename = "Auth")]
    pub auth: AuthConfig,
    #[serde(rename = "Network")]
    pub network: NetworkConfig,
    #[serde(rename = "Logging")]
    pub logging: LoggingConfig,
    #[serde(rename = "TLS", default)]
    pub tls: Option<TlsConfigData>,
    #[serde(rename = "Updates", default)]
    pub updates: UpdatesConfig,
    #[serde(rename = "Discovery", default)]
    pub discovery: DiscoveryConfig,
}

#[derive(Debug, Clone, Deserialize)]
pub struct GeneralConfig {
    #[serde(rename = "Name")]
    pub name: String,
    #[serde(rename = "Port", default = "default_port")]
    pub port: u16,
    #[serde(rename = "PublicAddr", default)]
    pub public_addr: Option<String>,
    #[serde(rename = "MaxPlayers", default = "default_max_players")]
    pub max_players: u32,
    #[serde(rename = "MaxCarsPerPlayer", default = "default_max_cars")]
    pub max_cars_per_player: u32,
    #[serde(rename = "Map")]
    pub map: String,
    #[serde(rename = "Description", default)]
    pub description: String,
    #[serde(rename = "ResourceFolder", default = "default_resource_folder")]
    pub resource_folder: String,
    #[serde(rename = "StateFile", default = "default_state_file")]
    pub state_file: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct AuthConfig {
    #[serde(rename = "Mode", default = "default_auth_mode")]
    pub mode: String,
    #[serde(rename = "MaxAuthAttempts", default = "default_max_auth_attempts")]
    pub max_auth_attempts: u32,
    #[serde(rename = "AuthTimeoutSec", default = "default_auth_timeout")]
    pub auth_timeout_sec: u64,
    #[serde(rename = "Password", default)]
    pub password: Option<String>,
    #[serde(rename = "Allowlist", default)]
    pub allowlist: Option<Vec<String>>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct NetworkConfig {
    #[serde(rename = "TickRate", default = "default_tick_rate")]
    pub tick_rate: u32,
    #[serde(rename = "UdpBufferSize", default = "default_udp_buffer")]
    pub udp_buffer_size: usize,
    #[serde(rename = "TcpKeepAliveSec", default = "default_tcp_keepalive")]
    pub tcp_keepalive_sec: u64,
    #[serde(rename = "ModSyncPort")]
    pub mod_sync_port: Option<u16>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct LoggingConfig {
    #[serde(rename = "Level", default = "default_log_level")]
    pub level: String,
    #[serde(rename = "LogFile", default = "default_log_file")]
    pub log_file: String,
    #[serde(rename = "LogChat", default)]
    pub log_chat: bool,
    #[serde(rename = "MetricsIntervalSec", default = "default_metrics_interval")]
    pub metrics_interval_sec: u64,
    #[serde(rename = "RotationMaxSizeMb", default = "default_rotation_max_size_mb")]
    pub rotation_max_size_mb: u64,
    #[serde(rename = "RotationMaxDays", default = "default_rotation_max_days")]
    pub rotation_max_days: u64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TlsConfigData {
    #[serde(rename = "Enabled", default)]
    pub enabled: bool,
    #[serde(rename = "CertPath", default = "default_cert_path")]
    pub cert_path: String,
    #[serde(rename = "KeyPath", default = "default_key_path")]
    pub key_path: String,
    #[serde(rename = "AutoGenerate", default = "default_auto_generate")]
    pub auto_generate: bool,
}

impl Default for TlsConfigData {
    fn default() -> Self {
        Self {
            enabled: false,
            cert_path: default_cert_path(),
            key_path: default_key_path(),
            auto_generate: default_auto_generate(),
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct UpdatesConfig {
    #[serde(rename = "AutoUpdate", default = "default_auto_update")]
    pub auto_update: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct DiscoveryConfig {
    #[serde(rename = "EnableRelay", default)]
    pub enable_relay: bool,
    #[serde(rename = "RelayUrls", default)]
    pub relay_urls: Vec<String>,
    #[serde(
        rename = "RegistrationIntervalSec",
        default = "default_discovery_registration_interval_sec"
    )]
    pub registration_interval_sec: u64,
}

impl Default for UpdatesConfig {
    fn default() -> Self {
        Self {
            auto_update: default_auto_update(),
        }
    }
}

impl Default for DiscoveryConfig {
    fn default() -> Self {
        Self {
            enable_relay: false,
            relay_urls: Vec::new(),
            registration_interval_sec: default_discovery_registration_interval_sec(),
        }
    }
}

fn default_port() -> u16 {
    18860
}
fn default_max_players() -> u32 {
    20
}
fn default_max_cars() -> u32 {
    3
}
fn default_resource_folder() -> String {
    "Resources".into()
}
fn default_state_file() -> String {
    "server_state.json".into()
}
fn default_auth_mode() -> String {
    "open".into()
}
fn default_max_auth_attempts() -> u32 {
    5
}
fn default_auth_timeout() -> u64 {
    30
}
fn default_tick_rate() -> u32 {
    20
}
fn default_udp_buffer() -> usize {
    65535
}
fn default_tcp_keepalive() -> u64 {
    15
}
fn default_log_level() -> String {
    "info".into()
}
fn default_log_file() -> String {
    "server.log".into()
}
fn default_metrics_interval() -> u64 {
    60
}
fn default_rotation_max_size_mb() -> u64 {
    100
}
fn default_rotation_max_days() -> u64 {
    7
}
fn default_cert_path() -> String {
    "certs/server.pem".into()
}
fn default_key_path() -> String {
    "certs/key.pem".into()
}
fn default_auto_generate() -> bool {
    false
}
fn default_auto_update() -> bool {
    true
}
fn default_discovery_registration_interval_sec() -> u64 {
    30
}

impl ServerConfig {
    pub fn load() -> Result<Self> {
        Self::load_from_path("ServerConfig.toml")
    }

    pub fn load_from_path(path: &str) -> Result<Self> {
        if Path::new(&path).exists() {
            let contents = std::fs::read_to_string(path)
                .with_context(|| format!("Failed to read config file: {path}"))?;
            toml::from_str(&contents)
                .with_context(|| format!("Failed to parse config file: {path}"))
        } else {
            tracing::warn!("No config file found at '{path}', using defaults");
            Ok(Self::default())
        }
    }
}

impl NetworkConfig {
    pub fn resolved_mod_sync_port(&self, gameplay_port: u16) -> u16 {
        self.mod_sync_port
            .unwrap_or_else(|| gameplay_port.saturating_add(1))
    }
}

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            general: GeneralConfig {
                name: "HighBeam Server".into(),
                port: 18860,
                public_addr: None,
                max_players: 20,
                max_cars_per_player: 3,
                map: "/levels/gridmap_v2/info.json".into(),
                description: String::new(),
                resource_folder: "Resources".into(),
                state_file: default_state_file(),
            },
            auth: AuthConfig {
                mode: "open".into(),
                max_auth_attempts: 5,
                auth_timeout_sec: 30,
                password: None,
                allowlist: None,
            },
            network: NetworkConfig {
                tick_rate: 20,
                udp_buffer_size: 65535,
                tcp_keepalive_sec: 15,
                mod_sync_port: None,
            },
            logging: LoggingConfig {
                level: "info".into(),
                log_file: "server.log".into(),
                log_chat: false,
                metrics_interval_sec: 60,
                rotation_max_size_mb: 100,
                rotation_max_days: 7,
            },
            tls: Some(TlsConfigData::default()),
            updates: UpdatesConfig::default(),
            discovery: DiscoveryConfig::default(),
        }
    }
}
