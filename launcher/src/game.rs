use anyhow::{anyhow, Result};
use std::process::Command;

/// Detect or validate the BeamNG.drive executable path and return a resolved string.
fn resolve_exe(beamng_exe: Option<&str>) -> Result<String> {
    match beamng_exe {
        Some(v) if !v.trim().is_empty() => Ok(v.to_string()),
        _ => {
            tracing::info!("No beamng_exe configured, attempting auto-detection");
            match crate::detect::detect_beamng_exe() {
                Some(path) => {
                    let s = path.to_string_lossy().to_string();
                    tracing::info!(path = %path.display(), "Auto-detected BeamNG.drive executable");
                    Ok(s)
                }
                None => Err(anyhow!(
                    "Could not find BeamNG.drive. Set beamng_exe in LauncherConfig.toml \
                     or install BeamNG.drive via Steam."
                )),
            }
        }
    }
}

/// Spawn BeamNG.drive and return the child process handle *without* waiting for it.
/// The caller is responsible for waiting or monitoring the child.
pub fn spawn_game(beamng_exe: Option<&str>) -> Result<std::process::Child> {
    let exe = resolve_exe(beamng_exe)?;
    println!("Launching BeamNG.drive: {exe}");
    let child = Command::new(&exe)
        .spawn()
        .map_err(|e| anyhow!("Failed to spawn BeamNG.drive ({}): {e}", exe))?;
    Ok(child)
}

/// Spawn BeamNG.drive and block until the process exits.
/// Equivalent to calling `spawn_game` then `child.wait()`.
#[allow(dead_code)]
pub fn launch_game(beamng_exe: Option<&str>) -> Result<()> {
    let mut child = spawn_game(beamng_exe)?;
    let status = child.wait()?;
    if status.success() {
        println!("BeamNG.drive exited normally");
    } else {
        let code = status.code().unwrap_or(-1);
        eprintln!("BeamNG.drive exited with code {code}");
    }
    Ok(())
}
