-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Compatibility check: notices EllesmereUI and Naowh Forever and offers to
-- switch off the SempreUI parts that do the same job. Never switches anything
-- by itself and never touches the other addons.
-- Interface (read-only, documented here):
--   SempreUI:ShowCompat()   -- opens the window (built on first use) when
--                              there is something to show
-- Opens once by itself after login (option "compat" of the core, default on),
-- after the "what's new" window if that opens in the same login, and not in
-- combat (it waits for combat end). The detected set of addons is stored as
-- SempreDB.global.compatAnswered ("eui", "nf" or "eui,nf") once answered;
-- the window comes back only when the set differs. The window has no global
-- name. Command: /sempre vertraeglich (compat, kompatibel).

local S = SempreUI
local L = S.L
local C_AddOns, CreateFrame, GetLocale, InCombatLockdown = C_AddOns, CreateFrame, GetLocale, InCombatLockdown
local C_Timer, UIParent, ReloadUI = C_Timer, UIParent, ReloadUI
local ipairs, pairs, next, type, concat = ipairs, pairs, next, type, table.concat

local DE = GetLocale() == "deDE"
local LANG = DE and "de" or "en"
if DE then
	L.COMPAT_TITLE = "SempreUI – Doppelte Funktionen"
	L.COMPAT_INTRO = "Erkannt: %s. Diese SempreUI-Teile machen dasselbe:"
	L.COMPAT_APPLY = "Ausgewählte ausschalten"
	L.COMPAT_LATER = "Nicht jetzt"
	L.COMPAT_NEVER = "Nicht mehr fragen"
	L.COMPAT_RELOAD = "Neu laden"
	L.COMPAT_CLOSE = "Schließen"
	L.COMPAT_NONE_FOUND = "Weder EllesmereUI noch Naowh Forever gefunden."
	L.COMPAT_NONE_OPEN = "Keine doppelten Funktionen."
	L.COMPAT_DETECTED = "Erkannt: %s."
	L.COMPAT_RELOAD_NOTE = "Module wurden ausgeschaltet. Zum Abschließen /reload eingeben oder im Fenster auf Neu laden klicken."
else
	L.COMPAT_TITLE = "SempreUI – Doubled functions"
	L.COMPAT_INTRO = "Found: %s. These SempreUI parts do the same:"
	L.COMPAT_APPLY = "Switch off selected"
	L.COMPAT_LATER = "Not now"
	L.COMPAT_NEVER = "Don't ask again"
	L.COMPAT_RELOAD = "Reload"
	L.COMPAT_CLOSE = "Close"
	L.COMPAT_NONE_FOUND = "Neither EllesmereUI nor Naowh Forever found."
	L.COMPAT_NONE_OPEN = "No doubled functions."
	L.COMPAT_DETECTED = "Found: %s."
	L.COMPAT_RELOAD_NOTE = "Modules were switched off. To finish, type /reload or click Reload in the window."
end

-- Detection patterns, one place to fix. Folder names and titles are compared
-- in lower case, without colour codes and without spaces.
local OTHERS = {
	{ id = "eui", name = "EllesmereUI", patterns = { "ellesmereui" } },
	{ id = "nf", name = "Naowh Forever", patterns = { "naowhforever", "naowforever" } },
}

-- Rule table, one row per overlap.
--   addons: which other addon it applies to ("eui", "nf", or both)
--   kind: "module" (target = folder), "option" (target = module folder, key,
--         default = the option's own default) or "info" (target = module
--         folder, key, default; shows a line without a switch)
--   reload: switching the module off needs a /reload
local RULES = {
	{ addons = { nf = true }, kind = "module", target = "Sempre_Way", reload = true,
		what = { de = "Modul Wegpunkte", en = "Waypoints module" },
		why = { de = "Naowh Forever hat Wegpunkte und Routen", en = "Naowh Forever has waypoint pins and routes" } },
	{ addons = { eui = true }, kind = "module", target = "Sempre_Buttons", reload = true,
		what = { de = "Modul Minimap-Knöpfe", en = "Minimap buttons module" },
		why = { de = "EllesmereUI sammelt die Minimap-Knöpfe", en = "EllesmereUI collects minimap buttons" } },
	{ addons = { nf = true }, kind = "module", target = "Sempre_Rares", reload = true,
		what = { de = "Modul Seltene", en = "Rares module" },
		why = { de = "Naowh Forever Discovery findet Seltene", en = "Naowh Forever Discovery finds rares" } },
	{ addons = { eui = true, nf = true }, kind = "option", target = "Sempre_Butler", key = "sell", default = true,
		what = { de = "Butler: Schrott verkaufen", en = "Butler: sell junk" },
		why = { de = "Schrott verkauft schon das andere Addon", en = "Junk is already sold by the other addon" } },
	{ addons = { eui = true, nf = true }, kind = "option", target = "Sempre_Butler", key = "repair", default = true,
		what = { de = "Butler: Reparieren", en = "Butler: repair" },
		why = { de = "Repariert wird schon vom anderen Addon", en = "Repairs are already done by the other addon" } },
	{ addons = { eui = true }, kind = "option", target = "Sempre_Butler", key = "quiet", default = false,
		what = { de = "Butler: Fehlertext ausblenden", en = "Butler: hide error text" },
		why = { de = "EllesmereUI blendet den Fehlertext aus", en = "EllesmereUI hides the error text" } },
	{ addons = { eui = true }, kind = "option", target = "Sempre_Map", key = "show_coords", default = true,
		what = { de = "Karte: Koordinaten", en = "Map: coordinates" },
		why = { de = "EllesmereUI zeigt Kartenkoordinaten", en = "EllesmereUI shows map coordinates" } },
	{ addons = { nf = true }, kind = "option", target = "Sempre_Map", key = "show_explored", default = true,
		what = { de = "Karte: erkundete Gebiete", en = "Map: explored areas" },
		why = { de = "Naowh Forever zeigt unerkundete Gebiete", en = "Naowh Forever shows unexplored areas" } },
	{ addons = { nf = true }, kind = "info", target = "Sempre_Items", key = "tooltip", default = true,
		what = { de = "Gegenstände: Tooltip", en = "Items: tooltip" },
		why = { de = "Zwei Besitzerzeilen im Tooltip. Eine genügt.", en = "Two owner lines in the tooltip. Keep one." } },
}
S.CompatRules = RULES

local function pick(t)
	return t[LANG] or t.en
end

-- Detection

local function normalize(text)
	if type(text) ~= "string" then return "" end
	text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("%s", "")
	return text:lower()
end

local function matches(other, text)
	for _, prefix in ipairs(other.patterns) do
		if text:sub(1, #prefix) == prefix then return true end
	end
	return false
end

-- Set of other addons that are loaded: { eui = true, nf = true }.
local function detect()
	local found = {}
	for i = 1, C_AddOns.GetNumAddOns() do
		local folder, title = C_AddOns.GetAddOnInfo(i)
		local name = normalize(folder)
		if name ~= "" and name:sub(1, 6) ~= "sempre" and C_AddOns.IsAddOnLoaded(folder) then
			local shown = normalize(title)
			for _, other in ipairs(OTHERS) do
				if matches(other, name) or matches(other, shown) then found[other.id] = true end
			end
		end
	end
	return found
end

local function setKey(found)
	local ids = {}
	for _, other in ipairs(OTHERS) do
		if found[other.id] then ids[#ids + 1] = other.id end
	end
	return concat(ids, ",")
end

local function setNames(found)
	local names = {}
	for _, other in ipairs(OTHERS) do
		if found[other.id] then names[#names + 1] = other.name end
	end
	return concat(names, ", ")
end

-- Rules

local function installed(name)
	for _, module in ipairs(S.ModuleList()) do
		if module == name then return true end
	end
	return false
end

-- The stored value lives in the core's saved options even while the module is
-- not loaded; without one the option's own default counts.
local function storedOption(rule)
	local options = S.db and S.db.global.options
	local mod = options and options[rule.target]
	local value = mod and mod[rule.key]
	if value == nil then return rule.default end
	return value
end

-- An option of a module that is switched off does nothing, so it is not shown.
local function isOpen(rule)
	if not installed(rule.target) then return false end
	if not S.IsModuleEnabled(rule.target) then return false end
	if rule.kind == "module" then return true end
	return storedOption(rule) == true
end

local function applies(rule, found)
	for id in pairs(rule.addons) do
		if found[id] then return true end
	end
	return false
end

local function openRules(found)
	local list = {}
	for _, rule in ipairs(RULES) do
		if applies(rule, found) and isOpen(rule) then list[#list + 1] = rule end
	end
	return list
end

-- Switching. A module whose options are not registered yet (not loaded) has no
-- option definition in the core, so SetOption refuses; the saved value is then
-- written directly, in the same layout SetOption uses.
local function switchOption(rule)
	if S:SetOption(rule.target, rule.key, false) then return end
	local global = S.db.global
	if type(global.options) ~= "table" then global.options = {} end
	local mod = global.options[rule.target]
	if rule.default == false then
		if mod then
			mod[rule.key] = nil
			if next(mod) == nil then global.options[rule.target] = nil end
		end
	else
		if not mod then
			mod = {}
			global.options[rule.target] = mod
		end
		mod[rule.key] = false
	end
end

-- Window

local PLAIN = "Interface\\Buttons\\WHITE8X8"
local WIDTH, PAD, ROW_H = 480, 14, 40
local OPEN_DELAY, AFTER_NEWS_DELAY = 4, 2

local frame, ready
local state = { found = {}, key = "", rules = {} }
local rows = {}
local intro, applyButton, laterButton, neverButton, reloadButton

local function fontString(parent, role, r, g, b)
	local fs = parent:CreateFontString(nil, "OVERLAY")
	S:SetFont(fs, role)
	fs:SetTextColor(r, g, b)
	fs:SetJustifyH("LEFT")
	return fs
end

local function button(width, text)
	local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(text)
	return b
end

local function storeAnswer()
	if S.db then S.db.global.compatAnswered = state.key end
end

local function newRow()
	local row = {}
	row.check = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
	row.check:SetSize(24, 24)
	row.what = fontString(frame, "text", 0.95, 0.95, 0.95)
	row.why = fontString(frame, "text", 0.6, 0.6, 0.6)
	row.what:SetWidth(WIDTH - 2 * PAD - 30)
	row.why:SetWidth(WIDTH - 2 * PAD - 30)
	return row
end

local function showRows()
	for i, rule in ipairs(state.rules) do
		local row = rows[i]
		if not row then
			row = newRow()
			rows[i] = row
		end
		local y = PAD + 28 + 36 + (i - 1) * ROW_H
		row.rule = rule
		row.check:ClearAllPoints()
		row.check:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -y)
		row.what:ClearAllPoints()
		row.what:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + 30, -y - 2)
		row.what:SetText(pick(rule.what))
		row.why:ClearAllPoints()
		row.why:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + 30, -y - 18)
		row.why:SetText(pick(rule.why))
		row.check:SetChecked(true)
		if rule.kind == "info" then row.check:Hide() else row.check:Show() end
		row.what:Show()
		row.why:Show()
	end
	for i = #state.rules + 1, #rows do
		rows[i].rule = nil
		rows[i].check:Hide()
		rows[i].what:Hide()
		rows[i].why:Hide()
	end
	frame:SetHeight(PAD + 28 + 36 + #state.rules * ROW_H + 10 + 22 + PAD)
end

local function apply()
	local reload = false
	for _, row in ipairs(rows) do
		local rule = row.rule
		if rule and rule.kind ~= "info" and row.check:GetChecked() then
			if rule.kind == "module" then
				if S.SetModuleEnabled and S.SetModuleEnabled(rule.target, false, true) and rule.reload then reload = true end
			else
				switchOption(rule)
			end
		end
	end
	storeAnswer()
	if not reload then
		frame:Hide()
		return
	end
	S:Print(L.COMPAT_RELOAD_NOTE)
	applyButton:Hide()
	neverButton:Hide()
	laterButton:SetText(L.COMPAT_CLOSE)
	reloadButton:Show()
end

local function build()
	frame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
	frame:SetWidth(WIDTH)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
	frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
	if frame.SetBackdrop then
		frame:SetBackdrop({ bgFile = PLAIN, edgeFile = PLAIN, edgeSize = 1 })
		frame:SetBackdropColor(0.06, 0.06, 0.06, 0.92)
		frame:SetBackdropBorderColor(S.color.r, S.color.g, S.color.b, 1)
	end

	local title = fontString(frame, "title", S.color.r, S.color.g, S.color.b)
	title:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -PAD)
	title:SetText(L.COMPAT_TITLE)

	intro = fontString(frame, "text", 0.9, 0.9, 0.9)
	intro:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -PAD - 28)
	intro:SetWidth(WIDTH - 2 * PAD)

	applyButton = button(170, L.COMPAT_APPLY)
	applyButton:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, PAD)
	applyButton:SetScript("OnClick", apply)
	laterButton = button(110, L.COMPAT_LATER)
	laterButton:SetPoint("LEFT", applyButton, "RIGHT", 8, 0)
	laterButton:SetScript("OnClick", function() frame:Hide() end)
	neverButton = button(150, L.COMPAT_NEVER)
	neverButton:SetPoint("LEFT", laterButton, "RIGHT", 8, 0)
	neverButton:SetScript("OnClick", function()
		storeAnswer()
		frame:Hide()
	end)
	-- Appears in place of the other two after modules were switched off.
	reloadButton = button(110, L.COMPAT_RELOAD)
	reloadButton:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, PAD)
	reloadButton:SetScript("OnClick", function()
		if ReloadUI then ReloadUI() end
	end)
	reloadButton:Hide()

	S.compatFrame = frame
	ready = true
end

-- Opens with the current rules; the answer is compared with the set found now.
local function show(found, list)
	if not ready then build() end
	state.found, state.key, state.rules = found, setKey(found), list
	intro:SetText(L.COMPAT_INTRO:format(setNames(found)))
	laterButton:SetText(L.COMPAT_LATER)
	applyButton:Show()
	neverButton:Show()
	reloadButton:Hide()
	showRows()
	frame:Show()
end

local detected = {}

function S:ShowCompat()
	local found = detect()
	local list = openRules(found)
	if #list == 0 then return false end
	show(found, list)
	return true
end

-- Automatic opening

local started, waitingCombat, waitingNews

local function answered(found)
	local global = S.db and S.db.global
	return global ~= nil and global.compatAnswered == setKey(found)
end

local attempt

local function onCombatEnd()
	S:Off("PLAYER_REGEN_ENABLED", onCombatEnd)
	waitingCombat = false
	attempt()
end

local function onNewsClosed()
	S:Unlisten("NEWS_CLOSED", onNewsClosed)
	waitingNews = false
	if C_Timer and C_Timer.After then
		C_Timer.After(AFTER_NEWS_DELAY, attempt)
	else
		attempt()
	end
end

function attempt()
	if S.NewsBusy and S:NewsBusy() then
		if not waitingNews then
			waitingNews = true
			S:Listen("NEWS_CLOSED", onNewsClosed)
		end
		return
	end
	if InCombatLockdown() then
		if not waitingCombat then
			waitingCombat = true
			S:On("PLAYER_REGEN_ENABLED", onCombatEnd)
		end
		return
	end
	if answered(detected) then return end
	local list = openRules(detected)
	if #list > 0 then show(detected, list) end
end

-- Decided at login (the other addons are loaded by then); the window itself
-- opens a moment after entering the world.
S:On("PLAYER_LOGIN", function()
	detected = detect()
	started = S:GetOption("Sempre", "compat") and next(detected) ~= nil
end)

local entered
S:On("PLAYER_ENTERING_WORLD", function()
	if entered then return end
	entered = true
	if not started then return end
	if C_Timer and C_Timer.After then
		C_Timer.After(OPEN_DELAY, attempt)
	else
		attempt()
	end
end)

-- Command: lists what was found, then opens the window even if it was answered.
S.commands.vertraeglich = function()
	local found = detect()
	if next(found) == nil then
		S:Print(L.COMPAT_NONE_FOUND)
		return
	end
	S:Print(L.COMPAT_DETECTED, setNames(found))
	local list = openRules(found)
	if #list == 0 then
		S:Print(L.COMPAT_NONE_OPEN)
		return
	end
	for _, rule in ipairs(list) do
		print("  " .. pick(rule.what) .. ": " .. pick(rule.why))
	end
	show(found, list)
end
S.commands.compat = S.commands.vertraeglich
S.commands.kompatibel = S.commands.vertraeglich
