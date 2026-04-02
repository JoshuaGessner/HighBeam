use std::path::PathBuf;

/// Common BeamNG.drive executable names to look for.
const BEAMNG_EXE_NAME: &str = "BeamNG.drive.exe";

/// Try to automatically locate the BeamNG.drive executable.
/// Checks Steam library folders first (most common), then well-known install
/// paths.
pub fn detect_beamng_exe() -> Option<PathBuf> {
    if let Some(path) = find_in_steam_libraries() {
        return Some(path);
    }
    if let Some(path) = find_in_common_paths() {
        return Some(path);
    }
    None
}

/// Try to automatically locate the BeamNG.drive user data folder where mods
/// are installed. Returns the **root** userfolder (caller appends `/mods`).
///
/// Modern BeamNG (0.27+) stores user data under:
///   `%LOCALAPPDATA%\BeamNG\BeamNG.drive\`   (Windows)
/// Legacy / BeamMP installs use:
///   `%LOCALAPPDATA%\BeamNG.drive\`           (Windows)
pub fn detect_beamng_userfolder() -> Option<PathBuf> {
    #[cfg(target_os = "windows")]
    {
        if let Some(local) = std::env::var_os("LOCALAPPDATA") {
            let local = PathBuf::from(local);
            // Modern BeamNG (0.27+): %LOCALAPPDATA%\BeamNG\BeamNG.drive
            let modern = local.join("BeamNG").join("BeamNG.drive");
            if modern.is_dir() {
                return Some(modern);
            }
            // Legacy / BeamMP: %LOCALAPPDATA%\BeamNG.drive
            let legacy = local.join("BeamNG.drive");
            if legacy.is_dir() {
                return Some(legacy);
            }
        }
    }

    if let Some(home) = std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE")) {
        let path = PathBuf::from(&home).join("BeamNG.drive");
        if path.is_dir() {
            return Some(path);
        }
        // Also check AppData\Local on Windows via USERPROFILE
        #[cfg(target_os = "windows")]
        {
            let local = PathBuf::from(home)
                .join("AppData")
                .join("Local");
            let modern = local.join("BeamNG").join("BeamNG.drive");
            if modern.is_dir() {
                return Some(modern);
            }
            let legacy = local.join("BeamNG.drive");
            if legacy.is_dir() {
                return Some(legacy);
            }
        }
    }

    None
}

/// Find BeamNG.drive in Steam library folders by parsing `libraryfolders.vdf`.
fn find_in_steam_libraries() -> Option<PathBuf> {
    let steam_root = find_steam_root()?;
    let vdf_path = steam_root.join("steamapps").join("libraryfolders.vdf");

    // Always check the default Steam library first
    let default_candidate = steam_root
        .join("steamapps")
        .join("common")
        .join("BeamNG.drive")
        .join(BEAMNG_EXE_NAME);
    if default_candidate.is_file() {
        tracing::info!(path = %default_candidate.display(), "Found BeamNG.drive in default Steam library");
        return Some(default_candidate);
    }

    // Parse libraryfolders.vdf for additional library paths
    if let Ok(contents) = std::fs::read_to_string(&vdf_path) {
        for lib_path in parse_library_folders(&contents) {
            let candidate = PathBuf::from(&lib_path)
                .join("steamapps")
                .join("common")
                .join("BeamNG.drive")
                .join(BEAMNG_EXE_NAME);
            if candidate.is_file() {
                tracing::info!(path = %candidate.display(), "Found BeamNG.drive in Steam library");
                return Some(candidate);
            }
        }
    }

    None
}

/// Locate the Steam installation root directory.
fn find_steam_root() -> Option<PathBuf> {
    // Try Windows registry first
    #[cfg(target_os = "windows")]
    {
        if let Some(path) = steam_root_from_registry() {
            if path.is_dir() {
                return Some(path);
            }
        }
    }

    // Well-known default Steam install paths
    let candidates: Vec<PathBuf> = vec![
        // Windows
        PathBuf::from(r"C:\Program Files (x86)\Steam"),
        PathBuf::from(r"C:\Program Files\Steam"),
        // macOS (for dev/testing)
        dirs_home()
            .map(|h| h.join("Library/Application Support/Steam"))
            .unwrap_or_default(),
        // Linux
        dirs_home()
            .map(|h| h.join(".steam/steam"))
            .unwrap_or_default(),
        dirs_home()
            .map(|h| h.join(".local/share/Steam"))
            .unwrap_or_default(),
    ];

    candidates.into_iter().find(|p| p.is_dir())
}

/// Read the Steam install path from the Windows registry.
#[cfg(target_os = "windows")]
fn steam_root_from_registry() -> Option<PathBuf> {
    use std::process::Command;

    // Query registry: HKLM\SOFTWARE\WOW6432Node\Valve\Steam  InstallPath
    let output = Command::new("reg")
        .args([
            "query",
            r"HKLM\SOFTWARE\WOW6432Node\Valve\Steam",
            "/v",
            "InstallPath",
        ])
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    // Output format: "    InstallPath    REG_SZ    C:\Program Files (x86)\Steam"
    for line in stdout.lines() {
        if let Some(idx) = line.find("REG_SZ") {
            let path = line[idx + "REG_SZ".len()..].trim();
            if !path.is_empty() {
                return Some(PathBuf::from(path));
            }
        }
    }
    None
}

/// Parse Steam's `libraryfolders.vdf` to extract library root paths.
/// The VDF format has lines like:  `"path"    "D:\\SteamLibrary"`
fn parse_library_folders(contents: &str) -> Vec<String> {
    let mut paths = Vec::new();
    for line in contents.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("\"path\"") {
            // Extract the value between the last pair of quotes
            let parts: Vec<&str> = trimmed.split('"').collect();
            if parts.len() >= 4 {
                let path = parts[3].replace("\\\\", "\\");
                paths.push(path);
            }
        }
    }
    paths
}

fn find_in_common_paths() -> Option<PathBuf> {
    let candidates = vec![
        PathBuf::from(
            r"C:\Program Files (x86)\Steam\steamapps\common\BeamNG.drive\BeamNG.drive.exe",
        ),
        PathBuf::from(r"C:\Program Files\Steam\steamapps\common\BeamNG.drive\BeamNG.drive.exe"),
        PathBuf::from(r"D:\SteamLibrary\steamapps\common\BeamNG.drive\BeamNG.drive.exe"),
        PathBuf::from(r"D:\Steam\steamapps\common\BeamNG.drive\BeamNG.drive.exe"),
        PathBuf::from(r"E:\SteamLibrary\steamapps\common\BeamNG.drive\BeamNG.drive.exe"),
    ];

    candidates.into_iter().find(|p| p.is_file())
}

fn dirs_home() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_library_folders_typical() {
        let vdf = r#"
"libraryfolders"
{
    "0"
    {
        "path"		"C:\\Program Files (x86)\\Steam"
        "label"		""
    }
    "1"
    {
        "path"		"D:\\SteamLibrary"
        "label"		""
    }
}
"#;
        let paths = parse_library_folders(vdf);
        assert_eq!(paths.len(), 2);
        assert_eq!(paths[0], r"C:\Program Files (x86)\Steam");
        assert_eq!(paths[1], r"D:\SteamLibrary");
    }

    #[test]
    fn test_parse_library_folders_empty() {
        let paths = parse_library_folders("");
        assert!(paths.is_empty());
    }
}
