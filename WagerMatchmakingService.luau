--!strict

local ServerScriptService = game:GetService("ServerScriptService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")
local MessagingService = game:GetService("MessagingService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStatsManager = require(ServerScriptService.Managers.Data.DataStatsManager)

--// MODULES & TYPES
local loadingScreenSetEvent = ReplicatedStorage.Matchmaking.LoadingScreenSetEvent

type MatchData = { UserIds: {number}, PrivateServerCode: string, DuelTicketId: string, WagerAmount: number, Teams: {[string]: {number}} }
type PlayerQueueData = { UserId: number, Wager: number, QueueTime: number, GameMode: string }
type SortedMapItem = { key: string, value: number }

--// CONFIGURATION
local QUEUE_MAP_NAME = "DuelQueue_SortedMap"
local PLAYER_DATA_MAP_NAME = "DuelQueue_PlayerData_HashMap"
local TELEPORT_TOPIC = "TeleportToDuelSolo"
local MIN_PLAYERS_FOR_MATCH = 2
local MATCH_PLACE_ID = 80943991227066

local VALID_WAGERS = {0, 50, 100, 500, 1000, 5000, 10000}
local MATCH_CONFIG = {
	["1v1"] = { TeamSize = 1, TotalPlayers = 2 },
	["2v2"] = { TeamSize = 2, TotalPlayers = 4 },
	["3v3"] = { TeamSize = 3, TotalPlayers = 6 }
}

--// SERVICES & MAPS
local DuelTicketsMap = MemoryStoreService:GetHashMap("DuelTickets")
local queueMap = MemoryStoreService:GetSortedMap(QUEUE_MAP_NAME)
local playerDataMap = MemoryStoreService:GetHashMap(PLAYER_DATA_MAP_NAME)

--// STATE
local RefundedPlayers = {}
local isProcessingActive = false
local processingThread: thread? = nil

--//
--// --- PRIVATE HELPER FUNCTIONS ---
--//

local function SafeRefund(player: Player, amount: number, reason: string)
	if not player or amount <= 0 then return end
	local userId = player.UserId
	if RefundedPlayers[userId] then return end
	RefundedPlayers[userId] = true
	print(`[MM] Refunding {amount} shells to {player.Name}. Reason: {reason}`);
	(DataStatsManager :: any).AddShellsServer(player, amount) -- the data stats manager is where we handle economy, based on shells (money)
	task.delay(5, function() RefundedPlayers[userId] = nil end)
end

-- Safely gets the list of queued player IDs from the SortedMap.
local function _getQueuedItems(): {any}?
	local success, result = pcall(function()
		return queueMap:GetRangeAsync(Enum.SortDirection.Ascending, 50)
	end)
	if not success then
		warn(`[MM] Error reading queue map: {tostring(result)}`)
		return nil
	end
	return result
end

-- Fetches all player data in ONE bulk request for performance.
local function _fetchPlayerData(queuedItems: {SortedMapItem}): {PlayerQueueData}?
	local playerKeys = {}
	for _, item in ipairs(queuedItems) do
		table.insert(playerKeys, item.key)
	end
	if #playerKeys == 0 then return {} end

	local formattedData = {}
	local successCount = 0

	-- We must loop and get each item individually for a HashMap
	for _, key in ipairs(playerKeys) do
		local success, result = pcall(function()
			return playerDataMap:GetAsync((key :: string))
		end)

		if success and result then
			table.insert(formattedData, result :: PlayerQueueData)
			successCount += 1
		else
			-- This can happen if a player leaves the queue between getting the keys and fetching the data. It's safe to just warn.
			warn(`[MM] Could not fetch player data for key {key}. It may have been removed. Error: {tostring(result)}`)
		end
	end

	if successCount == 0 and #playerKeys > 0 then
		warn(`[MM] Error bulk-fetching player data: Failed to fetch any data for the provided keys.`)
		return nil -- Return nil if we failed to get any data at all
	end

	return formattedData
end

-- Sorts players into groups by GameMode and Wager.
local function _groupPlayers(fullPlayerData: {PlayerQueueData}): {[string]: {[number]: {PlayerQueueData}}}
	local playersByGroup: {[string]: {[number]: {PlayerQueueData}}} = {}
	for _, data in ipairs(fullPlayerData) do
		local gameMode = data.GameMode
		local wager = data.Wager

		if not playersByGroup[gameMode] then playersByGroup[gameMode] = {} end
		if not playersByGroup[gameMode][wager] then playersByGroup[gameMode][wager] = {} end

		table.insert(playersByGroup[gameMode][wager], data)
	end
	return playersByGroup
end

-- Creates balanced NvN matches from the sorted groups.
local function _createMatchesFromGroups(playersByGroup: {[string]: {[number]: {PlayerQueueData}}})
	for gameMode, wagers in pairs(playersByGroup) do
		local config = MATCH_CONFIG[gameMode]
		if not config then continue end

		local matchSize = config.TotalPlayers

		for wager, queuedPlayers in pairs(wagers) do
			while #queuedPlayers >= matchSize do
				print(`[MM] Match found for {gameMode} @ {wager} wager! Attempting to reserve server...`)

				-- GATHER players for the potential match, but DO NOT remove them from the list yet.
				local playersInMatchData = {}
				for i = 1, matchSize do
					table.insert(playersInMatchData, queuedPlayers[i])
				end
				
				-- Attempt to reserve the server FIRST. This is the most likely point of failure.
				local reserveSuccess, privateServerCode = pcall(function() return TeleportService:ReserveServerAsync(MATCH_PLACE_ID) end)
				if not reserveSuccess then
					warn(`[MM] Failed to reserve server: {tostring(privateServerCode)}. Players will remain in queue.`)
					-- Break the loop for this wager group for this cycle to avoid repeatedly failing on the same group.
					break
				end

				print(`[MM] Server reserved successfully. Removing players from queue...`)
				
				local teamsData = { Red = {}, Blue = {} }
				local userIdsToRemove = {}
				local userIdsToTeleport = {}

				-- Now we actually remove the players from the list and prepare their data
				for i = 1, matchSize do
					local playerData = table.remove(queuedPlayers, 1) -- This removes from the start of the list
					if playerData then
						table.insert(userIdsToRemove, tostring(playerData.UserId))
						table.insert(userIdsToTeleport, playerData.UserId)

						-- Assign teams
						if #teamsData.Red < config.TeamSize then
							table.insert(teamsData.Red, playerData.UserId)
						else
							table.insert(teamsData.Blue, playerData.UserId)
						end
						
						-- Clear player attribute
						local player = Players:GetPlayerByUserId(playerData.UserId)
						if player then player:SetAttribute("InQueueForWager", nil) end
					end
				end

				-- Remove players from MemoryStore
				for _, userIdString in ipairs(userIdsToRemove) do
					-- Using separate pcalls is more robust against single-item failures
					pcall(function() queueMap:RemoveAsync((userIdString :: string)) end)
					pcall(function() playerDataMap:RemoveAsync((userIdString :: string)) end)
				end

				-- Teleportation logic
				local duelTicketId = HttpService:GenerateGUID(false)
				local duelTicket = { Teams = teamsData, WagerAmount = wager, Status = "Pending", Timestamp = os.time() }
				DuelTicketsMap:SetAsync(duelTicketId, duelTicket, 300)

				local messageData = { UserIds = userIdsToTeleport, PrivateServerCode = privateServerCode, DuelTicketId = duelTicketId, WagerAmount = wager, Teams = teamsData }
				pcall(function() MessagingService:PublishAsync(TELEPORT_TOPIC, HttpService:JSONEncode(messageData)) end)
			end
		end
	end
end


--//
--// --- PUBLIC MODULE FUNCTIONS ---
--//

local MatchmakingService = {}

function MatchmakingService.AddToQueue(player: Player, wagerAmount: number, gameMode: string): (boolean, string)
	if not table.find(VALID_WAGERS, wagerAmount) then return false, "Invalid mode selected." end
	if not MATCH_CONFIG[gameMode] then return false, "Invalid game mode." end
	if player:GetAttribute("InQueueForWager") then return false, "You are already in a queue." end

	if RefundedPlayers[player.UserId] then
		RefundedPlayers[player.UserId] = nil
		print(`[MM] Cleared refund cooldown for {player.Name} as they are starting a new queue session.`)
	end

	if wagerAmount > 0 then
		local hasEnough = DataStatsManager.AddShellsServer(player, -math.abs(wagerAmount)) 
		-- this math method always returns a positive so adding a minues (-) at the start makes it always negative for SAFETY!
		if not hasEnough then return false, "You do not have enough shells." end
	end

	local userId = player.UserId
	local queueTime = os.time()
	local playerData: PlayerQueueData = { UserId = userId, Wager = wagerAmount, QueueTime = queueTime, GameMode = gameMode }

	local success, err = pcall(function()
		queueMap:SetAsync(tostring(userId), queueTime, 3600)
		playerDataMap:SetAsync(tostring(userId), playerData, 3600)
		return true
	end)

	if not success then
		warn(`[MM] FAILED to add {player.Name} to queue. Error: {tostring(err)}`)
		SafeRefund(player, wagerAmount, "Failed to join queue")
		return false, "Server is busy. Please try again."
	end

	print(`[MM] SUCCESS: Added {player.Name} to queue for {gameMode} @ wager {wagerAmount}.`)
	player:SetAttribute("InQueueForWager", wagerAmount)
	return true, "Successfully added to queue!"
end

function MatchmakingService.RemoveFromQueue(player: Player, isDisconnecting: boolean?): (boolean, string)
	local wagerAmount = player:GetAttribute("InQueueForWager")
	if not wagerAmount then return false, "You are not in a queue." end

	local keyToRemove = tostring(player.UserId)
	local success, err = pcall(function()
		queueMap:RemoveAsync(keyToRemove)
		playerDataMap:RemoveAsync(keyToRemove)
		return true
	end)

	if not success then
		return false, "Failed to leave queue. Please try again."
	end

	player:SetAttribute("InQueueForWager", nil) -- Clear attribute on success
	if wagerAmount > 0 and not isDisconnecting then SafeRefund(player, wagerAmount, "Left queue voluntarily") end
	print(`[MM] Removed {player.Name} from queue.`)
	return true, "Successfully left the queue."
end

-- The main processing function.
function MatchmakingService.ProcessQueue()
	local queuedItems = _getQueuedItems()
	if not queuedItems or #queuedItems < MIN_PLAYERS_FOR_MATCH then return end

	local fullPlayerData = _fetchPlayerData(queuedItems)
	if not fullPlayerData or #fullPlayerData < MIN_PLAYERS_FOR_MATCH then return end

	local playersByGroup = _groupPlayers(fullPlayerData)

	_createMatchesFromGroups(playersByGroup)
end

function MatchmakingService.StartProcessing()
	if isProcessingActive then return end
	isProcessingActive = true
	print("[MM] Starting ProcessQueue loop...")
	processingThread = task.spawn(function()
		while isProcessingActive do
			MatchmakingService.ProcessQueue()
			task.wait(3)
		end
	end)
end

function MatchmakingService.StopProcessing()
	if not isProcessingActive then return end
	isProcessingActive = false
	print("[MM] Stopping ProcessQueue loop...")
	if processingThread then task.cancel(processingThread) end
end

function MatchmakingService.SetupTeleportListener()
	print("[MM] Setting up teleport listener...")
	MessagingService:SubscribeAsync(TELEPORT_TOPIC, function(message)
		local success, data = pcall(function() return HttpService:JSONDecode(message.Data) end)
		if not success or not data then return end

		data = data :: MatchData
		local playersOnThisServer = {}
		for _, userId in ipairs(data.UserIds) do
			local player = Players:GetPlayerByUserId(userId)
			if player then table.insert(playersOnThisServer, player) end
		end

		if #playersOnThisServer > 0 then
			-- No need to re-fetch the ticket from MemoryStore, the required data is already in the message.
			local dataToSend = {
				TicketId = data.DuelTicketId,
				WagerAmount = data.WagerAmount,
				MatchType = "Global",
				Teams = data.Teams -- Correctly use the Teams data from the message
			}
			local teleportDataString = HttpService:JSONEncode(dataToSend)

			local teleportSuccess, teleportErr = pcall(function()
				TeleportService:TeleportToPrivateServer(
					MATCH_PLACE_ID, 
					data.PrivateServerCode, 
					(playersOnThisServer :: {Instance}), 
					nil, 
					teleportDataString, 
					nil)
				
				return true
			end)
			if teleportSuccess then
				for _, player : Player in ipairs(playersOnThisServer) do loadingScreenSetEvent:FireClient((player :: Player), "DEATHMATCH") end
			else
				warn(`[MM] Teleport failed: {teleportErr}`)
				for _, p in ipairs(playersOnThisServer) do SafeRefund(p, data.WagerAmount, "Teleport failed") end
			end
		end
	end)
	print("[MM] Teleport listener setup complete!")
end

function MatchmakingService.OnPlayerRemoving(player: Player)
	if player:GetAttribute("InQueueForWager") then
		MatchmakingService.RemoveFromQueue(player, true)
	end
end

return MatchmakingService
