use mlua::{Table, Value};

#[derive(Debug, Clone)]
pub enum PluginEvent {
    PlayerAuth {
        username: String,
        addr: String,
    },
    VehicleSpawn {
        player_id: u32,
        data: String,
    },
    ChatMessage {
        player_id: u32,
        text: String,
    },
    ClientEvent {
        player_id: u32,
        name: String,
        payload: String,
    },
}

impl PluginEvent {
    pub fn handler_name(&self) -> &'static str {
        match self {
            Self::PlayerAuth { .. } => "OnPlayerAuth",
            Self::VehicleSpawn { .. } => "OnVehicleSpawn",
            Self::ChatMessage { .. } => "OnChatMessage",
            Self::ClientEvent { .. } => "OnClientEvent",
        }
    }

    pub fn fill_ctx(&self, ctx: &Table) -> mlua::Result<()> {
        match self {
            Self::PlayerAuth { username, addr } => {
                ctx.set("username", username.clone())?;
                ctx.set("addr", addr.clone())?;
            }
            Self::VehicleSpawn { player_id, data } => {
                ctx.set("player_id", *player_id)?;
                ctx.set("data", data.clone())?;
            }
            Self::ChatMessage { player_id, text } => {
                ctx.set("player_id", *player_id)?;
                ctx.set("text", text.clone())?;
            }
            Self::ClientEvent {
                player_id,
                name,
                payload,
            } => {
                ctx.set("player_id", *player_id)?;
                ctx.set("name", name.clone())?;
                ctx.set("payload", payload.clone())?;
            }
        }
        Ok(())
    }
}

pub fn parse_cancel_result(value: Value) -> Option<String> {
    match value {
        Value::Nil => None,
        Value::Boolean(false) => Some("Cancelled by plugin".to_string()),
        Value::Boolean(true) => None,
        Value::String(s) => Some(
            s.to_str()
                .map(|v| v.to_string())
                .unwrap_or_else(|_| "Cancelled by plugin".to_string()),
        ),
        Value::Table(t) => parse_cancel_table(&t),
        _ => None,
    }
}

fn parse_cancel_table(table: &Table) -> Option<String> {
    let cancel = table.get::<Option<bool>>("cancel").ok().flatten();
    if cancel != Some(true) {
        return None;
    }

    let reason = table
        .get::<Option<String>>("reason")
        .ok()
        .flatten()
        .unwrap_or_else(|| "Cancelled by plugin".to_string());
    Some(reason)
}
