local M = {}
local logTag = "HighBeam.Chat"

M.messages = {}

M.send = function(message)
end

M.receive = function(playerId, playerName, message)
  table.insert(M.messages, {
    playerId = playerId,
    name = playerName,
    message = message,
    time = os.time(),
  })
end

return M
