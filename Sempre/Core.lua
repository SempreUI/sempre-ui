-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- SempreUI core: event and message bus, saved settings, module loader, slash commands.
-- Always loaded, so it stays small. Everything else lives in LoadOnDemand modules.

local ADDON_NAME = ...

local CreateFrame, GetLocale, GetBuildInfo = CreateFrame, GetLocale, GetBuildInfo
local UpdateAddOnMemoryUsage, GetAddOnMemoryUsage = UpdateAddOnMemoryUsage, GetAddOnMemoryUsage
local C_AddOns = C_AddOns
local next = next
local pairs, ipairs, type, format, tostring, tonumber, select = pairs, ipairs, type, string.format, tostring, tonumber, select
local collectgarbage, setmetatable = collectgarbage, setmetatable
local UnitName, GetRealmName = UnitName, GetRealmName
local sort, wipe = table.sort, table.wipe
local geterrorhandler, seterrorhandler, debugstack = geterrorhandler, seterrorhandler, debugstack
local issecretvalue, time, date, C_EventUtils = issecretvalue, time, date, C_EventUtils

local S = {}
SempreUI = S

S.name = ADDON_NAME
S.version = C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or "dev"
if S.version:find("@", 1, true) then S.version = "dev" end
S.color = { r = 0.78, g = 0.47, b = 0.29, hex = "c8794a" }

-- Missing translations fall back to the key, so a typo shows up instead of erroring.
local L = setmetatable({}, { __index = function(_, k) return k end })
S.L = L
if GetLocale() == "deDE" then
	L.LOADED = "geladen. /sempre für Befehle."
	L.HELP = "Befehle: |cffc8794a/sempre optionen|r Einstellungen, |cffc8794a/sempre modul <Name> an|aus|r Modul schalten, |cffc8794a/sempre perf|r Speicher pro Modul, |cffc8794a/sempre fehler|r Fehlerliste, |cffc8794a/sempre neu|r Neuigkeiten, |cffc8794a/sempre vertraeglich|r doppelte Funktionen, |cffc8794a/sempre version|r Version."
	L.PERF_HEADER = "Speicher pro Modul (KB, Budget in Klammern):"
	L.PERF_TOTAL = "Gesamt"
	L.OVER_BUDGET = "über Budget"
	L.NO_MEMORY_API = "Dieser Client meldet keinen Speicher pro Addon."
	L.MODULE_FAILED = "Modul %s konnte nicht geladen werden: %s"
	L.UNKNOWN_EVENT = "Ereignis %s gibt es in diesem Client nicht."
	L.LOAD_COST = "beim Laden"
	L.ERR_NOTICE = "Ein SempreUI-Fehler wurde erfasst. /sempre fehler zeigt ihn."
	L.ERR_NONE = "Keine Fehler erfasst."
	L.ERR_CLEARED = "Fehlerliste geleert."
	L.ERR_OTHER = "fremd"
	L.ERR_MORE = "%d weitere, /sempre fehler alle zeigt alle."
	L.ERR_BLOCKED = "Aktion blockiert: %s, %s"
	L.SECRET = "<geheim>"
else
	L.LOADED = "loaded. /sempre for commands."
	L.HELP = "Commands: |cffc8794a/sempre options|r settings, |cffc8794a/sempre module <name> on|off|r switch a module, |cffc8794a/sempre perf|r memory per module, |cffc8794a/sempre errors|r error list, |cffc8794a/sempre news|r what's new, |cffc8794a/sempre compat|r doubled functions, |cffc8794a/sempre version|r version."
	L.PERF_HEADER = "Memory per module (KB, budget in brackets):"
	L.PERF_TOTAL = "Total"
	L.OVER_BUDGET = "over budget"
	L.NO_MEMORY_API = "This client does not report memory per addon."
	L.MODULE_FAILED = "Module %s could not be loaded: %s"
	L.UNKNOWN_EVENT = "Event %s does not exist in this client."
	L.LOAD_COST = "on load"
	L.ERR_NOTICE = "A SempreUI error was recorded. /sempre errors shows it."
	L.ERR_NONE = "No errors recorded."
	L.ERR_CLEARED = "Error list cleared."
	L.ERR_OTHER = "other"
	L.ERR_MORE = "%d more, /sempre errors all shows all."
	L.ERR_BLOCKED = "Action blocked: %s, %s"
	L.SECRET = "<secret>"
end

-- Formats only when arguments follow, so a plain "50%" message is safe.
function S:Print(msg, ...)
	if select("#", ...) > 0 then msg = format(msg, ...) end
	print("|cffc8794aSempre|r " .. tostring(msg))
end

-- Handler lists shared by the event bus and the message bus. A bus is a set of
-- lists keyed by name. Removing only marks a slot (false); the slots are swept
-- once the outermost run of that key has finished, so removing during a run,
-- also during a nested run of the same key, never skips or repeats a handler.
-- A run reads #list once, so handlers added during it wait for the next run.

local function newBus(eager)
	return { lists = {}, dirty = {}, depth = {}, eager = eager }
end

local function sweep(bus, key)
	local list = bus.lists[key]
	local n = 0
	for i = 1, #list do
		local fn = list[i]
		list[i] = nil
		if fn then
			n = n + 1
			list[n] = fn
		end
	end
	bus.dirty[key] = nil
	if n == 0 then
		bus.lists[key] = nil
		return true
	end
end

local function busAdd(bus, key, fn)
	local list = bus.lists[key]
	if not list then
		list = {}
		bus.lists[key] = list
	end
	list[#list + 1] = fn
end

-- Returns true when the list ended up empty and was dropped (eager buses only).
local function busRemove(bus, key, fn)
	local list = bus.lists[key]
	if not list then return end
	for i = 1, #list do
		if list[i] == fn then
			list[i] = false
			bus.dirty[key] = true
		end
	end
	if bus.eager and bus.dirty[key] and not bus.depth[key] then
		return sweep(bus, key)
	end
end

-- Returns true when the sweep after the run dropped an empty list.
local function busRun(bus, key, ...)
	local list = bus.lists[key]
	if not list then return end
	local depth = (bus.depth[key] or 0) + 1
	bus.depth[key] = depth
	for i = 1, #list do
		local fn = list[i]
		if fn then
			local ok, err = pcall(fn, key, ...)
			-- A throwing error handler must not leave the depth counter stuck.
			if not ok then pcall(geterrorhandler(), err) end
		end
	end
	bus.depth[key] = depth > 1 and depth - 1 or nil
	if depth == 1 and bus.dirty[key] then return sweep(bus, key) end
end

-- Event bus: one frame, one handler list per game event.

local frame = CreateFrame("Frame")
local events = newBus(false)

-- Returns false when the client does not know the event, instead of erroring.
function S:On(event, fn)
	if not events.lists[event] and not pcall(frame.RegisterEvent, frame, event) then
		self:Print(L.UNKNOWN_EVENT, event)
		return false
	end
	busAdd(events, event, fn)
	return true
end

-- Off only marks the slot; the dispatcher sweeps the list after it ran.
function S:Off(event, fn)
	busRemove(events, event, fn)
end

frame:SetScript("OnEvent", function(_, event, ...)
	if busRun(events, event, ...) then frame:UnregisterEvent(event) end
end)

-- Message bus: modules tell each other about changes without knowing each
-- other. Messages are plain strings (ITEMS_CHANGED) and never touch the frame,
-- so a message named like a game event does not register that event.

local messages = newBus(true)

function S:Listen(msg, fn)
	busAdd(messages, msg, fn)
end

function S:Unlisten(msg, fn)
	busRemove(messages, msg, fn)
end

-- Synchronous; nobody listening costs one table lookup.
function S:Send(msg, ...)
	busRun(messages, msg, ...)
end

-- Saved settings with defaults.

-- version: bump with a migration when the layout changes.
-- global: account-wide data, chars: per "Name-Realm", profiles: named setting sets.
local DB_VERSION = 1
local defaults = {
	version = DB_VERSION,
	global = { errors = {}, options = {}, compatAnswered = "" },
	chars = {},
	profiles = {},
}

local function applyDefaults(db, defs)
	for k, v in pairs(defs) do
		if db[k] == nil then
			db[k] = type(v) == "table" and {} or v
		end
		if type(v) == "table" and type(db[k]) == "table" then
			applyDefaults(db[k], v)
		end
	end
end

-- Options. Interface for modules (read-only, documented here):
--   SempreUI:RegisterOptions(moduleName, list) -- call from the module's own
--       ADDON_LOADED. list = { { key = "x", default = true,
--       label = { de = "...", en = "..." }, tooltip = { de = "...", en = "..." } } }
--       (tooltip optional; checkboxes only; disabled optional: a function
--       returning a reason text when the option is unavailable, the settings
--       window greys it out and adds the reason to the tooltip).
--       Registering again replaces the list.
--   SempreUI:GetOption(moduleName, key)        -- stored value or the default
--   SempreUI:SetOption(moduleName, key, value) -- stores, sends OPTION_CHANGED
-- Values live in SempreDB.global.options[moduleName][key], only when they
-- differ from the default. Messages: OPTION_CHANGED(moduleName, key, value) and
-- OPTIONS_REGISTERED(moduleName), sent after a module registered its list.

local optionLists, optionDefs = {}, {}

function S:RegisterOptions(moduleName, list)
	local defs = {}
	for _, opt in ipairs(list) do defs[opt.key] = opt end
	optionLists[moduleName], optionDefs[moduleName] = list, defs
	self:Send("OPTIONS_REGISTERED", moduleName)
end

-- The registered list of a module, or nil. Do not modify it.
function S:GetOptionList(moduleName)
	return optionLists[moduleName]
end

function S:GetOption(moduleName, key)
	local options = S.db and S.db.global.options
	local mod = options and options[moduleName]
	local value = mod and mod[key]
	if value ~= nil then return value end
	local def = optionDefs[moduleName] and optionDefs[moduleName][key]
	return def and def.default
end

-- Returns false for an unknown option or before the saved data exists. The
-- message is sent only when the value actually changed.
function S:SetOption(moduleName, key, value)
	local def = optionDefs[moduleName] and optionDefs[moduleName][key]
	local global = S.db and S.db.global
	if not (def and global) then return false end
	value = value and true or false
	local old = S:GetOption(moduleName, key)
	if type(global.options) ~= "table" then global.options = {} end
	local mod = global.options[moduleName]
	if value == def.default then
		if mod then
			mod[key] = nil
			if next(mod) == nil then global.options[moduleName] = nil end
		end
	else
		if not mod then
			mod = {}
			global.options[moduleName] = mod
		end
		mod[key] = value
	end
	if old ~= value then S:Send("OPTION_CHANGED", moduleName, key, value) end
	return true
end

-- Modules: addon folders named Sempre_<Name> that mark themselves with
-- "## X-Sempre-Module: 1", so foreign addons with the same prefix are ignored.

local function isModule(name)
	return name and name:sub(1, 7) == "Sempre_" and C_AddOns.GetAddOnMetadata(name, "X-Sempre-Module") == "1"
end

local function moduleList()
	local list = {}
	for i = 1, C_AddOns.GetNumAddOns() do
		local name = C_AddOns.GetAddOnInfo(i)
		if name == ADDON_NAME or isModule(name) then
			list[#list + 1] = name
		end
	end
	sort(list)
	return list
end
S.ModuleList = moduleList

-- Memory grown while each module loaded, in KB. Closer to its real cost than
-- GetAddOnMemoryUsage, which bills tables to whichever addon created them.
local loadCost = {}

-- Loads without touching the enable state, so the login path can never switch
-- on a module the player switched off.
local function loadOnly(name)
	if C_AddOns.IsAddOnLoaded(name) then return true end
	local before = collectgarbage("count")
	local loaded, reason = C_AddOns.LoadAddOn(name)
	if loaded then
		loadCost[name] = collectgarbage("count") - before
	else
		S:Print(L.MODULE_FAILED, name, tostring(reason))
	end
	return loaded
end

-- A loaded module cannot be unloaded; switching one off takes a /reload.
-- Asking for a module switches it on for this character first.
function S:LoadModule(name)
	if C_AddOns.IsAddOnLoaded(name) then return true end
	C_AddOns.EnableAddOn(name, UnitName("player"))
	return loadOnly(name)
end

-- Assumption: GetAddOnEnableState(addon, character) returns a number (0 none,
-- 1 some, 2 all) or an Enum.AddOnEnableState value; anything above 0 is on.
-- A missing function or a nil result counts as enabled.
local function isEnabled(name, char)
	if not C_AddOns.GetAddOnEnableState then return true end
	local state = C_AddOns.GetAddOnEnableState(name, char)
	if type(state) ~= "number" then return state ~= false end
	return state > 0
end

S.IsModuleEnabled = isEnabled

-- Modules with "## X-Sempre-LoadWith: Login" load right after login, in
-- alphabetical order, if the player has not switched them off.
local function loadLoginModules()
	local char = UnitName("player")
	for _, name in ipairs(moduleList()) do
		if name ~= ADDON_NAME
			and C_AddOns.GetAddOnMetadata(name, "X-Sempre-LoadWith") == "Login"
			and isEnabled(name, char) then
			loadOnly(name)
		end
	end
end

-- /sempre perf

local perfRows = {}

local function budgetOf(name)
	return tonumber(C_AddOns.GetAddOnMetadata(name, "X-Sempre-Budget-KB"))
end

local function printPerf()
	if not (UpdateAddOnMemoryUsage and GetAddOnMemoryUsage) then
		S:Print(L.NO_MEMORY_API)
		return
	end
	UpdateAddOnMemoryUsage()
	wipe(perfRows)
	local total = 0
	for _, name in ipairs(moduleList()) do
		if C_AddOns.IsAddOnLoaded(name) then
			local kb = GetAddOnMemoryUsage(name)
			total = total + kb
			perfRows[#perfRows + 1] = { name = name, kb = kb, budget = budgetOf(name), load = loadCost[name] }
		end
	end
	sort(perfRows, function(a, b) return a.kb > b.kb end)
	S:Print(L.PERF_HEADER)
	for _, row in ipairs(perfRows) do
		local line = format("  %s: %.0f", row.name, row.kb)
		if row.budget then
			line = line .. format(" (%d)", row.budget)
			if row.kb > row.budget then line = line .. " |cffff5555" .. L.OVER_BUDGET .. "|r" end
		end
		if row.load then line = line .. format(", %s %.0f", L.LOAD_COST, row.load) end
		print(line)
	end
	print(format("  %s: %.0f", L.PERF_TOTAL, total))
end

-- Error collector. Wraps the game's error handler: records first, then passes
-- the error on unchanged. Records live in memory until the saved data is
-- loaded, then in SempreDB.global.errors (oldest dropped past ERR_MAX).

local ERR_MAX, ERR_SHOWN, STACK_LINES = 50, 10, 4
local errStore = {}
local errNotified, errBusy = false, false

-- Never compares or joins a secret value; a placeholder is stored instead.
local function plain(v)
	if issecretvalue and issecretvalue(v) then return L.SECRET end
	if type(v) == "string" then return v end
	return tostring(v)
end

local function firstLine(text)
	return text and text:match("[^\r\n]+") or ""
end

-- Ours when the text names the Sempre folder or a Sempre_<Name> folder.
local function isOurs(text)
	return text ~= nil and text:find("Sempre[_/\\]") ~= nil
end

-- Assumption: debugstack(start, lines, lines) returns a string. How many
-- frames the collector itself adds is not known for sure, so a generous stack
-- is taken and its leading lines that point into the core (the collector) or
-- into C code are skipped; an error inside the core still names its file in
-- the message. Missing function: no stack.
local function stackText()
	if not debugstack then return end
	local ok, text = pcall(debugstack, 1, STACK_LINES + 12, 0)
	if not ok or type(text) ~= "string" or (issecretvalue and issecretvalue(text)) then return end
	local lines, leading = {}, true
	for line in text:gmatch("[^\r\n]+") do
		-- Leading core and C lines belong to the collector itself.
		if leading and not (line:find("Sempre[/\\]Core%.lua") or line:find("^%[C%]")) then leading = false end
		if not leading and #lines < STACK_LINES then lines[#lines + 1] = line end
	end
	return #lines > 0 and table.concat(lines, "\n") or nil
end

local function addRecord(msg, stack, ours)
	local key = firstLine(stack)
	for i = 1, #errStore do
		local r = errStore[i]
		if r.msg == msg and firstLine(r.stack) == key then
			r.count = r.count + 1
			r.time = time()
			return ours
		end
	end
	errStore[#errStore + 1] = { msg = msg, stack = stack, time = time(), version = S.version, count = 1, ours = ours }
	while #errStore > ERR_MAX do table.remove(errStore, 1) end
	return ours
end

-- Guarded as a whole by the callers' pcall; prints one chat line per session.
local function record(msg, stack, ours)
	if errBusy then return end
	errBusy = true
	local ok, mine = pcall(function()
		if stack == nil then stack = stackText() end
		msg = plain(msg)
		if ours == nil then ours = isOurs(msg) or isOurs(stack) end
		return addRecord(msg, stack, ours)
	end)
	errBusy = false
	if ok and mine and not errNotified then
		errNotified = true
		pcall(S.Print, S, L.ERR_NOTICE)
	end
end

local function installErrorHandler()
	if type(geterrorhandler) ~= "function" or type(seterrorhandler) ~= "function" then return end
	local okGet, previous = pcall(geterrorhandler)
	if not okGet or type(previous) ~= "function" then return end
	pcall(seterrorhandler, function(msg)
		pcall(record, msg)
		return previous(msg)
	end)
end
installErrorHandler()

-- Blocked or forbidden addon actions. Events the client does not know are
-- skipped before registering, so the unknown-event warning stays quiet.
local function onActionBlocked(_, addon, func)
	pcall(function()
		local name, fn = plain(addon), plain(func)
		record(format(L.ERR_BLOCKED, name, fn), nil, name == ADDON_NAME or name:sub(1, 7) == "Sempre_")
	end)
end

local function eventKnown(event)
	if not (C_EventUtils and C_EventUtils.IsEventValid) then return false end
	local ok, valid = pcall(C_EventUtils.IsEventValid, event)
	return ok and valid == true
end

for _, event in ipairs({ "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN" }) do
	if eventKnown(event) then S:On(event, onActionBlocked) end
end

-- Called once the saved data exists: early records move into it.
local function attachErrorStore(db)
	if type(db.global.errors) ~= "table" then db.global.errors = {} end
	local saved = db.global.errors
	for i = 1, #errStore do saved[#saved + 1] = errStore[i] end
	while #saved > ERR_MAX do table.remove(saved, 1) end
	errStore = saved
end

local function stamp(t)
	local ok, text = pcall(date, "%d.%m. %H:%M", t)
	return ok and text or tostring(t)
end

local function printErrors(arg)
	arg = (arg or ""):lower()
	if arg == "leeren" or arg == "clear" then
		wipe(errStore)
		S:Print(L.ERR_CLEARED)
		return
	end
	-- Newest first, ours before the others.
	local ours, others = {}, {}
	for i = #errStore, 1, -1 do
		local r = errStore[i]
		local list = r.ours and ours or others
		list[#list + 1] = r
	end
	for _, r in ipairs(others) do ours[#ours + 1] = r end
	if #ours == 0 then
		S:Print(L.ERR_NONE)
		return
	end
	local limit = (arg == "alle" or arg == "all") and #ours or ERR_SHOWN
	for i = 1, math.min(limit, #ours) do
		local r = ours[i]
		local text = tostring(r.msg):gsub("%s*[\r\n]+%s*", " "):sub(1, 200)
		local line = format("%s x%d %s%s", stamp(r.time), r.count or 1, r.ours and "" or "[" .. L.ERR_OTHER .. "] ", text)
		local top = firstLine(r.stack)
		if top ~= "" then line = line .. " | " .. top end
		print(line)
	end
	if #ours > limit then S:Print(L.ERR_MORE, #ours - limit) end
end

local commands = {
	perf = printPerf,
	fehler = printErrors,
	errors = printErrors,
	version = function()
		local build, _, _, interface = GetBuildInfo()
		S:Print("%s, client %s (%s)", S.version, tostring(build), tostring(interface))
	end,
}
S.commands = commands

SLASH_SEMPRE1 = "/sempre"
SlashCmdList.SEMPRE = function(input)
	local cmd, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
	local fn = commands[cmd:lower()]
	if fn then
		fn(rest)
	else
		S:Print(L.HELP)
	end
end

S:On("ADDON_LOADED", function(_, name)
	if name ~= ADDON_NAME then return end
	-- No saved data yet: a first install (the news window stays quiet).
	S.freshInstall = SempreDB == nil
	SempreDB = SempreDB or {}
	applyDefaults(SempreDB, defaults)
	S.db = SempreDB
	attachErrorStore(SempreDB)
	S:RegisterOptions(ADDON_NAME, {
		{
			key = "login_message", default = true,
			label = { de = "Begrüßung im Chat beim Login", en = "Login message in chat" },
			tooltip = { de = "Zeigt beim Login die Zeile mit der Version.", en = "Shows the line with the version at login." },
		},
		{
			key = "fonts", default = true,
			label = { de = "SempreUI-Schriften", en = "SempreUI fonts" },
			tooltip = { de = "Benutzt in den SempreUI-Fenstern die Schriften Grenze und Atkinson Hyperlegible. Aus: Spielschriften.", en = "Uses the Grenze and Atkinson Hyperlegible fonts in SempreUI windows. Off: game fonts." },
			disabled = function() return S.FontLockReason and S:FontLockReason() end,
		},
		{
			key = "game_fonts", default = false,
			label = { de = "Auch Spielschriften ersetzen", en = "Replace game fonts too" },
			tooltip = { de = "Ersetzt die Schrift der gängigen Spielschriftobjekte (Text, Tooltips, Chat, Quests). Manche Fenster ändern sich erst nach /reload.", en = "Replaces the font of the game's common font objects (text, tooltips, chat, quests). Some frames only change after /reload." },
			disabled = function() return S.FontLockReason and S:FontLockReason() end,
		},
		{
			key = "news", default = true,
			label = { de = "Neuigkeiten nach Updates zeigen", en = "Show what's new after updates" },
			tooltip = { de = "Öffnet nach einem Update einmal das Fenster mit den Neuigkeiten. /sempre neu öffnet es jederzeit.", en = "Opens the what's new window once after an update. /sempre news opens it at any time." },
		},
		{
			key = "compat", default = true,
			label = { de = "Auf doppelte Funktionen mit anderen Addons hinweisen", en = "Point out functions doubled by other addons" },
			tooltip = { de = "Fragt nach dem Login, ob SempreUI-Teile abgeschaltet werden sollen, die EllesmereUI oder Naowh Forever schon erledigen. /sempre vertraeglich öffnet das Fenster jederzeit.", en = "After login, asks whether to switch off SempreUI parts that EllesmereUI or Naowh Forever already do. /sempre compat opens the window at any time." },
		},
	})
end)

S:On("PLAYER_LOGIN", function()
	-- The player's own name is never secret; read it once here and cache it.
	S.charKey = format("%s-%s", UnitName("player"), GetRealmName())
	S.db.chars[S.charKey] = S.db.chars[S.charKey] or {}
	S.char = S.db.chars[S.charKey]
	loadLoginModules()
	if S:GetOption(ADDON_NAME, "login_message") then S:Print("%s %s", S.version, L.LOADED) end
end)
