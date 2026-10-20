-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- SempreUI core: event bus, saved settings, module loader, slash commands.
-- Always loaded, so it stays small. Everything else lives in LoadOnDemand modules.

local ADDON_NAME = ...

local CreateFrame, GetLocale, GetBuildInfo = CreateFrame, GetLocale, GetBuildInfo
local UpdateAddOnMemoryUsage, GetAddOnMemoryUsage = UpdateAddOnMemoryUsage, GetAddOnMemoryUsage
local C_AddOns = C_AddOns
local pairs, ipairs, type, format, tostring, tonumber, select = pairs, ipairs, type, string.format, tostring, tonumber, select
local collectgarbage, setmetatable = collectgarbage, setmetatable
local UnitName, GetRealmName = UnitName, GetRealmName
local sort, wipe = table.sort, table.wipe
local geterrorhandler = geterrorhandler

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
	L.HELP = "Befehle: |cffc8794a/sempre perf|r Speicher pro Modul, |cffc8794a/sempre version|r Version."
	L.PERF_HEADER = "Speicher pro Modul (KB, Budget in Klammern):"
	L.PERF_TOTAL = "Gesamt"
	L.OVER_BUDGET = "über Budget"
	L.NO_MEMORY_API = "Dieser Client meldet keinen Speicher pro Addon."
	L.MODULE_FAILED = "Modul %s konnte nicht geladen werden: %s"
	L.UNKNOWN_EVENT = "Ereignis %s gibt es in diesem Client nicht."
	L.LOAD_COST = "beim Laden"
else
	L.LOADED = "loaded. /sempre for commands."
	L.HELP = "Commands: |cffc8794a/sempre perf|r memory per module, |cffc8794a/sempre version|r version."
	L.PERF_HEADER = "Memory per module (KB, budget in brackets):"
	L.PERF_TOTAL = "Total"
	L.OVER_BUDGET = "over budget"
	L.NO_MEMORY_API = "This client does not report memory per addon."
	L.MODULE_FAILED = "Module %s could not be loaded: %s"
	L.UNKNOWN_EVENT = "Event %s does not exist in this client."
	L.LOAD_COST = "on load"
end

-- Formats only when arguments follow, so a plain "50%" message is safe.
function S:Print(msg, ...)
	if select("#", ...) > 0 then msg = format(msg, ...) end
	print("|cffc8794aSempre|r " .. tostring(msg))
end

-- Event bus: one frame, one handler list per event.

local frame = CreateFrame("Frame")
local handlers = {}

-- Returns false when the client does not know the event, instead of erroring.
function S:On(event, fn)
	local list = handlers[event]
	if not list then
		if not pcall(frame.RegisterEvent, frame, event) then
			self:Print(L.UNKNOWN_EVENT, event)
			return false
		end
		list = {}
		handlers[event] = list
	end
	list[#list + 1] = fn
	return true
end

-- Off only marks the slot; the dispatcher compacts the list after it ran,
-- so removing a handler during its own event never skips the next one.
local dirty = {}

function S:Off(event, fn)
	local list = handlers[event]
	if not list then return end
	for i = 1, #list do
		if list[i] == fn then
			list[i] = false
			dirty[event] = true
		end
	end
end

local function compact(event)
	local list = handlers[event]
	local n = 0
	for i = 1, #list do
		local fn = list[i]
		list[i] = nil
		if fn then
			n = n + 1
			list[n] = fn
		end
	end
	dirty[event] = nil
	if n == 0 then
		handlers[event] = nil
		frame:UnregisterEvent(event)
	end
end

frame:SetScript("OnEvent", function(_, event, ...)
	local list = handlers[event]
	if not list then return end
	for i = 1, #list do
		local fn = list[i]
		if fn then
			local ok, err = pcall(fn, event, ...)
			if not ok then geterrorhandler()(err) end
		end
	end
	if dirty[event] then compact(event) end
end)

-- Saved settings with defaults.

-- version: bump with a migration when the layout changes.
-- global: account-wide data, chars: per "Name-Realm", profiles: named setting sets.
local DB_VERSION = 1
local defaults = {
	version = DB_VERSION,
	global = {},
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

-- A loaded module cannot be unloaded; switching one off takes a /reload.
function S:LoadModule(name)
	if C_AddOns.IsAddOnLoaded(name) then return true end
	C_AddOns.EnableAddOn(name, UnitName("player"))
	local before = collectgarbage("count")
	local loaded, reason = C_AddOns.LoadAddOn(name)
	if loaded then
		loadCost[name] = collectgarbage("count") - before
	else
		self:Print(L.MODULE_FAILED, name, tostring(reason))
	end
	return loaded
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

local commands = {
	perf = printPerf,
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
	SempreDB = SempreDB or {}
	applyDefaults(SempreDB, defaults)
	S.db = SempreDB
end)

S:On("PLAYER_LOGIN", function()
	-- The player's own name is never secret; read it once here and cache it.
	S.charKey = format("%s-%s", UnitName("player"), GetRealmName())
	S.db.chars[S.charKey] = S.db.chars[S.charKey] or {}
	S.char = S.db.chars[S.charKey]
	S:Print("%s %s", S.version, L.LOADED)
end)
