use anyhow::{anyhow, Result};
use std::process::Command;

pub fn launch_game(beamng_exe: Option<&str>) -> Result<()> {
    let resolved;
    let exe = match beamng_exe {
        Some(v) if !v.trim().is_empty() => v,
        _ => {
            tracing::info!("No beamng_exe configured, attempting auto-detection");
            match crate::detect::detect_beamng_exe() {
                Some(path) => {
                    tracing::info!(path = %path.display(), "Auto-detected BeamNG.drive executable");
                    resolved = path.to_string_lossy().to_string();
                    &resolved
                }
                None => {
                    return Err(anyhow!(
                        "Could not find BeamNG.drive. Set beamng_exe in LauncherConfig.toml or install BeamNG.drive via Steam."
                    ));
                }
            }
        }
    };

    println!("Launching BeamNG.drive: {}", exe);
    let mut child = Command::new(exe).spawn()?;

    let status = child.wait()?;
    if status.success() {
        println!("BeamNG.drive exited normally");
    } else {
        let code = status.code().unwrap_or(-1);
        eprintln!("BeamNG.drive exited with code {}", code);
    }
    Ok(())
}
