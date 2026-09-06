-- ============================================================
-- QuickFarm - Core.lua
-- Handles: saved variables, skinning-error detection, the actual
-- gear swap (forward + backward), combat safety, timeout failsafe.
-- See README.md for the full explanation of every piece.
-- ============================================================

-- Maps our internal slot names to the real WoW inventory slot IDs.
-- 10 = Hands (gloves), 16 = Main Hand weapon, 17 = Off Hand weapon.
QUICKFARM_SLOTID = {
	gloves    = 10,
	mainhand  = 16,
	offhand   = 17,
}

-- Slots that this server will NOT let you swap while in combat.
-- Weapons (mainhand/offhand) are fine in combat, only gloves are not.
local QUICKFARM_COMBAT_LOCKED = {
	gloves = true,
}

QuickFarm_InCombat = false

-- ------------------------------------------------------------
-- Chat helpers
-- ------------------------------------------------------------
function QuickFarm_Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99QuickFarm:|r " .. msg)
end

function QuickFarm_Error(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cffff3333QuickFarm Error:|r " .. msg)
end

-- ------------------------------------------------------------
-- Saved variables setup
-- ------------------------------------------------------------
function QuickFarm_InitDB()
	QuickFarmDB = QuickFarmDB or {}

	if QuickFarmDB.enabled == nil then
		QuickFarmDB.enabled = true
	end

	-- slots.gloves / slots.mainhand / slots.offhand each hold:
	--   { itemName = "Exact Item Name", texture = "Interface\\Icons\\..." }
	QuickFarmDB.slots = QuickFarmDB.slots or {}

	-- pending holds the info needed to swap back later:
	--   active  = true while we are currently wearing swapped gear
	--   waiting = true if a swap-back was attempted but blocked by combat
	--   slots[slotKey] = the item NAME that was equipped before the swap,
	--                    or the string "EMPTY" if nothing was equipped there.
	QuickFarmDB.pending = QuickFarmDB.pending or { active = false, waiting = false, slots = {} }
	-- forwardWaiting holds itemNames for slots that still need to be
	-- equipped because combat blocked them earlier (e.g. gloves).
	QuickFarmDB.pending.forwardWaiting = QuickFarmDB.pending.forwardWaiting or {}

	-- minimap button position (angle in degrees around the minimap)
	QuickFarmDB.minimap = QuickFarmDB.minimap or { angle = 220 }
end

-- ------------------------------------------------------------
-- Class capability check (can this class use an off-hand weapon?)
-- Only Warriors, Rogues and Hunters can. Shaman Dual Wield talent
-- does not exist on this server (per user), so Shaman is excluded too.
-- ------------------------------------------------------------
function QuickFarm_CanOffhand()
	local _, classToken = UnitClass("player")
	if classToken == "WARRIOR" or classToken == "ROGUE" or classToken == "HUNTER" then
		return true
	end
	return false
end

-- ------------------------------------------------------------
-- Bag search: find an item by exact name (case-insensitive).
-- Returns: found (true/false), texture (icon path, or nil)
-- ------------------------------------------------------------
function QuickFarm_FindItemInBags(name)
	if not name or name == "" then
		return false, nil
	end
	local lname = string.lower(name)
	for bag = 0, 4 do
		local numSlots = GetContainerNumSlots(bag)
		if numSlots and numSlots > 0 then
			for slot = 1, numSlots do
				local link = GetContainerItemLink(bag, slot)
				if link then
					local itemName = string.match(link, "%[(.-)%]")
					if itemName and string.lower(itemName) == lname then
						local texture = GetContainerItemInfo(bag, slot)
						return true, texture, bag, slot
					end
				end
			end
		end
	end
	return false, nil
end

-- ------------------------------------------------------------
-- Read what's currently equipped in a given slot, as an item name
-- (used for snapshotting before we swap, and for "EMPTY" detection).
-- ------------------------------------------------------------
local function QuickFarm_GetEquippedName(invSlot)
	local link = GetInventoryItemLink("player", invSlot)
	if not link then
		return "EMPTY"
	end
	return string.match(link, "%[(.-)%]") or "EMPTY"
end

-- ------------------------------------------------------------
-- Equip an item from the bags into a specific gear slot, by name.
-- Vanilla 1.12 has no EquipItemByName, so we pick the item up out
-- of the bag ourselves and drop it onto the paperdoll slot.
-- ------------------------------------------------------------
local function QuickFarm_EquipItemByName(name, invSlot)
	local found, _, bag, slot = QuickFarm_FindItemInBags(name)
	if not found then
		return false
	end
	PickupContainerItem(bag, slot)
	EquipCursorItem(invSlot)
	return true
end

-- ------------------------------------------------------------
-- Detects the specific "skill too low" errors for Skinning and Mining.
-- Matches:      "Requires Skinning 305"  /  "Requires Mining 305"
-- Does NOT match: "Requires Skinning Knife"  (different problem, gear swap won't help)
-- Does NOT match: "Out of range."
-- ------------------------------------------------------------
function QuickFarm_IsSkinningSkillError(msg)
	if not msg then return false end
	if string.find(msg, "^Requires Skinning %d") then
		return true
	end
	if string.find(msg, "^Requires Mining %d") then
		return true
	end
	return false
end

-- ------------------------------------------------------------
-- FORWARD SWAP: equip the configured skinning gear.
-- Snapshots whatever was equipped first, so we know what to restore.
-- ------------------------------------------------------------
function QuickFarm_DoForwardSwap()
	if not QuickFarmDB.enabled then
		return
	end
	if QuickFarmDB.pending.active then
		-- Already swapped from a previous attempt. Still double-check every
		-- configured slot actually got equipped (see QuickFarm_RetrySlots).
		QuickFarm_RetrySlots()
		return
	end

	local didSwap = false

	for slotKey, invSlot in pairs(QUICKFARM_SLOTID) do
		local cfg = QuickFarmDB.slots[slotKey]
		if cfg and cfg.itemName and cfg.itemName ~= "" then
			local found = QuickFarm_FindItemInBags(cfg.itemName)
			if not found then
				QuickFarm_Error("Could not find '" .. cfg.itemName .. "' in your bags! (" .. slotKey .. ")")
			elseif QuickFarm_InCombat and QUICKFARM_COMBAT_LOCKED[slotKey] then
				-- Can't swap this one right now (e.g. gloves in combat).
				-- Remember it and try again the moment combat ends.
				QuickFarmDB.pending.forwardWaiting[slotKey] = cfg.itemName
				QuickFarm_Print(slotKey .. " swap skipped (in combat) - will swap as soon as combat ends.")
			else
				-- Snapshot current item BEFORE swapping, every single time,
				-- so a respec/gear change during the evening is always respected.
				QuickFarmDB.pending.slots[slotKey] = QuickFarm_GetEquippedName(invSlot)
				QuickFarm_EquipItemByName(cfg.itemName, invSlot)
				QuickFarmDB.pending.forwardWaiting[slotKey] = nil
				didSwap = true
			end
		end
	end

	if didSwap or next(QuickFarmDB.pending.forwardWaiting) then
		QuickFarmDB.pending.active = true
		QuickFarmDB.pending.waiting = false
		QuickFarm_StartTimeoutTimer()
	end
end

-- ------------------------------------------------------------
-- Safety re-check: goes over gloves, mainhand AND offhand and makes
-- sure each one that has a configured item is actually wearing it.
-- This both finishes any slot combat blocked earlier (gloves) and
-- acts as a general safety net so the weapon swap is never missed.
-- ------------------------------------------------------------
function QuickFarm_RetrySlots()
	if not QuickFarmDB or not QuickFarmDB.pending or not QuickFarmDB.pending.active then
		return
	end

	for slotKey, invSlot in pairs(QUICKFARM_SLOTID) do
		local cfg = QuickFarmDB.slots[slotKey]
		if cfg and cfg.itemName and cfg.itemName ~= "" then
			local current = QuickFarm_GetEquippedName(invSlot)
			if string.lower(current) ~= string.lower(cfg.itemName) then
				if QuickFarm_InCombat and QUICKFARM_COMBAT_LOCKED[slotKey] then
					-- Still can't do this one right now.
					QuickFarmDB.pending.forwardWaiting[slotKey] = cfg.itemName
				else
					local found = QuickFarm_FindItemInBags(cfg.itemName)
					if found then
						if not QuickFarmDB.pending.slots[slotKey] then
							QuickFarmDB.pending.slots[slotKey] = current
						end
						QuickFarm_EquipItemByName(cfg.itemName, invSlot)
						if QuickFarmDB.pending.forwardWaiting[slotKey] then
							QuickFarm_Print(slotKey .. " swapped successfully now that combat has ended.")
						end
						QuickFarmDB.pending.forwardWaiting[slotKey] = nil
					end
				end
			end
		end
	end
end

-- ------------------------------------------------------------
-- BACKWARD SWAP: restore whatever was equipped before the forward swap.
-- ------------------------------------------------------------
function QuickFarm_DoBackwardSwap()
	if not QuickFarmDB or not QuickFarmDB.pending or not QuickFarmDB.pending.active then
		return
	end
	if QuickFarm_InCombat then
		QuickFarmDB.pending.waiting = true
		return
	end

	for slotKey, snapshot in pairs(QuickFarmDB.pending.slots) do
		local invSlot = QUICKFARM_SLOTID[slotKey]
		if invSlot and snapshot then
			if snapshot == "EMPTY" then
				PickupInventoryItem(invSlot)
				PutItemInBackpack()
			else
				QuickFarm_EquipItemByName(snapshot, invSlot)
			end
		end
	end

	QuickFarmDB.pending.active = false
	QuickFarmDB.pending.waiting = false
	QuickFarmDB.pending.slots = {}
	QuickFarm_CancelTimeoutTimer()
end

-- ------------------------------------------------------------
-- Timeout failsafe: if LOOT_CLOSED never fires (skin failed again,
-- you rode off, etc.) swap back on its own after TIMEOUT_SECONDS.
-- Vanilla has no C_Timer, so this uses a hidden frame's OnUpdate.
-- ------------------------------------------------------------
local TIMEOUT_SECONDS = 15
local timeoutElapsed = 0
local timeoutFrame = CreateFrame("Frame", "QuickFarmTimeoutFrame")
timeoutFrame:Hide()

timeoutFrame:SetScript("OnUpdate", function()
	timeoutElapsed = timeoutElapsed + arg1
	if timeoutElapsed >= TIMEOUT_SECONDS then
		timeoutFrame:Hide()
		timeoutElapsed = 0
		if QuickFarmDB and QuickFarmDB.pending and QuickFarmDB.pending.active then
			QuickFarm_Print("Safety timeout reached - swapping your gear back.")
			QuickFarm_DoBackwardSwap()
		end
	end
end)

function QuickFarm_StartTimeoutTimer()
	timeoutElapsed = 0
	timeoutFrame:Show()
end

function QuickFarm_CancelTimeoutTimer()
	timeoutElapsed = 0
	timeoutFrame:Hide()
end

-- ------------------------------------------------------------
-- Event handling
-- ------------------------------------------------------------
local eventFrame = CreateFrame("Frame", "QuickFarmEventFrame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("UI_ERROR_MESSAGE")
eventFrame:RegisterEvent("LOOT_CLOSED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

eventFrame:SetScript("OnEvent", function()
	if event == "ADDON_LOADED" and arg1 == "QuickFarm" then
		QuickFarm_InitDB()
		if QuickFarm_UI_Init then
			QuickFarm_UI_Init()
		end

	elseif event == "PLAYER_ENTERING_WORLD" then
		-- Recovery: if we logged out/crashed/reloaded while still wearing
		-- the swapped gear, try to put things back now.
		if QuickFarmDB and QuickFarmDB.pending and QuickFarmDB.pending.active then
			QuickFarm_Print("Found a pending gear swap from before - restoring it now.")
			QuickFarm_DoBackwardSwap()
		end

	elseif event == "UI_ERROR_MESSAGE" then
		-- On real 1.12 clients this event passes just the message as arg1.
		-- We also check arg2 in case of a differently-ordered client/emulator.
		local msg = arg1
		if type(arg1) == "number" then
			msg = arg2
		end
		if QuickFarm_IsSkinningSkillError(msg) then
			QuickFarm_DoForwardSwap()
		end

	elseif event == "LOOT_CLOSED" then
		QuickFarm_DoBackwardSwap()

	elseif event == "PLAYER_REGEN_DISABLED" then
		QuickFarm_InCombat = true

	elseif event == "PLAYER_REGEN_ENABLED" then
		QuickFarm_InCombat = false
		if QuickFarmDB and QuickFarmDB.pending and QuickFarmDB.pending.active then
			-- Combat just ended - finish any slot (gloves) that was blocked,
			-- and double check mainhand/offhand really did get swapped too.
			QuickFarm_RetrySlots()
			-- Only restore gear here if a swap-back was actually waiting on
			-- combat to end (e.g. loot closed while you got attacked).
			if QuickFarmDB.pending.waiting then
				QuickFarm_DoBackwardSwap()
			end
		end
	end
end)

-- ------------------------------------------------------------
-- Slash commands (manual safety net)
--   /qf status  - print current state
--   /qf back    - force a swap-back right now
-- ------------------------------------------------------------
SLASH_QUICKFARM1 = "/qf"
SLASH_QUICKFARM2 = "/quickfarm"
SlashCmdList["QUICKFARM"] = function(msg)
	msg = string.lower(msg or "")
	if msg == "back" then
		QuickFarm_Print("Manual swap-back requested.")
		QuickFarm_DoBackwardSwap()
	else
		QuickFarm_Print("Enabled: " .. tostring(QuickFarmDB.enabled)
			.. " | Pending swap: " .. tostring(QuickFarmDB.pending.active)
			.. " | In combat: " .. tostring(QuickFarm_InCombat))
	end
end
