-- ============================================================
-- QuickFarm - UI.lua
-- Handles: minimap button, its dropdown menu, and the popup
-- window used to type in an item name for each slot.
-- All frames are created once, inside QuickFarm_UI_Init(),
-- which Core.lua calls right after the saved variables are ready.
-- ============================================================

local uiCreated = false

-- These are declared here (file scope) so multiple functions
-- in this file can see them, but they don't exist as globals.
local minimapButton, icon, dropdown, popup, popupIcon, popupTitle, popupEditBox, popupError
local currentSlotKey

-- ------------------------------------------------------------
-- Minimap button positioning
-- ------------------------------------------------------------
local function QuickFarm_UpdateMinimapPos()
	local angle = QuickFarmDB.minimap.angle or 220
	local rad = math.rad(angle)
	local x = math.cos(rad) * 80
	local y = math.sin(rad) * 80
	minimapButton:ClearAllPoints()
	minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function QuickFarm_UpdateMinimapIcon()
	if QuickFarmDB.enabled then
		icon:SetVertexColor(1, 1, 1)
	else
		icon:SetVertexColor(0.4, 0.4, 0.4)
	end
end

local function QuickFarm_Minimap_OnUpdate()
	local mx, my = GetCursorPosition()
	local scale = Minimap:GetEffectiveScale()
	mx, my = mx / scale, my / scale
	local cx, cy = Minimap:GetCenter()
	local angle = math.deg(math.atan2(my - cy, mx - cx))
	QuickFarmDB.minimap.angle = angle
	QuickFarm_UpdateMinimapPos()
end

-- ------------------------------------------------------------
-- Popup window (used by "Set Gloves / Mainhand / Offhand")
-- ------------------------------------------------------------
local function QuickFarm_CreatePopup()
	popup = CreateFrame("Frame", "QuickFarmPopup", UIParent)
	popup:SetWidth(260)
	popup:SetHeight(130)
	popup:SetPoint("CENTER", 0, 0)
	popup:SetFrameStrata("DIALOG")
	popup:EnableMouse(true)
	popup:SetMovable(true)
	popup:RegisterForDrag("LeftButton")
	popup:SetScript("OnDragStart", function() this:StartMoving() end)
	popup:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
	popup:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	popup:Hide()

	local closeBtn = CreateFrame("Button", nil, popup, "UIPanelCloseButton")
	closeBtn:SetPoint("TOPRIGHT", -4, -4)
	closeBtn:SetScript("OnClick", function() popup:Hide() end)

	popupTitle = popup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	popupTitle:SetPoint("TOP", 0, -16)

	popupIcon = popup:CreateTexture(nil, "ARTWORK")
	popupIcon:SetWidth(24)
	popupIcon:SetHeight(24)
	popupIcon:SetPoint("TOPLEFT", 20, -42)
	popupIcon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")

	popupEditBox = CreateFrame("EditBox", "QuickFarmEditBox", popup, "InputBoxTemplate")
	popupEditBox:SetWidth(160)
	popupEditBox:SetHeight(20)
	popupEditBox:SetPoint("LEFT", popupIcon, "RIGHT", 12, 0)
	popupEditBox:SetAutoFocus(false)
	popupEditBox:SetScript("OnEnterPressed", function() this:ClearFocus() QuickFarm_Popup_OnSet() end)

	popupError = popup:CreateFontString(nil, "OVERLAY", "GameFontRedSmall")
	popupError:SetPoint("TOP", popupIcon, "BOTTOM", 60, -14)
	popupError:SetWidth(220)
	popupError:Hide()

	local setBtn = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
	setBtn:SetWidth(70)
	setBtn:SetHeight(22)
	setBtn:SetText("Set")
	setBtn:SetPoint("BOTTOM", 0, 16)
	setBtn:SetScript("OnClick", function() QuickFarm_Popup_OnSet() end)
end

-- Called by the "Set" button (and Enter key) in the popup.
function QuickFarm_Popup_OnSet()
	local name = popupEditBox:GetText()
	if not name or name == "" then
		return
	end
	local found, texture = QuickFarm_FindItemInBags(name)
	if not found then
		popupError:SetText("Item not found in your bags!")
		popupError:Show()
		return
	end
	QuickFarmDB.slots[currentSlotKey] = { itemName = name, texture = texture }
	popupIcon:SetTexture(texture)
	popupError:Hide()
	QuickFarm_Print("Saved '" .. name .. "' for " .. currentSlotKey .. ".")
end

-- Opens the popup for a given slot ("gloves", "mainhand", "offhand"),
-- pre-filling it with whatever is already saved.
function QuickFarm_OpenPopup(slotKey)
	currentSlotKey = slotKey
	popupTitle:SetText("Set item for: " .. slotKey)
	popupError:Hide()

	local saved = QuickFarmDB.slots[slotKey]
	if saved and saved.itemName then
		popupEditBox:SetText(saved.itemName)
		popupIcon:SetTexture(saved.texture or "Interface\\Icons\\INV_Misc_QuestionMark")
	else
		popupEditBox:SetText("")
		popupIcon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
	end

	popup:Show()
end

-- ------------------------------------------------------------
-- Dropdown menu (left-click on the minimap button)
-- ------------------------------------------------------------
local function QuickFarm_Dropdown_Initialize()
	local info = {}

	info.text = "Set Gloves"
	info.func = function() QuickFarm_OpenPopup("gloves") end
	info.notCheckable = 1
	UIDropDownMenu_AddButton(info)

	info = {}
	info.text = "Set Mainhand"
	info.func = function() QuickFarm_OpenPopup("mainhand") end
	info.notCheckable = 1
	UIDropDownMenu_AddButton(info)

	info = {}
	info.text = "Set Offhand"
	info.func = function() QuickFarm_OpenPopup("offhand") end
	info.notCheckable = 1
	info.disabled = not QuickFarm_CanOffhand()
	UIDropDownMenu_AddButton(info)
end

-- ------------------------------------------------------------
-- Minimap button itself
-- ------------------------------------------------------------
local function QuickFarm_CreateMinimapButton()
	minimapButton = CreateFrame("Button", "QuickFarmMinimapButton", Minimap)
	minimapButton:SetWidth(31)
	minimapButton:SetHeight(31)
	minimapButton:SetFrameStrata("MEDIUM")
	minimapButton:SetFrameLevel(8)
	minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	minimapButton:RegisterForDrag("LeftButton")

	icon = minimapButton:CreateTexture(nil, "BACKGROUND")
	icon:SetWidth(20)
	icon:SetHeight(20)
	icon:SetTexture("Interface\\Icons\\INV_Misc_Pelt_Wolf_01")
	icon:SetPoint("CENTER", 0, 1)

	local border = minimapButton:CreateTexture(nil, "OVERLAY")
	border:SetWidth(54)
	border:SetHeight(54)
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetPoint("TOPLEFT", 0, 0)

	minimapButton:SetScript("OnDragStart", function()
		this:SetScript("OnUpdate", QuickFarm_Minimap_OnUpdate)
	end)
	minimapButton:SetScript("OnDragStop", function()
		this:SetScript("OnUpdate", nil)
	end)

	minimapButton:SetScript("OnClick", function()
		if arg1 == "RightButton" then
			QuickFarmDB.enabled = not QuickFarmDB.enabled
			QuickFarm_Print(QuickFarmDB.enabled and "Enabled." or "Disabled.")
			QuickFarm_UpdateMinimapIcon()
		else
			ToggleDropDownMenu(1, nil, dropdown, "QuickFarmMinimapButton", 0, 0)
		end
	end)

	minimapButton:SetScript("OnEnter", function()
		GameTooltip:SetOwner(this, "ANCHOR_LEFT")
		GameTooltip:SetText("QuickFarm")
		GameTooltip:AddLine("Left-click: menu", 1, 1, 1)
		GameTooltip:AddLine("Right-click: enable/disable", 1, 1, 1)
		GameTooltip:Show()
	end)
	minimapButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
end

-- ------------------------------------------------------------
-- Entry point, called once from Core.lua after saved vars load.
-- ------------------------------------------------------------
function QuickFarm_UI_Init()
	if uiCreated then
		return
	end
	uiCreated = true

	QuickFarm_CreateMinimapButton()
	QuickFarm_CreatePopup()

	dropdown = CreateFrame("Frame", "QuickFarmDropDown", UIParent, "UIDropDownMenuTemplate")
	UIDropDownMenu_Initialize(dropdown, QuickFarm_Dropdown_Initialize, "MENU")

	QuickFarm_UpdateMinimapPos()
	QuickFarm_UpdateMinimapIcon()
end
