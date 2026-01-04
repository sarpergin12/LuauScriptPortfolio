local SkinMastery = {}

local Players = game:GetService("Players")

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")


-- // REQUIRING //

local DataStatsManager = require(ServerScriptService.Managers.Data.DataStatsManager)

local CosmeticsConfig = require(ReplicatedStorage.Data.Configs.CosmeticsConfig)

local WeaponConfig = require(ReplicatedStorage.Data.Configs.WeaponConfig)

-- // REMOTES //

local contractCompletedEvent = ReplicatedStorage.Contracts.Remotes.ContractCompletedEvent

local requestSkinMasteryProgressFunction = ReplicatedStorage.SkinMastery.Remotes.RequestSkinMasteryProgressFunction
local requestUpdateSkinMasteryFunction = ReplicatedStorage.SkinMastery.Remotes.RequestUpdateSkinMasteryFunction

-- // RUNTIME VALUES //

local defaultSkins = {}

-- Initialize the defaultSkins table
for skinKey, skinData in pairs(CosmeticsConfig.Skins) do
	if skinData.Contract and skinData.Contract.Goal == 1 then
		defaultSkins[skinKey] = true
	end
end


-- // TYPES //

export type EventTypes = "Elimination" | "Headshot" | "DuelWon" | "DeathmatchWon"

------------------
-- MAIN HANDLERS
------------------

-- Add this new function to your module
function SkinMastery.EnsureAllActiveContracts(player: Player)
	local profile = DataStatsManager.ActivePlayers[player]
	if not profile then return end

	-- 1. Iterate through every weapon that exists in the game
	for weaponName, _ in pairs(WeaponConfig.Weapons) do

		-- 2. Check if the weapon already has an active contract.
		local currentContract = profile.Data.ActiveMasteryContracts[weaponName]

		if currentContract then
			local skinConfig = CosmeticsConfig.Skins[currentContract]
			if not skinConfig then
				warn("SkinConfig not found for : "..currentContract)
				return
			end

			-- Check if the contract is still valid and not already unlocked
			local isApplicable = not skinConfig.ApplicableWeapons or table.find(skinConfig.ApplicableWeapons, weaponName)
			if isApplicable and profile.Data.SkinMasteries[currentContract][weaponName].Unlocked then
				-- This contract is completed, clear it so a new one can be found below.
				profile.Data.ActiveMasteryContracts[weaponName] = nil
			else
				-- The contract is valid and in-progress, so skip to the next weapon.
				continue
			end
		end

		-- 3. If we reach here, the weapon needs a new contract. Let's find one.
		local availableContracts = {}
		for skinKey, masteryData in pairs(profile.Data.SkinMasteries) do
			if skinKey ~= "Default" then
				if masteryData[weaponName] and not masteryData[weaponName].Unlocked then
					table.insert(availableContracts, skinKey)
				end
			end
		end

		-- 4. If any available contracts were found, pick one at random and assign it.
		if #availableContracts > 0 then
			local randomIndex = math.random(1, #availableContracts)
			local newContractSkin = availableContracts[randomIndex]
			profile.Data.ActiveMasteryContracts[weaponName] = newContractSkin
		end
	end
end

function SkinMastery.ReconcileMasteries(player : Player) : ()

	local profile = DataStatsManager.ActivePlayers[player]
	if not profile then return end

	--if not profile.Data.SkinMasteries["Default"] then
	--	profile.Data.SkinMasteries["Default"] = {} -- MOVED BELOW 
	--end

	for weaponName, _ in pairs(WeaponConfig.Weapons) do
		-- INITIALIZE DEFAULT SKINS
		
		for defaultSkin, _ in pairs(defaultSkins) do
			
			local masteryData = profile.Data.SkinMasteries[defaultSkin]
				if not masteryData then
					profile.Data.SkinMasteries[defaultSkin] = {} -- reconcile defaults
					masteryData = profile.Data.SkinMasteries[defaultSkin]
				end
			
			if not profile.Data.SkinMasteries[defaultSkin][weaponName] then
				--warn("Reconciling: Adding '"..weaponName.."' to skin '".."Default".."' for player "..player.Name)
				masteryData[weaponName] = {Progress = 2, Unlocked = true}
				
				if defaultSkin == "Default" then -- set equippedSkin to default once per loop
					profile.Data.Equipped.EquippedSkins[weaponName] = "Default" -- set the equipped to default!
				end
			end
		end
		
	end

	-- Iterate over every skin the player has started a mastery for.
	for skinKey, masteryData in pairs(profile.Data.SkinMasteries) do

		local skinConfig = CosmeticsConfig.Skins[skinKey]
		if not skinConfig then
			warn("Reconcile: Skipping unknown skin:", skinKey)
			continue -- Skip to the next skin mastery
		end

		-- Case 1: The skin is meant for ALL weapons
		if not skinConfig.ApplicableWeapons then

			-- Check against every weapon that exists in the game
			for weaponName, _ in pairs(WeaponConfig.Weapons) do
				-- If the player's mastery data for this skin doesn't have an entry for this weapon...
				if not masteryData[weaponName] then
					--warn("Reconciling: Adding '"..weaponName.."' to skin '"..skinKey.."' for player "..player.Name)
					masteryData[weaponName] = {Progress = 0, Unlocked = false}
				end
			end

			-- Case 2: The skin is only for a SPECIFIC list of weapons
		else

			-- Check against only the weapons this skin can be applied to
			for _, weaponName in ipairs(skinConfig.ApplicableWeapons) do
				-- If the player's mastery data for this skin doesn't have an entry for this weapon...
				if not masteryData[weaponName] then
					--warn("Reconciling: Adding '"..weaponName.."' to skin '"..skinKey.."' for player "..player.Name)
					masteryData[weaponName] = {Progress = 0, Unlocked = false}
				end
			end
		end
	end
	
	SkinMastery.EnsureAllActiveContracts(player) -- this updates un-valued weapons so every weapon has an active contract!	

end

function SkinMastery.NewMastery(player : Player, skinKey : string) : ()

	local profile = DataStatsManager.ActivePlayers[player]
	if not profile then return false, "Profile not loaded!" end

	if profile.Data.SkinMasteries[skinKey] then
		warn(player.Name.." tried setting new mastery to a skin they already own.")
		return false, "You already own that skin."
	end

	local wantedSkinData = CosmeticsConfig.Skins[skinKey]
	if not wantedSkinData then
		warn("SkinData doesn't exist for : "..skinKey)
		return
	end

	-- This initializes the table for the skin! Important!
	profile.Data.SkinMasteries[skinKey] = {}
	
		SkinMastery.ReconcileMasteries(player) -- safety
	
	--------------------	
	local totalMasteryCount = 0
	for mastery, _ in pairs(profile.Data.SkinMasteries) do
		if mastery == "Default" then continue end -- don't count the default skinMastery!!!
		totalMasteryCount += 1 -- increment total count by 1
	end



	if wantedSkinData.ApplicableWeapons then

		for _, weaponName in pairs(wantedSkinData.ApplicableWeapons) do
			profile.Data.SkinMasteries[skinKey][weaponName] = {Progress = 0, Unlocked = false }

			if totalMasteryCount == 1 then
				profile.Data.ActiveMasteryContracts[weaponName] = skinKey
			end

		end
	else

		for weaponName, _ in pairs(WeaponConfig.Weapons) do
			profile.Data.SkinMasteries[skinKey][weaponName] = {Progress = 0, Unlocked = false }

			if totalMasteryCount == 1 then
				profile.Data.ActiveMasteryContracts[weaponName] = skinKey
			end

		end
	end
	--------------------
end

function SkinMastery.SetActiveMastery(player : Player, weaponName : string, skinKey : string) : boolean

	local profile = DataStatsManager.ActivePlayers[player]
	if not profile then return false, "Profile not loaded!" end

	if not profile.Data.SkinMasteries[skinKey] then
		warn(player.Name.." tried setting active mastery to a skin they don't own.")
		return false, "You don't own that skin."
	end

	local skinConfig = CosmeticsConfig.Skins[skinKey]
	if not skinConfig then
		warn(player.Name.." tried to update skin progress with a non-existent skin!")
		return false, "That skin doesn't exist."
	end

	if not profile.Data.Weapons[weaponName] then
		warn(player.Name.." tried setting activeSkinMastery to a weapon they don't own!")
		return false, "You don't own that weapon."
	end

	if not WeaponConfig.Weapons[weaponName] then
		warn(player.Name.." tried to set a mastery for a non-existent weapon!")
		return false, "That weapon doesn't exist."
	end


	profile.Data.ActiveMasteryContracts[weaponName] = skinKey
	return true, "Mastery set successfully!"

end


function SkinMastery.UpdateProgress(player : Player, weaponName : string, eventType : EventTypes, amount : number) : ()

	amount = amount or 1 -- for safety, if amount isn't specified, defaults to 1	

	local profile = DataStatsManager.ActivePlayers[player]
	if not profile then return false, "Profile not loaded!" end

	local skinKey = profile.Data.ActiveMasteryContracts[weaponName]
	if not skinKey then
		return -- player doesn't have an active contract with this weapon!
	end

	local skinData = profile.Data.SkinMasteries[skinKey]
	if not skinData then
		warn(player.Name.." doesn't own the skin but has it set in active contracts?")
		return
	end

	if skinData[weaponName].Unlocked then
		return -- unlocked already, just return
	end	

	local skinConfig = CosmeticsConfig.Skins[skinKey]
	if not skinConfig then
		warn(player.Name.." tried to update skin progress with a non-existent skin!")
		return
	end

	if not WeaponConfig.Weapons[weaponName] then
		warn(player.Name.." is trying to update skin progress with a non-existent weapon!")
		return
	end

	local configEventType = skinConfig.Contract.EventType
	if configEventType ~= eventType then
		warn(string.format("Event type for skin is wrong : %s / %s", configEventType, eventType))
		return
	end

	skinData[weaponName].Progress += amount

	if skinData[weaponName].Progress >= skinConfig.Contract.Goal then
		SkinMastery.ContractComplete(player, weaponName, skinKey)		
	end

end

function SkinMastery.ContractComplete(player : Player, weaponName : string, skinKey : string) : ()

	local profile = DataStatsManager.ActivePlayers[player]
	if not profile then return false, "Profile not loaded!" end

	local skinKey = profile.Data.ActiveMasteryContracts[weaponName]
	if not skinKey then
		return -- player doesn't have an active contract with this weapon!
	end

	local skinConfig = CosmeticsConfig.Skins[skinKey]
	if not skinConfig then
		warn(player.Name.." tried to update skin progress with a non-existent skin!")
		return
	end

	if not WeaponConfig.Weapons[weaponName] then
		warn(player.Name.." is trying to update skin progress with a non-existent weapon!")
		return
	end

	local skinData = profile.Data.SkinMasteries[skinKey]
	if not skinData then
		warn(player.Name.." doesn't own the skin but has it set in active contracts?")
		return
	end

	if skinData[weaponName].Unlocked then
		return -- unlocked already, just return
	end

	--------------------


	contractCompletedEvent:FireClient(player, "Skin", skinConfig.Name, weaponName)


	local function setRandomContract()

		local masterySkinsArray = {}
		for masteryName, masteryData in pairs(profile.Data.SkinMasteries) do
			if masteryName then
				if masteryData[weaponName] and masteryData[weaponName].Unlocked == true then
					continue
				end
				table.insert(masterySkinsArray, masteryName)
			end
		end

		if #masterySkinsArray < 1 then
			return -- no masteries to add to
		end

		local chosenMastery = masterySkinsArray[math.random(1, #masterySkinsArray)]

		if chosenMastery then
			SkinMastery.SetActiveMastery(player, weaponName, chosenMastery)
		end
	end

	profile.Data.ActiveMasteryContracts[weaponName] = nil
	profile.Data.SkinMasteries[skinKey][weaponName].Unlocked = true

	setRandomContract() -- sets a random contract automatically when the contract for the weapon is completed

end

local function handleProgressRequest(player : Player, weaponName : string, item : string)

	local profile = DataStatsManager.ActivePlayers[player]
	if not profile then return false, "Profile not loaded!" end

	if weaponName and not item then
		local activeMastery = profile.Data.ActiveMasteryContracts[weaponName]
		return activeMastery
	end

	local skinData = profile.Data.SkinMasteries[item]
	
	if not skinData then

		return false, false -- implies that the user doesn't own the skin
	end		

	local skinWeapon = skinData[weaponName]
		if not skinWeapon then
			warn("Couldn't find skinWeapon for :".. tostring(item))
			return
		end
	-----------

	local activeMastery = profile.Data.ActiveMasteryContracts[weaponName]

	local isActive = activeMastery and activeMastery == item -- if the value inside the weapon is the item, then it's active
	--check if active mastery exists ^^

	return skinWeapon.Progress, skinWeapon.Unlocked or false, isActive and item -- returns the item if active

end

requestSkinMasteryProgressFunction.OnServerInvoke = handleProgressRequest

requestUpdateSkinMasteryFunction.OnServerInvoke = SkinMastery.SetActiveMastery

return SkinMastery
