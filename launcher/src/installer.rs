use std::fs::File;
use std::io::{Read, Seek};
use std::path::{Path, PathBuf};

use anyhow::{anyhow, Context, Result};
use sha2::{Digest, Sha256};
use zip::write::SimpleFileOptions;

use crate::mod_cache::CacheIndex;
use crate::mod_sync::ServerMod;

const HIGHBEAM_CLIENT_ZIP: &str = "highbeam-client.zip";

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
        let dst = mods_dir.join(&mod_info.name);
        copy_if_changed(&src, &dst, &mod_info.hash)?;
        installed_server_mods += 1;
    }

    let installed_client_mod = install_highbeam_client_mod(workspace_root, &mods_dir)?;

    Ok(InstallReport {
        installed_server_mods,
        installed_client_mod,
        mods_dir,
    })
}

fn resolve_mods_dir(beamng_userfolder: Option<&str>) -> Result<PathBuf> {
    if let Some(userfolder) = beamng_userfolder {
        let root = expand_tilde(userfolder);
        return Ok(root.join("mods"));
    }

    // Try auto-detection
    if let Some(userfolder) = crate::detect::detect_beamng_userfolder() {
        tracing::info!(path = %userfolder.display(), "Auto-detected BeamNG.drive user folder");
        return Ok(userfolder.join("mods"));
    }

    #[cfg(target_os = "windows")]
    {
        if let Some(local_app_data) = std::env::var_os("LOCALAPPDATA") {
            return Ok(PathBuf::from(local_app_data)
                .join("BeamNG.drive")
                .join("mods"));
        }
    }

    if let Some(home) = std::env::var_os("HOME") {
        return Ok(PathBuf::from(home).join("BeamNG.drive").join("mods"));
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

    let out_zip = mods_dir.join(HIGHBEAM_CLIENT_ZIP);
    create_zip_from_dir(&client_root, &out_zip)?;

    verify_client_zip(&out_zip)?;
    let bytes = std::fs::metadata(&out_zip)
        .with_context(|| format!("Failed to read zip metadata: {}", out_zip.display()))?
        .len();
    tracing::info!(
        path = %out_zip.display(),
        bytes,
        "Installed HighBeam client mod archive"
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
    let mut has_mod_script = false;
    let mut has_extension = false;

    for i in 0..archive.len() {
        let entry = archive.by_index(i).context("Failed to read zip entry")?;
        let name = entry.name();
        if name == "scripts/highbeam/modScript.lua" {
            has_mod_script = true;
        }
        if name == "lua/ge/extensions/highbeam.lua" {
            has_extension = true;
        }
    }

    if !has_mod_script || !has_extension {
        return Err(anyhow!(
            "HighBeam client zip is missing required files (modScript={}, extension={})",
            has_mod_script,
            has_extension
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
            zip.start_file("scripts/highbeam/modScript.lua", options)
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
            zip.start_file("scripts/highbeam/modScript.lua", options)
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
}
