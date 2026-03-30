local M = {}
local logTag = "HighBeam.Chat"

M.messages = {}
local MAX_MESSAGES = 100

-- Send a chat message to server
M.send = function(text)
  if not text or text == "" then
    log('W', logTag, 'Cannot send empty message')
    return false
  end

  local connection = require("highbeam/connection")
  if connection.state ~= connection.STATE_CONNECTED then
    log('W', logTag, 'Not connected, cannot send chat')
    return false
  end

  -- Send chat_message packet
  connection.send("chat_message", {
    text = text
  })

  log('I', logTag, 'Chat message sent: ' .. text)
  return true
end

-- Receive a chat message from server
M.receive = function(playerId, playerName, message)
  if not playerName or not message then
    log('W', logTag, 'Invalid chat message: name=' .. tostring(playerName))
    return
  end

  table.insert(M.messages, {
    playerId = playerId,
    name = playerName,
    message = message,
    time = os.time(),
  })

  -- Keep only last MAX_MESSAGES
  if #M.messages > MAX_MESSAGES then
    table.remove(M.messages, 1)
  end

  log('I', logTag, 'Chat received from ' .. playerName .. ': ' .. message)
end

return M
