-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Settings window: one category "SempreUI" in the game's settings menu with a
-- switch per module, plus one subpage per module that registered options.
-- Also the slash fallback: /sempre modul, /sempre optionen.
-- Registered at login (never before), through the vertical-layout category if
-- the client has it, else through a small canvas page, else chat only.

local ADDON_NAME = ...

local S = SempreUI
local L = S.L
local C_AddOns, GetLocale, InCombatLockdown = C_AddOns, GetLocale, InCombatLockdown
local ipairs, type, pcall, tostring = ipairs, type, pcall, tostring
local sort = table.sort

local DE = GetLocale() == "deDE"
if DE then
	L.SETTINGS_TITLE = "SempreUI"
	L.GENERAL = "Allgemein"
	L.MODULES = "Module"
	L.ON = "an"
	L.STATE_LOADED = "geladen"
	L.STATE_OFF = "aus"
	L.STATE_RELOAD = "nach /reload"
	L.RELOAD = "Neu laden"
	L.RELOAD_TIP = "Lädt die Oberfläche neu, damit abgeschaltete Module nicht mehr laufen."
	L.NOT_LOADED_TIP = "Nicht geladen. Die Optionen erscheinen, sobald das Modul läuft."
	L.OPTIONS_TIP = "Optionen: Unterseite %s."
	L.MODULE_LINE = "%s: %s"
	L.MODULE_HINT = "Schalten mit |cffc8794a/sempre modul <Name> an|aus|r, Einstellungen mit |cffc8794a/sempre optionen|r."
	L.NO_SUCH_MODULE = "Kein Modul namens %s. /sempre modul listet alle."
	L.MODULE_USAGE = "Benutzung: /sempre modul <Name> an|aus"
	L.NO_ENABLE_API = "Dieser Client kann Module nicht per Addon-Schnittstelle schalten."
	L.NO_SETTINGS_API = "Dieser Client hat keine Einstellungsseite für Addons. Hier die Module:"
	L.OPEN_AFTER_COMBAT = "Die Einstellungen öffnen sich nach dem Kampf."
	L.RELOAD_NOTE = "Zum Abschalten bitte /reload eingeben oder in den Einstellungen auf Neu laden klicken."
	L.BUILD_FAILED = "Die Einstellungsseite konnte nicht aufgebaut werden: %s"
else
	L.SETTINGS_TITLE = "SempreUI"
	L.GENERAL = "General"
	L.MODULES = "Modules"
	L.ON = "on"
	L.STATE_LOADED = "loaded"
	L.STATE_OFF = "off"
	L.STATE_RELOAD = "after /reload"
	L.RELOAD = "Reload"
	L.RELOAD_TIP = "Reloads the interface so switched-off modules stop running."
	L.NOT_LOADED_TIP = "Not loaded. Its options appear as soon as the module runs."
	L.OPTIONS_TIP = "Options: subpage %s."
	L.MODULE_LINE = "%s: %s"
	L.MODULE_HINT = "Switch with |cffc8794a/sempre module <name> on|off|r, settings with |cffc8794a/sempre options|r."
	L.NO_SUCH_MODULE = "No module named %s. /sempre module lists all."
	L.MODULE_USAGE = "Usage: /sempre module <name> on|off"
	L.NO_ENABLE_API = "This client cannot switch modules through the addon interface."
	L.NO_SETTINGS_API = "This client has no settings page for addons. The modules:"
	L.OPEN_AFTER_COMBAT = "The settings open after combat."
	L.RELOAD_NOTE = "To finish switching off, type /reload or click Reload in the settings."
	L.BUILD_FAILED = "The settings page could not be built: %s"
end

local CATEGORY_NAME = "|cffc8794aSempre|rUI"

-- Locale pick from { de = "", en = "" } (or positional { de, en }).
local function pick(t)
	if type(t) ~= "table" then return t end
	if DE then return t.de or t[1] or t.en or t[2] end
	return t.en or t[2] or t.de or t[1]
end

local function plainText(text)
	return (tostring(text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

local function metadata(name, key)
	return C_AddOns.GetAddOnMetadata(name, key)
end

-- Modules

local function shortName(name)
	return name:sub(8)
end

-- One row per module except the core, sorted by title.
local function moduleRows()
	local rows = {}
	for _, name in ipairs(S.ModuleList()) do
		if name ~= ADDON_NAME then
			local title = plainText(metadata(name, "Title"))
			if title == "" then title = name end
			local notes = metadata(name, "Notes-" .. GetLocale()) or metadata(name, "Notes") or ""
			rows[#rows + 1] = { name = name, title = title, notes = notes }
		end
	end
	sort(rows, function(a, b)
		local x, y = a.title:lower(), b.title:lower()
		if x ~= y then return x < y end
		return a.name < b.name
	end)
	return rows
end

local function moduleTitle(name)
	local title = plainText(metadata(name, "Title"))
	return title ~= "" and title or name
end

-- "loaded", "off" or "reload" (the checkbox differs from what is running).
local function stateOf(name)
	local running = C_AddOns.IsAddOnLoaded(name) and true or false
	local wanted = S.IsModuleEnabled(name) and true or false
	if running == wanted then return running and "loaded" or "off" end
	return "reload"
end

local function stateWord(name)
	local state = stateOf(name)
	if state == "loaded" then return L.STATE_LOADED end
	if state == "off" then return L.STATE_OFF end
	return L.STATE_RELOAD
end

local function needsReload()
	for _, row in ipairs(moduleRows()) do
		if stateOf(row.name) == "reload" then return true end
	end
	return false
end

local refreshRow

-- Switches a module for all characters. Returns false when the client cannot.
-- quiet: no chat lines (the caller reports). Also used by Compat.lua through
-- SempreUI.SetModuleEnabled(name, on, quiet), the documented internal switch.
local function setModule(name, on, quiet)
	local api = C_AddOns
	if not (api.EnableAddOn and api.DisableAddOn) then
		S:Print(L.NO_ENABLE_API)
		return false
	end
	if on then
		api.EnableAddOn(name)
		if metadata(name, "LoadOnDemand") == "1" and not api.IsAddOnLoaded(name) then
			S:LoadModule(name)
		end
	else
		api.DisableAddOn(name)
	end
	refreshRow(name, quiet)
	return true
end
S.SetModuleEnabled = setModule

local function findModule(arg)
	arg = arg:lower()
	if arg:sub(1, 7) == "sempre_" then arg = arg:sub(8) end
	for _, row in ipairs(moduleRows()) do
		if shortName(row.name):lower() == arg then return row end
	end
end

local function printModules()
	for _, row in ipairs(moduleRows()) do
		S:Print(L.MODULE_LINE, shortName(row.name), stateWord(row.name))
	end
end

-- Pages

local category, layout          -- vertical layout category
local canvas                    -- canvas fallback: { category, refresh }
local mode                      -- "vertical", "canvas" or "chat"
local attempted = false
local pages = {}                -- module -> subcategory
local moduleInit = {}           -- module -> checkbox initializer
local moduleVar = {}            -- module -> setting variable
local openAfterCombat = false

local function rowTooltip(row)
	local parts = { row.notes, stateWord(row.name) }
	if not C_AddOns.IsAddOnLoaded(row.name) then
		parts[#parts + 1] = L.NOT_LOADED_TIP
	elseif S:GetOptionList(row.name) then
		parts[#parts + 1] = L.OPTIONS_TIP:format(moduleTitle(row.name))
	end
	return table.concat(parts, "\n")
end

-- Keeps the page in step after a switch. Every call is optional: a client
-- without it keeps the page as built, the chat line says the result.
refreshRow = function(name, quiet)
	if not quiet then
		S:Print(L.MODULE_LINE, shortName(name), stateWord(name))
		if stateOf(name) == "reload" then S:Print(L.RELOAD_NOTE) end
	end
	if mode == "canvas" then
		canvas.refresh()
		return
	end
	local init = moduleInit[name]
	local data = init and init.GetData and init:GetData()
	if type(data) == "table" then
		for _, row in ipairs(moduleRows()) do
			if row.name == name then data.tooltip = rowTooltip(row) end
		end
	end
	if Settings and Settings.NotifyUpdate and moduleVar[name] then
		pcall(Settings.NotifyUpdate, moduleVar[name])
	end
end

local function reloadGame()
	if ReloadUI then ReloadUI() end
end

-- Vertical layout (the game's own list look)

local function canVertical()
	return Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterVerticalLayoutSubcategory
		and Settings.RegisterProxySetting and Settings.RegisterAddOnCategory and Settings.OpenToCategory
		and Settings.VarType and (Settings.CreateCheckbox or Settings.CreateCheckBox) and true or false
end

local function canCanvas()
	return Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory
		and Settings.OpenToCategory and CreateFrame and true or false
end

local function addCheckbox(cat, variable, name, default, getter, setter, tooltip)
	local setting = Settings.RegisterProxySetting(cat, variable, Settings.VarType.Boolean, name, default, getter, setter)
	local create = Settings.CreateCheckbox or Settings.CreateCheckBox
	return create(cat, setting, tooltip), setting
end

local function optionTitle(moduleName)
	if moduleName == ADDON_NAME then return L.GENERAL end
	return moduleTitle(moduleName)
end

local function addOptionPage(moduleName)
	local list = S:GetOptionList(moduleName)
	if pages[moduleName] or not list or #list == 0 then return end
	local sub = Settings.RegisterVerticalLayoutSubcategory(category, optionTitle(moduleName))
	pages[moduleName] = sub
	for _, opt in ipairs(list) do
		local key = opt.key
		-- A reason from opt.disabled() greys the option out and joins its tooltip.
		local reason = opt.disabled and opt.disabled()
		local tip = pick(opt.tooltip) or ""
		if reason then tip = tip .. (tip ~= "" and "\n" or "") .. reason end
		local init = addCheckbox(sub, "SempreUI_" .. moduleName .. "_" .. key, pick(opt.label), opt.default and true or false,
			function() return S:GetOption(moduleName, key) end,
			function(value)
				if reason then return end
				S:SetOption(moduleName, key, value)
			end,
			tip)
		-- Assumption: AddModifyPredicate on a settings initializer greys it out
		-- while the predicate returns false.
		if reason and init and init.AddModifyPredicate then init:AddModifyPredicate(function() return false end) end
	end
end

local function buildVertical()
	category, layout = Settings.RegisterVerticalLayoutCategory(CATEGORY_NAME)
	if layout and layout.AddInitializer and CreateSettingsListSectionHeaderInitializer then
		layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("|cffc8794a" .. L.MODULES .. "|r"))
	end
	for _, row in ipairs(moduleRows()) do
		local name = row.name
		local variable = "SempreUI_module_" .. name
		moduleVar[name] = variable
		moduleInit[name] = addCheckbox(category, variable, row.title .. " (" .. L.ON .. ")",
			S.IsModuleEnabled(name) and true or false,
			function() return S.IsModuleEnabled(name) and true or false end,
			function(value) setModule(name, value and true or false) end,
			rowTooltip(row))
	end
	-- The reload button shows only while some module waits for a reload.
	if layout and layout.AddInitializer and CreateSettingsButtonInitializer then
		local button = CreateSettingsButtonInitializer(L.RELOAD, L.RELOAD, reloadGame, L.RELOAD_TIP, true)
		if button.AddShownPredicate then button:AddShownPredicate(needsReload) end
		layout:AddInitializer(button)
		S.reloadButton = button
	end
	Settings.RegisterAddOnCategory(category)
	addOptionPage(ADDON_NAME)
	for _, row in ipairs(moduleRows()) do addOptionPage(row.name) end
end

-- Canvas fallback: one page, rows are created on first show and then reused.

local function buildCanvas()
	local frame = CreateFrame("Frame")
	local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText(CATEGORY_NAME)
	S:SetFont(title, "title", 16)
	local widgets, used = {}, 0
	local reload = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	reload:SetText(L.RELOAD)
	reload:SetScript("OnClick", reloadGame)
	local refresh

	local function checkbox(label, getter, setter, reason)
		used = used + 1
		local w = widgets[used]
		if not w then
			w = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
			widgets[used] = w
		end
		w:SetPoint("TOPLEFT", 16, -40 - used * 26)
		w.Text:SetText(reason and (label .. " (" .. reason .. ")") or label)
		w:SetChecked(getter())
		if w.SetEnabled then w:SetEnabled(not reason) end
		w:SetScript("OnClick", function(self)
			setter(self:GetChecked() and true or false)
			refresh()
		end)
		w:Show()
	end

	refresh = function()
		used = 0
		for _, row in ipairs(moduleRows()) do
			local name = row.name
			checkbox(row.title .. " (" .. L.ON .. "): " .. stateWord(name),
				function() return S.IsModuleEnabled(name) end,
				function(value) setModule(name, value) end)
		end
		local names = { ADDON_NAME }
		for _, row in ipairs(moduleRows()) do names[#names + 1] = row.name end
		for _, moduleName in ipairs(names) do
			for _, opt in ipairs(S:GetOptionList(moduleName) or {}) do
				local key = opt.key
				checkbox(optionTitle(moduleName) .. ": " .. pick(opt.label),
					function() return S:GetOption(moduleName, key) end,
					function(value) S:SetOption(moduleName, key, value) end,
					opt.disabled and opt.disabled())
			end
		end
		for i = used + 1, #widgets do widgets[i]:Hide() end
		reload:SetPoint("TOPLEFT", 16, -40 - (used + 1) * 26)
		if needsReload() then reload:Show() else reload:Hide() end
	end
	frame:SetScript("OnShow", refresh)
	category = Settings.RegisterCanvasLayoutCategory(frame, CATEGORY_NAME)
	Settings.RegisterAddOnCategory(category)
	canvas = { frame = frame, refresh = refresh, reload = reload }
end

-- Builds once, after PLAYER_LOGIN. A failing Settings API never breaks login:
-- the next way down (canvas, then chat) takes over.
local function build()
	if attempted or not S.charKey then return end
	attempted = true
	if canVertical() then
		local ok, err = pcall(buildVertical)
		if ok then
			mode = "vertical"
			return
		end
		S:Print(L.BUILD_FAILED, tostring(err))
		category = nil
	end
	if canCanvas() then
		local ok, err = pcall(buildCanvas)
		if ok then
			mode = "canvas"
			return
		end
		S:Print(L.BUILD_FAILED, tostring(err))
		category = nil
	end
	mode = "chat"
end

local function open()
	if InCombatLockdown() then
		S:Print(L.OPEN_AFTER_COMBAT)
		if not openAfterCombat then
			local function onRegen()
				S:Off("PLAYER_REGEN_ENABLED", onRegen)
				openAfterCombat = false
				if not InCombatLockdown() then S.OpenSettings() end
			end
			openAfterCombat = S:On("PLAYER_REGEN_ENABLED", onRegen)
		end
		return
	end
	build()
	if mode == "vertical" or mode == "canvas" then
		Settings.OpenToCategory(category:GetID())
		return
	end
	S:Print(L.NO_SETTINGS_API)
	printModules()
	S:Print(L.MODULE_HINT)
end
S.OpenSettings = open

-- Commands

local ON_WORDS = { an = true, ein = true, on = true, ["1"] = true }
local OFF_WORDS = { aus = true, off = true, ["0"] = true }

local function moduleCommand(arg)
	local name, value = (arg or ""):match("^(%S*)%s*(%S*)")
	if name == "" then
		printModules()
		S:Print(L.MODULE_HINT)
		return
	end
	local row = findModule(name)
	if not row then
		S:Print(L.NO_SUCH_MODULE, name)
		return
	end
	value = value:lower()
	if value == "" then
		S:Print(L.MODULE_LINE, shortName(row.name), stateWord(row.name))
	elseif ON_WORDS[value] then
		setModule(row.name, true)
	elseif OFF_WORDS[value] then
		setModule(row.name, false)
	else
		S:Print(L.MODULE_USAGE)
	end
end

S.commands.modul = moduleCommand
S.commands.module = moduleCommand
S.commands.optionen = open
S.commands.options = open
S.commands.config = open

S:On("PLAYER_LOGIN", build)

S:Listen("OPTIONS_REGISTERED", function(_, moduleName)
	if mode == "vertical" then pcall(addOptionPage, moduleName) end
end)
