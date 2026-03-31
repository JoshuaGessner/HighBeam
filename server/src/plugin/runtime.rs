use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, RwLock};

use anyhow::{anyhow, bail, Context, Result};
use mlua::{Function, Lua, LuaOptions, StdLib, Value};

use crate::plugin::api;
use crate::plugin::events::{parse_cancel_result, PluginEvent};
use crate::session::manager::SessionManager;
use crate::state::world::WorldState;

struct PluginInstance {
    name: String,
    lua: Mutex<Lua>,
}

pub struct PluginRuntime {
    resource_folder: PathBuf,
    sessions: Arc<SessionManager>,
    world: Arc<WorldState>,
    plugins: RwLock<Vec<PluginInstance>>,
    last_scan_marker: Mutex<u64>,
}

impl PluginRuntime {
    pub fn load_from_resource(
        resource_folder: &str,
        sessions: Arc<SessionManager>,
        world: Arc<WorldState>,
    ) -> Result<Self> {
        let runtime = Self {
            resource_folder: PathBuf::from(resource_folder),
            sessions,
            world,
            plugins: RwLock::new(Vec::new()),
            last_scan_marker: Mutex::new(0),
        };

        runtime.reload()?;
        let marker = runtime.compute_scan_marker()?;
        if let Ok(mut guard) = runtime.last_scan_marker.lock() {
            *guard = marker;
        }

        Ok(runtime)
    }

    pub fn plugin_count(&self) -> usize {
        self.plugins.read().map(|v| v.len()).unwrap_or(0)
    }

    pub fn plugin_names(&self) -> Vec<String> {
        self.plugins
            .read()
            .map(|plugins| plugins.iter().map(|p| p.name.clone()).collect())
            .unwrap_or_default()
    }

    pub fn reload(&self) -> Result<()> {
        let server_plugins_dir = self.resource_folder.join("Server");
        if !server_plugins_dir.exists() {
            tracing::warn!(
                path = %server_plugins_dir.display(),
                "Resources/Server directory not found; plugin runtime disabled"
            );
            if let Ok(mut plugins) = self.plugins.write() {
                plugins.clear();
            }
            return Ok(());
        }

        let loaded = load_plugins_from_folder(
            &server_plugins_dir,
            self.sessions.clone(),
            self.world.clone(),
        )?;
        let loaded_count = loaded.len();

        if let Ok(mut plugins) = self.plugins.write() {
            *plugins = loaded;
        }

        tracing::info!(count = loaded_count, "Plugin runtime reloaded");
        Ok(())
    }

    pub fn refresh_if_changed(&self) -> Result<bool> {
        let marker = self.compute_scan_marker()?;
        let mut last = self
            .last_scan_marker
            .lock()
            .map_err(|_| anyhow!("Plugin scan marker lock poisoned"))?;

        if marker == *last {
            return Ok(false);
        }

        self.reload()?;
        *last = marker;
        Ok(true)
    }

    pub fn eval_in_plugin(&self, plugin_name: &str, code: &str) -> Result<String> {
        let plugins = self
            .plugins
            .read()
            .map_err(|_| anyhow!("Plugin store lock poisoned"))?;

        let Some(plugin) = plugins.iter().find(|p| p.name == plugin_name) else {
            bail!("Plugin not found: {plugin_name}");
        };

        let lua = plugin
            .lua
            .lock()
            .map_err(|_| anyhow!("Plugin Lua state lock poisoned"))?;

        let result: Value = lua
            .load(code)
            .eval()
            .with_context(|| format!("Failed evaluating code in plugin {plugin_name}"))?;
        Ok(value_to_string(result))
    }

    pub fn dispatch_event(&self, event: &PluginEvent) -> Option<String> {
        let plugins = match self.plugins.read() {
            Ok(v) => v,
            Err(_) => {
                tracing::error!("Plugin store lock poisoned");
                return None;
            }
        };

        for plugin in plugins.iter() {
            let lock = plugin.lua.lock();
            let Ok(lua) = lock else {
                tracing::error!(plugin = %plugin.name, "Plugin Lua state lock poisoned");
                continue;
            };

            match dispatch_event_to_plugin(&lua, &plugin.name, event) {
                Ok(Some(reason)) => return Some(reason),
                Ok(None) => {}
                Err(e) => {
                    tracing::error!(plugin = %plugin.name, error = %e, event = event.handler_name(), "Plugin event handler failed");
                }
            }
        }

        None
    }

    fn compute_scan_marker(&self) -> Result<u64> {
        let server_plugins_dir = self.resource_folder.join("Server");
        if !server_plugins_dir.exists() {
            return Ok(0);
        }

        let mut hasher = DefaultHasher::new();
        let mut plugin_dirs = Vec::new();
        for entry in std::fs::read_dir(&server_plugins_dir).with_context(|| {
            format!(
                "Failed to read plugin root: {}",
                server_plugins_dir.display()
            )
        })? {
            let entry = entry?;
            let path = entry.path();
            if path.is_dir() {
                plugin_dirs.push(path);
            }
        }
        plugin_dirs.sort();

        for plugin_dir in plugin_dirs {
            plugin_dir.hash(&mut hasher);
            let main_lua = plugin_dir.join("main.lua");
            main_lua.hash(&mut hasher);

            if let Ok(meta) = std::fs::metadata(&main_lua) {
                if let Ok(modified) = meta.modified() {
                    if let Ok(duration) = modified.duration_since(std::time::UNIX_EPOCH) {
                        duration.as_secs().hash(&mut hasher);
                        duration.subsec_nanos().hash(&mut hasher);
                    }
                }
                meta.len().hash(&mut hasher);
            }
        }

        Ok(hasher.finish())
    }
}

fn load_plugins_from_folder(
    server_plugins_dir: &Path,
    sessions: Arc<SessionManager>,
    world: Arc<WorldState>,
) -> Result<Vec<PluginInstance>> {
    let mut plugin_dirs = Vec::new();
    for entry in std::fs::read_dir(server_plugins_dir).with_context(|| {
        format!(
            "Failed to read plugin root: {}",
            server_plugins_dir.display()
        )
    })? {
        let entry = entry?;
        let path = entry.path();
        if path.is_dir() {
            plugin_dirs.push(path);
        }
    }
    plugin_dirs.sort();

    let mut plugins = Vec::new();

    for plugin_dir in plugin_dirs {
        let Some(name) = plugin_dir
            .file_name()
            .and_then(|v| v.to_str())
            .map(|v| v.to_string())
        else {
            tracing::warn!(path = %plugin_dir.display(), "Skipping plugin with non-UTF8 name");
            continue;
        };

        let main_lua = plugin_dir.join("main.lua");
        if !main_lua.exists() {
            tracing::debug!(plugin = %name, path = %main_lua.display(), "Skipping plugin without main.lua");
            continue;
        }

        match load_plugin_instance(
            &name,
            &plugin_dir,
            &main_lua,
            sessions.clone(),
            world.clone(),
        ) {
            Ok(instance) => {
                tracing::info!(plugin = %name, "Plugin loaded");
                plugins.push(instance);
            }
            Err(e) => {
                tracing::error!(plugin = %name, error = %e, "Failed to load plugin");
            }
        }
    }

    Ok(plugins)
}

fn load_plugin_instance(
    name: &str,
    plugin_dir: &Path,
    main_lua: &Path,
    sessions: Arc<SessionManager>,
    world: Arc<WorldState>,
) -> Result<PluginInstance> {
    // Deliberately exclude OS/IO/debug/package libs for sandboxing.
    let libs = StdLib::TABLE | StdLib::STRING | StdLib::MATH | StdLib::UTF8 | StdLib::COROUTINE;
    let lua = Lua::new_with(libs, LuaOptions::default())?;

    api::register_api(&lua, sessions, plugin_dir.to_path_buf(), world)
        .with_context(|| format!("Failed to register HB API for plugin {name}"))?;

    let script = std::fs::read_to_string(main_lua)
        .with_context(|| format!("Failed to read {}", main_lua.display()))?;

    lua.load(&script)
        .set_name(format!("{name}/main.lua"))
        .exec()
        .with_context(|| format!("Failed to execute {}", main_lua.display()))?;

    Ok(PluginInstance {
        name: name.to_string(),
        lua: Mutex::new(lua),
    })
}

fn dispatch_event_to_plugin(
    lua: &Lua,
    plugin_name: &str,
    event: &PluginEvent,
) -> Result<Option<String>> {
    let globals = lua.globals();
    let handler: Option<Function> = globals.get(event.handler_name())?;
    let Some(handler) = handler else {
        return Ok(None);
    };

    let ctx = lua.create_table()?;
    event.fill_ctx(&ctx)?;

    let result: Value = handler
        .call(ctx)
        .with_context(|| format!("Plugin {plugin_name} failed in {}", event.handler_name()))?;

    Ok(parse_cancel_result(result))
}

fn value_to_string(value: Value) -> String {
    match value {
        Value::Nil => "nil".to_string(),
        Value::Boolean(v) => v.to_string(),
        Value::Integer(v) => v.to_string(),
        Value::Number(v) => v.to_string(),
        Value::String(v) => v
            .to_str()
            .map(|s| s.to_string())
            .unwrap_or_else(|_| "<non-utf8-string>".to_string()),
        Value::Table(_) => "<table>".to_string(),
        Value::Function(_) => "<function>".to_string(),
        Value::Thread(_) => "<thread>".to_string(),
        Value::UserData(_) => "<userdata>".to_string(),
        Value::LightUserData(_) => "<lightuserdata>".to_string(),
        Value::Error(v) => format!("<lua-error: {v}>"),
        Value::Other(_) => "<other>".to_string(),
    }
}
