--!strict
-- MatchmakingManager.lua
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local MatchmakingModule = require(ServerScriptService.Matchmaking.DuelQueueHandler)

local debounceTable: {[number]: number} = {}
local DEBOUNCE_TIME = 2.5

local toggleQueueFunction = ReplicatedStorage:WaitForChild("Matchmaking"):WaitForChild("Duels"):WaitForChild("ToggleQueueFunction")

toggleQueueFunction.OnServerInvoke = function(player: Player, isQueued: boolean, wagerAmount: number, gameMode: string)
	if not player then return false, "Invalid player" end
	
	local userId = player.UserId
	local now = os.time()
	
	-- Debounce
	if debounceTable[userId] and (now - debounceTable[userId] < DEBOUNCE_TIME) then
		return false, "Slow down!"
	end
	debounceTable[userId] = now
	
	if isQueued then
		return MatchmakingModule.AddToQueue(player, wagerAmount, gameMode)
	else
		return MatchmakingModule.RemoveFromQueue(player, false)
	end
end

-- Initialize the module (This starts the processing and listeners)
MatchmakingModule.Init()

Players.PlayerRemoving:Connect(function(player)
	MatchmakingModule.RemoveFromQueue(player, true)
	debounceTable[player.UserId] = nil
end)

print("[MM_MANAGER] Systems Loaded.")
