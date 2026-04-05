//! Firewall rule management for the HighBeam launcher.
//!
//! The launcher makes outbound TCP and UDP connections to remote game servers
//! and listens only on `127.0.0.1` (localhost) for its proxy relay and IPC.
//! Localhost listeners do not require firewall rules, but on Windows the
//! application firewall may block outbound connections from unknown executables.
//!
//! This module ensures the launcher binary has an outbound allow rule.
//!
//! Platform behaviour:
//! - **Windows** — creates an outbound allow rule for the launcher executable
//!   via `netsh` if one does not already exist.
//! - **macOS/Linux** — outbound connections are allowed by default on standard
//!   firewall configurations; we just log for awareness.

#[cfg(target_os = "windows")]
use std::process::Command;

/// Ensure the launcher binary is allowed through the firewall for outbound
/// connections.  Best-effort — failures are logged as warnings.
pub fn ensure_outbound_allowed() {
    ensure_outbound_impl();
}

// ─────────────────────────── Windows ────────────────────────────────────────

#[cfg(target_os = "windows")]
fn ensure_outbound_impl() {
    let exe_path = match std::env::current_exe() {
        Ok(p) => p,
        Err(e) => {
            tracing::warn!(error = %e, "Could not determine launcher executable path; skipping firewall check");
            return;
        }
    };

    let rule_name = "HighBeam Launcher";

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
            tracing::debug!(rule = rule_name, "Launcher firewall rule already exists");
            return;
        }
        Ok(_) => {
            tracing::info!(
                rule = rule_name,
                "Launcher firewall rule missing, attempting to add"
            );
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
            "dir=out",
            "action=allow",
            &format!("program={}", exe_path.display()),
            "profile=any",
        ])
        .output();

    match add {
        Ok(output) if output.status.success() => {
            tracing::info!(
                rule = rule_name,
                "Launcher firewall rule added successfully"
            );
        }
        Ok(output) => {
            let stderr = String::from_utf8_lossy(&output.stderr);
            let stdout = String::from_utf8_lossy(&output.stdout);
            tracing::warn!(
                rule = rule_name,
                stdout = %stdout.trim(),
                stderr = %stderr.trim(),
                "Failed to add launcher firewall rule (may require administrator privileges)"
            );
        }
        Err(e) => {
            tracing::warn!(
                rule = rule_name,
                error = %e,
                "Failed to add launcher firewall rule"
            );
        }
    }
}

// ──────────────────────── macOS / Linux / Other ─────────────────────────────

#[cfg(not(target_os = "windows"))]
fn ensure_outbound_impl() {
    // Outbound connections are allowed by default on macOS and Linux.
    // Just log for operator awareness.
    tracing::debug!(
        "Firewall: launcher only uses outbound connections and localhost listeners; \
         no firewall rules required on this platform."
    );
}
