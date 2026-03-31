use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use sysinfo::{ProcessesToUpdate, System};

use crate::session::manager::SessionManager;
use crate::state::world::WorldState;

static GLOBAL_METRICS: OnceLock<Arc<ServerMetrics>> = OnceLock::new();

pub struct ServerMetrics {
    tcp_rx_packets: AtomicU64,
    tcp_tx_packets: AtomicU64,
    udp_rx_packets: AtomicU64,
    udp_tx_packets: AtomicU64,
    mod_sync_packets: AtomicU64,
    mod_sync_bytes: AtomicU64,
}

impl ServerMetrics {
    pub fn new() -> Self {
        Self {
            tcp_rx_packets: AtomicU64::new(0),
            tcp_tx_packets: AtomicU64::new(0),
            udp_rx_packets: AtomicU64::new(0),
            udp_tx_packets: AtomicU64::new(0),
            mod_sync_packets: AtomicU64::new(0),
            mod_sync_bytes: AtomicU64::new(0),
        }
    }

    pub fn record_tcp_rx(&self) {
        self.tcp_rx_packets.fetch_add(1, Ordering::Relaxed);
    }

    pub fn record_tcp_tx(&self) {
        self.tcp_tx_packets.fetch_add(1, Ordering::Relaxed);
    }

    pub fn record_udp_rx(&self) {
        self.udp_rx_packets.fetch_add(1, Ordering::Relaxed);
    }

    pub fn record_udp_tx(&self, packet_count: u64) {
        self.udp_tx_packets
            .fetch_add(packet_count, Ordering::Relaxed);
    }

    pub fn record_mod_sync_packet(&self) {
        self.mod_sync_packets.fetch_add(1, Ordering::Relaxed);
    }

    pub fn record_mod_sync_bytes(&self, byte_count: u64) {
        self.mod_sync_bytes.fetch_add(byte_count, Ordering::Relaxed);
    }

    fn take_interval_snapshot(&self) -> MetricsSnapshot {
        MetricsSnapshot {
            tcp_rx_packets: self.tcp_rx_packets.swap(0, Ordering::Relaxed),
            tcp_tx_packets: self.tcp_tx_packets.swap(0, Ordering::Relaxed),
            udp_rx_packets: self.udp_rx_packets.swap(0, Ordering::Relaxed),
            udp_tx_packets: self.udp_tx_packets.swap(0, Ordering::Relaxed),
            mod_sync_packets: self.mod_sync_packets.swap(0, Ordering::Relaxed),
            mod_sync_bytes: self.mod_sync_bytes.swap(0, Ordering::Relaxed),
        }
    }
}

struct MetricsSnapshot {
    tcp_rx_packets: u64,
    tcp_tx_packets: u64,
    udp_rx_packets: u64,
    udp_tx_packets: u64,
    mod_sync_packets: u64,
    mod_sync_bytes: u64,
}

pub fn install_global(metrics: Arc<ServerMetrics>) {
    let _ = GLOBAL_METRICS.set(metrics);
}

pub fn global() -> Option<&'static Arc<ServerMetrics>> {
    GLOBAL_METRICS.get()
}

pub fn spawn_metrics_logger(
    interval_sec: u64,
    sessions: Arc<SessionManager>,
    world: Arc<WorldState>,
    log_rotation_policy: Option<crate::log_rotation::LogRotationPolicy>,
) {
    if interval_sec == 0 {
        tracing::info!("Runtime metrics logging disabled (MetricsIntervalSec=0)");
        return;
    }

    tokio::spawn(async move {
        let interval = Duration::from_secs(interval_sec);
        let mut system = System::new();
        let current_pid = sysinfo::get_current_pid().ok();

        loop {
            tokio::time::sleep(interval).await;

            let snapshot = global()
                .map(|metrics| metrics.take_interval_snapshot())
                .unwrap_or(MetricsSnapshot {
                    tcp_rx_packets: 0,
                    tcp_tx_packets: 0,
                    udp_rx_packets: 0,
                    udp_tx_packets: 0,
                    mod_sync_packets: 0,
                    mod_sync_bytes: 0,
                });

            let memory_rss_mib = current_pid.and_then(|pid| {
                let _ = system.refresh_processes(ProcessesToUpdate::Some(&[pid]), false);
                system
                    .process(pid)
                    .map(|process| process.memory() as f64 / (1024.0 * 1024.0))
            });

            tracing::info!(
                player_count = sessions.player_count(),
                vehicle_count = world.vehicle_count(),
                tcp_rx_packets = snapshot.tcp_rx_packets,
                tcp_tx_packets = snapshot.tcp_tx_packets,
                udp_rx_packets = snapshot.udp_rx_packets,
                udp_tx_packets = snapshot.udp_tx_packets,
                mod_sync_packets = snapshot.mod_sync_packets,
                mod_sync_bytes = snapshot.mod_sync_bytes,
                memory_rss_mib = memory_rss_mib.unwrap_or(0.0),
                interval_sec,
                "Runtime metrics"
            );

            // Perform log rotation if policy is configured
            if let Some(ref policy) = log_rotation_policy {
                if let Err(e) = policy.rotate_and_clean(std::path::Path::new("server.log")) {
                    tracing::warn!(error = %e, "Log rotation failed");
                }
            }
        }
    });
}
