#[cfg(target_os = "windows")]
fn main() {
    let icon_path = "../server/assets/icon.ico";
    println!("cargo:rerun-if-changed={icon_path}");

    let mut res = winresource::WindowsResource::new();
    res.set_icon(icon_path);

    if let Err(e) = res.compile() {
        panic!("failed to compile launcher Windows resources: {e}");
    }
}

#[cfg(not(target_os = "windows"))]
fn main() {}
