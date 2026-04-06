use anyhow::Result;
use serde::{Deserialize, Serialize};

/// Maximum allowed packet payload size (1 MB).
pub const MAX_PACKET_SIZE: u32 = 1_048_576;

/// Protocol version. Incremented when packet formats change.
pub const PROTOCOL_VERSION: u32 = 2;

/// All TCP packet types, JSON-encoded with a length prefix on the wire.
///
/// The `type` field in JSON determines which variant to deserialize into.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum TcpPacket {
    // ── Server → Client ──────────────────────────────────────────────
    /// First packet sent by the server after TCP connect.
    #[serde(rename = "server_hello")]
    ServerHello {
        version: u32,
        name: String,
        map: String,
        players: u32,
        max_players: u32,
        max_cars: u32,
    },

    /// Response to an AuthRequest.
    #[serde(rename = "auth_response")]
    AuthResponse {
        success: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        player_id: Option<u32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        session_token: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },

    /// Broadcast: a new player joined.
    #[serde(rename = "player_join")]
    PlayerJoin { player_id: u32, name: String },

    /// Broadcast: a player left.
    #[serde(rename = "player_leave")]
    PlayerLeave { player_id: u32 },

    /// Periodic player metrics snapshot (ping, etc.) for HUD overlays.
    #[serde(rename = "player_metrics")]
    PlayerMetrics { players: Vec<PlayerPingInfo> },

    /// Server kicking a player.
    #[serde(rename = "kick")]
    Kick { reason: String },

    /// Generic server-to-client notification message.
    #[serde(rename = "server_message")]
    ServerMessage { text: String },

    /// Server-initiated custom event for client scripts.
    #[serde(rename = "trigger_client_event")]
    TriggerClientEvent {
        name: String,
        #[serde(default)]
        payload: String,
    },

    /// Server sends available mod manifest to a launcher.
    #[serde(rename = "mod_list")]
    ModList { mods: Vec<ModDescriptor> },

    // ── Client → Server ──────────────────────────────────────────────
    /// Client authentication request.
    #[serde(rename = "auth_request")]
    AuthRequest {
        username: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        password: Option<String>,
    },

    /// Client signals it is ready (handshake complete).
    #[serde(rename = "ready")]
    Ready {},

    /// Launcher requests a subset of mods by filename.
    #[serde(rename = "mod_request")]
    ModRequest { names: Vec<String> },

    /// Client-initiated custom event for server plugin handlers.
    #[serde(rename = "trigger_server_event")]
    TriggerServerEvent {
        name: String,
        #[serde(default)]
        payload: String,
    },

    // ── Vehicle packets (Phase 2) ────────────────────────────────────
    /// A vehicle was spawned (client → server has no player_id; server → client fills it in).
    #[serde(rename = "vehicle_spawn")]
    VehicleSpawn {
        #[serde(skip_serializing_if = "Option::is_none")]
        player_id: Option<u32>,
        vehicle_id: u16,
        data: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        spawn_request_id: Option<u32>,
    },

    /// Spawn request was rejected by the server.
    #[serde(rename = "vehicle_spawn_rejected")]
    VehicleSpawnRejected {
        #[serde(skip_serializing_if = "Option::is_none")]
        spawn_request_id: Option<u32>,
        reason: String,
    },

    /// A vehicle's config was edited.
    #[serde(rename = "vehicle_edit")]
    VehicleEdit {
        #[serde(skip_serializing_if = "Option::is_none")]
        player_id: Option<u32>,
        vehicle_id: u16,
        data: String,
    },

    /// A vehicle was deleted.
    #[serde(rename = "vehicle_delete")]
    VehicleDelete {
        #[serde(skip_serializing_if = "Option::is_none")]
        player_id: Option<u32>,
        vehicle_id: u16,
    },

    /// A vehicle was reset (respawned at a position).
    #[serde(rename = "vehicle_reset")]
    VehicleReset {
        #[serde(skip_serializing_if = "Option::is_none")]
        player_id: Option<u32>,
        vehicle_id: u16,
        data: String,
    },

    /// Lightweight transform update over TCP used as fallback while UDP bind is pending.
    #[serde(rename = "vehicle_pose")]
    VehiclePose {
        #[serde(skip_serializing_if = "Option::is_none")]
        player_id: Option<u32>,
        vehicle_id: u16,
        data: String,
    },

    /// Damage/deformation data for a vehicle.
    #[serde(rename = "vehicle_damage")]
    VehicleDamage {
        #[serde(skip_serializing_if = "Option::is_none")]
        player_id: Option<u32>,
        vehicle_id: u16,
        data: String,
    },

    /// Electrics state (lights, signals, horn) for a vehicle.
    #[serde(rename = "vehicle_electrics")]
    VehicleElectrics {
        #[serde(skip_serializing_if = "Option::is_none")]
        player_id: Option<u32>,
        vehicle_id: u16,
        data: String,
    },

    /// Coupling/trailer attachment state between two vehicles.
    #[serde(rename = "vehicle_coupling")]
    VehicleCoupling {
        #[serde(skip_serializing_if = "Option::is_none")]
        player_id: Option<u32>,
        vehicle_id: u16,
        target_vehicle_id: u16,
        coupled: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        node_id: Option<i32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        target_node_id: Option<i32>,
    },

    /// Full world snapshot sent to newly-joined players.
    #[serde(rename = "world_state")]
    WorldState {
        players: Vec<PlayerInfo>,
        vehicles: Vec<VehicleInfo>,
    },

    /// Chat message from client.
    #[serde(rename = "chat_message")]
    ChatMessage { text: String },

    /// Chat message broadcast to all players (includes sender info).
    #[serde(rename = "chat_broadcast")]
    ChatBroadcast {
        player_id: u32,
        player_name: String,
        text: String,
    },

    /// Heartbeat ping/pong packet (Phase 2.2). Server sends ping, client responds with pong.
    #[serde(rename = "ping_pong")]
    PingPong { seq: u32 },
}

/// Player info included in WorldState.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlayerInfo {
    pub player_id: u32,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ping_ms: Option<u32>,
}

/// Lightweight per-player ping snapshot for frequent updates.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlayerPingInfo {
    pub player_id: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ping_ms: Option<u32>,
}

/// Vehicle info included in WorldState.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VehicleInfo {
    pub player_id: u32,
    pub vehicle_id: u16,
    pub data: String,
    pub position: [f32; 3],
    pub rotation: [f32; 4],
    pub velocity: [f32; 3],
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub snapshot_time_ms: Option<u64>,
}

/// Mod descriptor included in ModList.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModDescriptor {
    pub name: String,
    pub size: u64,
    pub hash: String,
}

/// Encode a packet to its wire format: 4-byte LE length + JSON payload.
pub fn encode(packet: &TcpPacket) -> Result<Vec<u8>> {
    let json = serde_json::to_vec(packet)?;
    let len = u32::try_from(json.len())
        .map_err(|_| anyhow::anyhow!("Packet payload exceeds u32 range"))?;

    let mut buf = Vec::with_capacity(4 + json.len());
    buf.extend_from_slice(&len.to_le_bytes());
    buf.extend_from_slice(&json);
    Ok(buf)
}

/// Decode a JSON payload (without length prefix) into a TcpPacket.
pub fn decode(payload: &[u8]) -> Result<TcpPacket> {
    let packet: TcpPacket = serde_json::from_slice(payload)?;
    Ok(packet)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Round-trip encode→decode for every variant.
    fn round_trip(packet: &TcpPacket) {
        let wire = encode(packet).expect("encode failed");
        // First 4 bytes are the LE length
        let len = u32::from_le_bytes(wire[..4].try_into().unwrap()) as usize;
        assert_eq!(len, wire.len() - 4);
        let decoded = decode(&wire[4..]).expect("decode failed");
        // Compare JSON representations for structural equality
        let original_json = serde_json::to_string(packet).unwrap();
        let decoded_json = serde_json::to_string(&decoded).unwrap();
        assert_eq!(original_json, decoded_json);
    }

    #[test]
    fn test_server_hello_round_trip() {
        round_trip(&TcpPacket::ServerHello {
            version: 1,
            name: "Test Server".into(),
            map: "/levels/gridmap_v2/info.json".into(),
            players: 3,
            max_players: 20,
            max_cars: 3,
        });
    }

    #[test]
    fn test_auth_response_success_round_trip() {
        round_trip(&TcpPacket::AuthResponse {
            success: true,
            player_id: Some(1),
            session_token: Some("abc123def456".into()),
            error: None,
        });
    }

    #[test]
    fn test_auth_response_failure_round_trip() {
        round_trip(&TcpPacket::AuthResponse {
            success: false,
            player_id: None,
            session_token: None,
            error: Some("Invalid password".into()),
        });
    }

    #[test]
    fn test_player_join_round_trip() {
        round_trip(&TcpPacket::PlayerJoin {
            player_id: 42,
            name: "TestPlayer".into(),
        });
    }

    #[test]
    fn test_player_leave_round_trip() {
        round_trip(&TcpPacket::PlayerLeave { player_id: 42 });
    }

    #[test]
    fn test_kick_round_trip() {
        round_trip(&TcpPacket::Kick {
            reason: "AFK timeout".into(),
        });
    }

    #[test]
    fn test_mod_list_round_trip() {
        round_trip(&TcpPacket::ModList {
            mods: vec![ModDescriptor {
                name: "my_map.zip".into(),
                size: 123_456,
                hash: "0123456789abcdef".into(),
            }],
        });
    }

    #[test]
    fn test_trigger_client_event_round_trip() {
        round_trip(&TcpPacket::TriggerClientEvent {
            name: "ui_notification".into(),
            payload: "hello".into(),
        });
    }

    #[test]
    fn test_trigger_server_event_round_trip() {
        round_trip(&TcpPacket::TriggerServerEvent {
            name: "ping_plugin".into(),
            payload: "{}".into(),
        });
    }

    #[test]
    fn test_auth_request_round_trip() {
        round_trip(&TcpPacket::AuthRequest {
            username: "Player1".into(),
            password: Some("secret".into()),
        });
    }

    #[test]
    fn test_auth_request_no_password_round_trip() {
        round_trip(&TcpPacket::AuthRequest {
            username: "Player1".into(),
            password: None,
        });
    }

    #[test]
    fn test_ready_round_trip() {
        round_trip(&TcpPacket::Ready {});
    }

    #[test]
    fn test_mod_request_round_trip() {
        round_trip(&TcpPacket::ModRequest {
            names: vec!["my_map.zip".into(), "car_pack.zip".into()],
        });
    }

    #[test]
    fn test_vehicle_spawn_round_trip() {
        round_trip(&TcpPacket::VehicleSpawn {
            player_id: Some(1),
            vehicle_id: 5,
            data: r#"{"model":"pickup"}"#.into(),
            spawn_request_id: None,
        });
    }

    #[test]
    fn test_vehicle_spawn_with_request_id_round_trip() {
        round_trip(&TcpPacket::VehicleSpawn {
            player_id: Some(1),
            vehicle_id: 5,
            data: r#"{"model":"pickup"}"#.into(),
            spawn_request_id: Some(42),
        });
    }

    #[test]
    fn test_vehicle_damage_round_trip() {
        round_trip(&TcpPacket::VehicleDamage {
            player_id: Some(1),
            vehicle_id: 3,
            data: r#"{"beams":[1,2,3]}"#.into(),
        });
    }

    #[test]
    fn test_vehicle_electrics_round_trip() {
        round_trip(&TcpPacket::VehicleElectrics {
            player_id: Some(1),
            vehicle_id: 2,
            data: r#"{"lights":2,"signal_L":1}"#.into(),
        });
    }

    #[test]
    fn test_vehicle_coupling_round_trip() {
        round_trip(&TcpPacket::VehicleCoupling {
            player_id: Some(1),
            vehicle_id: 3,
            target_vehicle_id: 4,
            coupled: true,
            node_id: Some(12),
            target_node_id: Some(7),
        });
    }

    #[test]
    fn test_vehicle_edit_round_trip() {
        round_trip(&TcpPacket::VehicleEdit {
            player_id: Some(1),
            vehicle_id: 5,
            data: r#"{"color":"red"}"#.into(),
        });
    }

    #[test]
    fn test_vehicle_delete_round_trip() {
        round_trip(&TcpPacket::VehicleDelete {
            player_id: Some(1),
            vehicle_id: 5,
        });
    }

    #[test]
    fn test_vehicle_reset_round_trip() {
        round_trip(&TcpPacket::VehicleReset {
            player_id: Some(1),
            vehicle_id: 5,
            data: r#"{"pos":[0,0,0]}"#.into(),
        });
    }

    #[test]
    fn test_world_state_round_trip() {
        round_trip(&TcpPacket::WorldState {
            players: vec![PlayerInfo {
                player_id: 1,
                name: "Alice".into(),
                ping_ms: Some(42),
            }],
            vehicles: vec![VehicleInfo {
                player_id: 1,
                vehicle_id: 1,
                data: r#"{"model":"pickup"}"#.into(),
                position: [10.0, 20.0, 30.0],
                rotation: [0.0, 0.0, 0.0, 1.0],
                velocity: [1.0, 0.0, 0.0],
                snapshot_time_ms: Some(1_700_000_000_000),
            }],
        });
    }

    #[test]
    fn test_max_packet_size_constant() {
        assert_eq!(MAX_PACKET_SIZE, 1_048_576);
    }

    #[test]
    fn test_protocol_version() {
        assert_eq!(PROTOCOL_VERSION, 2);
    }

    #[test]
    fn test_chat_message_round_trip() {
        round_trip(&TcpPacket::ChatMessage {
            text: "Hello, world!".into(),
        });
    }

    #[test]
    fn test_chat_broadcast_round_trip() {
        round_trip(&TcpPacket::ChatBroadcast {
            player_id: 1,
            player_name: "Alice".into(),
            text: "Hello, everyone!".into(),
        });
    }

    #[test]
    fn test_player_metrics_round_trip() {
        round_trip(&TcpPacket::PlayerMetrics {
            players: vec![PlayerPingInfo {
                player_id: 7,
                ping_ms: Some(55),
            }],
        });
    }

    #[test]
    fn test_server_message_round_trip() {
        round_trip(&TcpPacket::ServerMessage {
            text: "Welcome to the server!".into(),
        });
    }

    #[test]
    fn test_decode_rejects_malformed_json_corpus() {
        // Corpus of malformed payloads used to validate decode hardening.
        let corpus: Vec<&[u8]> = vec![
            b"",
            b"{",
            b"[]",
            b"{\"type\":}",
            b"{\"type\":\"unknown\"}",
            b"{\"type\":123}",
            b"{\"success\":true}",
            b"\x00\x01\x02\x03",
            b"not json",
        ];

        for payload in corpus {
            assert!(
                decode(payload).is_err(),
                "payload should fail decode: {payload:?}"
            );
        }
    }

    #[test]
    fn test_decode_fuzz_like_random_bytes_do_not_panic() {
        // Deterministic pseudo-random corpus for malformed payload coverage.
        let mut seed: u64 = 0xBAD5EED;
        for len in [1usize, 2, 3, 4, 8, 16, 32, 64, 128] {
            let mut payload = vec![0u8; len];
            for byte in &mut payload {
                seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
                *byte = (seed >> 56) as u8;
            }

            // Any result is acceptable (Err expected in practice); the key is no panic.
            let _ = decode(&payload);
        }
    }
}
