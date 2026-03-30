use tokio::time::Instant;

/// Represents a single vehicle tracked by the server.
#[derive(Debug, Clone)]
pub struct Vehicle {
    pub id: u16,
    pub owner_id: u32,
    /// JSON blob of vehicle configuration (model, parts, color, etc.).
    pub config: String,
    pub position: [f32; 3],
    pub rotation: [f32; 4],
    pub velocity: [f32; 3],
    pub last_update: Instant,
}
