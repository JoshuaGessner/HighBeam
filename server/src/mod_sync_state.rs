use std::sync::RwLock;

use crate::net::packet::ModDescriptor;

/// Live-togglable mod sync state shared between GUI and the mod-transfer listener.
/// Allows instant enable/disable and manifest refresh without restarting the server
/// or kicking players.
pub struct ModSyncInner {
    /// Whether mod sync is enabled by the operator.
    pub enabled: bool,
    /// The port the listener is bound to (static per startup).
    pub port: u16,
    /// Current mod manifest loaded from Resources/Client/. May be empty.
    pub manifest: Vec<ModDescriptor>,
}

pub struct ModSyncState {
    inner: RwLock<ModSyncInner>,
}

impl ModSyncState {
    /// Create a new mod sync state with the given port and initial manifest.
    pub fn new(port: u16, manifest: Vec<ModDescriptor>, enabled: bool) -> Self {
        Self {
            inner: RwLock::new(ModSyncInner {
                enabled,
                port,
                manifest,
            }),
        }
    }

    /// Toggle mod sync enable/disable. Takes effect immediately for new connections.
    pub fn set_enabled(&self, enabled: bool) {
        if let Ok(mut guard) = self.inner.write() {
            guard.enabled = enabled;
        }
    }

    /// Check if mod sync is currently enabled.
    pub fn is_enabled(&self) -> bool {
        self.inner
            .read()
            .map(|g| g.enabled)
            .unwrap_or(false)
    }

    /// Get the manifest if mod sync is enabled, or None if disabled.
    /// Returns an empty vec (not None) if enabled but no mods are present.
    pub fn manifest_if_enabled(&self) -> Option<Vec<ModDescriptor>> {
        let guard = self.inner.read().ok()?;
        if guard.enabled {
            Some(guard.manifest.clone())
        } else {
            None
        }
    }

    /// Get the current manifest regardless of enabled state (for GUI display).
    pub fn get_manifest(&self) -> Vec<ModDescriptor> {
        self.inner
            .read()
            .map(|g| g.manifest.clone())
            .unwrap_or_default()
    }

    /// Refresh the manifest by replacing it with a new one (loaded from disk).
    /// Does not change the enabled state.
    pub fn refresh_manifest(&self, new_manifest: Vec<ModDescriptor>) {
        if let Ok(mut guard) = self.inner.write() {
            guard.manifest = new_manifest;
        }
    }

    /// Return the active mod_sync port if enabled AND has mods, or None otherwise.
    /// Used by UDP discovery to advertise whether mod sync is actually available.
    pub fn active_port_if_ready(&self) -> Option<u16> {
        let guard = self.inner.read().ok()?;
        if guard.enabled && !guard.manifest.is_empty() {
            Some(guard.port)
        } else {
            None
        }
    }

    /// Check if mod sync is effectively active (enabled and has mods).
    pub fn is_effectively_active(&self) -> bool {
        self.active_port_if_ready().is_some()
    }

    /// Get the bound port regardless of state (for GUI display).
    pub fn port(&self) -> u16 {
        self.inner
            .read()
            .map(|g| g.port)
            .unwrap_or(0)
    }

    /// Get the mod count for display.
    pub fn mod_count(&self) -> usize {
        self.inner
            .read()
            .map(|g| g.manifest.len())
            .unwrap_or(0)
    }
}
