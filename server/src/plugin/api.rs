use std::path::{Path, PathBuf};
use std::sync::Arc;

use mlua::{Lua, Table};
use rand::Rng;

use crate::net::packet::TcpPacket;
use crate::session::manager::SessionManager;
use crate::state::world::WorldState;

pub fn register_api(
    lua: &Lua,
    sessions: Arc<SessionManager>,
    plugin_dir: PathBuf,
    world: Arc<WorldState>,
) -> mlua::Result<()> {
    let hb = lua.create_table()?;

    register_player_api(lua, &hb, sessions.clone())?;
    register_chat_api(lua, &hb, sessions.clone())?;
    register_vehicle_api(lua, &hb, sessions.clone(), world)?;
    register_event_api(lua, &hb, sessions)?;
    register_util_api(lua, &hb)?;
    register_fs_api(lua, &hb, plugin_dir)?;

    lua.globals().set("HB", hb)?;
    Ok(())
}

fn register_player_api(lua: &Lua, hb: &Table, sessions: Arc<SessionManager>) -> mlua::Result<()> {
    let player = lua.create_table()?;

    let sessions_for_get = sessions.clone();
    player.set(
        "GetPlayers",
        lua.create_function(move |lua, ()| {
            let players = sessions_for_get.get_player_snapshot();
            let out = lua.create_table()?;
            for (i, p) in players.iter().enumerate() {
                let row = lua.create_table()?;
                row.set("id", p.player_id)?;
                row.set("name", p.name.clone())?;
                out.set(i + 1, row)?;
            }
            Ok(out)
        })?,
    )?;

    let sessions_for_drop = sessions.clone();
    player.set(
        "DropPlayer",
        lua.create_function(move |_, (player_id, reason): (u32, Option<String>)| {
            if let Some(target) = sessions_for_drop.get_player(player_id) {
                let kick = TcpPacket::Kick {
                    reason: reason.unwrap_or_else(|| "Dropped by server plugin".to_string()),
                };
                let _ = target.tcp_tx.try_send(kick);
                Ok(true)
            } else {
                Ok(false)
            }
        })?,
    )?;

    hb.set("Player", player)?;
    Ok(())
}

fn register_chat_api(lua: &Lua, hb: &Table, sessions: Arc<SessionManager>) -> mlua::Result<()> {
    let chat = lua.create_table()?;

    chat.set(
        "SendChatMessage",
        lua.create_function(move |_, text: String| {
            let packet = TcpPacket::ChatBroadcast {
                player_id: 0,
                player_name: "Server".to_string(),
                text,
            };
            sessions.broadcast(packet, None);
            Ok(())
        })?,
    )?;

    hb.set("Chat", chat)?;
    Ok(())
}

fn register_vehicle_api(
    lua: &Lua,
    hb: &Table,
    sessions: Arc<SessionManager>,
    world: Arc<WorldState>,
) -> mlua::Result<()> {
    let vehicle = lua.create_table()?;

    let world_for_get = world.clone();
    vehicle.set(
        "GetVehicles",
        lua.create_function(move |lua, ()| {
            let snapshot = world_for_get.get_vehicle_snapshot();
            let out = lua.create_table()?;
            for (i, v) in snapshot.iter().enumerate() {
                let row = lua.create_table()?;
                row.set("player_id", v.player_id)?;
                row.set("vehicle_id", v.vehicle_id)?;
                row.set("data", v.data.clone())?;
                out.set(i + 1, row)?;
            }
            Ok(out)
        })?,
    )?;

    let world_for_delete = world.clone();
    let sessions_for_delete = sessions.clone();
    vehicle.set(
        "DeleteVehicle",
        lua.create_function(move |_, (player_id, vehicle_id): (u32, u16)| {
            if !world_for_delete.is_owner(player_id, vehicle_id) {
                return Ok(false);
            }

            world_for_delete.remove_vehicle(player_id, vehicle_id);
            sessions_for_delete.broadcast(
                TcpPacket::VehicleDelete {
                    player_id: Some(player_id),
                    vehicle_id,
                },
                None,
            );
            Ok(true)
        })?,
    )?;

    hb.set("Vehicle", vehicle)?;
    Ok(())
}

fn register_event_api(lua: &Lua, hb: &Table, sessions: Arc<SessionManager>) -> mlua::Result<()> {
    let event = lua.create_table()?;

    let sessions_for_server_message = sessions.clone();
    event.set(
        "SendServerMessage",
        lua.create_function(move |_, text: String| {
            sessions_for_server_message.broadcast(TcpPacket::ServerMessage { text }, None);
            Ok(())
        })?,
    )?;

    let sessions_for_targeted = sessions.clone();
    event.set(
        "TriggerClientEvent",
        lua.create_function(
            move |_, (player_id, name, payload): (u32, String, Option<String>)| {
                let sent = sessions_for_targeted.send_to_player(
                    player_id,
                    TcpPacket::TriggerClientEvent {
                        name,
                        payload: payload.unwrap_or_default(),
                    },
                );
                Ok(sent)
            },
        )?,
    )?;

    let sessions_for_broadcast = sessions.clone();
    event.set(
        "BroadcastClientEvent",
        lua.create_function(move |_, (name, payload): (String, Option<String>)| {
            sessions_for_broadcast.broadcast(
                TcpPacket::TriggerClientEvent {
                    name,
                    payload: payload.unwrap_or_default(),
                },
                None,
            );
            Ok(())
        })?,
    )?;

    hb.set("Event", event)?;
    Ok(())
}

fn register_util_api(lua: &Lua, hb: &Table) -> mlua::Result<()> {
    let util = lua.create_table()?;

    util.set(
        "Log",
        lua.create_function(|_, (level, message): (String, String)| {
            match level.to_ascii_lowercase().as_str() {
                "trace" => tracing::trace!(target: "highbeam::plugin", "{}", message),
                "debug" => tracing::debug!(target: "highbeam::plugin", "{}", message),
                "warn" => tracing::warn!(target: "highbeam::plugin", "{}", message),
                "error" => tracing::error!(target: "highbeam::plugin", "{}", message),
                _ => tracing::info!(target: "highbeam::plugin", "{}", message),
            }
            Ok(())
        })?,
    )?;

    util.set(
        "RandomInt",
        lua.create_function(|_, (min, max): (i64, i64)| {
            if min > max {
                return Ok(min);
            }
            let mut rng = rand::thread_rng();
            Ok(rng.gen_range(min..=max))
        })?,
    )?;

    hb.set("Util", util)?;
    Ok(())
}

fn register_fs_api(lua: &Lua, hb: &Table, plugin_dir: PathBuf) -> mlua::Result<()> {
    let fs = lua.create_table()?;

    let root_for_read = plugin_dir.clone();
    fs.set(
        "ReadFile",
        lua.create_function(move |_, relative_path: String| {
            let resolved = safe_resolve(&root_for_read, &relative_path)
                .ok_or_else(|| mlua::Error::runtime("Path traversal blocked"))?;
            let contents = std::fs::read_to_string(&resolved).map_err(mlua::Error::external)?;
            Ok(contents)
        })?,
    )?;

    let root_for_write = plugin_dir.clone();
    fs.set(
        "WriteFile",
        lua.create_function(move |_, (relative_path, contents): (String, String)| {
            let resolved = safe_resolve(&root_for_write, &relative_path)
                .ok_or_else(|| mlua::Error::runtime("Path traversal blocked"))?;
            std::fs::write(&resolved, contents).map_err(mlua::Error::external)?;
            Ok(())
        })?,
    )?;

    let root_for_exists = plugin_dir;
    fs.set(
        "Exists",
        lua.create_function(move |_, relative_path: String| {
            let resolved = safe_resolve(&root_for_exists, &relative_path)
                .ok_or_else(|| mlua::Error::runtime("Path traversal blocked"))?;
            Ok(resolved.exists())
        })?,
    )?;

    hb.set("FS", fs)?;
    Ok(())
}

fn safe_resolve(root: &Path, relative_path: &str) -> Option<PathBuf> {
    let rel = Path::new(relative_path);
    if rel.is_absolute() {
        return None;
    }

    let root_canon = root.canonicalize().ok()?;
    let candidate = root.join(rel);

    // Ensure parent exists before canonicalization checks.
    if let Some(parent) = candidate.parent() {
        std::fs::create_dir_all(parent).ok()?;
    }

    let candidate_canon = if candidate.exists() {
        candidate.canonicalize().ok()?
    } else {
        // For non-existing write targets, canonicalize the parent directory and append file name.
        let parent = candidate.parent()?.canonicalize().ok()?;
        parent.join(candidate.file_name()?)
    };

    if candidate_canon.starts_with(&root_canon) {
        Some(candidate_canon)
    } else {
        None
    }
}
