-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Sempre_Buttons: minimap button collector, part 1. Buttons that other addons
-- put around the minimap are moved (reparented and re-anchored, nothing else)
-- into a panel behind one SempreUI button. Nothing of the other addons is
-- hooked or changed; their own size, scripts, tooltips and textures stay.
--
-- Interface on SempreUI.Buttons (read-only):
--   GetCollected() -> list of frame names currently in the panel, sorted
--   GetOutside()   -> list of frame names on the "keep outside" list, sorted
-- Message BUTTONS_CHANGED(count) after each scan.
-- Data: SempreButtonsDB = { version, angle, outside = { [frameName] = true } }.

local ADDON_NAME = ...

local S = SempreUI
local ipairs, pairs, type, format, floor, tonumber, pcall = ipairs, pairs, type, string.format, math.floor, tonumber, pcall
local sort, tremove = table.sort, table.remove
local cos, sin, atan2, rad, deg, max, min, abs = math.cos, math.sin, math.atan2, math.rad, math.deg, math.max, math.min, math.abs
local issecretvalue, InCombatLockdown = issecretvalue, InCombatLockdown
local C_Timer, C_EventUtils = C_Timer, C_EventUtils
local CreateFrame, GetLocale, GetCursorPosition = CreateFrame, GetLocale, GetCursorPosition

local Buttons = {}
S.Buttons = Buttons

local L = setmetatable({}, { __index = function(_, k) return k end })
Buttons.L = L
if GetLocale() == "deDE" then
	L.TITLE = "SempreUI"
	L.COLLECTED = "%d Knöpfe gesammelt"
	L.HINT_LEFT = "Linksklick: Knopffeld öffnen oder schließen"
	L.HINT_RIGHT = "Rechtsklick: SempreUI-Einstellungen"
	L.HINT_DRAG = "Ziehen: Knopf um die Minikarte bewegen"
	L.NO_MINIMAP = "Buttons: Die Minikarte ist in diesem Client nicht verfügbar, das Modul bleibt aus."
	L.IN_COMBAT = "Buttons: Das geht erst nach dem Kampf."
	L.USAGE = "Benutzung: |cffc8794a/sempre knoepfe|r, |cffc8794a/sempre knoepfe raus <Nr|Name>|r, |cffc8794a/sempre knoepfe rein <Nr|Name>|r, |cffc8794a/sempre knoepfe neu|r, |cffc8794a/sempre knoepfe zeigen|r."
	L.LIST_HEADER = "Minikarten-Knöpfe: %d im Feld, %d außen gehalten."
	L.LIST_NONE = "Buttons: Keine Knöpfe gefunden."
	L.ROW_IN = "%d. %s"
	L.ROW_OUT = "%d. %s (außen)"
	L.NO_SUCH = "Buttons: Knopf %s gibt es nicht."
	L.NOT_COLLECTED = "Buttons: %s ist nicht im Feld."
	L.NOT_OUTSIDE = "Buttons: %s ist nicht auf der Außen-Liste."
	L.MOVED_OUT = "Buttons: %s bleibt jetzt außen."
	L.MOVED_IN = "Buttons: %s kommt wieder ins Feld."
	L.RESCANNED = "Buttons: %d Knöpfe im Feld."
else
	L.TITLE = "SempreUI"
	L.COLLECTED = "%d buttons collected"
	L.HINT_LEFT = "Left click: open or close the button panel"
	L.HINT_RIGHT = "Right click: SempreUI settings"
	L.HINT_DRAG = "Drag: move the button around the minimap"
	L.NO_MINIMAP = "Buttons: the minimap is not available in this client, the module stays off."
	L.IN_COMBAT = "Buttons: that works after combat."
	L.USAGE = "Usage: |cffc8794a/sempre buttons|r, |cffc8794a/sempre buttons out <n|name>|r, |cffc8794a/sempre buttons in <n|name>|r, |cffc8794a/sempre buttons rescan|r, |cffc8794a/sempre buttons show|r."
	L.LIST_HEADER = "Minimap buttons: %d in the panel, %d kept outside."
	L.LIST_NONE = "Buttons: no buttons found."
	L.ROW_IN = "%d. %s"
	L.ROW_OUT = "%d. %s (outside)"
	L.NO_SUCH = "Buttons: there is no button %s."
	L.NOT_COLLECTED = "Buttons: %s is not in the panel."
	L.NOT_OUTSIDE = "Buttons: %s is not on the outside list."
	L.MOVED_OUT = "Buttons: %s stays outside now."
	L.MOVED_IN = "Buttons: %s goes back into the panel."
	L.RESCANNED = "Buttons: %d buttons in the panel."
end

local MIN_SIZE, MAX_SIZE = 20, 40 -- accepted button size in px
local MAX_COLS = 6
local GAP = 4
local PAD = 4
local BUTTON_SIZE = 32
local EDGE_OFFSET = 5 -- px outside the minimap radius
local DEFAULT_ANGLE = 225
local ICON = "Interface\\AddOns\\Sempre\\Media\\Icon"
local PLAIN = "Interface\\Buttons\\WHITE8X8"
local LATE_SCAN = 5 -- seconds after the first scan, for slow addons

-- Frames the game itself puts around the minimap. Names starting with one of
-- these prefixes are skipped; the exact names below are the game frames of the
-- current client that do not carry such a prefix. Assumption: the list comes
-- from the briefing and the known minimap layout, not from a client dump.
local SKIP_PREFIXES = { "Minimap", "MiniMap", "GameTime", "TimeManager", "Queue", "Expansion", "Garrison", "Tracking", "Mail" }
local SKIP_NAMES = {
	AddonCompartmentFrame = true,
	StreamingIcon = true,
	GuildInstanceDifficulty = true,
	HybridMinimap = true,
	ZoneTextFrame = true,
	ZoneTextString = true,
	SubZoneTextFrame = true,
	BattlefieldMapTab = true,
	ExpansionLandingPageMinimapButton = true,
	LFGMinimapFrame = true,
	DurabilityFrame = true,
	WorldMapFrame = true,
}
local HOLDERS = { "MinimapCluster", "MinimapBackdrop" }

local db
local minimap
local button, panel
local collected = {} -- entries sorted by name, in the panel
local known = {} -- name -> entry, every frame ever collected this session
local pendingScan = false
local pendingRelease = {}
local firstWorld = true

-- Helpers

local function clean(v)
	if issecretvalue and issecretvalue(v) then return nil end
	return v
end

local function isNum(v)
	v = clean(v)
	return type(v) == "number" and v == v
end

local function lowerName(e) return e.name:lower() end

local function sortEntries(list)
	sort(list, function(a, b)
		local la, lb = lowerName(a), lowerName(b)
		if la ~= lb then return la < lb end
		return a.name < b.name
	end)
end

local function sortedNames(set)
	local out = {}
	for name in pairs(set) do out[#out + 1] = name end
	sort(out, function(a, b)
		local la, lb = a:lower(), b:lower()
		if la ~= lb then return la < lb end
		return a < b
	end)
	return out
end

local function blockedName(name)
	if SKIP_NAMES[name] then return true end
	for _, prefix in ipairs(SKIP_PREFIXES) do
		if name:sub(1, #prefix) == prefix then return true end
	end
	return false
end

-- Reads a frame's facts; false when it is not a usable candidate. Wrapped in
-- pcall by the caller, a strange frame must never break the scan.
local function inspect(f)
	if f == button or f == panel then return false end
	local name = f:GetName()
	if type(name) ~= "string" or name == "" or issecretvalue and issecretvalue(name) then return false end
	if blockedName(name) or db.outside[name] then return false end
	if f.IsProtected then
		local protected = f:IsProtected()
		if issecretvalue and issecretvalue(protected) then return false end
		if protected then return false end
	end
	local w, h = f:GetSize()
	if not (isNum(w) and isNum(h)) then return false end
	if w < MIN_SIZE or w > MAX_SIZE or h < MIN_SIZE or h > MAX_SIZE then return false end
	local clickable = f.GetObjectType and f:GetObjectType() == "Button"
	if not clickable and f.HasScript and f.GetScript then
		for _, kind in ipairs({ "OnClick", "OnMouseUp" }) do
			if f:HasScript(kind) and f:GetScript(kind) then clickable = true break end
		end
	end
	if not clickable then return false end
	return name
end

local function savePoints(f)
	local points = {}
	for i = 1, f:GetNumPoints() do
		local point, rel, relPoint, x, y = f:GetPoint(i)
		points[#points + 1] = { point, rel, relPoint, x, y }
	end
	return points
end

-- The SempreUI button

local function squareShape()
	if not GetMinimapShape then return false end
	local ok, shape = pcall(GetMinimapShape)
	return ok and shape == "SQUARE"
end

local function placeButton()
	if not (button and minimap) then return end
	local angle = rad(db.angle)
	local radius = (minimap:GetWidth() or 140) / 2 + EDGE_OFFSET
	local dx, dy = cos(angle), sin(angle)
	if squareShape() then
		local m = max(abs(dx), abs(dy))
		if m > 0 then dx, dy = dx / m, dy / m end
	end
	button:ClearAllPoints()
	button:SetPoint("CENTER", minimap, "CENTER", dx * radius, dy * radius)
end

local function applyButtonVisibility()
	if not button then return end
	if S:GetOption(ADDON_NAME, "show_button") then
		button:Show()
	else
		button:Hide()
	end
end

local function dragUpdate()
	local mx, my = minimap:GetCenter()
	local cx, cy = GetCursorPosition()
	if not (isNum(mx) and isNum(my) and isNum(cx) and isNum(cy)) then return end
	local scale = minimap:GetEffectiveScale() or 1
	local angle = deg(atan2(cy / scale - my, cx / scale - mx))
	db.angle = angle % 360
	placeButton()
end

-- The panel

local function cellSize()
	local size = MIN_SIZE
	for _, e in ipairs(collected) do
		local w, h = e.frame:GetSize()
		if isNum(w) then size = max(size, min(w, MAX_SIZE)) end
		if isNum(h) then size = max(size, min(h, MAX_SIZE)) end
	end
	return size
end

-- Puts every collected button into its grid cell. Called on every open, so a
-- button that moved itself away is put back; never called in combat.
local function layout()
	local n = #collected
	local cols = min(MAX_COLS, max(n, 1))
	local rows = floor((max(n, 1) - 1) / cols) + 1
	local cell = cellSize()
	panel:SetSize(PAD * 2 + cols * cell + (cols - 1) * GAP, PAD * 2 + rows * cell + (rows - 1) * GAP)
	local strata, level = panel:GetFrameStrata(), panel:GetFrameLevel()
	for i, e in ipairs(collected) do
		local f = e.frame
		local col, row = (i - 1) % cols, floor((i - 1) / cols)
		if f:GetParent() ~= panel then f:SetParent(panel) end
		f:SetFrameStrata(strata)
		f:SetFrameLevel(level + 2)
		f:ClearAllPoints()
		f:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD + col * (cell + GAP), -(PAD + row * (cell + GAP)))
	end
end

local function anchorPanel()
	local target = (button and button:IsShown()) and button or minimap
	local cx, cy = target:GetCenter()
	local ux, uy = UIParent:GetCenter()
	local left = not (isNum(cx) and isNum(ux)) or cx < ux
	local top = not (isNum(cy) and isNum(uy)) or cy > uy
	local horiz = left and "LEFT" or "RIGHT"
	panel:ClearAllPoints()
	panel:SetPoint((top and "TOP" or "BOTTOM") .. horiz, target, (top and "BOTTOM" or "TOP") .. horiz, 0, top and -GAP or GAP)
end

local function closePanel()
	if panel and panel:IsShown() then panel:Hide() end
end

local function openPanel()
	if InCombatLockdown() then
		S:Print(L.IN_COMBAT)
		return
	end
	layout()
	anchorPanel()
	panel:Show()
end

local function togglePanel()
	if panel:IsShown() then closePanel() else openPanel() end
end

-- Collecting and releasing

local function collect(f, name)
	local e = known[name]
	if not e or e.frame ~= f then
		e = { name = name, frame = f }
		known[name] = e
	end
	if not e.collected then
		-- Original place, taken while the frame is at home.
		e.parent = f:GetParent()
		e.points = savePoints(f)
		e.strata = f:GetFrameStrata()
		e.level = f:GetFrameLevel()
		e.collected = true
		collected[#collected + 1] = e
	end
	f:SetParent(panel)
end

local function restore(e)
	local f = e.frame
	f:SetParent(e.parent)
	f:ClearAllPoints()
	for _, p in ipairs(e.points) do
		f:SetPoint(p[1], p[2], p[3], p[4], p[5])
	end
	f:SetFrameStrata(e.strata)
	f:SetFrameLevel(e.level)
	e.collected = false
end

local function release(e)
	for i, other in ipairs(collected) do
		if other == e then tremove(collected, i) break end
	end
	if InCombatLockdown() then
		pendingRelease[e] = true
		return
	end
	restore(e)
end

local function children(parent, found)
	if not (parent and parent.GetChildren) then return end
	for _, kid in ipairs({ parent:GetChildren() }) do
		found[#found + 1] = kid
	end
end

local function scan()
	if not panel then return end
	if InCombatLockdown() then
		pendingScan = true
		return
	end
	pendingScan = false
	local found = {}
	children(minimap, found)
	for _, holderName in ipairs(HOLDERS) do
		local holder = _G[holderName]
		if holder and holder ~= minimap then children(holder, found) end
	end
	local changed = false
	for _, f in ipairs(found) do
		local ok, name = pcall(inspect, f)
		if ok and name then
			collect(f, name)
			changed = true
		end
	end
	if changed then
		sortEntries(collected)
		layout()
	end
	Buttons.count = #collected
	S:Send("BUTTONS_CHANGED", #collected)
end

local function afterCombat()
	if InCombatLockdown() then return end
	for e in pairs(pendingRelease) do
		pendingRelease[e] = nil
		restore(e)
	end
	if pendingScan then scan() end
end

-- Mouse handling: a click that ends over a collected button (with the option)
-- or over the minimap outside the panel closes the panel. The close waits one
-- frame so the button still receives its own click first.
local function laterClose()
	if C_Timer and C_Timer.After then
		C_Timer.After(0, closePanel)
	else
		closePanel()
	end
end

local function onMouseUp()
	if not (panel and panel:IsShown()) then return end
	if button and button:IsShown() and button:IsMouseOver() then return end
	if panel:IsMouseOver() then
		if S:GetOption(ADDON_NAME, "close_on_click") then
			for _, e in ipairs(collected) do
				if e.frame:IsMouseOver() then laterClose() return end
			end
		end
		return
	end
	if minimap:IsMouseOver() then laterClose() end
end

-- Commands

local function rows()
	local out = {}
	for _, e in ipairs(collected) do out[#out + 1] = { name = e.name, entry = e } end
	for _, name in ipairs(sortedNames(db.outside)) do out[#out + 1] = { name = name, outside = true } end
	return out
end

local function find(arg)
	if arg == "" then return end
	local list = rows()
	local n = tonumber(arg)
	if n then return list[n], arg end
	local lower = arg:lower()
	for _, row in ipairs(list) do
		if row.name:lower() == lower then return row, arg end
	end
	return nil, arg
end

local function printList()
	local list = rows()
	if #list == 0 then
		S:Print(L.LIST_NONE)
		return
	end
	S:Print(L.LIST_HEADER, #collected, #list - #collected)
	for i, row in ipairs(list) do
		print(format(row.outside and L.ROW_OUT or L.ROW_IN, i, row.name))
	end
end

local function moveOut(arg)
	local row, text = find(arg)
	if not row then
		S:Print(arg == "" and L.USAGE or L.NO_SUCH, text)
		return
	end
	if row.outside then
		S:Print(L.NOT_COLLECTED, row.name)
		return
	end
	db.outside[row.name] = true
	release(row.entry)
	if panel:IsShown() then layout() end
	S:Print(L.MOVED_OUT, row.name)
	S:Send("BUTTONS_CHANGED", #collected)
end

local function moveIn(arg)
	local row, text = find(arg)
	if not row then
		S:Print(arg == "" and L.USAGE or L.NO_SUCH, text)
		return
	end
	if not row.outside then
		S:Print(L.NOT_OUTSIDE, row.name)
		return
	end
	db.outside[row.name] = nil
	S:Print(L.MOVED_IN, row.name)
	scan()
end

local function command(input)
	if not db then return end
	local sub, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
	sub = sub:lower()
	if sub == "" then
		printList()
	elseif sub == "raus" or sub == "out" then
		moveOut(rest)
	elseif sub == "rein" or sub == "in" then
		moveIn(rest)
	elseif sub == "neu" or sub == "rescan" then
		scan()
		S:Print(L.RESCANNED, #collected)
	elseif sub == "zeigen" or sub == "show" then
		togglePanel()
	else
		S:Print(L.USAGE)
	end
end
S.commands.knoepfe = command
S.commands.buttons = command

-- Interface

function Buttons.GetCollected()
	local out = {}
	for i, e in ipairs(collected) do out[i] = e.name end
	return out
end

function Buttons.GetOutside()
	return sortedNames(db and db.outside or {})
end

-- Setup

local function build()
	panel = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
	panel:SetFrameStrata("DIALOG")
	panel:SetClampedToScreen(true)
	panel:EnableMouse(true)
	if panel.SetBackdrop then
		panel:SetBackdrop({ bgFile = PLAIN, edgeFile = PLAIN, edgeSize = 1 })
		panel:SetBackdropColor(0.06, 0.06, 0.06, 0.92)
		panel:SetBackdropBorderColor(0.78, 0.47, 0.29, 1)
	end
	panel:Hide()
	Buttons.panel = panel

	button = CreateFrame("Button", nil, minimap)
	button:SetSize(BUTTON_SIZE, BUTTON_SIZE)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetAllPoints()
	icon:SetTexture(ICON)
	button.icon = icon
	button:SetHighlightTexture(PLAIN)
	local hl = button:GetHighlightTexture()
	if hl then hl:SetAlpha(0.15) end
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")
	button:SetScript("OnClick", function(_, mouse)
		if mouse == "RightButton" then
			if S.OpenSettings then S.OpenSettings() end
		else
			togglePanel()
		end
	end)
	button:SetScript("OnDragStart", function(self)
		GameTooltip:Hide()
		self:SetScript("OnUpdate", dragUpdate)
	end)
	button:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
		dragUpdate()
	end)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine(L.TITLE, 0.78, 0.47, 0.29)
		GameTooltip:AddLine(format(L.COLLECTED, #collected), 1, 1, 1)
		GameTooltip:AddLine(L.HINT_LEFT, 0.7, 0.7, 0.7)
		GameTooltip:AddLine(L.HINT_RIGHT, 0.7, 0.7, 0.7)
		GameTooltip:AddLine(L.HINT_DRAG, 0.7, 0.7, 0.7)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function() GameTooltip:Hide() end)
	Buttons.button = button
	placeButton()
	applyButtonVisibility()
end

local function onOptional(event, fn)
	if C_EventUtils and C_EventUtils.IsEventValid and not C_EventUtils.IsEventValid(event) then return false end
	return S:On(event, fn)
end

local function onLoaded(_, name)
	if name ~= ADDON_NAME then return end
	S:Off("ADDON_LOADED", onLoaded)
	SempreButtonsDB = SempreButtonsDB or {}
	db = SempreButtonsDB
	db.version = db.version or 1
	if type(db.outside) ~= "table" then db.outside = {} end
	if not isNum(db.angle) then db.angle = DEFAULT_ANGLE end

	S:RegisterOptions(ADDON_NAME, {
		{
			key = "close_on_click", default = true,
			label = { de = "Panel schließt nach einem Klick auf einen Knopf", en = "Close the panel after clicking a button" },
			tooltip = { de = "Das Knopffeld schließt sich, sobald du einen gesammelten Knopf anklickst.", en = "The panel closes as soon as you click a collected button." },
		},
		{
			key = "show_button", default = true,
			label = { de = "SempreUI-Knopf an der Minikarte", en = "SempreUI button on the minimap" },
			tooltip = { de = "Aus: Der Knopf verschwindet, das Feld erreichst du mit /sempre knoepfe zeigen.", en = "Off: the button is hidden, reach the panel with /sempre buttons show." },
		},
	})

	minimap = Minimap
	if not (minimap and minimap.GetChildren and CreateFrame) then
		S:Print(L.NO_MINIMAP)
		return
	end
	build()
	Buttons.minimap = minimap

	S:Listen("OPTION_CHANGED", function(_, moduleName, key)
		if moduleName ~= ADDON_NAME then return end
		if key == "show_button" then applyButtonVisibility() end
	end)

	S:On("PLAYER_ENTERING_WORLD", function()
		if not firstWorld then return end
		firstWorld = false
		scan()
		if C_Timer and C_Timer.After then C_Timer.After(LATE_SCAN, scan) end
	end)
	S:On("PLAYER_REGEN_DISABLED", closePanel)
	S:On("PLAYER_REGEN_ENABLED", afterCombat)
	if not onOptional("GLOBAL_MOUSE_UP", onMouseUp) and minimap.HookScript then
		-- Older clients: at least a click on the minimap closes the panel.
		minimap:HookScript("OnMouseUp", function()
			if panel:IsShown() and not panel:IsMouseOver() then closePanel() end
		end)
	end
end
S:On("ADDON_LOADED", onLoaded)
