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
