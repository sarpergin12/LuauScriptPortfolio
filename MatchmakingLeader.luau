--!strict

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MemoryStoreService = game:GetService("MemoryStoreService")
local HttpService = game:GetService("HttpService")

local MatchmakingModule = require(ServerScriptService.Matchmaking.DuelQueueHandler)

local debounceTable = {} :: {[number] : number}
local DEBOUNCE_TIME = 2.6

local matchmakingLock = MemoryStoreService:GetSortedMap("MatchmakingLock")
local LOCK_KEY = "CurrentMatchmaker"
local LOCK_EXPIRATION = 15 -- seconds
local CHECK_INTERVAL = 5   -- seconds

local isCurrentMatchmaker = false
local serverId = game.JobId .. "_" .. HttpService:GenerateGUID(false):sub(1, 4)
print(`[MM_MANAGER] Server ID: {serverId}`)

local function tryAcquireMatchmakerRole(): boolean
	local success, result = pcall(function()
		return matchmakingLock:UpdateAsync(
			LOCK_KEY,
			function(currentValue : any)
				local currentTime = os.time()
				if not currentValue or (currentTime - (currentValue.timestamp or 0)) > LOCK_EXPIRATION then
					return { owner = serverId, timestamp = currentTime }
				end
				if currentValue.owner == serverId then
					return { owner = serverId, timestamp = currentTime }
				end
				return currentValue
			end,
			LOCK_EXPIRATION * 2
		)
	end)
	return success and result and result.owner == serverId
end

local function updateMatchmakerStatus()
	local hasRole = tryAcquireMatchmakerRole()
	if hasRole and not isCurrentMatchmaker then
		print(`✅ [MM_MANAGER] Server {serverId} acquired Matchmaker role. Starting queue processing...`)
		isCurrentMatchmaker = true
		MatchmakingModule.StartProcessing()
	elseif not hasRole and isCurrentMatchmaker then
		print(`❌ [MM_MANAGER] Server {serverId} lost Matchmaker role. Stopping queue processing...`)
		isCurrentMatchmaker = false
		MatchmakingModule.StopProcessing()
	end
end

local matchmakingFolder = ReplicatedStorage:WaitForChild("Matchmaking")
local duelsFolder = matchmakingFolder:WaitForChild("Duels")
local toggleQueueFunction = duelsFolder:WaitForChild("ToggleQueueFunction")

toggleQueueFunction.OnServerInvoke = function(player: Player, isQueued: boolean, wagerAmount: number, gameMode: string)
	if not player or not player.Parent then return false, "Player not found" end
	
	local userId = player.UserId
	local currentTime = os.time()
	
	if not isQueued then -- handle queue removal before debounce to ensure stability
		if debounceTable[userId] then -- remove the debounce anyway
			debounceTable[userId] = nil
		end
		return MatchmakingModule.RemoveFromQueue(player, false)
	end
	
	if debounceTable[userId] and (currentTime - debounceTable[userId] < DEBOUNCE_TIME) then
		return false, "Please wait a moment..."
	end
	debounceTable[userId] = currentTime
	
	task.delay(DEBOUNCE_TIME, function()
		-- This check ensures we don't accidentally remove a newer debounce entry
		-- set by a subsequent request. We only remove the key if it's still our original timestamp.
		if debounceTable[userId] == currentTime then
			debounceTable[userId] = nil
		end
	end)
	
	if isQueued then
		if type(wagerAmount) ~= "number" then return false, "Invalid wager amount" end
		-- Pass the new gameMode parameter to the module
		return MatchmakingModule.AddToQueue(player, wagerAmount, gameMode) -- <<< PASS gameMode HERE
	else
		return MatchmakingModule.RemoveFromQueue(player, false)
	end
end

print("[MM_MANAGER] Initializing MatchmakingManager...")
MatchmakingModule.SetupTeleportListener()
task.spawn(function()
	while true do
		updateMatchmakerStatus()
		task.wait(CHECK_INTERVAL)
	end
end)
print(`[MM_MANAGER] MatchmakingManager initialized.`)
