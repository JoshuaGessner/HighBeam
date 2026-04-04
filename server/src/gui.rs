use std::sync::Arc;
use std::time::{Duration, Instant};

use eframe::egui;

use crate::control::{ControlPlane, MapEntry, ServerSnapshot};
use crate::session::manager::PlayerAdminSnapshot;

#[cfg(any(target_os = "windows", target_os = "linux"))]
use std::sync::mpsc::{self, Receiver};

#[cfg(any(target_os = "windows", target_os = "linux"))]
use std::sync::Mutex;

#[cfg(any(target_os = "windows", target_os = "linux"))]
use tray_icon::{
    menu::{Menu, MenuEvent, MenuItem},
    MouseButton as TrayMouseButton, TrayIconBuilder, TrayIconEvent,
};

#[derive(Clone, Copy)]
enum TrayCommand {
    Show,
    Toggle,
    Quit,
}

#[cfg(any(target_os = "windows", target_os = "linux"))]
struct TrayBridge {
    rx: Receiver<TrayCommand>,
    /// Shared egui context so tray event handlers can wake the eframe event loop
    /// even when the window is hidden.
    ctx_holder: Arc<Mutex<Option<egui::Context>>>,
    available: bool,
}

#[cfg(not(any(target_os = "windows", target_os = "linux")))]
struct TrayBridge {
    available: bool,
}

#[cfg(any(target_os = "windows", target_os = "linux"))]
fn setup_system_tray_bridge() -> TrayBridge {
    let (tx, rx) = mpsc::channel::<TrayCommand>();
    let ctx_holder: Arc<Mutex<Option<egui::Context>>> = Arc::new(Mutex::new(None));

    // Build context menu with Show/Hide + Quit items.
    let show_hide_item = MenuItem::new("Show/Hide", true, None);
    let quit_item = MenuItem::new("Quit", true, None);
    let menu = Menu::new();
    if let Err(e) = menu.append(&show_hide_item) {
        tracing::warn!(error = %e, "Failed to add Show/Hide tray menu item");
    }
    if let Err(e) = menu.append(&quit_item) {
        tracing::warn!(error = %e, "Failed to add Quit tray menu item");
    }

    // Decode embedded PNG into RGBA for the tray icon.
    let bytes = include_bytes!("../assets/icon.png");
    let img = image::load_from_memory(bytes)
        .expect("embedded tray icon is valid PNG")
        .to_rgba8();
    let (w, h) = img.dimensions();
    let icon = match tray_icon::Icon::from_rgba(img.into_raw(), w, h) {
        Ok(icon) => icon,
        Err(e) => {
            tracing::warn!(error = %e, "Failed to create tray icon from embedded PNG");
            return TrayBridge {
                rx,
                ctx_holder,
                available: false,
            };
        }
    };

    // Build the tray icon with our menu.
    let tray = match TrayIconBuilder::new()
        .with_tooltip("HighBeam Server")
        .with_icon(icon)
        .with_menu(Box::new(menu))
        .build()
    {
        Ok(tray) => tray,
        Err(e) => {
            tracing::warn!(error = %e, "System tray unavailable; running without tray integration");
            return TrayBridge {
                rx,
                ctx_holder,
                available: false,
            };
        }
    };

    // Keep tray icon alive for the process lifetime (dropping it removes the icon).
    Box::leak(Box::new(tray));

    // Wire up menu events → TrayCommand channel + wake eframe.
    let show_hide_id = show_hide_item.id().clone();
    let quit_id = quit_item.id().clone();
    let tx_menu = tx.clone();
    let ctx_menu = ctx_holder.clone();
    MenuEvent::set_event_handler(Some(move |event: MenuEvent| {
        let cmd = if event.id == show_hide_id {
            TrayCommand::Toggle
        } else if event.id == quit_id {
            TrayCommand::Quit
        } else {
            return;
        };
        let _ = tx_menu.send(cmd);
        if let Ok(guard) = ctx_menu.lock() {
            if let Some(ctx) = guard.as_ref() {
                ctx.request_repaint();
            }
        }
    }));

    // Wire up tray icon events (double-click to show, Windows only).
    let tx_icon = tx.clone();
    let ctx_icon = ctx_holder.clone();
    TrayIconEvent::set_event_handler(Some(move |event: TrayIconEvent| {
        #[allow(clippy::single_match)]
        match event {
            TrayIconEvent::DoubleClick {
                button: TrayMouseButton::Left,
                ..
            } => {
                let _ = tx_icon.send(TrayCommand::Show);
                if let Ok(guard) = ctx_icon.lock() {
                    if let Some(ctx) = guard.as_ref() {
                        ctx.request_repaint();
                    }
                }
            }
            _ => {}
        }
    }));

    tracing::info!("System tray integration enabled");
    TrayBridge {
        rx,
        ctx_holder,
        available: true,
    }
}

#[cfg(not(any(target_os = "windows", target_os = "linux")))]
fn setup_system_tray_bridge() -> TrayBridge {
    TrayBridge { available: false }
}

/// Run the GUI event loop on the **calling thread**.
///
/// This must be called from the main thread because winit (used by eframe)
/// requires the event loop to be created there on Windows and most platforms.
/// The function blocks until the window is closed.
pub fn run(control: Arc<ControlPlane>) {
    let tray_bridge = setup_system_tray_bridge();

    let icon_bytes = include_bytes!("../assets/icon.png");
    let icon_image = image::load_from_memory(icon_bytes)
        .expect("embedded icon is valid PNG")
        .to_rgba8();
    let (w, h) = icon_image.dimensions();
    let icon_data = egui::IconData {
        rgba: icon_image.into_raw(),
        width: w,
        height: h,
    };

    let native_options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([1024.0, 720.0])
            .with_icon(Arc::new(icon_data)),
        ..Default::default()
    };

    let app_name = "HighBeam Server";
    let result = eframe::run_native(
        app_name,
        native_options,
        Box::new(move |_cc| Ok(Box::new(ServerGuiApp::new(control.clone(), tray_bridge)))),
    );

    if let Err(e) = result {
        tracing::warn!(error = %e, "Failed to start GUI shell");
    }
}

struct ServerGuiApp {
    control: Arc<ControlPlane>,
    tray_bridge: TrayBridge,
    tray_hidden: bool,
    allow_window_close: bool,
    selected_tab: Tab,
    last_refresh_at: Instant,
    snapshot: ServerSnapshot,
    players: Vec<PlayerAdminSnapshot>,
    plugins: Vec<String>,
    maps: Vec<MapEntry>,
    mods: Vec<crate::control::ClientModEntry>,
    console_input: String,
    console_output: Vec<String>,
    advanced_console: bool,
    kick_reason: String,
    selected_map_path: String,
    // Mod sync state
    mod_sync_enabled: bool,
    // Community tab state
    community_enabled: bool,
    community_port_buf: String,
    community_region_buf: String,
    community_tags_buf: String,
    community_seed_input: String,
    community_apply_error: String,
    community_apply_success_until: Option<Instant>,
}

#[derive(Copy, Clone, Eq, PartialEq)]
enum Tab {
    Dashboard,
    Players,
    Maps,
    Mods,
    Plugins,
    Console,
    Community,
    Settings,
}

impl ServerGuiApp {
    fn new(control: Arc<ControlPlane>, tray_bridge: TrayBridge) -> Self {
        let snapshot = control.snapshot();
        // Pre-populate community fields from current state
        let (cn_enabled, cn_port, cn_region, cn_tags) = {
            control
                .get_community_node()
                .map(|cn| {
                    let s = cn.status();
                    (
                        s.enabled,
                        s.listen_port.to_string(),
                        s.region,
                        s.tags.join(", "),
                    )
                })
                .unwrap_or_else(|| (false, "18862".to_string(), String::new(), String::new()))
        };

        let mod_sync_enabled = control
            .get_mod_sync_state()
            .map(|s| s.is_enabled())
            .unwrap_or(false);

        Self {
            control,
            tray_bridge,
            tray_hidden: false,
            allow_window_close: false,
            selected_tab: Tab::Dashboard,
            last_refresh_at: Instant::now(),
            players: Vec::new(),
            plugins: Vec::new(),
            maps: Vec::new(),
            mods: Vec::new(),
            snapshot,
            console_input: String::new(),
            console_output: Vec::new(),
            advanced_console: false,
            kick_reason: "Kicked by admin".to_string(),
            selected_map_path: String::new(),
            mod_sync_enabled,
            community_enabled: cn_enabled,
            community_port_buf: cn_port,
            community_region_buf: cn_region,
            community_tags_buf: cn_tags,
            community_seed_input: String::new(),
            community_apply_error: String::new(),
            community_apply_success_until: None,
        }
    }

    fn refresh_snapshot_if_needed(&mut self) {
        if self.last_refresh_at.elapsed() >= Duration::from_secs(1) {
            self.snapshot = self.control.snapshot();
            self.players = self.control.get_player_admin_snapshot();
            self.plugins = self.control.plugin_names();
            self.maps = self.control.list_available_maps().unwrap_or_default();
            self.mods = self.control.list_client_mods().unwrap_or_default();
            if self.selected_map_path.is_empty() {
                self.selected_map_path = self.control.get_active_map();
            }
            self.last_refresh_at = Instant::now();
        }
    }

    fn map_display_name(&self, map_path: &str) -> String {
        self.maps
            .iter()
            .find(|entry| entry.map_path == map_path)
            .map(|entry| entry.display_name.clone())
            .unwrap_or_else(|| map_path.to_string())
    }

    fn selected_map_entry(&self) -> Option<&MapEntry> {
        self.maps
            .iter()
            .find(|entry| entry.map_path == self.selected_map_path)
    }

    fn handle_tray_commands(&mut self, _ctx: &egui::Context) {
        #[cfg(any(target_os = "windows", target_os = "linux"))]
        {
            loop {
                let Ok(cmd) = self.tray_bridge.rx.try_recv() else {
                    break;
                };

                match cmd {
                    TrayCommand::Show => {
                        if self.tray_hidden {
                            _ctx.send_viewport_cmd(egui::ViewportCommand::Visible(true));
                            _ctx.send_viewport_cmd(egui::ViewportCommand::Minimized(false));
                            _ctx.send_viewport_cmd(egui::ViewportCommand::Focus);
                            self.tray_hidden = false;
                        }
                    }
                    TrayCommand::Toggle => {
                        if self.tray_hidden {
                            _ctx.send_viewport_cmd(egui::ViewportCommand::Visible(true));
                            _ctx.send_viewport_cmd(egui::ViewportCommand::Minimized(false));
                            _ctx.send_viewport_cmd(egui::ViewportCommand::Focus);
                            self.tray_hidden = false;
                        } else {
                            _ctx.send_viewport_cmd(egui::ViewportCommand::Visible(false));
                            self.tray_hidden = true;
                        }
                    }
                    TrayCommand::Quit => {
                        self.allow_window_close = true;
                        _ctx.send_viewport_cmd(egui::ViewportCommand::Close);
                    }
                }
            }
        }

        #[cfg(not(any(target_os = "windows", target_os = "linux")))]
        {
            let _ = _ctx;
        }
    }

    fn hide_to_tray(&mut self, ctx: &egui::Context) {
        if self.tray_bridge.available {
            ctx.send_viewport_cmd(egui::ViewportCommand::Visible(false));
            self.tray_hidden = true;
        }
    }

    fn request_exit(&mut self, ctx: &egui::Context) {
        self.allow_window_close = true;
        ctx.send_viewport_cmd(egui::ViewportCommand::Close);
    }

    fn render_tab_selector(&mut self, ctx: &egui::Context, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            ui.selectable_value(&mut self.selected_tab, Tab::Dashboard, "Dashboard");
            ui.selectable_value(&mut self.selected_tab, Tab::Players, "Players");
            ui.selectable_value(&mut self.selected_tab, Tab::Maps, "Maps");
            ui.selectable_value(&mut self.selected_tab, Tab::Mods, "Mods");
            ui.selectable_value(&mut self.selected_tab, Tab::Plugins, "Plugins");
            ui.selectable_value(&mut self.selected_tab, Tab::Console, "Console");
            ui.selectable_value(&mut self.selected_tab, Tab::Community, "Community");
            ui.selectable_value(&mut self.selected_tab, Tab::Settings, "Settings");

            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if ui.button("Exit Server").clicked() {
                    self.request_exit(ctx);
                }

                let hide_button = ui.add_enabled(
                    self.tray_bridge.available,
                    egui::Button::new("Hide to Tray"),
                );
                if hide_button.clicked() {
                    self.hide_to_tray(ctx);
                }
            });
        });
    }

    fn render_dashboard(&self, ui: &mut egui::Ui) {
        ui.heading("Server Dashboard");
        ui.separator();

        ui.label(format!("Server: {}", self.snapshot.server_name));
        ui.label(format!("Map: {}", self.snapshot.map_display_name));
        ui.label(format!("Port: {}", self.snapshot.port));
        ui.label(format!(
            "Players: {}/{}",
            self.snapshot.player_count, self.snapshot.max_players
        ));
        ui.label(format!("Vehicles: {}", self.snapshot.vehicle_count));
        ui.label(format!("Plugins: {}", self.snapshot.plugin_count));
        ui.label(format!("Uptime: {}s", self.snapshot.uptime_secs));
    }

    fn push_console_line(&mut self, line: String) {
        self.console_output.push(line);
    }

    fn render_players(&mut self, ui: &mut egui::Ui) {
        ui.heading("Players");
        ui.separator();

        ui.horizontal(|ui| {
            ui.label("Kick reason:");
            ui.text_edit_singleline(&mut self.kick_reason);
        });

        let players = self.players.clone();
        egui::ScrollArea::vertical().show(ui, |ui| {
            for player in &players {
                ui.horizontal(|ui| {
                    ui.label(format!(
                        "#{} {} ({}) connected {}s",
                        player.player_id, player.name, player.addr, player.connected_secs
                    ));
                    if ui.button("Kick").clicked() {
                        match self.control.execute_console_line(&format!(
                            "kick {} {}",
                            player.player_id, self.kick_reason
                        )) {
                            Ok(msg) => self.push_console_line(msg),
                            Err(e) => self.push_console_line(format!("Kick failed: {}", e)),
                        }
                    }
                });
            }
            if self.players.is_empty() {
                ui.label("No connected players.");
            }
        });
    }

    fn render_mods(&mut self, ui: &mut egui::Ui) {
        ui.heading("Client Mods");
        ui.separator();

        // ── Mod sync control ────────────────────────────────────────────────
        let mod_sync_state = self.control.get_mod_sync_state();
        if let Some(ref mss) = mod_sync_state {
            let prev_enabled = self.mod_sync_enabled;
            ui.checkbox(&mut self.mod_sync_enabled, "Enable mod sync (port 18861)")
                .on_hover_text("When enabled, the launcher can download mods before players join");

            if self.mod_sync_enabled != prev_enabled {
                mss.set_enabled(self.mod_sync_enabled);
            }

            let mod_count = mss.mod_count();
            if self.mod_sync_enabled {
                ui.label(format!("🔄 Serving {} mods on port 18861", mod_count));
            } else {
                ui.label("⊘ Mod sync disabled");
            }

            ui.horizontal(|ui| {
                if ui.button("Refresh Manifest").clicked() {
                    match crate::mods::build_manifest(
                        &self.control.get_server_config().general.resource_folder,
                    ) {
                        Ok(new_manifest) => {
                            mss.refresh_manifest(new_manifest);
                            self.push_console_line("Mod manifest refreshed.".to_string());
                        }
                        Err(e) => {
                            self.push_console_line(format!("Refresh manifest failed: {}", e));
                        }
                    }
                }
            });
        }

        ui.separator();
        ui.label("Client mods are discovered automatically from Resources/Client.");
        if ui.button("Refresh mods list").clicked() {
            self.mods = self.control.list_client_mods().unwrap_or_default();
        }

        egui::ScrollArea::vertical().show(ui, |ui| {
            for item in self.mods.clone() {
                ui.horizontal(|ui| {
                    ui.label(format!("{} ({} bytes)", item.name, item.size_bytes));
                    if ui.button("Remove").clicked() {
                        match self.control.remove_client_mod(&item.name) {
                            Ok(()) => {
                                self.push_console_line(format!("Removed mod: {}", item.name));
                                self.mods = self.control.list_client_mods().unwrap_or_default();
                            }
                            Err(e) => self.push_console_line(format!("Remove mod failed: {}", e)),
                        }
                    }
                });
            }
            if self.mods.is_empty() {
                ui.label("No mods in Resources/Client.");
            }
        });
    }

    fn render_maps(&mut self, ui: &mut egui::Ui) {
        ui.heading("Map Management");
        ui.separator();

        ui.label(format!(
            "Current active map: {}",
            self.snapshot.map_display_name
        ));
        if ui.button("Refresh available maps").clicked() {
            self.maps = self.control.list_available_maps().unwrap_or_default();
        }

        egui::ScrollArea::vertical()
            .max_height(240.0)
            .show(ui, |ui| {
                for map in &self.maps {
                    let selected = self.selected_map_path == map.map_path;
                    let label = format!("{} [{}]", map.display_name, map.source);
                    if ui.selectable_label(selected, label).clicked() {
                        self.selected_map_path = map.map_path.clone();
                    }
                }

                if self.maps.is_empty() {
                    ui.label("No maps discovered from BeamNG content or Resources/Maps.");
                }
            });

        ui.horizontal(|ui| {
            let selected_label = self
                .selected_map_entry()
                .map(|entry| format!("{} [{}]", entry.display_name, entry.source))
                .unwrap_or_else(|| self.map_display_name(&self.selected_map_path));
            ui.label(format!("Selected map: {}", selected_label));
            if ui.button("Set Active Map").clicked() {
                match self
                    .control
                    .execute_console_line(&format!("map {}", self.selected_map_path.trim()))
                {
                    Ok(msg) => {
                        self.push_console_line(msg);
                        self.selected_map_path = self.control.get_active_map();
                    }
                    Err(e) => self.push_console_line(format!("Map update failed: {}", e)),
                }
            }
        });
    }

    fn render_plugins(&mut self, ui: &mut egui::Ui) {
        ui.heading("Plugins");
        ui.separator();

        if ui.button("Reload Plugins").clicked() {
            match self.control.execute_console_line("plugins reload") {
                Ok(msg) => {
                    self.push_console_line(msg);
                    self.plugins = self.control.plugin_names();
                }
                Err(e) => self.push_console_line(format!("Reload failed: {}", e)),
            }
        }

        egui::ScrollArea::vertical().show(ui, |ui| {
            for name in &self.plugins {
                ui.label(name);
            }
            if self.plugins.is_empty() {
                ui.label("No plugins loaded.");
            }
        });
    }

    fn render_console(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            ui.heading("Console");
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                ui.checkbox(&mut self.advanced_console, "Advanced");
            });
        });
        ui.separator();

        ui.horizontal(|ui| {
            let enter = ui
                .text_edit_singleline(&mut self.console_input)
                .lost_focus()
                && ui.input(|i| i.key_pressed(egui::Key::Enter));
            let run = ui.button("Run").clicked();
            if run || enter {
                let cmd = self.console_input.trim().to_string();
                if !cmd.is_empty() {
                    self.push_console_line(format!("> {}", cmd));
                    match self.control.execute_console_line(&cmd) {
                        Ok(msg) if !msg.is_empty() => self.push_console_line(msg),
                        Ok(_) => {}
                        Err(e) => self.push_console_line(format!("Error: {}", e)),
                    }
                    self.console_input.clear();
                }
            }
            if ui.button("Clear").clicked() {
                self.console_output.clear();
            }
        });

        let max_lines = if self.advanced_console { 5000 } else { 100 };
        while self.console_output.len() > max_lines {
            self.console_output.remove(0);
        }

        let scroll = if self.advanced_console {
            egui::ScrollArea::vertical()
        } else {
            egui::ScrollArea::vertical().max_height(420.0)
        };
        scroll.stick_to_bottom(true).show(ui, |ui| {
            for line in &self.console_output {
                ui.label(line);
            }
        });
    }

    fn render_settings(&mut self, ui: &mut egui::Ui) {
        ui.heading("Settings");
        ui.separator();

        ui.label("Map selection now lives in the Maps tab.");
        ui.label("Settings in this tab are reserved for non-map server controls.");
    }

    fn render_community(&mut self, ui: &mut egui::Ui) {
        ui.heading("Community Node Discovery");
        ui.separator();

        let Some(cn) = self.control.get_community_node() else {
            ui.label("Community node not initialised.");
            return;
        };

        let status = cn.status();
        let server_cfg = self.control.get_server_config();

        // ── Introduction ─────────────────────────────────────────────────────
        ui.label("Let players find your server by name without sharing its IP in the browser. To use this safely, set PublicAddr in ServerConfig.toml, open a separate TCP port for the node, then add at least one public seed node below.");
        ui.separator();

        // ── Status row ──────────────────────────────────────────────────────
        ui.horizontal(|ui| {
            let (dot, label) = if status.running {
                ("🟢", "Running")
            } else if status.enabled {
                ("🟡", "Starting")
            } else {
                ("⚫", "Stopped")
            };
            ui.label(format!(
                "{} {} | {} peers | {} servers",
                dot, label, status.peer_count, status.server_count,
            ));
            if status.last_gossip_at > 0 {
                let ago =
                    crate::community_node::now_secs_pub().saturating_sub(status.last_gossip_at);
                ui.label(format!("| last gossip {}s ago", ago));
            }
        });
        if !status.server_id.is_empty() {
            ui.label(format!("Server ID: {}", status.server_id));
        } else if self.community_enabled {
            ui.colored_label(
                egui::Color32::YELLOW,
                "Server ID will be generated after you enable the node and click Apply.",
            );
        }

        if self.community_enabled {
            match server_cfg.general.public_addr.as_deref() {
                Some(public_addr) => {
                    if let Err(e) = crate::validation::validate_public_address(public_addr) {
                        ui.colored_label(
                            egui::Color32::YELLOW,
                            format!(
                                "PublicAddr needs attention: {}. Update ServerConfig.toml and restart before enabling public discovery.",
                                e
                            ),
                        );
                    } else {
                        ui.label(format!("Advertised address: {}", public_addr));
                    }
                }
                None => {
                    ui.colored_label(
                        egui::Color32::YELLOW,
                        "PublicAddr is not set. Add your public IP or hostname to ServerConfig.toml and restart before players use the community browser.",
                    );
                }
            }
        }

        ui.separator();

        // ── Settings form ────────────────────────────────────────────────────
        egui::Grid::new("cn_grid")
            .num_columns(2)
            .spacing([12.0, 6.0])
            .show(ui, |ui| {
                ui.label("Enable");
                ui.checkbox(&mut self.community_enabled, "Participate in discovery mesh");
                ui.end_row();

                ui.label("HTTP Port");
                ui.text_edit_singleline(&mut self.community_port_buf);
                ui.end_row();

                ui.label("Region")
                    .on_hover_text("Optional regional label shown to players. Leave empty to show the server worldwide.");
                egui::ComboBox::from_id_salt("cn_region")
                    .selected_text(if self.community_region_buf.is_empty() {
                        "(any)"
                    } else {
                        &self.community_region_buf
                    })
                    .show_ui(ui, |ui| {
                        for code in &["", "NA", "EU", "AP", "SA", "OC", "AF"] {
                            ui.selectable_value(
                                &mut self.community_region_buf,
                                code.to_string(),
                                if code.is_empty() { "(any)" } else { code },
                            );
                        }
                    });
                ui.end_row();

                ui.label("Tags");
                ui.add(
                    egui::TextEdit::singleline(&mut self.community_tags_buf)
                        .hint_text("drift, racing  (comma-separated, max 5)"),
                );
                ui.end_row();
            });

        ui.add_space(4.0);

        ui.colored_label(
            egui::Color32::GRAY,
            "Open this TCP port only if you want community-browser discovery. It must be forwarded separately from gameplay port 18860.",
        );
        ui.add_space(8.0);

        if let Some(until) = self.community_apply_success_until {
            if Instant::now() < until {
                ui.colored_label(egui::Color32::GREEN, "Settings applied.");
            } else {
                self.community_apply_success_until = None;
            }
        }
        if !self.community_apply_error.is_empty() {
            ui.colored_label(egui::Color32::RED, &self.community_apply_error);
        }
        if ui.button("Apply").clicked() {
            let port: u16 = self.community_port_buf.trim().parse().unwrap_or(18862);
            let tags: Vec<String> = self
                .community_tags_buf
                .split(',')
                .map(|t| t.trim().to_string())
                .filter(|t| !t.is_empty())
                .collect();
            let seeds = status.seed_nodes.clone();
            match crate::validation::validate_community_node_settings(
                &tags,
                &self.community_region_buf,
                &seeds,
                port,
            ) {
                Ok(()) => {
                    cn.apply_settings(
                        self.community_enabled,
                        port,
                        self.community_region_buf.clone(),
                        tags,
                        seeds,
                    );
                    self.community_apply_error.clear();
                    self.community_apply_success_until =
                        Some(Instant::now() + Duration::from_secs(2));
                    self.push_console_line("Community node settings applied.".to_string());
                }
                Err(e) => {
                    self.community_apply_success_until = None;
                    self.community_apply_error = e.to_string();
                }
            }
        }

        // ── Seed node management ─────────────────────────────────────────────
        ui.separator();
        ui.label("Seed Nodes");
        ui.colored_label(
            egui::Color32::LIGHT_GRAY,
            "Add one or more public community nodes here to bootstrap discovery. Seed nodes are shared by the HighBeam community and are safe to remove or replace later."
        );
        egui::ScrollArea::vertical()
            .max_height(120.0)
            .id_salt("cn_seeds_scroll")
            .show(ui, |ui| {
                let mut remove_addr: Option<String> = None;
                for seed in &status.seed_nodes {
                    ui.horizontal(|ui| {
                        ui.label(seed);
                        if ui.small_button("Remove").clicked() {
                            remove_addr = Some(seed.clone());
                        }
                    });
                }
                if let Some(addr) = remove_addr {
                    cn.remove_seed_node(&addr);
                }
            });
        ui.horizontal(|ui| {
            ui.label("Add seed:");
            ui.text_edit_singleline(&mut self.community_seed_input);
            if ui.button("Add").clicked() {
                let addr = self.community_seed_input.trim().to_string();
                let dummy: Vec<String> = vec![];
                match crate::validation::validate_community_node_settings(
                    &dummy,
                    "",
                    std::slice::from_ref(&addr),
                    18862,
                ) {
                    Ok(()) => {
                        cn.add_seed_node(addr);
                        self.community_seed_input.clear();
                        self.community_apply_error.clear();
                    }
                    Err(e) => {
                        self.community_apply_error = e.to_string();
                    }
                }
            }
        });
        ui.add_space(4.0);
        ui.label("Seed node format: host:port  (e.g. relay.example.com:18862)");
    }
}

impl eframe::App for ServerGuiApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        // Store the egui context so tray event handlers can wake the event loop
        // even when the window is hidden.
        #[cfg(any(target_os = "windows", target_os = "linux"))]
        {
            if let Ok(mut guard) = self.tray_bridge.ctx_holder.lock() {
                *guard = Some(ctx.clone());
            }
        }

        self.handle_tray_commands(ctx);

        #[cfg(any(target_os = "windows", target_os = "linux"))]
        {
            if ctx.input(|i| i.viewport().close_requested())
                && !self.allow_window_close
                && self.tray_bridge.available
            {
                // Keep server running and hide the GUI to tray.
                ctx.send_viewport_cmd(egui::ViewportCommand::CancelClose);
                self.hide_to_tray(ctx);
            }
        }

        self.refresh_snapshot_if_needed();

        egui::TopBottomPanel::top("tabs").show(ctx, |ui| {
            self.render_tab_selector(ctx, ui);
        });

        egui::CentralPanel::default().show(ctx, |ui| match self.selected_tab {
            Tab::Dashboard => self.render_dashboard(ui),
            Tab::Players => self.render_players(ui),
            Tab::Maps => self.render_maps(ui),
            Tab::Mods => self.render_mods(ui),
            Tab::Plugins => self.render_plugins(ui),
            Tab::Console => self.render_console(ui),
            Tab::Community => self.render_community(ui),
            Tab::Settings => self.render_settings(ui),
        });

        ctx.request_repaint_after(Duration::from_millis(250));
    }
}
