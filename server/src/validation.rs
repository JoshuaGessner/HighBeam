//! Input validation and sanitization for HighBeam server.

use anyhow::{anyhow, Result};

const MAX_USERNAME_LEN: usize = 32;
const MIN_USERNAME_LEN: usize = 1;
const MAX_PASSWORD_LEN: usize = 256;
const MAX_CHAT_MESSAGE_LEN: usize = 200;
const MAX_VEHICLE_CONFIG_LEN: usize = 1_000_000; // 1MB

/// Validate and normalize a username.
pub fn validate_username(username: &str) -> Result<String> {
    let trimmed = username.trim();

    if trimmed.is_empty() {
        return Err(anyhow!("Username cannot be empty"));
    }

    if trimmed.len() < MIN_USERNAME_LEN || trimmed.len() > MAX_USERNAME_LEN {
        return Err(anyhow!(
            "Username must be between {} and {} characters",
            MIN_USERNAME_LEN,
            MAX_USERNAME_LEN
        ));
    }

    // Check for valid UTF-8 (already guaranteed by Rust strings, but be explicit)
    if !trimmed.chars().all(|c| !c.is_control() || c == '\t') {
        return Err(anyhow!("Username contains invalid characters"));
    }

    // Reject usernames that look like system commands
    let lower = trimmed.to_lowercase();
    if lower.starts_with("admin") || lower.starts_with("root") || lower.starts_with("system") {
        return Err(anyhow!("Username is reserved"));
    }

    Ok(trimmed.to_string())
}

/// Validate a password (if present).
pub fn validate_password(password: Option<&str>) -> Result<Option<String>> {
    match password {
        None => Ok(None),
        Some(p) => {
            if p.len() > MAX_PASSWORD_LEN {
                return Err(anyhow!(
                    "Password is too long (max {} characters)",
                    MAX_PASSWORD_LEN
                ));
            }
            if p.is_empty() {
                return Err(anyhow!("Password cannot be empty when provided"));
            }
            Ok(Some(p.to_string()))
        }
    }
}

/// Validate a chat message.
pub fn validate_chat_message(text: &str) -> Result<String> {
    let trimmed = text.trim();

    if trimmed.is_empty() {
        return Err(anyhow!("Chat message cannot be empty"));
    }

    if trimmed.len() > MAX_CHAT_MESSAGE_LEN {
        return Err(anyhow!(
            "Chat message is too long (max {} characters)",
            MAX_CHAT_MESSAGE_LEN
        ));
    }

    // Reject messages with excessive control characters
    if trimmed.chars().filter(|c| c.is_control()).count() > trimmed.len() / 10 {
        return Err(anyhow!("Chat message contains too many control characters"));
    }

    Ok(trimmed.to_string())
}

/// Validate a vehicle ID.
pub fn validate_vehicle_id(vehicle_id: u16) -> Result<()> {
    // Vehicle IDs should be reasonable (0-10000 is plenty for per-player vehicles)
    if vehicle_id > 10000 {
        return Err(anyhow!("Vehicle ID out of valid range"));
    }
    Ok(())
}

/// Validate vehicle configuration JSON blob size.
pub fn validate_vehicle_config_size(config: &str) -> Result<()> {
    if config.len() > MAX_VEHICLE_CONFIG_LEN {
        return Err(anyhow!(
            "Vehicle config is too large (max {} bytes)",
            MAX_VEHICLE_CONFIG_LEN
        ));
    }
    Ok(())
}

/// Validate configuration parameters.
pub fn validate_server_config(
    max_players: u32,
    max_cars_per_player: u32,
    auth_mode: &str,
    password: Option<&str>,
    allowlist: Option<&Vec<String>>,
    port: u16,
    tick_rate: u32,
) -> Result<()> {
    // Check bounds
    if max_players == 0 || max_players > 1000 {
        return Err(anyhow!("MaxPlayers must be between 1 and 1000"));
    }

    if max_cars_per_player == 0 || max_cars_per_player > 100 {
        return Err(anyhow!("MaxCarsPerPlayer must be between 1 and 100"));
    }

    if port == 0 {
        return Err(anyhow!("Port cannot be 0"));
    }

    if tick_rate == 0 || tick_rate > 120 {
        return Err(anyhow!("TickRate must be between 1 and 120 Hz"));
    }

    // Check auth mode
    match auth_mode {
        "open" => {
            // No password needed
        }
        "password" => {
            if password.is_none() || password.map(|p| p.is_empty()).unwrap_or(true) {
                return Err(anyhow!(
                    "Auth mode is 'password' but no password is configured"
                ));
            }
        }
        "allowlist" => {
            if allowlist.is_none() || allowlist.map(|a| a.is_empty()).unwrap_or(true) {
                return Err(anyhow!("Auth mode is 'allowlist' but allowlist is empty"));
            }
        }
        _ => {
            return Err(anyhow!(
                "Invalid auth mode '{}'. Must be 'open', 'password', or 'allowlist'",
                auth_mode
            ));
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_validate_username_valid() {
        assert!(validate_username("Player1").is_ok());
        assert!(validate_username("Alice").is_ok());
    }

    #[test]
    fn test_validate_username_empty() {
        assert!(validate_username("").is_err());
        assert!(validate_username("   ").is_err());
    }

    #[test]
    fn test_validate_username_too_long() {
        let long = "a".repeat(MAX_USERNAME_LEN + 1);
        assert!(validate_username(&long).is_err());
    }

    #[test]
    fn test_validate_username_reserved() {
        assert!(validate_username("admin").is_err());
        assert!(validate_username("root").is_err());
    }

    #[test]
    fn test_validate_chat_valid() {
        assert!(validate_chat_message("Hello world!").is_ok());
    }

    #[test]
    fn test_validate_chat_empty() {
        assert!(validate_chat_message("").is_err());
    }

    #[test]
    fn test_validate_chat_too_long() {
        let long = "a".repeat(MAX_CHAT_MESSAGE_LEN + 1);
        assert!(validate_chat_message(&long).is_err());
    }
}

/// Validate inputs for the community-node settings panel.
///
/// `tags` – max 5 entries, each 1–20 lowercase alphanumeric + hyphen chars  
/// `region` – empty string or one of: NA, EU, AP, SA, OC, AF  
/// `seed_nodes` – each must be `host:port`, not a private/loopback address  
/// `port` – 1024–65535
pub fn validate_community_node_settings(
    tags: &[String],
    region: &str,
    seed_nodes: &[String],
    port: u16,
) -> anyhow::Result<()> {
    if port < 1024 {
        anyhow::bail!("Community node port must be 1024 or higher");
    }

    if !region.is_empty() && !matches!(region, "NA" | "EU" | "AP" | "SA" | "OC" | "AF") {
        anyhow::bail!("Region must be one of: NA, EU, AP, SA, OC, AF, or empty");
    }

    if tags.len() > 5 {
        anyhow::bail!("Maximum 5 tags allowed");
    }
    for tag in tags {
        if tag.is_empty() || tag.len() > 20 {
            anyhow::bail!("Each tag must be between 1 and 20 characters");
        }
        if !tag
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
        {
            anyhow::bail!(
                "Tags must only contain lowercase letters, digits, and hyphens (got: {})",
                tag
            );
        }
    }

    for seed in seed_nodes {
        // Expect host:port form; rsplitn handles IPv6 [addr]:port
        let mut parts = seed.rsplitn(2, ':');
        let port_str = parts.next().unwrap_or("");
        let host = parts.next().unwrap_or("");

        if host.is_empty() || port_str.is_empty() {
            anyhow::bail!("Seed node '{}' must be in host:port format", seed);
        }
        let _: u16 = port_str
            .parse()
            .map_err(|_| anyhow::anyhow!("Seed node '{}' has an invalid port number", seed))?;
        if community_node_is_private_host(host) {
            anyhow::bail!(
                "Seed node '{}' resolves to a private or loopback address",
                seed
            );
        }
        if host.len() > 253 {
            anyhow::bail!("Seed node hostname is too long");
        }
    }

    Ok(())
}

fn community_node_is_private_host(host: &str) -> bool {
    let h = host.to_lowercase();
    if h == "localhost" || h == "::1" || h == "[::1]" {
        return true;
    }
    if h.starts_with("127.") || h.starts_with("0.0.0.0") {
        return true;
    }
    if h.starts_with("10.") || h.starts_with("192.168.") {
        return true;
    }
    if let Some(b) = h
        .strip_prefix("172.")
        .and_then(|rest| rest.split('.').next())
        .and_then(|n| n.parse::<u8>().ok())
    {
        if (16..=31).contains(&b) {
            return true;
        }
    }
    false
}

/// Validate a public address for use in community node mesh advertisement.
/// 
/// The address must:
/// - Not be empty
/// - Not be 0.0.0.0, 127.x.x.x, 192.168.x.x, 10.x.x.x, or 172.16–31.x.x (private/loopback)
/// - Be at most 253 characters (DNS limit)
/// 
/// Can be an IPv4, IPv6, or hostname.
pub fn validate_public_address(addr: &str) -> anyhow::Result<()> {
    let trimmed = addr.trim();
    
    if trimmed.is_empty() {
        return Err(anyhow!("Public address cannot be empty"));
    }
    
    if trimmed.len() > 253 {
        return Err(anyhow!("Public address is too long (max 253 characters)"));
    }
    
    // Extract hostname part (strip :port if present)
    let host = if let Some(idx) = trimmed.rfind(':') {
        let potential_port = &trimmed[idx + 1..];
        // If the part after : is numeric, treat it as port; otherwise it might be IPv6
        if potential_port.parse::<u16>().is_ok() {
            &trimmed[..idx]
        } else {
            trimmed
        }
    } else {
        trimmed
    };
    
    if community_node_is_private_host(host) {
        return Err(anyhow!(
            "Public address '{}' resolves to a private or loopback address. Use your actual public IP or domain.",
            host
        ));
    }
    
    Ok(())
}

#[cfg(test)]
mod community_node_validation_tests {
    use super::*;

    #[test]
    fn test_valid_settings() {
        assert!(validate_community_node_settings(
            &["drift".to_string(), "racing".to_string()],
            "NA",
            &["203.0.113.10:18862".to_string()],
            18862,
        )
        .is_ok());
    }

    #[test]
    fn test_invalid_port_too_low() {
        assert!(validate_community_node_settings(&[], "", &[], 80).is_err());
    }

    #[test]
    fn test_invalid_region() {
        assert!(validate_community_node_settings(&[], "XX", &[], 18862).is_err());
    }

    #[test]
    fn test_too_many_tags() {
        let tags: Vec<String> = (0..6).map(|i| format!("tag{}", i)).collect();
        assert!(validate_community_node_settings(&tags, "", &[], 18862).is_err());
    }

    #[test]
    fn test_tag_invalid_chars() {
        assert!(
            validate_community_node_settings(&["UPPERCASE".to_string()], "", &[], 18862).is_err()
        );
    }

    #[test]
    fn test_private_seed_rejected() {
        assert!(
            validate_community_node_settings(&[], "", &["127.0.0.1:18862".to_string()], 18862)
                .is_err()
        );
    }

    #[test]
    fn test_seed_bad_format() {
        assert!(
            validate_community_node_settings(&[], "", &["not-a-seed".to_string()], 18862).is_err()
        );
    }
}
