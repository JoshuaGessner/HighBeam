use std::fs::File;
use std::io::{Read, Seek};
use std::path::{Path, PathBuf};

use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

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
    pub mods_dir: PathBuf,
}

pub struct ClientModDisableReport {
    pub removed_zip: bool,
    pub removed_temp_zip: bool,
    pub mods_dir: PathBuf,
}

pub fn install_all(
    beamng_userfolder: Option<&str>,
    cache_dir: &Path,
    cache_index: &CacheIndex,
    server_mods: &[ServerMod],
) -> Result<InstallReport> {
    let mods_dir = resolve_mods_dir(beamng_userfolder)?;
    tracing::info!(
        mods_dir = %mods_dir.display(),
        server_mod_count = server_mods.len(),
        "Installing server mods into BeamNG mods directory"
    );
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
        tracing::debug!(
            mod_name = %mod_info.name,
            src = %src.display(),
            dst = %dst.display(),
            hash = %mod_info.hash,
            "Staging server mod"
        );
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

    Ok(InstallReport {
        installed_server_mods,
        mods_dir,
    })
}

pub fn install_client_mod(beamng_userfolder: Option<&str>, payload_zip: &Path) -> Result<PathBuf> {
    let mods_dir = resolve_mods_dir(beamng_userfolder)?;
    tracing::info!(
        mods_dir = %mods_dir.display(),
        payload_zip = %payload_zip.display(),
        "Installing HighBeam client mod"
    );
    std::fs::create_dir_all(&mods_dir)
        .with_context(|| format!("Failed to create BeamNG mods dir: {}", mods_dir.display()))?;
    install_highbeam_client_mod(payload_zip, &mods_dir)
}

/// Disable the HighBeam client mod by removing only the payload zip files.
/// This intentionally preserves user preferences stored in userdata/highbeam.
pub fn disable_client_mod(beamng_userfolder: Option<&str>) -> Result<ClientModDisableReport> {
    let mods_dir = resolve_mods_dir(beamng_userfolder)?;
    let client_zip = mods_dir.join("highbeam.zip");
    let temp_zip = mods_dir.join("highbeam.zip.tmp");

    let mut report = ClientModDisableReport {
        removed_zip: false,
        removed_temp_zip: false,
        mods_dir: mods_dir.clone(),
    };

    if client_zip.exists() {
        std::fs::remove_file(&client_zip).with_context(|| {
            format!(
                "Failed to remove HighBeam client mod zip: {}",
                client_zip.display()
            )
        })?;
        report.removed_zip = true;
    }

    if temp_zip.exists() {
        std::fs::remove_file(&temp_zip).with_context(|| {
            format!(
                "Failed to remove temporary HighBeam client mod zip: {}",
                temp_zip.display()
            )
        })?;
        report.removed_temp_zip = true;
    }

    Ok(report)
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
                    if best.as_ref().is_none_or(|b| (b.0, b.1) < (major, minor)) {
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

/// Resolve the BeamNG userfolder root (the parent of the `mods/` directory).
/// Returns the root path before `resolve_mods_subdir` is applied.
pub fn resolve_userfolder(beamng_userfolder: Option<&str>) -> Result<PathBuf> {
    if let Some(userfolder) = beamng_userfolder {
        return Ok(expand_tilde(userfolder));
    }
    if let Some(userfolder) = crate::detect::detect_beamng_userfolder() {
        return Ok(userfolder);
    }
    #[cfg(target_os = "windows")]
    {
        if let Some(local_app_data) = std::env::var_os("LOCALAPPDATA") {
            let modern = PathBuf::from(&local_app_data)
                .join("BeamNG")
                .join("BeamNG.drive");
            if modern.is_dir() {
                return Ok(modern);
            }
            return Ok(PathBuf::from(local_app_data).join("BeamNG.drive"));
        }
    }
    if let Some(home) = std::env::var_os("HOME") {
        return Ok(PathBuf::from(home).join("BeamNG.drive"));
    }
    Err(anyhow!(
        "Unable to resolve BeamNG userfolder; set beamng_userfolder in LauncherConfig.toml"
    ))
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
            tracing::debug!(
                dst = %dst.display(),
                "Mod already up to date; skipping copy"
            );
            return Ok(());
        }
    }

    tracing::info!(
        src = %src.display(),
        dst = %dst.display(),
        "Copying mod file"
    );
    std::fs::copy(src, dst).with_context(|| {
        format!(
            "Failed to copy mod into BeamNG mods directory: {} -> {}",
            src.display(),
            dst.display()
        )
    })?;
    Ok(())
}

fn install_highbeam_client_mod(payload_zip: &Path, mods_dir: &Path) -> Result<PathBuf> {
    if !payload_zip.exists() {
        return Err(anyhow!(
            "Bundled HighBeam client payload not found: {}",
            payload_zip.display()
        ));
    }

    verify_client_zip(payload_zip)?;

    let final_zip = mods_dir.join("highbeam.zip");
    let temp_zip = mods_dir.join("highbeam.zip.tmp");

    if final_zip.exists() {
        let src_hash = sha256_file_hex(payload_zip)?;
        let dst_hash = sha256_file_hex(&final_zip)?;
        if src_hash.eq_ignore_ascii_case(&dst_hash) {
            tracing::info!(
                path = %final_zip.display(),
                "HighBeam client mod zip already up to date"
            );
            cleanup_legacy_client_folder(mods_dir);
            return Ok(final_zip);
        }
    }

    tracing::info!(
        source = %payload_zip.display(),
        temp = %temp_zip.display(),
        target = %final_zip.display(),
        "Installing bundled HighBeam client zip"
    );

    if temp_zip.exists() {
        std::fs::remove_file(&temp_zip).with_context(|| {
            format!(
                "Failed to remove stale temporary client mod zip: {}",
                temp_zip.display()
            )
        })?;
    }

    std::fs::copy(payload_zip, &temp_zip).with_context(|| {
        format!(
            "Failed to stage bundled HighBeam client zip: {} -> {}",
            payload_zip.display(),
            temp_zip.display()
        )
    })?;
    verify_client_zip(&temp_zip)?;

    if final_zip.exists() {
        std::fs::remove_file(&final_zip).with_context(|| {
            format!(
                "Failed to replace existing HighBeam client mod zip: {}",
                final_zip.display()
            )
        })?;
    }
    std::fs::rename(&temp_zip, &final_zip).with_context(|| {
        format!(
            "Failed to activate HighBeam client mod zip: {} -> {}",
            temp_zip.display(),
            final_zip.display()
        )
    })?;

    cleanup_legacy_client_folder(mods_dir);

    tracing::info!(
        path = %final_zip.display(),
        "Installed HighBeam client mod zip to BeamNG mods directory"
    );

    Ok(final_zip)
}

fn cleanup_legacy_client_folder(mods_dir: &Path) {
    // Best-effort migration cleanup from the old extracted-folder install format.
    let legacy_folder = mods_dir.join("highbeam");
    if legacy_folder.is_dir() {
        match std::fs::remove_dir_all(&legacy_folder) {
            Ok(()) => tracing::info!(
                path = %legacy_folder.display(),
                "Removed legacy extracted HighBeam mod folder"
            ),
            Err(e) => tracing::warn!(
                error = %e,
                path = %legacy_folder.display(),
                "Failed to remove legacy extracted HighBeam mod folder"
            ),
        }
    }
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
    let mut has_vehicle_ext = false;
    let mut has_position_ve = false;
    let mut has_inputs_ve = false;
    let mut has_electrics_ve = false;
    let mut has_powertrain_ve = false;
    let mut has_damage_ve = false;

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
        if name == "lua/vehicle/extensions/highbeam/highbeamVE.lua" {
            has_vehicle_ext = true;
        }
        if name == "lua/vehicle/extensions/highbeam/highbeamPositionVE.lua" {
            has_position_ve = true;
        }
        if name == "lua/vehicle/extensions/highbeam/highbeamInputsVE.lua" {
            has_inputs_ve = true;
        }
        if name == "lua/vehicle/extensions/highbeam/highbeamElectricsVE.lua" {
            has_electrics_ve = true;
        }
        if name == "lua/vehicle/extensions/highbeam/highbeamPowertrainVE.lua" {
            has_powertrain_ve = true;
        }
        if name == "lua/vehicle/extensions/highbeam/highbeamDamageVE.lua" {
            has_damage_ve = true;
        }
    }

    let has_mod_script = has_mod_script_root || has_mod_script_legacy;
    let has_required_ve = has_vehicle_ext
        && has_position_ve
        && has_inputs_ve
        && has_electrics_ve
        && has_powertrain_ve
        && has_damage_ve;
    if !has_mod_script || !has_extension || !has_required_ve {
        return Err(anyhow!(
            "HighBeam client zip is missing required files (modScript_root={}, modScript_legacy={}, extension={}, ve={}, position_ve={}, inputs_ve={}, electrics_ve={}, powertrain_ve={}, damage_ve={})",
            has_mod_script_root,
            has_mod_script_legacy,
            has_extension,
            has_vehicle_ext,
            has_position_ve,
            has_inputs_ve,
            has_electrics_ve,
            has_powertrain_ve,
            has_damage_ve
        ));
    }

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
    use std::fs;
    use std::io::Cursor;
    use std::io::Write;
    use std::time::{SystemTime, UNIX_EPOCH};
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
            zip.start_file("lua/vehicle/extensions/highbeam/highbeamVE.lua", options)
                .expect("write highbeamVE entry");
            zip.write_all(b"return {}")
                .expect("write highbeamVE contents");
            zip.start_file(
                "lua/vehicle/extensions/highbeam/highbeamPositionVE.lua",
                options,
            )
            .expect("write highbeamPositionVE entry");
            zip.write_all(b"return {}")
                .expect("write highbeamPositionVE contents");
            zip.start_file("lua/vehicle/extensions/highbeam/highbeamInputsVE.lua", options)
                .expect("write highbeamInputsVE entry");
            zip.write_all(b"return {}")
                .expect("write highbeamInputsVE contents");
            zip.start_file(
                "lua/vehicle/extensions/highbeam/highbeamElectricsVE.lua",
                options,
            )
            .expect("write highbeamElectricsVE entry");
            zip.write_all(b"return {}")
                .expect("write highbeamElectricsVE contents");
            zip.start_file(
                "lua/vehicle/extensions/highbeam/highbeamPowertrainVE.lua",
                options,
            )
            .expect("write highbeamPowertrainVE entry");
            zip.write_all(b"return {}")
                .expect("write highbeamPowertrainVE contents");
            zip.start_file("lua/vehicle/extensions/highbeam/highbeamDamageVE.lua", options)
                .expect("write highbeamDamageVE entry");
            zip.write_all(b"return {}")
                .expect("write highbeamDamageVE contents");
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
            zip.start_file("lua/vehicle/extensions/highbeam/highbeamVE.lua", options)
                .expect("write highbeamVE entry");
            zip.write_all(b"return {}")
                .expect("write highbeamVE contents");
            zip.start_file(
                "lua/vehicle/extensions/highbeam/highbeamPositionVE.lua",
                options,
            )
            .expect("write highbeamPositionVE entry");
            zip.write_all(b"return {}")
                .expect("write highbeamPositionVE contents");
            zip.start_file("lua/vehicle/extensions/highbeam/highbeamInputsVE.lua", options)
                .expect("write highbeamInputsVE entry");
            zip.write_all(b"return {}")
                .expect("write highbeamInputsVE contents");
            zip.start_file(
                "lua/vehicle/extensions/highbeam/highbeamElectricsVE.lua",
                options,
            )
            .expect("write highbeamElectricsVE entry");
            zip.write_all(b"return {}")
                .expect("write highbeamElectricsVE contents");
            zip.start_file(
                "lua/vehicle/extensions/highbeam/highbeamPowertrainVE.lua",
                options,
            )
            .expect("write highbeamPowertrainVE entry");
            zip.write_all(b"return {}")
                .expect("write highbeamPowertrainVE contents");
            zip.start_file("lua/vehicle/extensions/highbeam/highbeamDamageVE.lua", options)
                .expect("write highbeamDamageVE entry");
            zip.write_all(b"return {}")
                .expect("write highbeamDamageVE contents");
            zip.finish().expect("finish zip");
        }

        cursor.set_position(0);
        verify_client_zip_reader(cursor).expect("zip with legacy modScript path should verify");
    }

    fn write_test_client_zip(zip_path: &Path, payload: &[u8]) {
        let mut cursor = Cursor::new(Vec::new());
        {
            let mut zip = zip::ZipWriter::new(&mut cursor);
            let options =
                SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
            zip.start_file("scripts/modScript.lua", options)
                .expect("write modScript entry");
            zip.write_all(payload).expect("write modScript payload");
            zip.start_file("lua/ge/extensions/highbeam.lua", options)
                .expect("write extension entry");
            zip.write_all(b"return {}")
                .expect("write extension contents");
            zip.start_file("lua/vehicle/extensions/highbeam/highbeamVE.lua", options)
                .expect("write highbeamVE entry");
            zip.write_all(b"return {}")
                .expect("write highbeamVE contents");
            zip.start_file(
                "lua/vehicle/extensions/highbeam/highbeamPositionVE.lua",
                options,
            )
            .expect("write highbeamPositionVE entry");
            zip.write_all(b"return {}")
                .expect("write highbeamPositionVE contents");
            zip.start_file("lua/vehicle/extensions/highbeam/highbeamInputsVE.lua", options)
                .expect("write highbeamInputsVE entry");
            zip.write_all(b"return {}")
                .expect("write highbeamInputsVE contents");
            zip.start_file(
                "lua/vehicle/extensions/highbeam/highbeamElectricsVE.lua",
                options,
            )
            .expect("write highbeamElectricsVE entry");
            zip.write_all(b"return {}")
                .expect("write highbeamElectricsVE contents");
            zip.start_file(
                "lua/vehicle/extensions/highbeam/highbeamPowertrainVE.lua",
                options,
            )
            .expect("write highbeamPowertrainVE entry");
            zip.write_all(b"return {}")
                .expect("write highbeamPowertrainVE contents");
            zip.start_file("lua/vehicle/extensions/highbeam/highbeamDamageVE.lua", options)
                .expect("write highbeamDamageVE entry");
            zip.write_all(b"return {}")
                .expect("write highbeamDamageVE contents");
            zip.finish().expect("finish zip");
        }
        fs::write(zip_path, cursor.into_inner()).expect("write payload zip");
    }

    #[test]
    fn install_highbeam_client_mod_writes_highbeam_zip_and_removes_legacy_folder() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock should be after epoch")
            .as_nanos();
        let root = std::env::temp_dir().join(format!("highbeam-launcher-test-{}", nonce));
        let payload_zip = root.join("payload/highbeam.zip");
        let mods_dir = root.join("mods");

        fs::create_dir_all(payload_zip.parent().expect("payload parent"))
            .expect("create payload directory");
        fs::create_dir_all(mods_dir.join("highbeam/old")).expect("create legacy extracted dir");
        write_test_client_zip(&payload_zip, b"return true");
        fs::write(mods_dir.join("highbeam/old/file.txt"), "legacy").expect("write legacy file");

        let installed =
            install_highbeam_client_mod(&payload_zip, &mods_dir).expect("install should succeed");
        let installed_zip = installed;

        assert_eq!(installed_zip, mods_dir.join("highbeam.zip"));
        assert!(installed_zip.is_file(), "expected highbeam.zip to exist");
        assert!(
            !mods_dir.join("highbeam").exists(),
            "legacy extracted folder should be removed"
        );
        assert!(
            !mods_dir.join("highbeam.zip.tmp").exists(),
            "temporary zip should not remain"
        );

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn install_highbeam_client_mod_skips_copy_when_zip_is_unchanged() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock should be after epoch")
            .as_nanos();
        let root = std::env::temp_dir().join(format!("highbeam-launcher-test-{}", nonce));
        let payload_zip = root.join("payload/highbeam.zip");
        let mods_dir = root.join("mods");
        fs::create_dir_all(payload_zip.parent().expect("payload parent"))
            .expect("create payload directory");
        fs::create_dir_all(&mods_dir).expect("create mods dir");

        write_test_client_zip(&payload_zip, b"return true");
        let first =
            install_highbeam_client_mod(&payload_zip, &mods_dir).expect("first install succeeds");
        let first_meta = fs::metadata(&first).expect("first zip metadata");
        let first_size = first_meta.len();

        let second = install_highbeam_client_mod(&payload_zip, &mods_dir)
            .expect("second install should also succeed");
        let second_meta = fs::metadata(&second).expect("second zip metadata");

        assert_eq!(
            first_size,
            second_meta.len(),
            "zip size should remain unchanged"
        );
        assert!(
            !mods_dir.join("highbeam.zip.tmp").exists(),
            "temporary zip should not remain"
        );

        let _ = fs::remove_dir_all(root);
    }
}
