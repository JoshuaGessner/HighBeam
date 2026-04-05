use anyhow::{Context, Result};
use serde::Deserialize;
use std::fs;
use std::io::Read;
use std::path::Path;

const GITHUB_API_URL: &str = "https://api.github.com/repos/JoshuaGessner/HighBeam/releases/latest";
const LAUNCHER_ASSET_NAME: &str = "highbeam-launcher-windows-x86_64.zip";
const VERSION_FILE_NAME: &str = "VERSION";
const CLIENT_PAYLOAD_NAME: &str = "highbeam.zip";
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

/// Compare two semver version strings (without leading 'v').
/// Returns true if `remote` is newer than `local`.
fn is_newer(local: &str, remote: &str) -> bool {
    let parse = |s: &str| -> (u32, u32, u32) {
        // Strip pre-release suffix (e.g. "2-dev.3" → "2") before parsing.
        let mut parts = s.split('.').map(|p| {
            let base = p.split('-').next().unwrap_or(p);
            base.parse::<u32>().unwrap_or(0)
        });
        (
            parts.next().unwrap_or(0),
            parts.next().unwrap_or(0),
            parts.next().unwrap_or(0),
        )
    };
    parse(remote) > parse(local)
}

/// Check GitHub for the latest release and auto-update the launcher binary if a
/// newer version is available. Returns `Ok(true)` if an update was applied and
/// the caller should restart, `Ok(false)` if already up to date.
pub fn check_and_update() -> Result<bool> {
    tracing::info!(current_version = CURRENT_VERSION, "Checking for updates");

    let client = reqwest::blocking::Client::builder()
        .user_agent(format!("highbeam-launcher/{CURRENT_VERSION}"))
        .timeout(std::time::Duration::from_secs(15))
        .build()
        .context("Failed to create HTTP client")?;

    let release: GithubRelease = match client.get(GITHUB_API_URL).send() {
        Ok(resp) => {
            if !resp.status().is_success() {
                tracing::warn!(
                    status = %resp.status(),
                    "Update check failed (non-200 response), skipping"
                );
                return Ok(false);
            }
            resp.json().context("Failed to parse release JSON")?
        }
        Err(e) => {
            tracing::warn!(error = %e, "Update check failed (network error), skipping");
            return Ok(false);
        }
    };

    // Dev builds (pre-release suffix like -dev.N) must never auto-update from
    // /releases/latest because that endpoint only returns stable releases,
    // which would cause a downgrade (e.g. 0.8.2-dev.3 → 0.8.1).
    if CURRENT_VERSION.contains('-') {
        tracing::info!(
            current = CURRENT_VERSION,
            "Dev build detected, skipping auto-update"
        );
        return Ok(false);
    }

    let remote_version = release
        .tag_name
        .strip_prefix('v')
        .unwrap_or(&release.tag_name);

    if !is_newer(CURRENT_VERSION, remote_version) {
        tracing::info!(
            current = CURRENT_VERSION,
            latest = remote_version,
            "Launcher is up to date"
        );
        return Ok(false);
    }

    tracing::info!(
        current = CURRENT_VERSION,
        latest = remote_version,
        "New version available, downloading update"
    );

    let asset = release
        .assets
        .iter()
        .find(|a| a.name == LAUNCHER_ASSET_NAME)
        .context("Launcher asset not found in latest release")?;

    let zip_bytes = client
        .get(&asset.browser_download_url)
        .send()
        .context("Failed to download update")?
        .bytes()
        .context("Failed to read update bytes")?;

    validate_update_package(&zip_bytes, remote_version)?;

    let current_exe = std::env::current_exe().context("Failed to determine current exe path")?;
    let parent = current_exe
        .parent()
        .context("Failed to determine exe directory")?;

    apply_update(&zip_bytes, &current_exe, parent)?;

    tracing::info!(
        new_version = remote_version,
        "Update applied successfully — please restart the launcher"
    );
    Ok(true)
}

fn validate_update_package(zip_bytes: &[u8], remote_version: &str) -> Result<()> {
    let cursor = std::io::Cursor::new(zip_bytes);
    let mut archive = zip::ZipArchive::new(cursor).context("Failed to inspect update zip")?;

    let mut has_launcher_binary = false;
    let mut has_client_payload = false;
    let mut package_version: Option<String> = None;

    for i in 0..archive.len() {
        let mut entry = archive.by_index(i)?;
        let name = entry.name().to_string();

        if is_launcher_exe(&name) {
            has_launcher_binary = true;
        }

        if name.eq_ignore_ascii_case(CLIENT_PAYLOAD_NAME) {
            has_client_payload = true;
        }

        if name.eq_ignore_ascii_case(VERSION_FILE_NAME) {
            let mut content = String::new();
            entry
                .read_to_string(&mut content)
                .context("Failed to read VERSION file from launcher update zip")?;
            package_version = Some(content.trim().trim_start_matches('v').to_string());
        }
    }

    if !has_launcher_binary {
        anyhow::bail!(
            "Launcher update package is invalid: missing launcher executable ({})",
            LAUNCHER_ASSET_NAME
        );
    }

    if !has_client_payload {
        anyhow::bail!(
            "Launcher update package is invalid: missing bundled client payload ({})",
            CLIENT_PAYLOAD_NAME
        );
    }

    let package_version = package_version
        .context("Launcher update package is missing VERSION marker; refusing to apply update")?;

    if package_version != remote_version {
        anyhow::bail!(
            "Launcher update package version mismatch: release tag is {}, package VERSION is {}",
            remote_version,
            package_version
        );
    }

    Ok(())
}

/// Extract the zip and replace the running binary.
///
/// On Windows we cannot overwrite a running exe, so we:
/// 1. Rename the current binary to `<name>.old`
/// 2. Extract the new binary to the original path
/// 3. The `.old` file can be cleaned up on next run.
fn apply_update(zip_bytes: &[u8], current_exe: &Path, install_dir: &Path) -> Result<()> {
    let cursor = std::io::Cursor::new(zip_bytes);
    let mut archive = zip::ZipArchive::new(cursor).context("Failed to open update zip")?;

    // Clean up any leftover .old file from previous update
    let old_path = current_exe.with_extension("old");
    let _ = fs::remove_file(&old_path);

    for i in 0..archive.len() {
        let mut entry = archive.by_index(i)?;
        let name = entry.name().to_string();

        if entry.is_dir() {
            continue;
        }

        let dest = install_dir.join(&name);

        // If this is the launcher exe, do the rename dance
        if is_launcher_exe(&name) {
            // Rename running exe out of the way
            fs::rename(current_exe, &old_path)
                .context("Failed to rename current exe for update")?;

            let mut file =
                fs::File::create(current_exe).context("Failed to create new launcher exe")?;
            std::io::copy(&mut entry, &mut file)?;
        } else {
            // Preserve user config, but refresh all other bundled payload files.
            if is_user_preserved_file(&name) && dest.exists() {
                tracing::debug!(path = %dest.display(), "Preserving existing user config file during update");
            } else {
                if let Some(p) = dest.parent() {
                    fs::create_dir_all(p)?;
                }
                let mut file = fs::File::create(&dest)?;
                std::io::copy(&mut entry, &mut file)?;
            }
        }
    }

    Ok(())
}

fn is_launcher_exe(name: &str) -> bool {
    let lower = name.to_lowercase();
    lower.ends_with("highbeam-launcher.exe") || lower.ends_with("highbeam-launcher")
}

fn is_user_preserved_file(name: &str) -> bool {
    name.eq_ignore_ascii_case("LauncherConfig.toml")
}

fn cleanup_old_binary() {
    if let Ok(exe) = std::env::current_exe() {
        let old = exe.with_extension("old");
        let _ = fs::remove_file(old);
    }
}

/// Call at startup to remove leftover `.old` binary from a previous update.
pub fn cleanup_previous_update() {
    cleanup_old_binary();
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
    fn test_is_launcher_exe() {
        assert!(is_launcher_exe("highbeam-launcher.exe"));
        assert!(is_launcher_exe("HighBeam-Launcher.exe"));
        assert!(is_launcher_exe("highbeam-launcher"));
        assert!(!is_launcher_exe("LauncherConfig.toml"));
    }
}
