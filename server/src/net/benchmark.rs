use std::time::Instant;

use anyhow::Result;

use crate::net::packet::{encode, TcpPacket, VehicleInfo};

#[derive(Debug, Clone)]
pub struct JsonBaselineReport {
    pub iterations: usize,
    pub corpus_size: usize,
    pub total_packets: usize,
    pub total_bytes: usize,
    pub elapsed_ms: u128,
    pub packets_per_sec: f64,
    pub mb_per_sec: f64,
    pub avg_packet_bytes: f64,
}

pub fn run_json_baseline_benchmark(iterations: usize) -> Result<JsonBaselineReport> {
    let corpus = sample_corpus();
    let corpus_size = corpus.len();
    let mut total_bytes = 0usize;

    let started = Instant::now();
    for _ in 0..iterations {
        for packet in &corpus {
            let wire = encode(packet)?;
            total_bytes += wire.len();
        }
    }
    let elapsed = started.elapsed();

    let total_packets = iterations * corpus_size;
    let elapsed_secs = elapsed.as_secs_f64().max(0.000_001);

    Ok(JsonBaselineReport {
        iterations,
        corpus_size,
        total_packets,
        total_bytes,
        elapsed_ms: elapsed.as_millis(),
        packets_per_sec: total_packets as f64 / elapsed_secs,
        mb_per_sec: (total_bytes as f64 / (1024.0 * 1024.0)) / elapsed_secs,
        avg_packet_bytes: total_bytes as f64 / total_packets.max(1) as f64,
    })
}

fn sample_corpus() -> Vec<TcpPacket> {
    vec![
        TcpPacket::ServerHello {
            version: 2,
            name: "HighBeam Server".into(),
            map: "/levels/gridmap_v2/info.json".into(),
            players: 12,
            max_players: 20,
            max_cars: 3,
        },
        TcpPacket::AuthRequest {
            username: "PlayerOne".into(),
            password: Some("secret".into()),
        },
        TcpPacket::AuthResponse {
            success: true,
            player_id: Some(1),
            session_token: Some("token_abcdef".into()),
            error: None,
        },
        TcpPacket::WorldState {
            players: vec![
                crate::net::packet::PlayerInfo {
                    player_id: 1,
                    name: "Alice".into(),
                },
                crate::net::packet::PlayerInfo {
                    player_id: 2,
                    name: "Bob".into(),
                },
            ],
            vehicles: vec![VehicleInfo {
                player_id: 1,
                vehicle_id: 11,
                data: "{\"model\":\"pickup\",\"color\":\"red\"}".into(),
                position: [10.0, 20.0, 30.0],
                rotation: [0.0, 0.0, 0.0, 1.0],
                velocity: [1.0, 0.0, 0.0],
            }],
        },
        TcpPacket::VehicleSpawn {
            player_id: Some(1),
            vehicle_id: 42,
            data: "{\"model\":\"sunburst\",\"config\":\"sport\"}".into(),
            spawn_request_id: None,
        },
        TcpPacket::VehicleEdit {
            player_id: Some(1),
            vehicle_id: 42,
            data: "{\"paint\":\"blue\",\"wheels\":\"alloy\"}".into(),
        },
        TcpPacket::ChatBroadcast {
            player_id: 1,
            player_name: "Alice".into(),
            text: "Hello from benchmark".into(),
        },
        TcpPacket::ServerMessage {
            text: "Server restart in 5 minutes".into(),
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn benchmark_runs_and_reports_values() {
        let report = run_json_baseline_benchmark(10).expect("benchmark should run");
        assert!(report.total_packets > 0);
        assert!(report.total_bytes > 0);
        assert!(report.avg_packet_bytes > 0.0);
        assert!(report.packets_per_sec > 0.0);
    }
}
