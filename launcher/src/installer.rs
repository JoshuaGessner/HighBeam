use std::fs::File;
use std::io::{Read, Seek};
use std::path::{Path, PathBuf};

use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use zip::write::SimpleFileOptions;

use crate::mod_cache::CacheIndex;
use crate::mod_sync::ServerMod;

const SESSION_MANIFEST_FILE: &str = "highbeam-session-manifest.json";


#[derive(Debug, Default)]
pub struct CleanupReport {
    pub removed_files: usize,
    pub missing_files: usize,
    pub mods_dir: PathBuf,
}

#[derive(Debug, Serialize, Deserialize)]
struct SessionManifest {
    staged_server_mod_files: Vec<String>,
}

pub struct InstallReport {
    pub installed_server_mods: usize,
    pub installed_client_mod: bool,
    pub mods_dir: PathBuf,
}

pub fn install_all(
    beamng_userfolder: Option<&str>,
    cache_dir: &Path,
    cache_index: &CacheIndex,
    server_mods: &[ServerMod],
    workspace_root: &Path,
) -> Result<InstallReport> {
    let mods_dir = resolve_mods_dir(beamng_userfolder)?;
    std::fs::create_dir_all(&mods_dir)
        .with_context(|| format!("Failed to create BeamNG mods dir: {}", mods_dir.display()))?;

    let mut installed_server_mods = 0usize;
    let mut staged_files = Vec::new();
    for mod_info in server_mods {
        let Some(cache_entry) = cache_index.entries.get(&mod_info.hash) else {
            return Err(anyhow!(
                "Server mod missing from cache index: {} ({})",
                mod_info.name,
                mod_info.hash
            ));
        };

        if cache_entry.size != mod_info.size {
            tracing::warn!(
                mod_name = %mod_info.name,
                expected_size = mod_info.size,
                cache_size = cache_entry.size,
                "Cached mod size differs from server manifest"
            );
        }

        let src = cache_dir.join(format!("{}.zip", cache_entry.hash));
        let dst = mods_dir.join(staged_server_mod_name(&mod_info.name));
        copy_if_changed(&src, &dst, &mod_info.hash)?;
        let Some(file_name) = dst.file_name().and_then(|s| s.to_str()) else {
            return Err(anyhow!("Invalid staged mod filename: {}", dst.display()));
        };
        staged_files.push(file_name.to_string());
        installed_server_mods += 1;
    }

    save_session_manifest(
        &mods_dir,
        &SessionManifest {
            staged_server_mod_files: staged_files,
        },
    )?;

    let installed_client_mod = install_highbeam_client_mod(workspace_root, &mods_dir)?;

    Ok(InstallReport {
        installed_server_mods,
        installed_client_mod,
        mods_dir,
    })
}

pub fn cleanup_staged_server_mods(beamng_userfolder: Option<&str>) -> Result<CleanupReport> {
    let mods_dir = resolve_mods_dir(beamng_userfolder)?;
    cleanup_staged_server_mods_in_dir(&mods_dir)
}

fn cleanup_staged_server_mods_in_dir(mods_dir: &Path) -> Result<CleanupReport> {
    let mut report = CleanupReport {
        removed_files: 0,
        missing_files: 0,
        mods_dir: mods_dir.to_path_buf(),
    };

    let Some(manifest) = load_session_manifest(mods_dir)? else {
        return Ok(report);
    };

    for file_name in &manifest.staged_server_mod_files {
        let path = mods_dir.join(file_name);
        if path.exists() {
            std::fs::remove_file(&path)
                .with_context(|| format!("Failed to remove staged mod: {}", path.display()))?;
            report.removed_files += 1;
        } else {
            report.missing_files += 1;
        }
    }

    let manifest_path = session_manifest_path(mods_dir);
    if manifest_path.exists() {
        std::fs::remove_file(&manifest_path).with_context(|| {
            format!(
                "Failed to remove staged session manifest: {}",
                manifest_path.display()
            )
        })?;
    }

    Ok(report)
}

fn staged_server_mod_name(original_name: &str) -> String {
    let base = Path::new(original_name)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("server-mod.zip");
    format!("highbeam-session-{}", base)
}

fn session_manifest_path(mods_dir: &Path) -> PathBuf {
    mods_dir.join(SESSION_MANIFEST_FILE)
}

fn save_session_manifest(mods_dir: &Path, manifest: &SessionManifest) -> Result<()> {
    let content = serde_json::to_string_pretty(manifest)
        .context("Failed to serialize staged session manifest")?;
    let path = session_manifest_path(mods_dir);
    std::fs::write(&path, content).with_context(|| {
        format!(
            "Failed to write staged session manifest: {}",
            path.display()
        )
    })
}

fn load_session_manifest(mods_dir: &Path) -> Result<Option<SessionManifest>> {
    let path = session_manifest_path(mods_dir);
    if !path.exists() {
        return Ok(None);
    }

    let content = std::fs::read_to_string(&path)
        .with_context(|| format!("Failed to read staged session manifest: {}", path.display()))?;
    let manifest: SessionManifest = serde_json::from_str(&content).with_context(|| {
        format!(
            "Failed to parse staged session manifest: {}",
            path.display()
        )
    })?;
    Ok(Some(manifest))
}

fn resolve_mods_dir(beamng_userfolder: Option<&str>) -> Result<PathBuf> {
    let root = if let Some(userfolder) = beamng_userfolder {
        expand_tilde(userfolder)
    } else if let Some(userfolder) = crate::detect::detect_beamng_userfolder() {
        tracing::info!(path = %userfolder.display(), "Auto-detected BeamNG.drive user folder");
        userfolder
    } else {
        // Hard last-resort fallback when detection fails entirely
        #[cfg(target_os = "windows")]
        {
            if let Some(local_app_data) = std::env::var_os("LOCALAPPDATA") {
                return Ok(PathBuf::from(local_app_data)
                    .join("BeamNG")
                    .join("BeamNG.drive")
                    .join("current")
                    .join("mods"));
            }
        }
        if let Some(home) = std::env::var_os("HOME") {
            return Ok(PathBuf::from(home).join("BeamNG.drive").join("mods"));
        }
        return Err(anyhow!(
            "Unable to resolve BeamNG userfolder; set beamng_userfolder in LauncherConfig.toml"
        ));
    };

    Ok(resolve_mods_subdir(&root))
}

/// Given a BeamNG userfolder root, locate the correct `mods/` subdirectory.
///
/// Modern BeamNG (0.27+) organises user data as:
///   `<root>/current/mods/`          – junction/symlink to the active version
///   `<root>/<major.minor>/mods/`    – fallback: highest numeric version dir
///
/// Legacy installs use:
///   `<root>/mods/`
fn resolve_mods_subdir(root: &Path) -> PathBuf {
    // 1. Modern path: current/ subdirectory (BeamNG 0.27+)
    let current = root.join("current");
    if current.is_dir() {
        let mods = current.join("mods");
        tracing::info!(path = %mods.display(), "Using modern BeamNG mods path (current/)");
        return mods;
    }

    // 2. Versioned subdirectory: pick the highest semver-like numeric directory
    if let Ok(entries) = std::fs::read_dir(root) {
        let mut best: Option<(u64, u64, PathBuf)> = None;
        for entry in entries.flatten() {
            let p = entry.path();
            if !p.is_dir() {
                continue;
            }
            if let Some(name) = p.file_name().and_then(|n| n.to_str()) {
                let mut parts = name.splitn(3, '.');
                if let (Some(major), Some(minor)) = (
                    parts.next().and_then(|s| s.parse::<u64>().ok()),
                    parts.next().and_then(|s| s.parse::<u64>().ok()),
                ) {
                    if best.as_ref().map_or(true, |b| (b.0, b.1) < (major, minor)) {
                        best = Some((major, minor, p));
                    }
                }
            }
        }
        if let Some((maj, min, versioned)) = best {
            let mods = versioned.join("mods");
            tracing::info!(
                version = %format!("{}.{}", maj, min),
                path = %mods.display(),
                "Using versioned BeamNG mods path"
            );
            return mods;
        }
    }

    // 3. Legacy fallback: mods/ directly on root
    let mods = root.join("mods");
    tracing::info!(path = %mods.display(), "Using legacy BeamNG mods path");
    mods
}

/// Public wrapper around `resolve_mods_dir` for use by other modules.
pub fn resolve_mods_dir_pub(beamng_userfolder: Option<&str>) -> Result<PathBuf> {
    resolve_mods_dir(beamng_userfolder)
}

fn expand_tilde(path: &str) -> PathBuf {
    if let Some(rest) = path.strip_prefix("~/") {
        if let Some(home) = std::env::var_os("HOME") {
            return PathBuf::from(home).join(rest);
        }
    }
    PathBuf::from(path)
}

fn copy_if_changed(src: &Path, dst: &Path, expected_hash: &str) -> Result<()> {
    if !src.exists() {
        return Err(anyhow!("Cached mod file is missing: {}", src.display()));
    }

    if dst.exists() {
        let current_hash = sha256_file_hex(dst)?;
        if current_hash.eq_ignore_ascii_case(expected_hash) {
            return Ok(());
        }
    }

    std::fs::copy(src, dst).with_context(|| {
        format!(
            "Failed to copy mod into BeamNG mods directory: {} -> {}",
            src.display(),
            dst.display()
        )
    })?;
    Ok(())
}

fn install_highbeam_client_mod(client_root: &Path, mods_dir: &Path) -> Result<bool> {
    if !client_root.exists() {
        tracing::warn!(
            path = %client_root.display(),
            "Client source directory not found; skipping HighBeam client mod install"
        );
        return Ok(false);
    }

    // Create a temporary zip for verification
    let temp_zip = mods_dir.join(".highbeam-temp.zip");
    create_zip_from_dir(client_root, &temp_zip)?;
    verify_client_zip(&temp_zip)?;

    // Now extract it to the proper mod directory
    let mod_dir = mods_dir.join("highbeam");
    extract_client_zip_to_mod_dir(&temp_zip, &mod_dir)?;

    // Clean up the temporary zip
    std::fs::remove_file(&temp_zip).with_context(|| {
        format!(
            "Failed to remove temporary client mod zip: {}",
            temp_zip.display()
        )
    })?;

    tracing::info!(
        path = %mod_dir.display(),
        "Installed HighBeam client mod to BeamNG mods directory"
    );

    Ok(true)
}

fn create_zip_from_dir(src_root: &Path, out_zip: &Path) -> Result<()> {
    let file = File::create(out_zip)
        .with_context(|| format!("Failed to create client mod zip: {}", out_zip.display()))?;
    let mut zip = zip::ZipWriter::new(file);
    let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);

    let mut stack = vec![src_root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir)
            .with_context(|| format!("Failed to read client dir: {}", dir.display()))?
        {
            let entry = entry?;
            let path = entry.path();
            let rel = path.strip_prefix(src_root).unwrap();

            if path.is_dir() {
                stack.push(path);
                continue;
            }

            let rel_str = rel.to_string_lossy().replace('\\', "/");
            zip.start_file(rel_str, options)?;

            let mut src_file = File::open(&path)
                .with_context(|| format!("Failed to open client file: {}", path.display()))?;
            std::io::copy(&mut src_file, &mut zip)?;
        }
    }

    zip.finish()?;
    Ok(())
}

fn verify_client_zip(out_zip: &Path) -> Result<()> {
    let file = File::open(out_zip)
        .with_context(|| format!("Failed to open client mod zip: {}", out_zip.display()))?;
    verify_client_zip_reader(file)
}

fn verify_client_zip_reader<R>(reader: R) -> Result<()>
where
    R: Read + Seek,
{
    let mut archive = zip::ZipArchive::new(reader).context("Failed to open zip archive")?;
    let mut has_mod_script_root = false;
    let mut has_mod_script_legacy = false;
    let mut has_extension = false;

    for i in 0..archive.len() {
        let entry = archive.by_index(i).context("Failed to read zip entry")?;
        let name = entry.name();
        if name == "scripts/modScript.lua" {
            has_mod_script_root = true;
        }
        if name == "scripts/highbeam/modScript.lua" {
            has_mod_script_legacy = true;
        }
        if name == "lua/ge/extensions/highbeam.lua" {
            has_extension = true;
        }
    }

    let has_mod_script = has_mod_script_root || has_mod_script_legacy;
    if !has_mod_script || !has_extension {
        return Err(anyhow!(
            "HighBeam client zip is missing required files (modScript_root={}, modScript_legacy={}, extension={})",
            has_mod_script_root,
            has_mod_script_legacy,
            has_extension
        ));
    }

    Ok(())
}

fn extract_client_zip_to_mod_dir(zip_path: &Path, mod_dir: &Path) -> Result<()> {
    // Create the mod directory (will overwrite any existing installation)
    std::fs::create_dir_all(mod_dir).with_context(|| {
        format!(
            "Failed to create HighBeam mod directory: {}",
            mod_dir.display()
        )
    })?;

    let file = File::open(zip_path).with_context(|| {
        format!("Failed to open HighBeam client zip for extraction: {}", zip_path.display())
    })?;
    let mut archive = zip::ZipArchive::new(file)
        .context("Failed to open zip archive for extraction")?;

    for i in 0..archive.len() {
        let mut entry = archive
            .by_index(i)
            .context("Failed to read zip entry for extraction")?;
        let outpath = mod_dir.join(entry.name());

        if entry.is_dir() {
            std::fs::create_dir_all(&outpath).with_context(|| {
                format!(
                    "Failed to create directory when extracting HighBeam mod: {}",
                    outpath.display()
                )
            })?;
        } else {
            if let Some(p) = outpath.parent() {
                if !p.exists() {
                    std::fs::create_dir_all(p).with_context(|| {
                        format!(
                            "Failed to create parent directory when extracting HighBeam mod: {}",
                            p.display()
                        )
                    })?;
                }
            }

            let mut outfile = File::create(&outpath).with_context(|| {
                format!(
                    "Failed to create file when extracting HighBeam mod: {}",
                    outpath.display()
                )
            })?;
            std::io::copy(&mut entry, &mut outfile).with_context(|| {
                format!(
                    "Failed to write file when extracting HighBeam mod: {}",
                    outpath.display()
                )
            })?;
        }
    }

    tracing::info!(
        path = %mod_dir.display(),
        "Successfully extracted HighBeam client mod to mod directory"
    );
    Ok(())
}

fn sha256_file_hex(path: &Path) -> Result<String> {
    let mut file = File::open(path)
        .with_context(|| format!("Failed to open file for hashing: {}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 64 * 1024];

    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }

    Ok(format!("{:x}", hasher.finalize()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;
    use std::io::Write;
    use zip::write::SimpleFileOptions;

    #[test]
    fn test_expand_tilde_plain_path() {
        let p = expand_tilde("abc/def");
        assert_eq!(p, PathBuf::from("abc/def"));
    }

    #[test]
    fn verify_client_zip_reader_accepts_required_files() {
        let mut cursor = Cursor::new(Vec::new());
        {
            let mut zip = zip::ZipWriter::new(&mut cursor);
            let options =
                SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
            zip.start_file("scripts/modScript.lua", options)
                .expect("write modScript entry");
            zip.write_all(b"load('highbeam')")
                .expect("write modScript contents");
            zip.start_file("lua/ge/extensions/highbeam.lua", options)
                .expect("write extension entry");
            zip.write_all(b"return {}")
                .expect("write extension contents");
            zip.finish().expect("finish zip");
        }

        cursor.set_position(0);
        verify_client_zip_reader(cursor).expect("zip with required files should verify");
    }

    #[test]
    fn verify_client_zip_reader_rejects_missing_required_files() {
        let mut cursor = Cursor::new(Vec::new());
        {
            let mut zip = zip::ZipWriter::new(&mut cursor);
            let options =
                SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
            zip.start_file("scripts/modScript.lua", options)
                .expect("write modScript entry");
            zip.write_all(b"load('highbeam')")
                .expect("write modScript contents");
            zip.finish().expect("finish zip");
        }

        cursor.set_position(0);
        let err = verify_client_zip_reader(cursor).expect_err("zip missing extension should fail");
        assert!(
            err.to_string().contains("missing required files"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn verify_client_zip_reader_accepts_legacy_mod_script_path() {
        let mut cursor = Cursor::new(Vec::new());
        {
            let mut zip = zip::ZipWriter::new(&mut cursor);
            let options =
                SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
            zip.start_file("scripts/highbeam/modScript.lua", options)
                .expect("write legacy modScript entry");
            zip.write_all(b"load('highbeam')")
                .expect("write legacy modScript contents");
            zip.start_file("lua/ge/extensions/highbeam.lua", options)
                .expect("write extension entry");
            zip.write_all(b"return {}")
                .expect("write extension contents");
            zip.finish().expect("finish zip");
        }

        cursor.set_position(0);
        verify_client_zip_reader(cursor).expect("zip with legacy modScript path should verify");
    }
}
