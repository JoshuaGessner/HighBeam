//! Firewall rule management for the HighBeam server.
//!
//! On startup the server needs inbound access on its gameplay port (TCP+UDP),
//! optionally the mod-sync port (TCP), and optionally the community-node
//! discovery port (TCP).  This module checks whether the appropriate firewall
//! rules exist and attempts to create them if they are missing.
//!
//! Platform behaviour:
//! - **Windows** — queries/creates Windows Firewall rules via `netsh`.
//! - **macOS**   — the application firewall auto-prompts on first listen;
//!                  we just log the required ports.
//! - **Linux**   — detects `ufw` or `firewalld` and adds allow rules.

#[cfg(any(target_os = "windows", target_os = "linux"))]
use std::process::Command;

/// Description of a port that the server needs open.
pub struct RequiredPort {
    pub port: u16,
    pub protocols: &'static [&'static str], // "tcp", "udp", or both
    pub label: &'static str,
}

/// Ensure firewall rules exist for the given ports.  Logs actions taken and
/// any errors encountered.  This is best-effort — bind failures later will
/// surface the real problem if the firewall check could not run.
pub fn ensure_firewall_rules(ports: &[RequiredPort]) {
    for req in ports {
        for proto in req.protocols {
            ensure_one(req.port, proto, req.label);
        }
    }
}

// ─────────────────────────── Windows ────────────────────────────────────────

#[cfg(target_os = "windows")]
fn ensure_one(port: u16, proto: &str, label: &str) {
    let rule_name = format!("HighBeam - {} ({}/{})", label, port, proto.to_uppercase());

    // Check whether the rule already exists.
    let check = Command::new("netsh")
        .args([
            "advfirewall",
            "firewall",
            "show",
            "rule",
            &format!("name={}", rule_name),
        ])
        .output();

    match check {
        Ok(output) if output.status.success() => {
            tracing::debug!(rule = %rule_name, "Firewall rule already exists");
            return;
        }
        Ok(_) => {
            // Rule not found — try to add it.
            tracing::info!(rule = %rule_name, "Firewall rule missing, attempting to add");
        }
        Err(e) => {
            tracing::warn!(error = %e, "Could not query Windows Firewall; skipping rule check");
            return;
        }
    }

    let add = Command::new("netsh")
        .args([
            "advfirewall",
            "firewall",
            "add",
            "rule",
            &format!("name={}", rule_name),
            "dir=in",
            "action=allow",
            &format!("protocol={}", proto),
            &format!("localport={}", port),
            "profile=any",
        ])
        .output();

    match add {
        Ok(output) if output.status.success() => {
            tracing::info!(rule = %rule_name, "Firewall rule added successfully");
        }
        Ok(output) => {
            let stderr = String::from_utf8_lossy(&output.stderr);
            let stdout = String::from_utf8_lossy(&output.stdout);
            tracing::warn!(
                rule = %rule_name,
                stdout = %stdout.trim(),
                stderr = %stderr.trim(),
                "Failed to add firewall rule (may require administrator privileges)"
            );
        }
        Err(e) => {
            tracing::warn!(
                rule = %rule_name,
                error = %e,
                "Failed to add firewall rule"
            );
        }
    }
}

// ──────────────────────────── macOS ─────────────────────────────────────────

#[cfg(target_os = "macos")]
fn ensure_one(port: u16, proto: &str, label: &str) {
    // macOS application firewall auto-prompts the user when a process first
    // listens on an external interface.  We log the requirement so operators
    // know which ports to allow if they use a third-party firewall (e.g. pf).
    tracing::info!(
        port,
        protocol = proto,
        label,
        "Firewall: ensure port {}/{} is allowed ({}). \
         macOS will prompt automatically on first listen if the application firewall is enabled.",
        port,
        proto.to_uppercase(),
        label,
    );
}

// ──────────────────────────── Linux ─────────────────────────────────────────

#[cfg(target_os = "linux")]
fn ensure_one(port: u16, proto: &str, label: &str) {
    // Try ufw first, then firewalld, then just log.
    if try_ufw(port, proto, label) {
        return;
    }
    if try_firewalld(port, proto, label) {
        return;
    }
    tracing::info!(
        port,
        protocol = proto,
        label,
        "No supported firewall manager detected (ufw, firewalld). \
         Ensure port {}/{} is allowed for {} in your firewall configuration.",
        port,
        proto.to_uppercase(),
        label,
    );
}

#[cfg(target_os = "linux")]
fn try_ufw(port: u16, proto: &str, label: &str) -> bool {
    // Check if ufw is available and active.
    let status = match Command::new("ufw").arg("status").output() {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).to_string(),
        _ => return false,
    };

    if !status.contains("Status: active") {
        tracing::debug!("ufw is installed but not active; skipping");
        return false;
    }

    // Check if the port is already allowed.
    let rule_pattern = format!("{}/{}", port, proto);
    if status.contains(&rule_pattern) {
        tracing::debug!(port, protocol = proto, label, "ufw rule already exists");
        return true;
    }

    tracing::info!(port, protocol = proto, label, "Adding ufw allow rule");
    let add = Command::new("sudo")
        .args(["ufw", "allow", &format!("{}/{}", port, proto)])
        .arg("comment")
        .arg(&format!("HighBeam {}", label))
        .output();

    match add {
        Ok(output) if output.status.success() => {
            tracing::info!(port, protocol = proto, label, "ufw rule added successfully");
            true
        }
        Ok(output) => {
            let stderr = String::from_utf8_lossy(&output.stderr);
            tracing::warn!(
                port,
                protocol = proto,
                stderr = %stderr.trim(),
                "Failed to add ufw rule (may require sudo privileges)"
            );
            true // Return true to indicate ufw is the active manager
        }
        Err(e) => {
            tracing::warn!(error = %e, "Failed to run ufw");
            true
        }
    }
}

#[cfg(target_os = "linux")]
fn try_firewalld(port: u16, proto: &str, label: &str) -> bool {
    // Check if firewall-cmd is available.
    let check = match Command::new("firewall-cmd").arg("--state").output() {
        Ok(o) if o.status.success() => true,
        _ => return false,
    };
    if !check {
        return false;
    }

    // Check if the port is already open.
    let query = Command::new("firewall-cmd")
        .args(["--query-port", &format!("{}/{}", port, proto)])
        .output();

    if let Ok(output) = query {
        if output.status.success() {
            tracing::debug!(port, protocol = proto, label, "firewalld rule already exists");
            return true;
        }
    }

    tracing::info!(port, protocol = proto, label, "Adding firewalld rule");
    let add = Command::new("sudo")
        .args([
            "firewall-cmd",
            "--permanent",
            "--add-port",
            &format!("{}/{}", port, proto),
        ])
        .output();

    match add {
        Ok(output) if output.status.success() => {
            // Reload to apply permanent rule.
            let _ = Command::new("sudo")
                .args(["firewall-cmd", "--reload"])
                .output();
            tracing::info!(port, protocol = proto, label, "firewalld rule added successfully");
            true
        }
        Ok(output) => {
            let stderr = String::from_utf8_lossy(&output.stderr);
            tracing::warn!(
                port,
                protocol = proto,
                stderr = %stderr.trim(),
                "Failed to add firewalld rule (may require sudo privileges)"
            );
            true
        }
        Err(e) => {
            tracing::warn!(error = %e, "Failed to run firewall-cmd");
            true
        }
    }
}

// ───────────────────────── Unsupported OS ───────────────────────────────────

#[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "linux")))]
fn ensure_one(port: u16, proto: &str, label: &str) {
    tracing::info!(
        port,
        protocol = proto,
        label,
        "Firewall management not supported on this platform. \
         Ensure port {}/{} is allowed for {}.",
        port,
        proto.to_uppercase(),
        label,
    );
}
