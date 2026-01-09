--!strict

local ServerScriptService = game:GetService("ServerScriptService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")
local MessagingService = game:GetService("MessagingService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--// MODULES
local DataStatsManager = require(ServerScriptService:WaitForChild("Managers"):WaitForChild("Data"):WaitForChild("DataStatsManager"))

--// TYPES
export type MatchData = {
	UserIds: {number},
	PrivateServerCode: string,
	DuelTicketId: string,
	WagerAmount: number,
	Teams: {Red: {number}, Blue: {number}}
}

export type PlayerQueueData = {
	UserId: number,
	Wager: number,
	QueueTime: number,
	GameMode: string
}

--// CONFIGURATION
local SETTINGS = {
	MAP_NAMES = {
		QUEUE = "DuelQueue_v3",
		DATA = "PlayerData_v3",
		LOCK = "ProcessorLock_v3",
		TICKETS = "DuelTickets_v3"
	},
	
	TOPIC = "TeleportToDuel",
	PLACE_ID = 80943991227066,
	
	LOCK_EXPIRY = 8, -- Seconds a server holds Leader status
	PROCESS_INTERVAL = 5,
	
	VALID_WAGERS = {0, 50, 100, 500, 1000, 5000, 10000},
	MODES = {
		["1v1"] = { TeamSize = 1, TotalPlayers = 2 },
		["2v2"] = { TeamSize = 2, TotalPlayers = 4 },
		["3v3"] = { TeamSize = 3, TotalPlayers = 6 }
	}
}

--// STATE
local MatchmakingService = {}
MatchmakingService.__index = MatchmakingService

local QueueMap = MemoryStoreService:GetSortedMap(SETTINGS.MAP_NAMES.QUEUE)
local DataMap = MemoryStoreService:GetHashMap(SETTINGS.MAP_NAMES.DATA)
local LockMap = MemoryStoreService:GetSortedMap(SETTINGS.MAP_NAMES.LOCK)
local TicketMap = MemoryStoreService:GetHashMap(SETTINGS.MAP_NAMES.TICKETS)

local isRunning = false
local processConnection: thread? = nil
local refundDebounce: {[number]: boolean} = {}

--// INTERNAL UTILITIES

-- Uses exponential backoff to ensure Roblox API calls don't fail
local function _safeReserveServer(placeId: number): (boolean, string?)
	local success, result
	for i = 1, 3 do
		success, result = pcall(function()
			return TeleportService:ReserveServerAsync(placeId)
		end)
		if success then break end
		task.wait(2 ^ i)
	end
	return success, result
end

local function _refundPlayer(userId: number, amount: number, reason: string)
	if amount <= 0 or refundDebounce[userId] then return end
	refundDebounce[userId] = true
	
	local player = Players:GetPlayerByUserId(userId)
	if player then
		print(`[MM] Refunding {player.Name}: {reason}`);
		(DataStatsManager :: any).AddShellsServer(player, amount)
	end
	
	task.delay(10, function() refundDebounce[userId] = nil end)
end

--// THE DISTRIBUTED LOCK
-- This ensures that only ONE server at a time runs the heavy matchmaking math.
local function _claimProcessorRole(): boolean
	local success, lockObj = pcall(function()
		return LockMap:UpdateAsync("LeaderKey", function(current)
			local now = os.time()
			if not current or (now > current.Expiry) then
				return { Owner = game.JobId, Expiry = now + SETTINGS.LOCK_EXPIRY }
			end
			if current.Owner == game.JobId then
				return { Owner = game.JobId, Expiry = now + SETTINGS.LOCK_EXPIRY }
			end
			return nil -- Someone else owns it
		end, SETTINGS.LOCK_EXPIRY)
	end)
	return success and lockObj ~= nil and lockObj.Owner == game.JobId
end

--// PUBLIC API

function MatchmakingService.AddToQueue(player: Player, wager: number, mode: string): (boolean, string)
	if not table.find(SETTINGS.VALID_WAGERS, wager) then return false, "Invalid wager." end
	if not SETTINGS.MODES[mode] then return false, "Invalid mode." end
	if player:GetAttribute("InQueue") then return false, "Already in queue." end

	-- Atomic Currency Check
	if wager > 0 then
		local deducted = (DataStatsManager :: any).AddShellsServer(player, -wager)
		if not deducted then return false, "Insufficient funds." end
	end

	local userId = player.UserId
	local data: PlayerQueueData = {
		UserId = userId,
		Wager = wager,
		QueueTime = os.time(),
		GameMode = mode
	}

	local success, _ = pcall(function()
		QueueMap:SetAsync(tostring(userId), data.QueueTime, 3600)
		DataMap:SetAsync(tostring(userId), data, 3600)
	end)

	if not success then
		_refundPlayer(userId, wager, "Queue system write error")
		return false, "Internal error. Try again."
	end

	player:SetAttribute("InQueue", true)
	return true, "Successfully queued!"
end

function MatchmakingService.RemoveFromQueue(player: Player, isDisconnect: boolean): (boolean, string)
	local userId = player.UserId
	local success, data = pcall(function() return DataMap:GetAsync(tostring(userId)) end)
	
	pcall(function()
		QueueMap:RemoveAsync(tostring(userId))
		DataMap:RemoveAsync(tostring(userId))
	end)

	player:SetAttribute("InInQueue", nil)

	if not isDisconnect and data and (data :: PlayerQueueData).Wager > 0 then
		_refundPlayer(userId, (data :: PlayerQueueData).Wager, "Player left queue")
	end

	return true, "Left queue."
end

--// THE MATCHMAKING ENGINE
function MatchmakingService.ProcessQueue()
	if not _claimProcessorRole() then return end

	local success, range = pcall(function() return QueueMap:GetRangeAsync(Enum.SortDirection.Ascending, 50) end)
	if not success or not range or #range < 2 then return end

	-- Gather all data
	local pool: {[string]: {[number]: {PlayerQueueData}}} = {}
	for _, item in ipairs(range) do
		local dSuccess, pData = pcall(function() return DataMap:GetAsync(item.key) end)
		if dSuccess and pData then
			local qData = pData :: PlayerQueueData
			pool[qData.GameMode] = pool[qData.GameMode] or {}
			pool[qData.GameMode][qData.Wager] = pool[qData.GameMode][qData.Wager] or {}
			table.insert(pool[qData.GameMode][qData.Wager], qData)
		end
	end

	-- Attempt matches with Atomic Claims
	for mode, wagers in pairs(pool) do
		local config = SETTINGS.MODES[mode]
		for wager, players in pairs(wagers) do
			while #players >= config.TotalPlayers do
				local matchCandidates = {}
				local claimedCount = 0
				
				-- Attempt to "Claim" players by removing them from the global queue
				for i = 1, config.TotalPlayers do
					local p = table.remove(players, 1) :: PlayerQueueData
					local removed = pcall(function() return QueueMap:RemoveAsync(tostring(p.UserId)) end)
					if removed then
						table.insert(matchCandidates, p)
						claimedCount += 1
					end
				end

				if claimedCount == config.TotalPlayers then
					-- SUCCESS: Create Match
					local resSuccess, serverCode = _safeReserveServer(SETTINGS.PLACE_ID)
					if resSuccess and serverCode then
						local ticketId = HttpService:GenerateGUID(false)
						local teamData = { Red = {}, Blue = {} }
						local uids = {}

						for i, p in ipairs(matchCandidates) do
							table.insert(uids, p.UserId)
							table.insert(i <= config.TeamSize and teamData.Red or teamData.Blue, p.UserId)
							pcall(function() DataMap:RemoveAsync(tostring(p.UserId)) end)
						end

						local payload: MatchData = {
							UserIds = uids,
							PrivateServerCode = serverCode,
							DuelTicketId = ticketId,
							WagerAmount = wager,
							Teams = teamData
						}

						MessagingService:PublishAsync(SETTINGS.TOPIC, HttpService:JSONEncode(payload))
					else
						-- Reserve failed, refund
						for _, p in ipairs(matchCandidates) do _refundPlayer(p.UserId, p.Wager, "Server Error") end
					end
				else
					-- FAIL: Someone else grabbed a player, return claimed ones to queue
					for _, p in ipairs(matchCandidates) do
						QueueMap:SetAsync(tostring(p.UserId), p.QueueTime, 3600)
					end
				end
			end
		end
	end
end

--// INITIALIZATION
function MatchmakingService.Init()
	if isRunning then return end
	isRunning = true

	-- Processor Loop
	processConnection = task.spawn(function()
		while isRunning do
			MatchmakingService.ProcessQueue()
			task.wait(SETTINGS.PROCESS_INTERVAL + math.random())
		end
	end)

	-- Teleport Listener
	MessagingService:SubscribeAsync(SETTINGS.TOPIC, function(msg)
		local success, data = pcall(function() return HttpService:JSONDecode(msg.Data) end)
		if not success then return end
		
		local mData = data :: MatchData
		local localPlayers = {}
		for _, id in ipairs(mData.UserIds) do
			local p = Players:GetPlayerByUserId(id)
			if p then table.insert(localPlayers, p) end
		end

		if #localPlayers > 0 then
			local options = Instance.new("TeleportOptions")
			options.ReservedServerAccessCode = mData.PrivateServerCode
			options:SetTeleportData({
				TicketId = mData.DuelTicketId,
				Teams = mData.Teams,
				Wager = mData.WagerAmount
			})
			
			-- Final verification: Send event to client
			local event = ReplicatedStorage:FindFirstChild("Matchmaking"):FindFirstChild("LoadingScreenSetEvent") :: RemoteEvent
			for _, p in ipairs(localPlayers) do event:FireClient(p, "DEATHMATCH") end
			
			pcall(function() TeleportService:TeleportAsync(SETTINGS.PLACE_ID, localPlayers, options) end)
		end
	end)
end

return MatchmakingService
