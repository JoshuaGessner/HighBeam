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
}

#[derive(Debug, Clone, Deserialize)]
pub struct GeneralConfig {
    #[serde(rename = "Name")]
    pub name: String,
    #[serde(rename = "Port", default = "default_port")]
    pub port: u16,
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
}

#[derive(Debug, Clone, Deserialize)]
pub struct AuthConfig {
    #[serde(rename = "Mode", default = "default_auth_mode")]
    pub mode: String,
    #[serde(rename = "MaxAuthAttempts", default = "default_max_auth_attempts")]
    pub max_auth_attempts: u32,
    #[serde(rename = "AuthTimeoutSec", default = "default_auth_timeout")]
    pub auth_timeout_sec: u64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct NetworkConfig {
    #[serde(rename = "TickRate", default = "default_tick_rate")]
    pub tick_rate: u32,
    #[serde(rename = "UdpBufferSize", default = "default_udp_buffer")]
    pub udp_buffer_size: usize,
    #[serde(rename = "TcpKeepAliveSec", default = "default_tcp_keepalive")]
    pub tcp_keepalive_sec: u64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct LoggingConfig {
    #[serde(rename = "Level", default = "default_log_level")]
    pub level: String,
    #[serde(rename = "LogFile", default = "default_log_file")]
    pub log_file: String,
    #[serde(rename = "LogChat", default)]
    pub log_chat: bool,
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

impl ServerConfig {
    pub fn load() -> Result<Self> {
        let path = std::env::args()
            .nth(1)
            .unwrap_or_else(|| "ServerConfig.toml".into());

        if Path::new(&path).exists() {
            let contents = std::fs::read_to_string(&path)
                .with_context(|| format!("Failed to read config file: {path}"))?;
            toml::from_str(&contents)
                .with_context(|| format!("Failed to parse config file: {path}"))
        } else {
            tracing::warn!("No config file found at '{path}', using defaults");
            Ok(Self::default())
        }
    }
}

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            general: GeneralConfig {
                name: "HighBeam Server".into(),
                port: 18860,
                max_players: 20,
                max_cars_per_player: 3,
                map: "/levels/gridmap_v2/info.json".into(),
                description: String::new(),
                resource_folder: "Resources".into(),
            },
            auth: AuthConfig {
                mode: "open".into(),
                max_auth_attempts: 5,
                auth_timeout_sec: 30,
            },
            network: NetworkConfig {
                tick_rate: 20,
                udp_buffer_size: 65535,
                tcp_keepalive_sec: 15,
            },
            logging: LoggingConfig {
                level: "info".into(),
                log_file: "server.log".into(),
                log_chat: false,
            },
        }
    }
}
