use anyhow::{anyhow, Result};
use std::process::Command;

pub fn launch_game(beamng_exe: Option<&str>) -> Result<()> {
    let exe = match beamng_exe {
        Some(v) if !v.trim().is_empty() => v,
        _ => {
            return Err(anyhow!(
                "No BeamNG executable configured. Set beamng_exe in LauncherConfig.toml or pass --no-launch"
            ));
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
