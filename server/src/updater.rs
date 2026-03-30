use anyhow::{Context, Result};
use serde::Deserialize;
use std::fs;
use std::path::Path;

const GITHUB_API_URL: &str = "https://api.github.com/repos/JoshuaGessner/HighBeam/releases/latest";
const CURRENT_VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Debug, Deserialize)]
struct GithubRelease {
    tag_name: String,
    assets: Vec<GithubAsset>,
}

#[derive(Debug, Deserialize)]
struct GithubAsset {
    name: String,
    browser_download_url: String,
}

/// Returns the expected asset name for the current platform.
fn platform_asset_name() -> Option<&'static str> {
    if cfg!(target_os = "linux") && cfg!(target_arch = "x86_64") {
        Some("highbeam-server-linux-x86_64.tar.gz")
    } else if cfg!(target_os = "windows") && cfg!(target_arch = "x86_64") {
        Some("highbeam-server-windows-x86_64.zip")
    } else if cfg!(target_os = "macos") && cfg!(target_arch = "x86_64") {
        Some("highbeam-server-macos-x86_64.tar.gz")
    } else if cfg!(target_os = "macos") && cfg!(target_arch = "aarch64") {
        Some("highbeam-server-macos-aarch64.tar.gz")
    } else {
        None
    }
}

fn is_newer(local: &str, remote: &str) -> bool {
    let parse = |s: &str| -> (u32, u32, u32) {
        let mut parts = s.split('.').map(|p| p.parse::<u32>().unwrap_or(0));
        (
            parts.next().unwrap_or(0),
            parts.next().unwrap_or(0),
            parts.next().unwrap_or(0),
        )
    };
    parse(remote) > parse(local)
}

/// Check GitHub for the latest release. If a newer version exists, downloads
/// and stages the update. Returns `Ok(true)` if an update was applied and the
/// server should be restarted.
pub async fn check_and_update() -> Result<bool> {
    tracing::info!(
        current_version = CURRENT_VERSION,
        "Checking for server updates"
    );

    let asset_name = match platform_asset_name() {
        Some(name) => name,
        None => {
            tracing::warn!("No release asset available for this platform, skipping update check");
            return Ok(false);
        }
    };

    let client = reqwest::Client::builder()
        .user_agent(format!("highbeam-server/{CURRENT_VERSION}"))
        .timeout(std::time::Duration::from_secs(15))
        .build()
        .context("Failed to create HTTP client")?;

    let release: GithubRelease = match client.get(GITHUB_API_URL).send().await {
        Ok(resp) => {
            if !resp.status().is_success() {
                tracing::warn!(
                    status = %resp.status(),
                    "Update check failed (non-200 response), skipping"
                );
                return Ok(false);
            }
            resp.json().await.context("Failed to parse release JSON")?
        }
        Err(e) => {
            tracing::warn!(error = %e, "Update check failed (network error), skipping");
            return Ok(false);
        }
    };

    let remote_version = release
        .tag_name
        .strip_prefix('v')
        .unwrap_or(&release.tag_name);

    if !is_newer(CURRENT_VERSION, remote_version) {
        tracing::info!(
            current = CURRENT_VERSION,
            latest = remote_version,
            "Server is up to date"
        );
        return Ok(false);
    }

    tracing::info!(
        current = CURRENT_VERSION,
        latest = remote_version,
        "New server version available, downloading update"
    );

    let asset = release
        .assets
        .iter()
        .find(|a| a.name == asset_name)
        .context("Server asset not found in latest release")?;

    let archive_bytes = client
        .get(&asset.browser_download_url)
        .send()
        .await
        .context("Failed to download update")?
        .bytes()
        .await
        .context("Failed to read update bytes")?;

    let current_exe = std::env::current_exe().context("Failed to determine current exe path")?;
    let parent = current_exe
        .parent()
        .context("Failed to determine exe directory")?;

    // Do the extraction on a blocking thread since it's file I/O
    let exe = current_exe.clone();
    let dir = parent.to_path_buf();
    let is_zip = asset_name.ends_with(".zip");
    tokio::task::spawn_blocking(move || apply_update(&archive_bytes, &exe, &dir, is_zip))
        .await
        .context("Update task panicked")??;

    tracing::info!(
        new_version = remote_version,
        "Update applied — restart the server to run the new version"
    );
    Ok(true)
}

fn apply_update(
    archive_bytes: &[u8],
    current_exe: &Path,
    install_dir: &Path,
    is_zip: bool,
) -> Result<()> {
    // Clean up previous .old file
    let old_path = current_exe.with_extension("old");
    let _ = fs::remove_file(&old_path);

    if is_zip {
        extract_zip(archive_bytes, current_exe, install_dir, &old_path)
    } else {
        extract_tar_gz(archive_bytes, current_exe, install_dir, &old_path)
    }
}

fn extract_zip(
    bytes: &[u8],
    current_exe: &Path,
    install_dir: &Path,
    old_path: &Path,
) -> Result<()> {
    let cursor = std::io::Cursor::new(bytes);
    let mut archive = zip::ZipArchive::new(cursor).context("Failed to open update zip")?;

    for i in 0..archive.len() {
        let mut entry = archive.by_index(i)?;
        if entry.is_dir() {
            continue;
        }
        let name = entry.name().to_string();
        extract_file_entry(&name, &mut entry, current_exe, install_dir, old_path)?;
    }
    Ok(())
}

fn extract_tar_gz(
    bytes: &[u8],
    current_exe: &Path,
    install_dir: &Path,
    old_path: &Path,
) -> Result<()> {
    use std::io::Read;

    let gz = flate2::read::GzDecoder::new(bytes);
    let mut archive = tar::Archive::new(gz);

    for entry in archive.entries().context("Failed to read tar entries")? {
        let mut entry = entry.context("Failed to read tar entry")?;
        let path = entry
            .path()
            .context("Failed to read entry path")?
            .to_path_buf();
        let name = path.to_string_lossy().to_string();

        if entry.header().entry_type().is_dir() {
            continue;
        }

        let mut buf = Vec::new();
        entry.read_to_end(&mut buf)?;
        let mut cursor = std::io::Cursor::new(buf);
        extract_file_entry(&name, &mut cursor, current_exe, install_dir, old_path)?;
    }
    Ok(())
}

fn extract_file_entry(
    name: &str,
    reader: &mut dyn std::io::Read,
    current_exe: &Path,
    install_dir: &Path,
    old_path: &Path,
) -> Result<()> {
    if is_server_exe(name) {
        // Rename the running binary out of the way, then write the new one
        fs::rename(current_exe, old_path).context("Failed to rename current exe for update")?;
        let mut file = fs::File::create(current_exe).context("Failed to create new server exe")?;
        std::io::copy(reader, &mut file)?;

        // Restore executable permission on Unix
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(current_exe, fs::Permissions::from_mode(0o755))?;
        }
    } else {
        // Config files etc. — don't overwrite if already present
        let dest = install_dir.join(name);
        if !dest.exists() {
            if let Some(p) = dest.parent() {
                fs::create_dir_all(p)?;
            }
            let mut file = fs::File::create(&dest)?;
            std::io::copy(reader, &mut file)?;
        }
    }
    Ok(())
}

fn is_server_exe(name: &str) -> bool {
    let lower = name.to_lowercase();
    lower.ends_with("highbeam-server.exe") || lower.ends_with("highbeam-server")
}

/// Clean up leftover `.old` binary from a previous update.
pub fn cleanup_previous_update() {
    if let Ok(exe) = std::env::current_exe() {
        let old = exe.with_extension("old");
        let _ = fs::remove_file(old);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_is_newer() {
        assert!(is_newer("0.4.1", "0.4.2"));
        assert!(is_newer("0.4.1", "0.5.0"));
        assert!(is_newer("0.4.1", "1.0.0"));
        assert!(!is_newer("0.4.1", "0.4.1"));
        assert!(!is_newer("0.4.1", "0.4.0"));
        assert!(!is_newer("0.4.1", "0.3.9"));
    }

    #[test]
    fn test_platform_asset_name() {
        // Just verify it returns something on the current platform
        let name = platform_asset_name();
        assert!(
            name.is_some(),
            "Should have an asset name for this platform"
        );
    }

    #[test]
    fn test_is_server_exe() {
        assert!(is_server_exe("highbeam-server"));
        assert!(is_server_exe("highbeam-server.exe"));
        assert!(!is_server_exe("ServerConfig.toml"));
    }
}
