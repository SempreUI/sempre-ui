-- SempreUI core: event bus, saved settings, module loader, slash commands.
-- Always loaded, so it stays small. Everything else lives in LoadOnDemand modules.

local ADDON_NAME = ...

local CreateFrame, GetLocale, GetBuildInfo = CreateFrame, GetLocale, GetBuildInfo
local UpdateAddOnMemoryUsage, GetAddOnMemoryUsage = UpdateAddOnMemoryUsage, GetAddOnMemoryUsage
local C_AddOns = C_AddOns
local pairs, ipairs, type, format, tostring, tonumber = pairs, ipairs, type, string.format, tostring, tonumber
local sort, wipe = table.sort, table.wipe
local geterrorhandler = geterrorhandler

local S = {}
SempreUI = S

S.name = ADDON_NAME
S.version = C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or "dev"
if S.version:find("@", 1, true) then S.version = "dev" end
S.color = { r = 0.78, g = 0.47, b = 0.29, hex = "c8794a" }

local L = {}
S.L = L
if GetLocale() == "deDE" then
	L.LOADED = "geladen. /sempre für Befehle."
	L.HELP = "Befehle: |cffc8794a/sempre perf|r Speicher pro Modul, |cffc8794a/sempre version|r Version."
	L.PERF_HEADER = "Speicher pro Modul (KB, Budget in Klammern):"
	L.PERF_TOTAL = "Gesamt"
	L.OVER_BUDGET = "über Budget"
	L.NO_MEMORY_API = "Dieser Client meldet keinen Speicher pro Addon."
	L.MODULE_FAILED = "Modul %s konnte nicht geladen werden: %s"
else
	L.LOADED = "loaded. /sempre for commands."
	L.HELP = "Commands: |cffc8794a/sempre perf|r memory per module, |cffc8794a/sempre version|r version."
	L.PERF_HEADER = "Memory per module (KB, budget in brackets):"
	L.PERF_TOTAL = "Total"
	L.OVER_BUDGET = "over budget"
	L.NO_MEMORY_API = "This client does not report memory per addon."
	L.MODULE_FAILED = "Module %s could not be loaded: %s"
end

function S:Print(msg, ...)
	if ... then msg = format(msg, ...) end
	print("|cffc8794aSempre|r " .. tostring(msg))
end

-- Event bus: one frame, one handler list per event.

local frame = CreateFrame("Frame")
local handlers = {}

function S:On(event, fn)
	local list = handlers[event]
	if not list then
		list = {}
		handlers[event] = list
		frame:RegisterEvent(event)
	end
	list[#list + 1] = fn
end

function S:Off(event, fn)
	local list = handlers[event]
	if not list then return end
	for i = #list, 1, -1 do
		if list[i] == fn then table.remove(list, i) end
	end
	if #list == 0 then
		handlers[event] = nil
		frame:UnregisterEvent(event)
	end
end

frame:SetScript("OnEvent", function(_, event, ...)
	local list = handlers[event]
	if not list then return end
	for i = 1, #list do
		local ok, err = pcall(list[i], event, ...)
		if not ok then geterrorhandler()(err) end
	end
end)

-- Saved settings with defaults.

local defaults = {
	modules = {},
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

-- Modules: every addon folder named Sempre_<Name> whose TOC we can see.

local function moduleList()
	local list = {}
	for i = 1, C_AddOns.GetNumAddOns() do
		local name = C_AddOns.GetAddOnInfo(i)
		if name == ADDON_NAME or (name and name:sub(1, 7) == "Sempre_") then
			list[#list + 1] = name
		end
	end
	sort(list)
	return list
end
S.ModuleList = moduleList

function S:LoadModule(name)
	if C_AddOns.IsAddOnLoaded(name) then return true end
	local loaded, reason = C_AddOns.LoadAddOn(name)
	if not loaded then
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
			perfRows[#perfRows + 1] = { name = name, kb = kb, budget = budgetOf(name) }
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
	S:Print("%s %s", S.version, L.LOADED)
end)
