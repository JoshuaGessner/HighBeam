use std::sync::Arc;
use std::time::{Duration, Instant};

use eframe::egui;

use crate::control::{ControlPlane, MapEntry, ServerSnapshot};
use crate::session::manager::PlayerAdminSnapshot;

#[cfg(any(target_os = "windows", target_os = "linux"))]
use std::sync::mpsc::{self, Receiver};

#[cfg(any(target_os = "windows", target_os = "linux"))]
use tray_item::{IconSource, TrayItem};

#[derive(Clone, Copy)]
enum TrayCommand {
    Toggle,
    Quit,
}

#[cfg(any(target_os = "windows", target_os = "linux"))]
struct TrayBridge {
    rx: Receiver<TrayCommand>,
    available: bool,
}

#[cfg(not(any(target_os = "windows", target_os = "linux")))]
struct TrayBridge {
    available: bool,
}

#[cfg(any(target_os = "windows", target_os = "linux"))]
fn setup_system_tray_bridge() -> TrayBridge {
    let (tx, rx) = mpsc::channel::<TrayCommand>();

    let mut tray = match TrayItem::new("HighBeam Server", IconSource::Resource("network-workgroup"))
    {
        Ok(item) => item,
        Err(e) => {
            tracing::warn!(error = %e, "System tray unavailable; running without tray integration");
            return TrayBridge {
                rx,
                available: false,
            };
        }
    };

    let tx_toggle = tx.clone();
    if let Err(e) = tray.add_menu_item("Show/Hide", move || {
        let _ = tx_toggle.send(TrayCommand::Toggle);
    }) {
        tracing::warn!(error = %e, "Failed to add Show/Hide tray menu item");
    }

    let tx_quit = tx.clone();
    if let Err(e) = tray.add_menu_item("Quit", move || {
        let _ = tx_quit.send(TrayCommand::Quit);
    }) {
        tracing::warn!(error = %e, "Failed to add Quit tray menu item");
    }

    // Keep tray icon alive for the process lifetime.
    let _leaked: &'static mut TrayItem = Box::leak(Box::new(tray));
    tracing::info!("System tray integration enabled");
    TrayBridge {
        rx,
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

    let native_options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default().with_inner_size([1024.0, 720.0]),
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
    kick_reason: String,
    selected_map_path: String,
}

#[derive(Copy, Clone, Eq, PartialEq)]
enum Tab {
    Dashboard,
    Players,
    Maps,
    Mods,
    Plugins,
    Console,
    Settings,
}

impl ServerGuiApp {
    fn new(control: Arc<ControlPlane>, tray_bridge: TrayBridge) -> Self {
        let snapshot = control.snapshot();
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
            kick_reason: "Kicked by admin".to_string(),
            selected_map_path: String::new(),
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
        if self.console_output.len() > 100 {
            let overflow = self.console_output.len() - 100;
            self.console_output.drain(0..overflow);
        }
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

        ui.label("Client mods are discovered automatically from Resources/Client.");
        if ui.button("Refresh mods").clicked() {
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
        ui.heading("Console");
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
        });

        egui::ScrollArea::vertical()
            .max_height(420.0)
            .show(ui, |ui| {
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
}

impl eframe::App for ServerGuiApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
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
            Tab::Settings => self.render_settings(ui),
        });

        ctx.request_repaint_after(Duration::from_millis(250));
    }
}
