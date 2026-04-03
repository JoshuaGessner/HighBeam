use std::sync::Arc;

use parking_lot::RwLock;

use crate::net::packet::ModDescriptor;

/// Live-togglable mod sync state shared between GUI and the mod-transfer listener.
/// Allows instant enable/disable and manifest refresh without restarting the server
/// or kicking players.
pub struct ModSyncInner {
    /// Whether mod sync is enabled by the operator.
    pub enabled: bool,
    /// The port the listener is bound to (static per startup).
    pub port: u16,
    /// Current mod manifest loaded from Resources/Client/. Stored as Arc for cheap sharing.
    pub manifest: Arc<Vec<ModDescriptor>>,
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
                manifest: Arc::new(manifest),
            }),
        }
    }

    /// Toggle mod sync enable/disable. Takes effect immediately for new connections.
    pub fn set_enabled(&self, enabled: bool) {
        self.inner.write().enabled = enabled;
    }

    /// Check if mod sync is currently enabled.
    pub fn is_enabled(&self) -> bool {
        self.inner.read().enabled
    }

    /// Get the manifest if mod sync is enabled, or None if disabled.
    /// Returns a cheap Arc clone instead of copying the entire vec.
    pub fn manifest_if_enabled(&self) -> Option<Arc<Vec<ModDescriptor>>> {
        let guard = self.inner.read();
        if guard.enabled {
            Some(Arc::clone(&guard.manifest))
        } else {
            None
        }
    }

    /// Get the current manifest regardless of enabled state (for GUI display).
    pub fn get_manifest(&self) -> Arc<Vec<ModDescriptor>> {
        Arc::clone(&self.inner.read().manifest)
    }

    /// Refresh the manifest by replacing it with a new one (loaded from disk).
    /// Does not change the enabled state.
    pub fn refresh_manifest(&self, new_manifest: Vec<ModDescriptor>) {
        self.inner.write().manifest = Arc::new(new_manifest);
    }

    /// Return the active mod_sync port if enabled AND has mods, or None otherwise.
    /// Used by UDP discovery to advertise whether mod sync is actually available.
    pub fn active_port_if_ready(&self) -> Option<u16> {
        let guard = self.inner.read();
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
        self.inner.read().port
    }

    /// Get the mod count for display.
    pub fn mod_count(&self) -> usize {
        self.inner.read().manifest.len()
    }
}
