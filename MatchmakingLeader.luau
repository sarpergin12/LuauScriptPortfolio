--!strict

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Require the Advanced Module
local MatchmakingModule = require(ServerScriptService.Matchmaking.DuelQueueHandler)

--// CONFIGURATION
local DEBOUNCE_TIME = 2.0

--// STATE
local debounceTable: {[number]: number} = {}

--// REMOTES
local matchmakingFolder = ReplicatedStorage:WaitForChild("Matchmaking")
local duelsFolder = matchmakingFolder:WaitForChild("Duels")
local toggleQueueFunction = duelsFolder:WaitForChild("ToggleQueueFunction")

--// HELPER FUNCTIONS

local function IsDebounced(userId: number): boolean
	local lastTime = debounceTable[userId]
	local currentTime = os.time()
	
	if lastTime and (currentTime - lastTime < DEBOUNCE_TIME) then
		return true
	end
	
	debounceTable[userId] = currentTime
	return false
end

--// HANDLERS

toggleQueueFunction.OnServerInvoke = function(player: Player, isJoining: boolean, wagerAmount: number?, gameMode: string?)
	-- 1. Input Validation
	if not player or not player.Parent then 
		return false, "Player invalid." 
	end
	
	-- 2. Debounce Check
	if IsDebounced(player.UserId) then
		return false, "Please wait a moment before clicking again."
	end

	-- 3. Logic Routing
	if isJoining then
		-- Type Guarding arguments since they come from Client
		if type(wagerAmount) ~= "number" then return false, "Invalid wager amount." end
		if type(gameMode) ~= "string" then return false, "Invalid game mode." end
		
		-- Call the Module
		-- Note: We assert wagerAmount and gameMode exist because of the check above
		return MatchmakingModule.AddToQueue(player, wagerAmount :: number, gameMode :: string)
	else
		-- Leaving Queue
		return MatchmakingModule.RemoveFromQueue(player, false)
	end
end

--// INITIALIZATION
print("[MM_MANAGER] Initializing Matchmaking Systems...")

-- Initialize the Module (This starts the processing loop and listeners)
-- Make sure your Module has an .Init() function as provided in the previous step
MatchmakingModule.Init()

-- Cleanup debounce table periodically to prevent memory leaks (Optional but good practice)
task.spawn(function()
	while true do
		task.wait(60)
		local currentTime = os.time()
		for userId, timestamp in pairs(debounceTable) do
			if currentTime - timestamp > DEBOUNCE_TIME then
				debounceTable[userId] = nil
			end
		end
	end
end)

print("[MM_MANAGER] Systems Loaded.")
