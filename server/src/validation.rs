//! Input validation and sanitization for HighBeam server.

use anyhow::{anyhow, Result};

const MAX_USERNAME_LEN: usize = 32;
const MIN_USERNAME_LEN: usize = 1;
const MAX_PASSWORD_LEN: usize = 256;
const MAX_CHAT_MESSAGE_LEN: usize = 200;
const MAX_VEHICLE_CONFIG_LEN: usize = 1_000_000; // 1MB
const MAX_DAMAGE_PAYLOAD_LEN: usize = 512 * 1024;
const MAX_DAMAGE_ITEMS: usize = 20_000;
const MAX_DAMAGE_GROUPS: usize = 2_048;
const MAX_COMPONENT_PAYLOAD_LEN: usize = 64 * 1024;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PoseMetadata {
    pub position: [f32; 3],
    pub rotation: [f32; 4],
    pub velocity: [f32; 3],
    pub motion_epoch: Option<u64>,
    pub motion_sequence: Option<u64>,
}

fn json_number(value: Option<&serde_json::Value>, name: &str, limit: f64) -> Result<f64> {
    let value = value
        .and_then(serde_json::Value::as_f64)
        .ok_or_else(|| anyhow!("{name} must be a number"))?;
    if !value.is_finite() || value.abs() > limit {
        return Err(anyhow!("{name} is out of range"));
    }
    Ok(value)
}

fn fixed_numeric_array<const N: usize>(
    value: Option<&serde_json::Value>,
    name: &str,
    limit: f64,
) -> Result<[f32; N]> {
    let values = value
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| anyhow!("{name} must be an array"))?;
    if values.len() != N {
        return Err(anyhow!("{name} must contain exactly {N} numbers"));
    }
    let mut result = [0.0; N];
    for (index, item) in values.iter().enumerate() {
        result[index] = json_number(Some(item), name, limit)? as f32;
    }
    Ok(result)
}

pub fn validate_vehicle_pose(data: &str) -> Result<PoseMetadata> {
    if data.len() > MAX_COMPONENT_PAYLOAD_LEN {
        return Err(anyhow!("Pose payload is too large"));
    }
    let value: serde_json::Value =
        serde_json::from_str(data).map_err(|e| anyhow!("Pose payload is not valid JSON: {e}"))?;
    let object = value
        .as_object()
        .ok_or_else(|| anyhow!("Pose payload must be an object"))?;
    let position = fixed_numeric_array::<3>(object.get("pos"), "pos", 1e7)?;
    let rotation = fixed_numeric_array::<4>(object.get("rot"), "rot", 4.0)?;
    let velocity = fixed_numeric_array::<3>(object.get("vel"), "vel", 1e5)?;
    let quat_len_sq: f32 = rotation.iter().map(|v| v * v).sum();
    if quat_len_sq < 1e-8 {
        return Err(anyhow!("Rotation quaternion is degenerate"));
    }
    json_number(object.get("time"), "time", 1e9)?;

    let motion_epoch = object
        .get("motionEpoch")
        .map(|v| {
            v.as_u64()
                .filter(|value| *value > 0 && *value <= u32::MAX as u64)
                .ok_or_else(|| anyhow!("motionEpoch must be a non-zero u32"))
        })
        .transpose()?;
    let motion_sequence = object
        .get("motionSequence")
        .map(|v| {
            v.as_u64()
                .filter(|value| *value <= u32::MAX as u64)
                .ok_or_else(|| anyhow!("motionSequence must be a u32"))
        })
        .transpose()?;
    if motion_epoch.is_some() != motion_sequence.is_some() {
        return Err(anyhow!(
            "motionEpoch and motionSequence must be supplied together"
        ));
    }
    if let Some(lock) = object.get("steeringLock") {
        let lock = lock
            .as_u64()
            .ok_or_else(|| anyhow!("steeringLock must be an integer"))?;
        if !(1..=4096).contains(&lock) {
            return Err(anyhow!("steeringLock is out of range"));
        }
    }
    if let Some(ang_vel) = object.get("angVel") {
        fixed_numeric_array::<3>(Some(ang_vel), "angVel", 1e4)?;
    }
    if let Some(inputs) = object.get("inputs") {
        let inputs = inputs
            .as_object()
            .ok_or_else(|| anyhow!("inputs must be an object"))?;
        for (field, limit) in [
            ("steer", 8.0),
            ("throttle", 2.0),
            ("brake", 2.0),
            ("gear", 16.0),
            ("handbrake", 2.0),
        ] {
            if let Some(value) = inputs.get(field) {
                json_number(Some(value), field, limit)?;
            }
        }
        if inputs.keys().any(|field| {
            !matches!(
                field.as_str(),
                "steer" | "throttle" | "brake" | "gear" | "handbrake"
            )
        }) {
            return Err(anyhow!("Unknown pose input field"));
        }
    }
    if let Some(sample_delta) = object.get("sampleDelta") {
        json_number(Some(sample_delta), "sampleDelta", 1.0)?;
    }

    Ok(PoseMetadata {
        position,
        rotation,
        velocity,
        motion_epoch,
        motion_sequence,
    })
}

pub fn validate_vehicle_reset(data: &str) -> Result<()> {
    if data.len() > MAX_COMPONENT_PAYLOAD_LEN {
        return Err(anyhow!("Reset payload is too large"));
    }
    let value: serde_json::Value =
        serde_json::from_str(data).map_err(|e| anyhow!("Reset payload is not valid JSON: {e}"))?;
    let object = value
        .as_object()
        .ok_or_else(|| anyhow!("Reset payload must be an object"))?;
    let rotation = fixed_numeric_array::<4>(object.get("rot"), "rot", 4.0)?;
    fixed_numeric_array::<3>(object.get("pos"), "pos", 1e7)?;
    if rotation.iter().map(|v| v * v).sum::<f32>() < 1e-8 {
        return Err(anyhow!("Reset rotation quaternion is degenerate"));
    }
    json_number(object.get("time"), "time", 1e9)?;
    if let Some(epoch) = object.get("motionEpoch") {
        let epoch = epoch
            .as_u64()
            .ok_or_else(|| anyhow!("motionEpoch must be an integer"))?;
        if epoch == 0 || epoch > u32::MAX as u64 {
            return Err(anyhow!("motionEpoch is out of range"));
        }
    }
    if object
        .get("damageEpoch")
        .is_some_and(|epoch| epoch.as_u64().is_none())
    {
        return Err(anyhow!("damageEpoch must be a non-negative integer"));
    }
    Ok(())
}

pub fn validate_vehicle_inputs(data: &str) -> Result<()> {
    if data.len() > 1024 {
        return Err(anyhow!("Input payload is too large"));
    }
    let mut seen = std::collections::HashSet::new();
    for part in data.split(',').filter(|part| !part.is_empty()) {
        let (key, raw) = part
            .split_once('=')
            .ok_or_else(|| anyhow!("Invalid input field"))?;
        if !seen.insert(key) {
            return Err(anyhow!("Duplicate input field"));
        }
        match key {
            "s" => {
                let value: f64 = raw.parse().map_err(|_| anyhow!("Invalid steering value"))?;
                if !value.is_finite() || value.abs() > 8.0 {
                    return Err(anyhow!("Steering is out of range"));
                }
            }
            "t" | "b" | "p" | "c" => {
                let value: f64 = raw.parse().map_err(|_| anyhow!("Invalid input value"))?;
                if !value.is_finite() || !(-0.1..=1.1).contains(&value) {
                    return Err(anyhow!("Input is out of range"));
                }
            }
            "l" => {
                let value: u16 = raw.parse().map_err(|_| anyhow!("Invalid steering lock"))?;
                if !(1..=4096).contains(&value) {
                    return Err(anyhow!("Steering lock is out of range"));
                }
            }
            "k" => match raw {
                "manual" | "sequential" | "automatic" | "cvt" | "electric" | "unknown" => {}
                _ => return Err(anyhow!("Unsupported gearbox schema")),
            },
            "g" => {
                if raw.len() > 16
                    || !raw
                        .chars()
                        .all(|c| c.is_ascii_alphanumeric() || "+-.".contains(c))
                {
                    return Err(anyhow!("Invalid gear value"));
                }
            }
            _ => return Err(anyhow!("Unknown input field")),
        }
    }
    Ok(())
}

pub fn validate_vehicle_electrics(data: &str) -> Result<()> {
    if data.len() > MAX_COMPONENT_PAYLOAD_LEN {
        return Err(anyhow!("Electrics payload is too large"));
    }
    let value: serde_json::Value = serde_json::from_str(data)
        .map_err(|e| anyhow!("Electrics payload is not valid JSON: {e}"))?;
    let object = value
        .as_object()
        .ok_or_else(|| anyhow!("Electrics payload must be an object"))?;
    if object.len() > 128 {
        return Err(anyhow!("Too many electrics fields"));
    }
    for (key, value) in object {
        if key.is_empty() || key.len() > 64 || key.chars().any(char::is_control) {
            return Err(anyhow!("Invalid electrics key"));
        }
        match value {
            serde_json::Value::Bool(_) | serde_json::Value::Null => {}
            serde_json::Value::Number(number)
                if number
                    .as_f64()
                    .is_some_and(|v| v.is_finite() && v.abs() <= 1e6) => {}
            serde_json::Value::String(text)
                if text.len() <= 128 && !text.chars().any(char::is_control) => {}
            _ => return Err(anyhow!("Invalid electrics value")),
        }
    }
    Ok(())
}

pub fn validate_vehicle_powertrain(data: &str) -> Result<()> {
    if data.len() > MAX_COMPONENT_PAYLOAD_LEN {
        return Err(anyhow!("Powertrain payload is too large"));
    }
    let value: serde_json::Value = serde_json::from_str(data)
        .map_err(|e| anyhow!("Powertrain payload is not valid JSON: {e}"))?;
    let object = value
        .as_object()
        .ok_or_else(|| anyhow!("Powertrain payload must be an object"))?;
    if object.len() > 256 {
        return Err(anyhow!("Too many powertrain fields"));
    }
    for (key, value) in object {
        if key == "engines" {
            let engines = value
                .as_object()
                .ok_or_else(|| anyhow!("engines must be an object"))?;
            if engines.len() > 32 {
                return Err(anyhow!("Too many engines"));
            }
            for (name, state) in engines {
                if name.is_empty() || name.len() > 64 {
                    return Err(anyhow!("Invalid engine name"));
                }
                let state = state
                    .as_object()
                    .ok_or_else(|| anyhow!("Engine state must be an object"))?;
                for (field, value) in state {
                    if !matches!(field.as_str(), "ignCoef" | "starterCoef" | "stalled") {
                        return Err(anyhow!("Unknown engine state field"));
                    }
                    json_number(Some(value), field, 4.0)?;
                }
            }
        } else if let Some(_device_name) = key.strip_prefix("dev_") {
            let mode = value
                .as_str()
                .ok_or_else(|| anyhow!("Device mode must be a string"))?;
            if mode.is_empty() || mode.len() > 64 || mode.chars().any(char::is_control) {
                return Err(anyhow!("Invalid device mode"));
            }
        } else if matches!(
            key.as_str(),
            "ignCoef" | "starterCoef" | "stalled" | "ignLevel"
        ) {
            json_number(Some(value), key, 16.0)?;
        } else {
            return Err(anyhow!("Unknown powertrain field"));
        }
    }
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DamageMetadata {
    pub epoch: Option<u64>,
    pub revision: Option<u64>,
    pub config_revision: Option<u64>,
}

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

/// Validate a cumulative vehicle-damage snapshot before retaining or relaying it.
/// Versioned envelopes use `{schemaVersion,epoch,revision,state}`; legacy root
/// snapshots remain accepted during the protocol-v2 migration.
pub fn validate_vehicle_damage(data: &str) -> Result<DamageMetadata> {
    if data.len() > MAX_DAMAGE_PAYLOAD_LEN {
        return Err(anyhow!("Damage payload is too large"));
    }
    let root: serde_json::Value =
        serde_json::from_str(data).map_err(|e| anyhow!("Damage payload is not valid JSON: {e}"))?;
    let root_obj = root
        .as_object()
        .ok_or_else(|| anyhow!("Damage payload must be an object"))?;

    let versioned = root_obj.contains_key("state");
    let (state, epoch, revision, config_revision) = if versioned {
        let version = root_obj
            .get("schemaVersion")
            .and_then(serde_json::Value::as_u64)
            .ok_or_else(|| anyhow!("Damage envelope is missing schemaVersion"))?;
        if version != 1 {
            return Err(anyhow!("Unsupported damage schema version"));
        }
        let epoch = root_obj
            .get("epoch")
            .and_then(serde_json::Value::as_u64)
            .ok_or_else(|| anyhow!("Damage envelope is missing epoch"))?;
        let revision = root_obj
            .get("revision")
            .and_then(serde_json::Value::as_u64)
            .ok_or_else(|| anyhow!("Damage envelope is missing revision"))?;
        let config_revision = root_obj
            .get("configRevision")
            .and_then(serde_json::Value::as_u64)
            .unwrap_or(0);
        let state = root_obj
            .get("state")
            .and_then(serde_json::Value::as_object)
            .ok_or_else(|| anyhow!("Damage envelope state must be an object"))?;
        (state, Some(epoch), Some(revision), Some(config_revision))
    } else {
        (root_obj, None, None, None)
    };

    if state.contains_key("nodes") {
        return Err(anyhow!(
            "Transient node positions are not valid damage state"
        ));
    }

    if let Some(broken) = state.get("broken") {
        let items = broken
            .as_array()
            .ok_or_else(|| anyhow!("broken must be an array"))?;
        if items.len() > MAX_DAMAGE_ITEMS {
            return Err(anyhow!("Too many broken beams"));
        }
        for id in items {
            let id = id
                .as_u64()
                .ok_or_else(|| anyhow!("Broken beam IDs must be non-negative integers"))?;
            if id > 1_000_000 {
                return Err(anyhow!("Broken beam ID is out of range"));
            }
        }
    }

    if let Some(groups) = state.get("breakGroups") {
        let items = groups
            .as_array()
            .ok_or_else(|| anyhow!("breakGroups must be an array"))?;
        if items.len() > MAX_DAMAGE_GROUPS {
            return Err(anyhow!("Too many break groups"));
        }
        for group in items {
            let group = group
                .as_str()
                .ok_or_else(|| anyhow!("Break groups must be strings"))?;
            if group.is_empty() || group.len() > 128 || group.chars().any(char::is_control) {
                return Err(anyhow!("Invalid break group"));
            }
        }
    }

    if let Some(deform) = state.get("deform") {
        let entries = deform
            .as_object()
            .ok_or_else(|| anyhow!("deform must be an object"))?;
        if entries.len() > MAX_DAMAGE_ITEMS {
            return Err(anyhow!("Too many deformed beams"));
        }
        for (raw_id, value) in entries {
            let id: u64 = raw_id
                .parse()
                .map_err(|_| anyhow!("Deformed beam ID must be an integer"))?;
            if id > 1_000_000 {
                return Err(anyhow!("Deformed beam ID is out of range"));
            }
            let (deformation, rest_length) = match value.as_array() {
                Some(values) if values.len() >= 2 => (
                    values[0]
                        .as_f64()
                        .ok_or_else(|| anyhow!("Invalid deformation value"))?,
                    values[1]
                        .as_f64()
                        .ok_or_else(|| anyhow!("Invalid beam rest length"))?,
                ),
                _ => (
                    0.0,
                    value
                        .as_f64()
                        .ok_or_else(|| anyhow!("Invalid legacy beam rest length"))?,
                ),
            };
            if !deformation.is_finite()
                || !rest_length.is_finite()
                || deformation.abs() > 1_000.0
                || !(0.0001..=1_000.0).contains(&rest_length)
            {
                return Err(anyhow!("Deformation values are out of range"));
            }
        }
    }

    Ok(DamageMetadata {
        epoch,
        revision,
        config_revision,
    })
}

#[cfg(test)]
mod damage_validation_tests {
    use super::*;

    #[test]
    fn accepts_versioned_damage_and_reports_ordering_metadata() {
        let data = r#"{"schemaVersion":1,"epoch":2,"revision":7,"configRevision":3,"state":{"broken":[1,9],"breakGroups":["door"],"deform":{"4":[0.25,1.5]}}}"#;
        let meta = validate_vehicle_damage(data).expect("valid damage envelope");
        assert_eq!(meta.epoch, Some(2));
        assert_eq!(meta.revision, Some(7));
        assert_eq!(meta.config_revision, Some(3));
    }

    #[test]
    fn rejects_transient_nodes_and_invalid_deformation() {
        assert!(validate_vehicle_damage(r#"{"broken":[],"nodes":{"1":[0,0,0]}}"#).is_err());
        assert!(validate_vehicle_damage(r#"{"broken":[],"deform":{"1":[0.2,-1]}}"#).is_err());
    }

    #[test]
    fn accepts_legacy_structural_snapshot_during_migration() {
        let meta = validate_vehicle_damage(r#"{"broken":[3],"deform":{}}"#)
            .expect("legacy structural snapshot");
        assert_eq!(meta.epoch, None);
    }
}

#[cfg(test)]
mod component_validation_tests {
    use super::*;

    #[test]
    fn validates_versioned_pose_and_rejects_nonfinite_or_partial_ordering() {
        let pose = r#"{"pos":[1,2,3],"rot":[0,0,0,1],"vel":[4,5,6],"time":2.5,"motionEpoch":3,"motionSequence":9,"steeringLock":1080,"angVel":[0,0.1,0]}"#;
        let metadata = validate_vehicle_pose(pose).expect("valid pose");
        assert_eq!(metadata.motion_epoch, Some(3));
        assert_eq!(metadata.motion_sequence, Some(9));
        assert!(validate_vehicle_pose(
            r#"{"pos":[1,2,3],"rot":[0,0,0,1],"vel":[0,0,0],"time":1,"motionEpoch":2}"#
        )
        .is_err());
        assert!(validate_vehicle_pose(
            r#"{"pos":[1e99,2,3],"rot":[0,0,0,1],"vel":[0,0,0],"time":1}"#
        )
        .is_err());
        assert!(validate_vehicle_reset(
            r#"{"pos":[1,2,3],"rot":[0,0,0,1],"time":1,"motionEpoch":4,"damageEpoch":2}"#
        )
        .is_ok());
        assert!(validate_vehicle_reset(r#"{"pos":[1,2,3],"rot":[0,0,0,0],"time":1}"#).is_err());
    }

    #[test]
    fn validates_complete_input_schema_and_ranges() {
        assert!(validate_vehicle_inputs("l=1080,s=1.2,t=1,b=0,p=0,c=0,k=automatic,g=M2").is_ok());
        assert!(validate_vehicle_inputs("l=0,s=0").is_err());
        assert!(validate_vehicle_inputs("k=spaceship,g=D").is_err());
        assert!(validate_vehicle_inputs("s=0,s=1").is_err());
    }

    #[test]
    fn validates_electrics_and_multi_engine_powertrain_shapes() {
        assert!(validate_vehicle_electrics(r#"{"lights_state":1,"signal_L":true}"#).is_ok());
        assert!(validate_vehicle_electrics(r#"{"bad":[]}"#).is_err());
        assert!(validate_vehicle_powertrain(r#"{"ignLevel":2,"dev_gearbox":"drive","engines":{"engineA":{"ignCoef":1,"starterCoef":0,"stalled":0},"engineB":{"ignCoef":0.5}}}"#).is_ok());
        assert!(validate_vehicle_powertrain(r#"{"rawPointer":1}"#).is_err());
    }
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
    if h.starts_with("fc") || h.starts_with("fd") || h.starts_with("fe80:") {
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

    if trimmed.starts_with('[') {
        let Some(end_bracket) = trimmed.find(']') else {
            return Err(anyhow!("Public address has an invalid IPv6 bracket format"));
        };
        if end_bracket != trimmed.len() - 1 {
            return Err(anyhow!(
                "Public address must not include a port; set only the host or IP"
            ));
        }

        let host = &trimmed[1..end_bracket];
        host.parse::<std::net::Ipv6Addr>()
            .map_err(|_| anyhow!("Public address '{}' is not a valid IPv6 host", trimmed))?;

        if community_node_is_private_host(host) {
            return Err(anyhow!(
                "Public address '{}' resolves to a private or loopback address. Use your actual public IP or domain.",
                host
            ));
        }

        return Ok(());
    }

    if trimmed.parse::<std::net::Ipv6Addr>().is_ok() {
        if community_node_is_private_host(trimmed) {
            return Err(anyhow!(
                "Public address '{}' resolves to a private or loopback address. Use your actual public IP or domain.",
                trimmed
            ));
        }
        return Ok(());
    }

    if trimmed.contains(':') {
        return Err(anyhow!(
            "Public address must not include a port; set only the host or IP"
        ));
    }

    if community_node_is_private_host(trimmed) {
        return Err(anyhow!(
            "Public address '{}' resolves to a private or loopback address. Use your actual public IP or domain.",
            trimmed
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

    #[test]
    fn test_public_address_accepts_hostname() {
        assert!(validate_public_address("play.example.com").is_ok());
    }

    #[test]
    fn test_public_address_rejects_private_ip() {
        assert!(validate_public_address("192.168.1.50").is_err());
    }

    #[test]
    fn test_public_address_rejects_host_with_port() {
        assert!(validate_public_address("play.example.com:18860").is_err());
    }
}
