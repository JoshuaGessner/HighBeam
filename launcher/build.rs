use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

fn main() {
    build_payload_zip();

    #[cfg(target_os = "windows")]
    compile_windows_resources();
}

/// Package the client mod (`client/{scripts,lua,ui}`) into
/// `launcher/payload/highbeam.zip` on every build.
///
/// This zip is the single source of truth for the client payload: the launcher
/// loads it at runtime (there is no download fallback — see
/// `resolve_client_payload_zip` in `main.rs`) and CI copies it next to the
/// release binary. Generating it here from source means it can never go stale or
/// missing, so the artifact is intentionally NOT committed (`.gitignore`).
fn build_payload_zip() {
    let manifest_dir =
        PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR not set"));
    let client_dir = manifest_dir.join("..").join("client");
    let out_path = manifest_dir.join("payload").join("highbeam.zip");

    const SUBDIRS: [&str; 3] = ["scripts", "lua", "ui"];

    // Rebuild whenever any client source changes.
    for sub in SUBDIRS {
        println!("cargo:rerun-if-changed={}", client_dir.join(sub).display());
    }
    println!("cargo:rerun-if-changed=build.rs");

    if let Some(parent) = out_path.parent() {
        fs::create_dir_all(parent).expect("failed to create launcher/payload directory");
    }

    let file = File::create(&out_path).expect("failed to create highbeam.zip");
    let mut zip = ZipWriter::new(file);
    let options = SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);

    for sub in SUBDIRS {
        let dir = client_dir.join(sub);
        if !dir.is_dir() {
            panic!(
                "client payload source missing: {} (expected client/{sub})",
                dir.display()
            );
        }
        add_dir_recursive(&mut zip, &client_dir, &dir, options)
            .unwrap_or_else(|e| panic!("failed to add client/{sub} to payload zip: {e}"));
    }

    zip.finish().expect("failed to finalize highbeam.zip");
}

/// Add `dir` and its contents to `zip`, using paths relative to `base` (so the
/// archive entries are `scripts/...`, `lua/...`, `ui/...`). Entries are sorted
/// for a deterministic layout, and macOS `.DS_Store` files are skipped.
fn add_dir_recursive<W: Write + std::io::Seek>(
    zip: &mut ZipWriter<W>,
    base: &Path,
    dir: &Path,
    options: SimpleFileOptions,
) -> std::io::Result<()> {
    let mut entries: Vec<_> = fs::read_dir(dir)?.filter_map(Result::ok).collect();
    entries.sort_by_key(|e| e.file_name());

    for entry in entries {
        let path = entry.path();
        if entry.file_name() == ".DS_Store" {
            continue;
        }

        // Zip entry names are relative to client/ and always use forward slashes.
        let rel = path
            .strip_prefix(base)
            .expect("entry is not under base dir")
            .to_string_lossy()
            .replace('\\', "/");

        if path.is_dir() {
            zip.add_directory(format!("{rel}/"), options)?;
            add_dir_recursive(zip, base, &path, options)?;
        } else {
            zip.start_file(rel, options)?;
            let mut buf = Vec::new();
            File::open(&path)?.read_to_end(&mut buf)?;
            zip.write_all(&buf)?;
        }
    }

    Ok(())
}

#[cfg(target_os = "windows")]
fn compile_windows_resources() {
    let icon_path = "../server/assets/icon.ico";
    println!("cargo:rerun-if-changed={icon_path}");

    let mut res = winresource::WindowsResource::new();
    res.set_icon(icon_path);

    if let Err(e) = res.compile() {
        panic!("failed to compile launcher Windows resources: {e}");
    }
}
