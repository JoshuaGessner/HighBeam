//! Transparent TCP + UDP relay proxy.
//!
//! The BeamNG.drive Lua sandbox restricts `socket.tcp():connect()` to
//! localhost only, returning `"connect restricted"` for any non‐loopback
//! address.  This module spins up a pair of local TCP and UDP listeners on
//! `127.0.0.1` (OS-assigned ports) and relays all bytes bidirectionally
//! to/from the real remote game server.
//!
//! The relay is **protocol-agnostic** — it never parses, decodes, or modifies
//! packets.  This keeps the launcher decoupled from the wire format and adds
//! negligible latency (one extra memcpy over the loopback interface).

use std::io::{self, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream, ToSocketAddrs, UdpSocket};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

/// Buffer size for relay read/write loops.
const RELAY_BUF: usize = 65_536; // 64 KiB

/// Timeout applied to UDP recv so threads can check the shutdown flag.
const UDP_POLL_TIMEOUT: Duration = Duration::from_millis(250);

/// Timeout applied to TCP reads so threads can check the shutdown flag.
const TCP_POLL_TIMEOUT: Duration = Duration::from_millis(250);

// ─────────────────────────────────────────── Public handle ──────────────────

/// Opaque handle returned by [`start`].  Drop or call [`ProxyHandle::shutdown`]
/// to tear the relay down.
pub struct ProxyHandle {
    pub tcp_port: u16,
    pub udp_port: u16,
    shutdown: Arc<AtomicBool>,
    threads: Vec<JoinHandle<()>>,
}

impl ProxyHandle {
    /// Signal all relay threads to stop and join them.
    pub fn shutdown(mut self) {
        self.shutdown.store(true, Ordering::SeqCst);
        for h in std::mem::take(&mut self.threads) {
            let _ = h.join();
        }
    }
}

impl Drop for ProxyHandle {
    fn drop(&mut self) {
        self.shutdown.store(true, Ordering::SeqCst);
        // We cannot move out of `self.threads` in Drop, but setting the flag
        // is enough — the OS will reclaim the threads when the process exits
        // or the sockets close.
    }
}

// ──────────────────────────────────────────── Entry point ───────────────────

/// Start a transparent TCP+UDP proxy to `remote_addr`.
///
/// Returns a [`ProxyHandle`] with the local ports the in-game client should
/// connect to.  The relay runs on background threads and stops when the handle
/// is dropped / `shutdown()` is called.
pub fn start(remote_addr: &str) -> anyhow::Result<ProxyHandle> {
    let remote: SocketAddr = remote_addr
        .to_socket_addrs()
        .map_err(|e| anyhow::anyhow!("Failed to resolve '{}': {}", remote_addr, e))?
        .next()
        .ok_or_else(|| anyhow::anyhow!("No addresses found for '{}'", remote_addr))?;

    let shutdown = Arc::new(AtomicBool::new(false));
    let mut threads = Vec::new();

    // ── TCP ──────────────────────────────────────────────────────────────
    let tcp_listener = TcpListener::bind("127.0.0.1:0")?;
    let tcp_port = tcp_listener.local_addr()?.port();
    tcp_listener.set_nonblocking(false)?;

    tracing::info!(tcp_port, %remote, "Proxy TCP listener bound");

    let sd = shutdown.clone();
    threads.push(
        thread::Builder::new()
            .name("proxy-tcp".into())
            .spawn(move || {
                if let Err(e) = run_tcp_proxy(tcp_listener, remote, sd) {
                    tracing::warn!(error = %e, "Proxy TCP relay ended with error");
                }
            })?,
    );

    // ── UDP ──────────────────────────────────────────────────────────────
    let udp_local = UdpSocket::bind("127.0.0.1:0")?;
    let udp_port = udp_local.local_addr()?.port();

    tracing::info!(udp_port, %remote, "Proxy UDP listener bound");

    let sd = shutdown.clone();
    threads.push(
        thread::Builder::new()
            .name("proxy-udp".into())
            .spawn(move || {
                if let Err(e) = run_udp_proxy(udp_local, remote, sd) {
                    tracing::warn!(error = %e, "Proxy UDP relay ended with error");
                }
            })?,
    );

    Ok(ProxyHandle {
        tcp_port,
        udp_port,
        shutdown,
        threads,
    })
}

// ─────────────────────────────── TCP relay ──────────────────────────────────

fn run_tcp_proxy(
    listener: TcpListener,
    remote: SocketAddr,
    shutdown: Arc<AtomicBool>,
) -> anyhow::Result<()> {
    // Accept clients in a loop so reconnects can re-use the same proxy ports.
    // Use a short non-blocking poll so we can honour `shutdown`.
    listener.set_nonblocking(true)?;

    while !shutdown.load(Ordering::SeqCst) {
        let client = loop {
            if shutdown.load(Ordering::SeqCst) {
                return Ok(());
            }
            match listener.accept() {
                Ok((stream, addr)) => {
                    tracing::info!(%addr, "Proxy TCP: client connected");
                    break stream;
                }
                Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(50));
                }
                Err(e) => return Err(e.into()),
            }
        };

        if let Err(e) = run_tcp_session(client, remote, shutdown.clone()) {
            tracing::warn!(error = %e, "Proxy TCP session ended with error");
        }
        tracing::info!("Proxy TCP: waiting for next client session");
    }

    Ok(())
}

fn run_tcp_session(
    client: TcpStream,
    remote: SocketAddr,
    shutdown: Arc<AtomicBool>,
) -> anyhow::Result<()> {
    // Connect to the real server.
    let server = TcpStream::connect_timeout(&remote, Duration::from_secs(10))
        .map_err(|e| anyhow::anyhow!("Proxy TCP: failed to connect to {}: {}", remote, e))?;
    tracing::info!(%remote, "Proxy TCP: connected to server");

    // Set read timeouts so relay threads can check `shutdown`.
    client.set_read_timeout(Some(TCP_POLL_TIMEOUT))?;
    server.set_read_timeout(Some(TCP_POLL_TIMEOUT))?;

    let client_r = client.try_clone()?;
    let client_w = client.try_clone()?;
    let server_r = server.try_clone()?;
    let server_w = server.try_clone()?;

    let session_stop = Arc::new(AtomicBool::new(false));
    let stop1 = session_stop.clone();
    let stop2 = session_stop.clone();
    let shutdown1 = shutdown.clone();
    let shutdown2 = shutdown.clone();
    let c2s_bytes = Arc::new(AtomicU64::new(0));
    let s2c_bytes = Arc::new(AtomicU64::new(0));
    let c2s_bytes_thread = c2s_bytes.clone();
    let s2c_bytes_thread = s2c_bytes.clone();

    // client -> server
    let h1 = thread::Builder::new()
        .name("proxy-tcp-c2s".into())
        .spawn(move || {
            relay_tcp(
                client_r,
                server_w,
                shutdown1,
                stop1,
                "client->server",
                c2s_bytes_thread,
            )
        })?;

    // server -> client
    let h2 = thread::Builder::new()
        .name("proxy-tcp-s2c".into())
        .spawn(move || {
            relay_tcp(
                server_r,
                client_w,
                shutdown2,
                stop2,
                "server->client",
                s2c_bytes_thread,
            )
        })?;

    let _ = h1.join();
    session_stop.store(true, Ordering::SeqCst);
    let _ = h2.join();

    tracing::info!(
        c2s_bytes = c2s_bytes.load(Ordering::Relaxed),
        s2c_bytes = s2c_bytes.load(Ordering::Relaxed),
        "Proxy TCP: client session closed"
    );
    Ok(())
}

fn relay_tcp(
    mut reader: TcpStream,
    mut writer: TcpStream,
    shutdown: Arc<AtomicBool>,
    session_stop: Arc<AtomicBool>,
    label: &str,
    byte_counter: Arc<AtomicU64>,
) {
    let mut buf = vec![0u8; RELAY_BUF];
    loop {
        if shutdown.load(Ordering::SeqCst) {
            break;
        }
        if session_stop.load(Ordering::SeqCst) {
            break;
        }

        match reader.read(&mut buf) {
            Ok(0) => {
                tracing::debug!(label, "Proxy TCP: EOF");
                break;
            }
            Ok(n) => {
                byte_counter.fetch_add(n as u64, Ordering::Relaxed);
                if writer.write_all(&buf[..n]).is_err() {
                    break;
                }
            }
            Err(ref e)
                if e.kind() == io::ErrorKind::WouldBlock || e.kind() == io::ErrorKind::TimedOut =>
            {
                continue;
            }
            Err(_) => break,
        }
    }
    session_stop.store(true, Ordering::SeqCst);
    // Shut down writer half to unblock the peer relay thread.
    let _ = writer.shutdown(std::net::Shutdown::Write);
}

// ─────────────────────────────── UDP relay ──────────────────────────────────

fn run_udp_proxy(
    local: UdpSocket,
    remote: SocketAddr,
    shutdown: Arc<AtomicBool>,
) -> anyhow::Result<()> {
    local.set_read_timeout(Some(UDP_POLL_TIMEOUT))?;

    // Create a second UDP socket for talking to the real server.
    // (We keep them separate so `recv_from` on `local` only returns client
    // packets and `recv_from` on `server_sock` only returns server packets.)
    let server_sock = UdpSocket::bind("0.0.0.0:0")?;
    server_sock.connect(remote)?;
    server_sock.set_read_timeout(Some(UDP_POLL_TIMEOUT))?;

    tracing::info!(%remote, "Proxy UDP: relay started");

    let local_clone = local.try_clone()?;
    let server_clone = server_sock.try_clone()?;

    let sd1 = shutdown.clone();
    let sd2 = shutdown.clone();
    let c2s_packets = Arc::new(AtomicU64::new(0));
    let c2s_bytes = Arc::new(AtomicU64::new(0));
    let s2c_packets = Arc::new(AtomicU64::new(0));
    let s2c_bytes = Arc::new(AtomicU64::new(0));

    let c2s_packets_thread = c2s_packets.clone();
    let c2s_bytes_thread = c2s_bytes.clone();
    let s2c_packets_thread = s2c_packets.clone();
    let s2c_bytes_thread = s2c_bytes.clone();

    // client → server
    let h1 = thread::Builder::new()
        .name("proxy-udp-c2s".into())
        .spawn(move || {
            relay_udp_c2s(
                local,
                server_sock,
                sd1,
                c2s_packets_thread,
                c2s_bytes_thread,
            )
        })?;

    // server → client
    let h2 = thread::Builder::new()
        .name("proxy-udp-s2c".into())
        .spawn(move || {
            relay_udp_s2c(
                server_clone,
                local_clone,
                sd2,
                s2c_packets_thread,
                s2c_bytes_thread,
            )
        })?;

    let _ = h1.join();
    shutdown.store(true, Ordering::SeqCst);
    let _ = h2.join();

    tracing::info!(
        c2s_packets = c2s_packets.load(Ordering::Relaxed),
        c2s_bytes = c2s_bytes.load(Ordering::Relaxed),
        s2c_packets = s2c_packets.load(Ordering::Relaxed),
        s2c_bytes = s2c_bytes.load(Ordering::Relaxed),
        "Proxy UDP relay stopped"
    );
    Ok(())
}

/// Relay datagrams from the local client to the remote server.
fn relay_udp_c2s(
    local: UdpSocket,
    server: UdpSocket,
    shutdown: Arc<AtomicBool>,
    packet_counter: Arc<AtomicU64>,
    byte_counter: Arc<AtomicU64>,
) {
    let mut buf = vec![0u8; RELAY_BUF];
    // We don't know the client's local ephemeral addr until the first packet.
    let mut client_addr: Option<SocketAddr> = None;
    let mut last_diag = std::time::Instant::now();
    let diag_interval = Duration::from_secs(10);
    let mut diag_packets: u64 = 0;

    loop {
        if shutdown.load(Ordering::SeqCst) {
            break;
        }
        // Periodic diagnostics
        let now_diag = std::time::Instant::now();
        if now_diag.duration_since(last_diag) >= diag_interval {
            tracing::info!(
                packets = diag_packets,
                client_addr = ?client_addr,
                "Proxy UDP c2s diag"
            );
            diag_packets = 0;
            last_diag = now_diag;
        }
        match local.recv_from(&mut buf) {
            Ok((n, addr)) => {
                if client_addr.is_none() {
                    tracing::info!(%addr, bytes = n, "Proxy UDP c2s: learned client address");
                }
                client_addr = Some(addr);
                packet_counter.fetch_add(1, Ordering::Relaxed);
                byte_counter.fetch_add(n as u64, Ordering::Relaxed);
                diag_packets += 1;
                let _ = server.send(&buf[..n]);
            }
            Err(ref e)
                if e.kind() == io::ErrorKind::WouldBlock || e.kind() == io::ErrorKind::TimedOut =>
            {
                continue;
            }
            Err(_) => break,
        }
    }
}

/// Relay datagrams from the remote server to the local client.
fn relay_udp_s2c(
    server: UdpSocket,
    local: UdpSocket,
    shutdown: Arc<AtomicBool>,
    packet_counter: Arc<AtomicU64>,
    byte_counter: Arc<AtomicU64>,
) {
    let mut buf = vec![0u8; RELAY_BUF];

    // Learn the client's ephemeral address by peeking the first incoming
    // packet on the local socket (the c2s thread owns recv, so we peek
    // non-destructively).  The client always sends UdpBind before the
    // server starts replying, so there is no race.
    //
    // Time-box to 30 seconds so this thread doesn't block forever if the
    // client never sends a UDP packet (e.g. SHA-256 unavailable).
    let deadline = std::time::Instant::now() + Duration::from_secs(30);
    let client_addr = loop {
        if shutdown.load(Ordering::SeqCst) {
            return;
        }
        if std::time::Instant::now() >= deadline {
            tracing::warn!("Proxy UDP s2c: timed out waiting for client UDP packet after 30s");
            return;
        }
        match local.peek_from(&mut buf) {
            Ok((_n, addr)) => break addr,
            Err(ref e)
                if e.kind() == io::ErrorKind::WouldBlock || e.kind() == io::ErrorKind::TimedOut =>
            {
                continue;
            }
            Err(_) => return,
        }
    };

    tracing::info!(%client_addr, "Proxy UDP s2c: learned client address, waiting for server packets");

    let server_local_addr = server.local_addr().ok();
    let server_peer_addr = server.peer_addr().ok();
    tracing::info!(
        local_addr = ?server_local_addr,
        peer_addr = ?server_peer_addr,
        "Proxy UDP s2c: server socket info"
    );

    let mut last_diag = std::time::Instant::now();
    let diag_interval = Duration::from_secs(10);
    let mut diag_packets: u64 = 0;
    let mut diag_timeouts: u64 = 0;
    let mut first_packet_logged = false;

    loop {
        if shutdown.load(Ordering::SeqCst) {
            break;
        }
        // Periodic diagnostics
        let now_diag = std::time::Instant::now();
        if now_diag.duration_since(last_diag) >= diag_interval {
            tracing::info!(
                packets = diag_packets,
                timeouts = diag_timeouts,
                %client_addr,
                "Proxy UDP s2c diag"
            );
            diag_packets = 0;
            diag_timeouts = 0;
            last_diag = now_diag;
        }
        match server.recv(&mut buf) {
            Ok(n) => {
                if !first_packet_logged {
                    tracing::info!(bytes = n, "Proxy UDP s2c: first packet from server");
                    first_packet_logged = true;
                }
                packet_counter.fetch_add(1, Ordering::Relaxed);
                byte_counter.fetch_add(n as u64, Ordering::Relaxed);
                diag_packets += 1;
                let _ = local.send_to(&buf[..n], client_addr);
            }
            Err(ref e)
                if e.kind() == io::ErrorKind::WouldBlock || e.kind() == io::ErrorKind::TimedOut =>
            {
                diag_timeouts += 1;
                continue;
            }
            Err(_) => break,
        }
    }
}
