-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Plain Lua 5.1 tests for Sempre/Core.lua with a stubbed WoW API.
-- Run from the repo root: lua5.1 tests/run.lua

local failures, count = 0, 0

local function check(cond, label)
	count = count + 1
	if not cond then
		failures = failures + 1
		print("FAIL: " .. label)
	end
end

local function same(a, b)
	return table.concat(a, ",") == table.concat(b, ",")
end

-- Loads a fresh copy of the core into its own environment.
-- addons: name -> { meta = {}, enabled = number|nil, fail = bool }
local function boot(addons, setup)
	addons = addons or {}
	local names = {}
	for name in pairs(addons) do names[#names + 1] = name end
	table.sort(names)
	table.insert(names, 1, "Sempre")
	addons.Sempre = addons.Sempre or { meta = {} }

	local env = { registered = {}, loaded = {}, enableCalls = {}, errors = {}, printed = {} }
	local frame = { scripts = {} }
	function frame.RegisterEvent(_, event)
		if event == "BOGUS_EVENT" then error("unknown event") end
		env.registered[event] = true
	end
	function frame.UnregisterEvent(_, event) env.registered[event] = nil end
	function frame.SetScript(_, kind, fn) frame.scripts[kind] = fn end
	env.frame = frame

	local g = setmetatable({}, { __index = _G })
	g.CreateFrame = function() return frame end
	g.GetLocale = function() return "enUS" end
	g.GetBuildInfo = function() return "1", "", "", 16001 end
	g.UnitName = function() return "Tester" end
	g.GetRealmName = function() return "Realm" end
	g.time = os.time
	g.geterrorhandler = function() return function(err) env.errors[#env.errors + 1] = err end end
	g.SlashCmdList = {}
	g.print = function(msg) env.printed[#env.printed + 1] = msg end
	-- The client adds table.wipe; give the core a copy of table that has it.
	g.table = setmetatable({ wipe = function(t) for k in pairs(t) do t[k] = nil end return t end }, { __index = table })
	g.C_AddOns = {
		GetAddOnMetadata = function(name, key)
			local a = addons[name]
			return a and a.meta[key]
		end,
		GetNumAddOns = function() return #names end,
		GetAddOnInfo = function(i) return names[i] end,
		IsAddOnLoaded = function(name) return env.loaded[name] == true end,
		EnableAddOn = function(name) env.enableCalls[#env.enableCalls + 1] = name end,
		LoadAddOn = function(name)
			if addons[name].fail then return false, "BROKEN" end
			env.loaded[name] = true
			env.loadOrder = env.loadOrder or {}
			env.loadOrder[#env.loadOrder + 1] = name
			return true
		end,
		GetAddOnEnableState = function(name)
			return addons[name].enabled
		end,
	}
	env.g = g
	if setup then setup(g, env) end

	local chunk = assert(loadfile("Sempre/Core.lua"))
	setfenv(chunk, g)
	chunk("Sempre")
	env.S = g.SempreUI
	return env
end

local function fire(env, event, ...)
	env.frame.scripts.OnEvent(env.frame, event, ...)
end

-- Message bus

do
	local env = boot()
	local S = env.S
	local seen = {}
	S:Listen("TEST_MSG", function(msg, a, b) seen[#seen + 1] = "1:" .. msg .. a .. b end)
	S:Listen("TEST_MSG", function(msg, a, b) seen[#seen + 1] = "2:" .. msg .. a .. b end)
	S:Send("TEST_MSG", "x", "y")
	check(same(seen, { "1:TEST_MSGxy", "2:TEST_MSGxy" }), "listeners run in order with arguments")
	S:Send("NOBODY_LISTENS", 1)
	check(true, "send without listeners is silent")
end

do
	local env = boot()
	local S = env.S
	local seen = {}
	S:Listen("M", function() error("boom") end)
	S:Listen("M", function() seen[#seen + 1] = "after" end)
	S:Send("M")
	check(same(seen, { "after" }), "erroring listener does not stop the next one")
	check(#env.errors == 1 and tostring(env.errors[1]):find("boom"), "error goes to the error handler")
end

do
	local env = boot()
	local S = env.S
	local seen = {}
	local selfRemoving
	selfRemoving = function() seen[#seen + 1] = "a"; S:Unlisten("M", selfRemoving) end
	S:Listen("M", selfRemoving)
	S:Listen("M", function() seen[#seen + 1] = "b" end)
	S:Listen("M", function() seen[#seen + 1] = "c" end)
	S:Send("M")
	check(same(seen, { "a", "b", "c" }), "self-removal: others run once")
	seen = {}
	S:Send("M")
	check(same(seen, { "b", "c" }), "self-removed listener is gone")
end

do
	local env = boot()
	local S = env.S
	local seen = {}
	local nextOne
	S:Listen("M", function() seen[#seen + 1] = "a"; S:Unlisten("M", nextOne) end)
	nextOne = function() seen[#seen + 1] = "b" end
	S:Listen("M", nextOne)
	S:Listen("M", function() seen[#seen + 1] = "c" end)
	S:Send("M")
	check(same(seen, { "a", "c" }), "removing the next listener skips only that one")
end

do
	local env = boot()
	local S = env.S
	local seen = {}
	S:Listen("M", function()
		seen[#seen + 1] = "a"
		S:Listen("M", function() seen[#seen + 1] = "late" end)
	end)
	S:Send("M")
	check(same(seen, { "a" }), "listener added during send is not called for it")
	seen = {}
	S:Send("M")
	check(seen[1] == "a" and seen[2] == "late", "added listener runs on the next send")
end

do
	-- Nested send of the same message with removal in the inner run.
	local env = boot()
	local S = env.S
	local seen = {}
	local depth = 0
	local b
	S:Listen("M", function()
		seen[#seen + 1] = "a" .. depth
		if depth == 0 then
			depth = 1
			S:Send("M")
			depth = 0
		else
			S:Unlisten("M", b)
		end
	end)
	b = function() seen[#seen + 1] = "b" end
	S:Listen("M", b)
	S:Listen("M", function() seen[#seen + 1] = "c" end)
	S:Send("M")
	-- Inner run: a1 (removes b), c. Outer continues: b is gone, c runs.
	check(same(seen, { "a0", "a1", "c", "c" }), "nested send with removal: " .. table.concat(seen, ","))
	seen = {}
	S:Send("M")
	check(same(seen, { "a0", "a1", "c", "c" }), "list stays consistent after nested send")
end

do
	-- Nested send of another message while removing.
	local env = boot()
	local S = env.S
	local seen = {}
	local one
	one = function() seen[#seen + 1] = "one"; S:Unlisten("OUTER", one) end
	S:Listen("INNER", one)
	S:Listen("OUTER", function() S:Send("INNER"); seen[#seen + 1] = "done" end)
	S:Listen("INNER", function() seen[#seen + 1] = "two" end)
	S:Send("OUTER")
	check(same(seen, { "one", "two", "done" }), "nested send of another message")
end

do
	local env = boot()
	local S = env.S
	S:Listen("PLAYER_LOGIN_X", function() end)
	S:Listen("PLAYER_ENTERING_WORLD", function() end)
	check(env.registered.PLAYER_ENTERING_WORLD == nil, "message named like an event does not register it")
	local hit = false
	S:On("PLAYER_ENTERING_WORLD", function() hit = true end)
	S:Send("PLAYER_ENTERING_WORLD")
	check(not hit and env.registered.PLAYER_ENTERING_WORLD, "message does not reach event handlers")
end

-- Event bus behaviour is unchanged

do
	local env = boot()
	local S = env.S
	local seen = {}
	check(S:On("FOO", function(e, x) seen[#seen + 1] = e .. x end) == true, "On returns true")
	check(env.registered.FOO, "On registers the event")
	fire(env, "FOO", 1)
	check(same(seen, { "FOO1" }), "event handler gets event and args")
	check(S:On("BOGUS_EVENT", function() end) == false, "unknown event returns false")
	check(env.printed[#env.printed]:find("BOGUS_EVENT"), "unknown event is reported")

	local a, b
	local order = {}
	a = function() order[#order + 1] = "a"; S:Off("BAR", a) end
	b = function() order[#order + 1] = "b" end
	S:On("BAR", a)
	S:On("BAR", b)
	fire(env, "BAR")
	check(same(order, { "a", "b" }), "Off during dispatch does not skip the next handler")
	order = {}
	fire(env, "BAR")
	check(same(order, { "b" }), "removed handler is gone")
	S:Off("BAR", b)
	check(env.registered.BAR, "Off alone keeps the event until it fires")
	fire(env, "BAR")
	check(env.registered.BAR == nil, "event unregistered after last handler was removed")
	order = {}
	S:On("BAR", b)
	fire(env, "BAR")
	check(same(order, { "b" }) and env.registered.BAR, "event can be added again")
	S:Off("NEVER", b)
	check(true, "Off for an unknown event is harmless")
end

-- Login modules

do
	local env = boot({
		Sempre_Zed = { meta = { ["X-Sempre-Module"] = "1", ["X-Sempre-LoadWith"] = "Login" }, enabled = 2 },
		Sempre_Alpha = { meta = { ["X-Sempre-Module"] = "1", ["X-Sempre-LoadWith"] = "Login" }, enabled = 1 },
		Sempre_Off = { meta = { ["X-Sempre-Module"] = "1", ["X-Sempre-LoadWith"] = "Login" }, enabled = 0 },
		Sempre_Broken = { meta = { ["X-Sempre-Module"] = "1", ["X-Sempre-LoadWith"] = "Login" }, enabled = 2, fail = true },
		Sempre_Lazy = { meta = { ["X-Sempre-Module"] = "1" }, enabled = 2 },
		Sempre_Other = { meta = { ["X-Sempre-LoadWith"] = "Login" }, enabled = 2 },
		Sempre_NoApi = { meta = { ["X-Sempre-Module"] = "1", ["X-Sempre-LoadWith"] = "Login" } },
	})
	env.S.db = nil
	fire(env, "ADDON_LOADED", "Sempre")
	fire(env, "PLAYER_LOGIN")
	check(same(env.loadOrder, { "Sempre_Alpha", "Sempre_NoApi", "Sempre_Zed" }),
		"login loads enabled Login modules alphabetically: " .. table.concat(env.loadOrder or {}, ","))
	check(not env.loaded.Sempre_Off, "disabled module is not loaded")
	check(not env.loaded.Sempre_Lazy and not env.loaded.Sempre_Other, "on-demand and foreign modules are left alone")
	check(#env.enableCalls == 0, "login path never calls EnableAddOn")
	local failed = 0
	for _, line in ipairs(env.printed) do
		if line:find("Sempre_Broken") then failed = failed + 1 end
	end
	check(failed == 1, "failing module prints the could-not-be-loaded message once")
	check(env.loaded.Sempre_Zed, "failing module does not stop later ones")
	check(#env.printed == 2, "one load line plus one failure line, nothing per module")

	env.S:LoadModule("Sempre_Lazy")
	check(env.loaded.Sempre_Lazy and env.enableCalls[1] == "Sempre_Lazy", "LoadModule still switches the module on")
end

do
	-- GetAddOnEnableState missing: treated as enabled.
	local env = boot({
		Sempre_A = { meta = { ["X-Sempre-Module"] = "1", ["X-Sempre-LoadWith"] = "Login" } },
	})
	env.g.C_AddOns.GetAddOnEnableState = nil
	fire(env, "ADDON_LOADED", "Sempre")
	fire(env, "PLAYER_LOGIN")
	check(env.loaded.Sempre_A, "missing GetAddOnEnableState counts as enabled")
end

-- Error collector

-- Installs stub error-handler functions; the handler is whatever was set last.
local function errSetup(extra)
	return function(g, env)
		env.prev = {}
		env.current = function(err) env.prev[#env.prev + 1] = err end
		g.geterrorhandler = function() return env.current end
		g.seterrorhandler = function(fn) env.current = fn end
		g.debugstack = function() return "Interface/AddOns/Other/A.lua:1: in a\nline2" end
		g.date = function() return "01.01. 12:00" end
		if extra then extra(g, env) end
	end
end

local function lastPrinted(env, n)
	local out = {}
	for i = math.max(1, #env.printed - n + 1), #env.printed do out[#out + 1] = env.printed[i] end
	return table.concat(out, "\n")
end

do
	local env = boot(nil, errSetup())
	env.current("Interface/AddOns/Other/A.lua:5: boom")
	check(#env.prev == 1 and env.prev[1]:find("boom"), "error still reaches the previous handler")
	fire(env, "ADDON_LOADED", "Sempre")
	local errs = env.S.db.global.errors
	check(#errs == 1 and errs[1].count == 1 and errs[1].ours == false, "early error moved into saved data, marked other")
	check(errs[1].version == env.S.version and errs[1].time and errs[1].stack, "record holds version, time, stack")
	env.current("Interface/AddOns/Other/A.lua:5: boom")
	check(#errs == 1 and errs[1].count == 2, "identical error counts up")
	env.current("Interface/AddOns/Other/A.lua:5: different")
	check(#errs == 2, "different message adds a record")
	check(#env.printed == 0, "foreign errors print no chat line")
	check(#env.prev == 3, "every error is passed on")
end

do
	local env = boot(nil, errSetup())
	fire(env, "ADDON_LOADED", "Sempre")
	for i = 1, 60 do env.current("Interface/AddOns/Other/A.lua:5: e" .. i) end
	local errs = env.S.db.global.errors
	check(#errs == 50 and errs[1].msg:find("e11$") and errs[50].msg:find("e60$"), "cap at 50 drops the oldest")
end

do
	local env = boot(nil, errSetup())
	fire(env, "ADDON_LOADED", "Sempre")
	env.current("Interface/AddOns/Other/A.lua:5: foreign")
	env.current("Interface/AddOns/Sempre_Items/X.lua:9: ours")
	env.current("Interface/AddOns/Sempre_Items/X.lua:9: ours2")
	check(#env.printed == 1 and env.printed[1]:find("/sempre errors"), "one chat line for the first own error")
	env.current("Interface/AddOns/Sempre/Core.lua:9: ours3")
	check(#env.printed == 1, "no further chat line in the session")
	env.commands = env.S.commands
	env.commands.fehler("")
	local out = lastPrinted(env, 4)
	local a, b, c = out:find("ours3"), out:find("ours2"), out:find("foreign")
	check(a and b and c and a < b and b < c, "own errors list first, newest first")
	check(out:find("%[other%]"), "foreign record is tagged")
	check(out:find("A.lua:1: in a", 1, true), "first stack line is listed")
	env.commands.errors("clear")
	check(#env.S.db.global.errors == 0, "clear empties the list")
	env.commands.fehler("")
	check(lastPrinted(env, 1) == "|cffc8794aSempre|r No errors recorded.", "empty list message")
end

do
	local env = boot(nil, errSetup())
	fire(env, "ADDON_LOADED", "Sempre")
	for i = 1, 12 do env.current("Interface/AddOns/Other/A.lua:5: e" .. i) end
	local before = #env.printed
	env.S.commands.fehler("")
	check(#env.printed - before == 11, "default list shows 10 plus a hint")
	before = #env.printed
	env.S.commands.fehler("alle")
	check(#env.printed - before == 12, "alle lists all")
end

do
	local env = boot(nil, errSetup(function(g) g.issecretvalue = function() error("collector broke") end end))
	env.current("msg")
	check(#env.prev == 1 and env.prev[1] == "msg", "failure inside the collector still passes the error on")
end

do
	local env = boot(nil, errSetup(function(g) g.issecretvalue = function(v) return v == "hidden" end end))
	fire(env, "ADDON_LOADED", "Sempre")
	env.current("hidden")
	check(env.S.db.global.errors[1].msg == "<secret>", "secret message is replaced by a placeholder")
end

do
	local env = boot(nil, errSetup(function(g)
		g.C_EventUtils = { IsEventValid = function(e) return e == "ADDON_ACTION_BLOCKED" end }
	end))
	check(env.registered.ADDON_ACTION_BLOCKED and not env.registered.ADDON_ACTION_FORBIDDEN, "only known blocked-action events are registered")
	check(#env.printed == 0, "no unknown-event warning")
	fire(env, "ADDON_LOADED", "Sempre")
	fire(env, "ADDON_ACTION_BLOCKED", "Sempre_Items", "Foo()")
	local r = env.S.db.global.errors[1]
	check(r and r.ours and r.msg:find("Sempre_Items") and r.msg:find("Foo%(%)"), "blocked action recorded")
	check(#env.prev == 0, "blocked action does not call the error handler")
end

do
	local env = boot()
	check(env.registered.ADDON_ACTION_BLOCKED == nil, "no C_EventUtils: blocked events skipped")
	local called = false
	env = boot(nil, function(g, e)
		g.geterrorhandler = function() return function() end end
		g.seterrorhandler = nil
		called = e ~= nil
	end)
	fire(env, "ADDON_LOADED", "Sempre")
	check(called and #env.printed == 0 and #env.S.db.global.errors == 0, "missing seterrorhandler leaves the feature off silently")
end

local bootItems = dofile("tests/items.lua")(check, same)
local bootLedger = dofile("tests/ledger.lua")(check)
dofile("tests/ledger2.lua")(check, bootLedger)
local bootLoot = dofile("tests/loot.lua")(check)
dofile("tests/fonts.lua")(check)
dofile("tests/mail.lua")(check, same)
dofile("tests/way.lua")(check)
dofile("tests/buttons.lua")(check)
dofile("tests/settings.lua")(check, same, { items = bootItems, loot = bootLoot })

print(string.format("%d checks, %d failed", count, failures))
os.exit(failures == 0 and 0 or 1)
