--!strict

local ServerScriptService = game:GetService("ServerScriptService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")
local MessagingService = game:GetService("MessagingService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Assume this exists based on your snippet
local DataStatsManager = require(ServerScriptService.Managers.Data.DataStatsManager) 

--// TYPES
type MatchData = {
	UserIds: {number},
	PrivateServerCode: string,
	DuelTicketId: string,
	WagerAmount: number,
	Teams: {[string]: {number}}
}

type PlayerQueueData = {
	UserId: number,
	Wager: number,
	QueueTime: number,
	GameMode: string
}

type QueueItem = {
	key: string,
	value: number -- QueueTime
}

--// CONFIGURATION
local CONFIG = {
	QUEUE_MAP = "DuelQueue_SortedMap_v2",
	PLAYER_DATA_MAP = "DuelQueue_PlayerData_HashMap_v2",
	TELEPORT_TOPIC = "TeleportToDuelSolo",
	MIN_PLAYERS = 2,
	MATCH_PLACE_ID = 80943991227066,
	QUEUE_EXPIRY = 3600,
	TICKET_EXPIRY = 300,
	VALID_WAGERS = {0, 50, 100, 500, 1000, 5000, 10000},
	MATCH_MODES = {
		["1v1"] = { TeamSize = 1, TotalPlayers = 2 },
		["2v2"] = { TeamSize = 2, TotalPlayers = 4 },
		["3v3"] = { TeamSize = 3, TotalPlayers = 6 }
	}
}

--// SERVICES & STATE
local DuelTicketsMap = MemoryStoreService:GetHashMap("DuelTickets")
local QueueMap = MemoryStoreService:GetSortedMap(CONFIG.QUEUE_MAP)
local PlayerDataMap = MemoryStoreService:GetHashMap(CONFIG.PLAYER_DATA_MAP)
local LoadingScreenSetEvent = ReplicatedStorage:WaitForChild("Matchmaking"):WaitForChild("LoadingScreenSetEvent")

local MatchmakingService = {}
MatchmakingService.__index = MatchmakingService
MatchmakingService._IsRunning = false
MatchmakingService._RefundCache = {} :: {[number]: boolean}

--// HELPER: Safe Refund with Debounce
local function SafeRefund(userId: number, amount: number, reason: string)
	if amount <= 0 then return end
	if MatchmakingService._RefundCache[userId] then return end
	
	MatchmakingService._RefundCache[userId] = true
	
	local player = Players:GetPlayerByUserId(userId)
	if player then
		warn(`[MM] Refunding {amount} to {player.Name}: {reason}`)
		-- Wrap in pcall to ensure economy errors don't break the thread
		task.spawn(function()
			pcall(function() 
				(DataStatsManager :: any).AddShellsServer(player, amount) 
			end)
		end)
	else
		-- TODO: Handle offline refunds via DataStore if necessary
		warn(`[MM] Could not refund {userId} (Offline). Amount: {amount}`)
	end

	task.delay(5, function() MatchmakingService._RefundCache[userId] = nil end)
end

--// HELPER: Retry Logic for Teleport
local function RetryReserveServer(placeId: number): (boolean, string?)
	local attempts = 0
	local maxAttempts = 3
	local code = nil
	local success = false
	
	repeat
		attempts += 1
		success, code = pcall(function()
			return TeleportService:ReserveServerAsync(placeId)
		end)
		if not success then task.wait(1) end
	until success or attempts >= maxAttempts
	
	return success, code
end

--// MAIN HANDLERS

function MatchmakingService.AddToQueue(player: Player, wagerAmount: number, gameMode: string): (boolean, string)
	-- Validation
	if not table.find(CONFIG.VALID_WAGERS, wagerAmount) then return false, "Invalid wager." end
	if not CONFIG.MATCH_MODES[gameMode] then return false, "Invalid game mode." end
	if player:GetAttribute("InQueueForWager") then return false, "Already in queue." end

	-- Payment
	if wagerAmount > 0 then
		local paymentSuccess = (DataStatsManager :: any).AddShellsServer(player, -wagerAmount)
		if not paymentSuccess then return false, "Insufficient shells." end
	end

	-- Data Construction
	local userId = player.UserId
	local queueTime = os.time()
	local playerData: PlayerQueueData = {
		UserId = userId,
		Wager = wagerAmount,
		QueueTime = queueTime,
		GameMode = gameMode
	}

	-- MemoryStore Operations
	local success, err = pcall(function()
		QueueMap:SetAsync(tostring(userId), queueTime, CONFIG.QUEUE_EXPIRY)
		PlayerDataMap:SetAsync(tostring(userId), playerData, CONFIG.QUEUE_EXPIRY)
	end)

	if not success then
		warn(`[MM] Queue Error for {player.Name}: {err}`)
		SafeRefund(userId, wagerAmount, "Queue System Error")
		return false, "System error. Try again."
	end

	player:SetAttribute("InQueueForWager", wagerAmount)
	return true, "Joined queue."
end

function MatchmakingService.RemoveFromQueue(player: Player, isDisconnect: boolean): (boolean, string)
	local wager = player:GetAttribute("InQueueForWager")
	if not wager then return false, "Not in queue." end

	local userIdStr = tostring(player.UserId)
	
	-- Fire and forget removal for speed, unless strict confirmation needed
	task.spawn(function()
		pcall(function()
			QueueMap:RemoveAsync(userIdStr)
			PlayerDataMap:RemoveAsync(userIdStr)
		end)
	end)

	player:SetAttribute("InQueueForWager", nil)
	
	if wager > 0 and not isDisconnect then
		SafeRefund(player.UserId, wager, "Left Queue")
	end

	return true, "Left queue."
end

--// THE ADVANCED MATCHMAKER LOGIC
function MatchmakingService._AttemptMatch(gameMode: string, wager: number, candidates: {PlayerQueueData})
	local config = CONFIG.MATCH_MODES[gameMode]
	if #candidates < config.TotalPlayers then return end

	local matchSize = config.TotalPlayers
	local claimedPlayers: {PlayerQueueData} = {}
	
	-- CLAIM PHASE (Atomic Lock Simulation)
	-- We attempt to remove players from the queue. If we successfully remove them, we 'own' them.
	for _, candidate in ipairs(candidates) do
		if #claimedPlayers >= matchSize then break end

		local removeSuccess = pcall(function()
			QueueMap:RemoveAsync(tostring(candidate.UserId))
		end)

		if removeSuccess then
			-- Verify Data Map Exists
			local dataExists, _ = pcall(function() return PlayerDataMap:GetAsync(tostring(candidate.UserId)) end)
			
			if dataExists then
				table.insert(claimedPlayers, candidate)
				-- Clean up their data map entry now that we have it locally
				pcall(function() PlayerDataMap:RemoveAsync(tostring(candidate.UserId)) end)
			else
				-- Data desync: Key existed in SortedMap but not HashMap. Skip.
			end
		end
	end

	-- VERIFICATION PHASE
	if #claimedPlayers < matchSize then
		-- We failed to grab enough players (another server might have stolen some).
		-- We must RETURN the claimed players to the queue (Rollback).
		for _, pData in ipairs(claimedPlayers) do
			pcall(function()
				-- Put them back with original queue time so they keep priority
				QueueMap:SetAsync(tostring(pData.UserId), pData.QueueTime, CONFIG.QUEUE_EXPIRY)
				PlayerDataMap:SetAsync(tostring(pData.UserId), pData, CONFIG.QUEUE_EXPIRY)
			end)
		end
		return -- Abort this match attempt
	end

	-- EXECUTION PHASE (We have a full team, proceed to server reservation)
	print(`[MM] Creating {gameMode} match for {matchSize} players...`)
	
	local success, code = RetryReserveServer(CONFIG.MATCH_PLACE_ID)
	
	if not success or not code then
		warn(`[MM] Critical: Failed to reserve server. Refunding players.`)
		for _, pData in ipairs(claimedPlayers) do
			SafeRefund(pData.UserId, pData.Wager, "Server Reservation Failed")
			-- Notify player locally if they are in this server
			local pl = Players:GetPlayerByUserId(pData.UserId)
			if pl then pl:SetAttribute("InQueueForWager", nil) end
		end
		return
	end

	-- Prepare Match Data
	local teams = { Red = {}, Blue = {} }
	local userIdsToTeleport = {}
	
	for i, pData in ipairs(claimedPlayers) do
		table.insert(userIdsToTeleport, pData.UserId)
		if i <= config.TeamSize then
			table.insert(teams.Red, pData.UserId)
		else
			table.insert(teams.Blue, pData.UserId)
		end
		
		-- Clear attributes for local players
		local pl = Players:GetPlayerByUserId(pData.UserId)
		if pl then pl:SetAttribute("InQueueForWager", nil) end
	end

	local duelTicketId = HttpService:GenerateGUID(false)
	local messageData: MatchData = {
		UserIds = userIdsToTeleport,
		PrivateServerCode = code,
		DuelTicketId = duelTicketId,
		WagerAmount = wager,
		Teams = teams
	}

	-- Broadcoast to all servers to teleport these specific UserIds
	pcall(function()
		MessagingService:PublishAsync(CONFIG.TELEPORT_TOPIC, HttpService:JSONEncode(messageData))
	end)
end

function MatchmakingService.ProcessQueue()
	-- Fetch Range (Snapshot of current queue)
	local success, queuedItems = pcall(function()
		return QueueMap:GetRangeAsync(Enum.SortDirection.Ascending, 100)
	end)

	if not success or not queuedItems or #queuedItems < CONFIG.MIN_PLAYERS then return end
	
	-- Fetch Data Bulk
	-- Note: In a production environment, you might throttle this to avoid hitting limits
	local playersByModeAndWager: {[string]: {[number]: {PlayerQueueData}}} = {}
	
	for _, item: any in ipairs(queuedItems) do
		local key = item.key
		local dSuccess, data = pcall(function() return PlayerDataMap:GetAsync(key) end)
		
		if dSuccess and data then
			local qData = data :: PlayerQueueData
			if not playersByModeAndWager[qData.GameMode] then playersByModeAndWager[qData.GameMode] = {} end
			if not playersByModeAndWager[qData.GameMode][qData.Wager] then playersByModeAndWager[qData.GameMode][qData.Wager] = {} end
			
			table.insert(playersByModeAndWager[qData.GameMode][qData.Wager], qData)
		end
	end

	-- Group and Attempt Matches
	for mode, wagerGroups in pairs(playersByModeAndWager) do
		for wager, candidates in pairs(wagerGroups) do
			MatchmakingService._AttemptMatch(mode, wager, candidates)
		end
	end
end

function MatchmakingService.Init()
	if MatchmakingService._IsRunning then return end
	MatchmakingService._IsRunning = true
	
	-- Matchmaking Loop
	task.spawn(function()
		while MatchmakingService._IsRunning do
			MatchmakingService.ProcessQueue()
			task.wait(5) -- Polling rate
		end
	end)

	-- Teleport Listener
	MessagingService:SubscribeAsync(CONFIG.TELEPORT_TOPIC, function(message)
		local s, data = pcall(function() return HttpService:JSONDecode(message.Data) end)
		if not s then return end
		
		local matchData = data :: MatchData
		local playersToTeleport: {Player} = {}
		
		for _, uid in ipairs(matchData.UserIds) do
			local pl = Players:GetPlayerByUserId(uid)
			if pl then
				table.insert(playersToTeleport, pl)
				LoadingScreenSetEvent:FireClient(pl, "DEATHMATCH")
			end
		end

		if #playersToTeleport > 0 then
			local tpData = {
				TicketId = matchData.DuelTicketId,
				WagerAmount = matchData.WagerAmount,
				MatchType = "Global",
				Teams = matchData.Teams
			}
			
			local tpOptions = Instance.new("TeleportOptions")
			tpOptions.ReservedServerAccessCode = matchData.PrivateServerCode
			tpOptions:SetTeleportData(tpData)
			
			SafeTeleport(CONFIG.MATCH_PLACE_ID, playersToTeleport, tpOptions)
		end
	end)

	-- Disconnect Listener
	Players.PlayerRemoving:Connect(function(player)
		MatchmakingService.RemoveFromQueue(player, true)
	end)
	
	print("[MM] Service Initialized.")
end

-- Helper for safe teleport handling
function SafeTeleport(placeId: number, players: {Player}, options: TeleportOptions)
	local success, res = pcall(function()
		return TeleportService:TeleportAsync(placeId, players, options)
	end)
	if not success then
		warn(`[MM] Teleport Failed: {res}`)
		-- Refund logic for failed teleports would go here
	end
end

return MatchmakingService
