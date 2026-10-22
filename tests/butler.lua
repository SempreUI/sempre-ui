-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Tests for Sempre_Butler with a stubbed WoW API. Loaded by tests/run.lua, which
-- passes in its check helper. Boots the real core, then the module's file, with
-- stubbed bags, merchant, repair, resurrection, duel and error frame.

return function(check)

local function newFake(kind)
	local f = { kind = kind, shown = true, scripts = {}, registered = {} }
	return setmetatable(f, { __index = function() return function() end end })
end

local fakeMethods = {
	Show = function(self) self.shown = true end,
	Hide = function(self) self.shown = false end,
	IsShown = function(self) return self.shown end,
	SetScript = function(self, kind, fn) self.scripts[kind] = fn end,
	RegisterEvent = function(self, e) self.registered[e] = true end,
	UnregisterEvent = function(self, e) self.registered[e] = nil end,
}

local GREY, WHITE = 0, 1

-- opts: options (stored options), no (set of missing API names), valid (set of
-- event names the client does not know, as true), locale, keep, combat, money,
-- repairCost, canRepair, guild (false | allowance), instance, shift
local function boot(opts)
	opts = opts or {}
	local env = { printed = {}, errors = {}, frames = {}, calls = {}, timers = {}, sent = {},
		bags = {}, prices = {}, now = 100, combat = opts.combat or false, merchant = false,
		money = opts.money or 0, repairCost = opts.repairCost or 0, instance = opts.instance or "none" }
	local no = opts.no or {}
	local g = setmetatable({}, { __index = _G })
	g.table = setmetatable({ wipe = function(t) for k in pairs(t) do t[k] = nil end return t end }, { __index = table })
	g.CreateFrame = function(kind)
		local f = newFake(kind)
		for k, v in pairs(fakeMethods) do f[k] = v end
		env.frames[#env.frames + 1] = f
		return f
	end
	g.GetLocale = function() return opts.locale or "enUS" end
	g.GetBuildInfo = function() return "1", "", "", 16001 end
	g.UnitName = function() return "Tester" end
	g.GetRealmName = function() return "Realm" end
	g.issecretvalue = function(v) return v == env.secret end
	g.geterrorhandler = function() return function(err) env.errors[#env.errors + 1] = err end end
	g.SlashCmdList = {}
	g.print = function(msg) env.printed[#env.printed + 1] = msg end
	g.C_AddOns = { GetAddOnMetadata = function() return nil end, GetNumAddOns = function() return 0 end }
	g.C_EventUtils = { IsEventValid = function(e) return not (opts.valid and opts.valid[e]) end }
	g.Enum = { PlayerInteractionType = { Merchant = 5 } }
	g.GetTime = function() return env.now end
	g.InCombatLockdown = function() return env.combat end
	g.IsShiftKeyDown = function() return opts.shift or false end
	g.GetMoney = function() return env.money end
	g.IsInInstance = function() return env.instance ~= "none", env.instance end

	-- Bags: env.bags[bag][slot] = { quality, itemID, stackCount, isLocked, hasNoValue }
	g.C_Container = {
		GetContainerNumSlots = function(bag)
			local b = env.bags[bag]
			return b and b.n or 0
		end,
		GetContainerItemInfo = function(bag, slot)
			local it = env.bags[bag] and env.bags[bag][slot]
			if not it then return nil end
			return { quality = it.quality, itemID = it.itemID, stackCount = it.stackCount or 1,
				isLocked = it.isLocked, hasNoValue = it.hasNoValue }
		end,
		UseContainerItem = function(bag, slot)
			env.calls[#env.calls + 1] = "use:" .. bag .. ":" .. slot
			if not env.merchant then env.usedWithoutMerchant = true end
			env.bags[bag][slot] = nil
		end,
	}
	g.C_Item = {
		GetItemInfo = function(id)
			if env.uncached and env.uncached[id] then return nil end
			local price = env.prices[id]
			return "Item" .. id, nil, nil, nil, nil, nil, nil, nil, nil, nil, price
		end,
	}
	for name in pairs(no) do
		if name:find("^C_Container%.") then g.C_Container[name:sub(13)] = nil end
		if name == "C_Item.GetItemInfo" then g.C_Item.GetItemInfo = nil end
	end

	if not no.repair then
		g.CanMerchantRepair = function() return opts.canRepair ~= false end
		g.GetRepairAllCost = function() return env.repairCost, true end
		g.RepairAllItems = function(useGuild)
			env.calls[#env.calls + 1] = useGuild and "repair:guild" or "repair:own"
			if not useGuild then env.money = env.money - env.repairCost end
			env.repairCost = 0
		end
	end
	if opts.guild ~= nil then
		g.CanGuildBankRepair = function() return opts.guild ~= false end
		if opts.guild then g.GetGuildBankWithdrawMoney = function() return opts.guild end end
	end
	if not no.resurrect then
		g.AcceptResurrect = function() env.calls[#env.calls + 1] = "accept" end
	end
	g.C_Timer = no.timer and {} or { After = function(delay, fn) env.timers[#env.timers + 1] = { delay = delay, fn = fn } end }
	if not no.duel then
		g.CancelDuel = function() env.calls[#env.calls + 1] = "cancelduel" end
	end
	if not no.quiet then
		g.UIErrorsFrame = newFake("UIErrorsFrame")
		for k, v in pairs(fakeMethods) do g.UIErrorsFrame[k] = v end
		g.UIErrorsFrame.registered.UI_ERROR_MESSAGE = true
	end

	local function run(path, ...)
		local chunk = assert(loadfile(path))
		setfenv(chunk, g)
		return chunk(...)
	end
	env.g = g
	run("Sempre/Core.lua", "Sempre")
	env.S = g.SempreUI
	env.core = env.frames[1]
	function env.fire(event, ...) env.core.scripts.OnEvent(env.core, event, ...) end
	env.fire("ADDON_LOADED", "Sempre")
	if opts.options then env.S.db.global.options.Sempre_Butler = opts.options end
	env.fire("PLAYER_LOGIN")
	env.S:Listen("BUTLER_SOLD", function(_, count, copper) env.sent[#env.sent + 1] = "sold:" .. count .. ":" .. copper end)
	env.S:Listen("BUTLER_REPAIRED", function(_, copper, source) env.sent[#env.sent + 1] = "repaired:" .. copper .. ":" .. source end)
	if opts.keep then g.SempreButlerDB = { version = 1, keep = opts.keep } end
	env.printed = {}
	local before = #env.frames
	run("Sempre_Butler/Butler.lua", "Sempre_Butler")
	env.ticker = env.frames[before + 1]
	env.fire("ADDON_LOADED", "Sempre_Butler")
	env.db = g.SempreButlerDB
	env.loadPrinted = env.printed
	env.printed = {}

	function env.bag(bag, slots, items)
		env.bags[bag] = { n = slots }
		for slot, it in pairs(items) do env.bags[bag][slot] = it end
	end
	function env.open() env.merchant = true env.fire("MERCHANT_SHOW") end
	function env.close() env.merchant = false env.fire("MERCHANT_CLOSED") end
	function env.tick(dt)
		local fn = env.ticker.scripts.OnUpdate
		if fn and env.ticker.shown then fn(env.ticker, dt or 0.2) end
	end
	function env.ticks(n) for _ = 1, n do env.tick(0.2) end end
	function env.runTimers()
		local list = env.timers
		env.timers = {}
		for _, t in ipairs(list) do t.fn() end
	end
	function env.out() return table.concat(env.printed, "\n") end
	function env.count(prefix)
		local n = 0
		for _, c in ipairs(env.calls) do if c:find("^" .. prefix) then n = n + 1 end end
		return n
	end
	return env
end

local function grey(id, count) return { quality = GREY, itemID = id, stackCount = count } end

-- Registration and loading

do
	local env = boot()
	check(env.db and env.db.version == 1 and next(env.db.keep) == nil, "saved data created with version and keep list")
	check(env.S:GetOption("Sempre_Butler", "sell") == true and env.S:GetOption("Sempre_Butler", "repair") == true, "sell and repair default on")
	check(env.S:GetOption("Sempre_Butler", "guild_repair") == false and env.S:GetOption("Sempre_Butler", "resurrect") == false
		and env.S:GetOption("Sempre_Butler", "duel") == false and env.S:GetOption("Sempre_Butler", "quiet") == false, "other options default off")
	check(#env.S:GetOptionList("Sempre_Butler") == 6, "six checkboxes registered")
	check(#env.loadPrinted == 0, "no chat line at load when everything is available")
	check(env.core.registered.MERCHANT_SHOW and env.core.registered.MERCHANT_CLOSED, "plain merchant events registered")
	check(not env.core.registered.PLAYER_INTERACTION_MANAGER_FRAME_SHOW, "interaction events not registered as well")
	check(env.S.commands.butler ~= nil, "butler command registered")
end

-- Selling

do
	local env = boot()
	env.prices = { [10] = 100, [11] = 250, [12] = 500, [13] = 700, [14] = 900 }
	env.bag(0, 6, {
		[1] = grey(10, 3), -- 300
		[2] = { quality = WHITE, itemID = 12, stackCount = 1 },
		[3] = grey(11, 1), -- 250
		[4] = grey(99, 1), -- no vendor price
		[5] = { quality = GREY, itemID = 13, stackCount = 1, isLocked = true },
		[6] = { quality = GREY, itemID = 14, stackCount = 1, hasNoValue = true },
	})
	env.open()
	check(env.count("use:") == 0, "nothing is sold in the open event itself")
	check(env.ticker.shown, "ticker runs while there is work")
	env.tick(0.1)
	check(env.count("use:") == 0, "no sale before the interval is up")
	env.tick(0.1)
	check(env.count("use:") == 1 and env.calls[1] == "use:0:1", "first grey item sold after 0.2 s")
	check(#env.sent == 0, "no summary before the run ends")
	env.tick(0.2)
	check(env.count("use:") == 2 and env.calls[2] == "use:0:3", "one item per tick")
	check(not env.ticker.shown, "ticker stops when done")
	check(env.out() == "|cffc8794aSempre|r Butler: Junk sold: 4 items for 5s 50c", "summary line: " .. env.out())
	check(env.sent[1] == "sold:4:550", "BUTLER_SOLD carries count and copper")
	check(env.bags[0][2] and env.bags[0][4] and env.bags[0][5] and env.bags[0][6], "white, priceless, locked and no-value items stay")
	check(not env.usedWithoutMerchant, "every sale happened with the merchant open")
end

do
	-- Summary in German, gold formatting.
	local env = boot({ locale = "deDE" })
	env.prices = { [10] = 123456 }
	env.bag(0, 1, { [1] = grey(10, 1) })
	env.open()
	env.tick()
	check(env.out():find("Schrott verkauft: 1 Gegenstände für 12g 34s 56c", 1, true), "German summary line: " .. env.out())
end

do
	-- Keep list and uncached items.
	local env = boot({ keep = { [10] = true } })
	env.prices = { [10] = 100, [11] = 100, [12] = 100 }
	env.uncached = { [12] = true }
	env.bag(0, 3, { [1] = grey(10, 1), [2] = grey(11, 1), [3] = grey(12, 1) })
	env.open()
	env.ticks(5)
	check(env.count("use:") == 1 and env.calls[1] == "use:0:2", "keep-listed and uncached items are skipped")
end

do
	-- Shift skips; option off; nothing to sell.
	local env = boot({ shift = true })
	env.prices = { [10] = 100 }
	env.bag(0, 1, { [1] = grey(10, 1) })
	env.open()
	env.ticks(3)
	check(env.count("use:") == 0 and not env.ticker.shown and env.out() == "", "Shift while opening skips selling")

	env = boot({ options = { sell = false } })
	env.prices = { [10] = 100 }
	env.bag(0, 1, { [1] = grey(10, 1) })
	env.open()
	env.ticks(3)
	check(env.count("use:") == 0, "sell option off sells nothing")

	env = boot()
	env.bag(0, 1, { [1] = { quality = WHITE, itemID = 5 } })
	env.open()
	check(not env.ticker.shown and env.out() == "", "no grey items: no run, no line")
end

do
	-- Stop on merchant close, with the partial summary.
	local env = boot()
	env.prices = { [10] = 100 }
	env.bag(0, 5, { [1] = grey(10, 1), [2] = grey(10, 1), [3] = grey(10, 1) })
	env.open()
	env.ticks(2)
	env.close()
	check(env.count("use:") == 2 and not env.ticker.shown, "closing the merchant stops selling")
	check(env.out():find("Junk sold: 2 items for 2s 0c", 1, true) ~= nil, "partial summary after close: " .. env.out())
	env.ticks(3)
	check(env.count("use:") == 2 and not env.usedWithoutMerchant, "nothing sold after close")
	check(env.sent[1] == "sold:2:200", "BUTLER_SOLD after a partial run")

	-- Stop on combat.
	env = boot()
	env.prices = { [10] = 100 }
	env.bag(0, 5, { [1] = grey(10, 1), [2] = grey(10, 1), [3] = grey(10, 1) })
	env.open()
	env.tick()
	env.combat = true
	env.fire("PLAYER_REGEN_DISABLED")
	env.ticks(3)
	check(env.count("use:") == 1 and not env.ticker.shown, "combat stops selling")
	check(env.sent[1] == "sold:1:100", "combat stop still reports what was sold")

	-- Combat flag without the event: checked before every sale.
	env = boot()
	env.prices = { [10] = 100 }
	env.bag(0, 5, { [1] = grey(10, 1), [2] = grey(10, 1) })
	env.open()
	env.tick()
	env.combat = true
	env.tick()
	check(env.count("use:") == 1 and not env.ticker.shown, "combat lockdown checked before each sale")

	-- Opening a merchant in combat sells nothing.
	env = boot({ combat = true })
	env.prices = { [10] = 100 }
	env.bag(0, 1, { [1] = grey(10, 1) })
	env.open()
	env.ticks(2)
	check(env.count("use:") == 0, "no selling in combat")
end

do
	-- Cap of 60 per visit across bags, slot changed meanwhile is skipped.
	local env = boot()
	env.prices = { [10] = 1 }
	local items = {}
	for i = 1, 40 do items[i] = grey(10, 1) end
	env.bag(0, 40, items)
	local items2 = {}
	for i = 1, 40 do items2[i] = grey(10, 1) end
	env.bag(1, 40, items2)
	env.open()
	env.ticks(100)
	check(env.count("use:") == 60, "at most 60 sales per visit: " .. env.count("use:"))
	check(env.sent[1] == "sold:60:60", "summary counts 60")

	env = boot()
	env.prices = { [10] = 100, [11] = 100 }
	env.bag(0, 3, { [1] = grey(10, 1), [2] = grey(11, 1), [3] = grey(11, 1) })
	env.open()
	env.bags[0][1] = nil -- sold elsewhere
	env.bags[0][2] = { quality = WHITE, itemID = 11 } -- replaced
	env.tick()
	check(env.count("use:") == 1 and env.calls[1] == "use:0:3", "slots that changed are skipped without waiting")
end

do
	-- Secret quality is not sold.
	local env = boot()
	env.secret = {}
	env.prices = { [10] = 100 }
	env.bag(0, 1, { [1] = { quality = env.secret, itemID = 10, stackCount = 1 } })
	env.open()
	env.ticks(2)
	check(env.count("use:") == 0, "secret value is never used in logic")
end

-- Repair

do
	local env = boot({ money = 5000, repairCost = 1234 })
	env.prices = { [10] = 100 }
	env.bag(0, 1, { [1] = grey(10, 1) })
	env.open()
	check(env.calls[1] == "repair:own" and env.count("use:") == 0, "repair happens in the open event, before any sale")
	env.tick()
	check(env.calls[2] == "use:0:1", "selling follows the repair")
	check(env.out():find("Repaired for 12s 34c.", 1, true), "repair line: " .. env.out())
	check(env.sent[1] == "repaired:1234:own", "BUTLER_REPAIRED with own source")
end

do
	local env = boot({ money = 100, repairCost = 1234 })
	env.open()
	check(env.count("repair") == 0, "no repair without the money")
	check(env.out() == "|cffc8794aSempre|r Butler: Repair costs 12s 34c, you are missing 11s 34c.", "missing money line: " .. env.out())
	check(#env.sent == 0, "no BUTLER_REPAIRED without a repair")
end

do
	local env = boot({ money = 100, repairCost = 0 })
	env.open()
	check(env.count("repair") == 0 and env.out() == "", "nothing to repair: no call, no line")
	env = boot({ money = 5000, repairCost = 500, canRepair = false })
	env.open()
	check(env.count("repair") == 0 and env.out() == "", "merchant cannot repair: nothing happens")
	env = boot({ money = 5000, repairCost = 500, options = { repair = false } })
	env.open()
	check(env.count("repair") == 0, "repair option off")
end

do
	-- Guild funds.
	local env = boot({ money = 5000, repairCost = 800, guild = -1, options = { guild_repair = true } })
	env.open()
	check(env.calls[1] == "repair:guild" and env.money == 5000, "guild funds pay first")
	check(env.out():find("from the guild bank", 1, true) and env.sent[1] == "repaired:800:guild", "guild line and message")

	env = boot({ money = 5000, repairCost = 800, guild = 300, options = { guild_repair = true } })
	env.open()
	check(env.calls[1] == "repair:own", "allowance too small: own money pays")

	env = boot({ money = 5000, repairCost = 800, guild = false, options = { guild_repair = true } })
	env.open()
	check(env.calls[1] == "repair:own", "guild bank not allowing: own money pays")

	env = boot({ money = 5000, repairCost = 800, guild = -1 })
	env.open()
	check(env.calls[1] == "repair:own", "guild option off: own money")

	env = boot({ money = 10, repairCost = 800, guild = -1, options = { guild_repair = true } })
	env.open()
	check(env.calls[1] == "repair:guild", "guild pays even when own money is short")
end

-- Merchant events

do
	-- Interaction manager as fallback.
	local env = boot({ valid = { MERCHANT_SHOW = true, MERCHANT_CLOSED = true } })
	check(env.core.registered.PLAYER_INTERACTION_MANAGER_FRAME_SHOW and not env.core.registered.MERCHANT_SHOW, "interaction events used when the plain ones are unknown")
	env.prices = { [10] = 100 }
	env.bag(0, 1, { [1] = grey(10, 1) })
	env.merchant = true
	env.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 7)
	env.ticks(2)
	check(env.count("use:") == 0, "other interaction types are ignored")
	env.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 5)
	env.tick()
	check(env.count("use:") == 1, "merchant interaction starts the run")
	env.merchant = false
	env.fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 5)
	check(not env.ticker.shown, "merchant interaction hide ends it")
end

-- Resurrection

do
	local env = boot({ options = { resurrect = true } })
	env.fire("RESURRECT_REQUEST", "Healer")
	check(#env.timers == 1 and env.timers[1].delay == 1 and env.count("accept") == 0, "accept waits one second")
	env.runTimers()
	check(env.count("accept") == 1 and env.out():find("Resurrection accepted", 1, true), "resurrection accepted after the delay")

	env = boot({ options = { resurrect = true }, combat = true })
	env.fire("RESURRECT_REQUEST", "Healer")
	check(#env.timers == 0, "no accept in combat")

	env = boot({ options = { resurrect = true } })
	env.fire("RESURRECT_REQUEST", "Healer")
	env.combat = true
	env.runTimers()
	check(env.count("accept") == 0, "combat starting during the delay cancels it")

	env = boot({ options = { resurrect = true }, instance = "pvp" })
	env.fire("RESURRECT_REQUEST", "Healer")
	check(#env.timers == 0, "no accept in a battleground")
	env.instance = "arena"
	env.fire("RESURRECT_REQUEST", "Healer")
	check(#env.timers == 0, "no accept in an arena")
	env.instance = "party"
	env.fire("RESURRECT_REQUEST", "Healer")
	check(#env.timers == 1, "accept in a dungeon")

	env = boot()
	env.fire("RESURRECT_REQUEST", "Healer")
	check(#env.timers == 0, "option off: nothing happens")

	env = boot({ options = { resurrect = true } })
	env.secret = {}
	env.fire("RESURRECT_REQUEST", env.secret)
	env.runTimers()
	check(env.count("accept") == 1, "secret caster name does not matter")
end

-- Duels

do
	local env = boot({ options = { duel = true } })
	env.fire("DUEL_REQUESTED", "Bob")
	check(env.count("cancelduel") == 1 and env.out():find("Duel declined", 1, true), "duel declined with one line")
	env.printed = {}
	env.now = 105
	env.fire("DUEL_REQUESTED", "Bob")
	check(env.count("cancelduel") == 2 and env.out() == "", "second request declined, line throttled")
	env.now = 111
	env.fire("DUEL_REQUESTED", "Bob")
	check(env.count("cancelduel") == 3 and env.out():find("Duel declined", 1, true), "line again after 10 seconds")

	env = boot()
	env.fire("DUEL_REQUESTED", "Bob")
	check(env.count("cancelduel") == 0, "duel option off: nothing happens")
end

-- Quiet error text

do
	local env = boot()
	local f = env.g.UIErrorsFrame
	check(f.registered.UI_ERROR_MESSAGE, "error frame untouched while the option is off")
	env.S:SetOption("Sempre_Butler", "quiet", true)
	check(not f.registered.UI_ERROR_MESSAGE, "error frame unregistered when switched on")
	env.S:SetOption("Sempre_Butler", "quiet", false)
	check(f.registered.UI_ERROR_MESSAGE, "error frame registered again when switched off")
	env.S:SetOption("Sempre_Butler", "sell", false)
	check(f.registered.UI_ERROR_MESSAGE, "other options leave it alone")

	env = boot({ options = { quiet = true } })
	check(not env.g.UIErrorsFrame.registered.UI_ERROR_MESSAGE, "option on at load unregisters")
end

-- Everything off

do
	local env = boot({ money = 5000, repairCost = 800, options = { sell = false, repair = false } })
	env.prices = { [10] = 100 }
	env.bag(0, 1, { [1] = grey(10, 1) })
	env.open()
	env.ticks(3)
	env.fire("RESURRECT_REQUEST", "x")
	env.fire("DUEL_REQUESTED", "x")
	env.runTimers()
	check(#env.calls == 0 and env.out() == "" and #env.sent == 0 and #env.timers == 0, "every option off: nothing happens")
end

-- Missing API

do
	local env = boot({ no = { ["C_Container.UseContainerItem"] = true } })
	check(#env.loadPrinted == 1 and env.loadPrinted[1]:find("Sell junk", 1, true), "missing sell function: one line at load")
	env.prices = { [10] = 100 }
	env.bag(0, 1, { [1] = grey(10, 1) })
	env.money, env.repairCost = 5000, 100
	env.open()
	env.ticks(2)
	check(env.calls[1] == "repair:own" and env.count("use:") == 0, "only selling is off, repair still works")
	local disabled
	for _, opt in ipairs(env.S:GetOptionList("Sempre_Butler")) do
		if opt.key == "sell" then disabled = opt.disabled() end
	end
	check(disabled ~= nil, "settings window gets a reason for the unavailable option")

	env = boot({ no = { repair = true }, options = { repair = true } })
	check(#env.loadPrinted == 1 and env.loadPrinted[1]:find("Repair", 1, true), "missing repair functions: one line")
	env.prices = { [10] = 100 }
	env.bag(0, 1, { [1] = grey(10, 1) })
	env.open()
	env.tick()
	check(env.count("use:") == 1, "selling still works without repair functions")

	env = boot({ no = { duel = true } })
	check(#env.loadPrinted == 0, "missing function of a switched-off feature: no line at load")
	env.S:SetOption("Sempre_Butler", "duel", true)
	check(#env.printed == 1 and env.printed[1]:find("Decline duels", 1, true), "line when the player switches it on")
	env.S:SetOption("Sempre_Butler", "duel", false)
	env.S:SetOption("Sempre_Butler", "duel", true)
	check(#env.printed == 1, "the line comes once per session")
	env.fire("DUEL_REQUESTED", "x")
	check(env.count("cancelduel") == 0, "no duel call without the function")

	env = boot({ no = { quiet = true }, options = { quiet = true } })
	check(#env.loadPrinted == 1 and env.loadPrinted[1]:find("Hide error text", 1, true), "missing error frame: one line, no error")

	env = boot({ no = { timer = true }, options = { resurrect = true } })
	check(#env.loadPrinted == 1, "missing timer disables resurrection with one line")
	env.fire("RESURRECT_REQUEST", "x")
	check(env.count("accept") == 0, "no accept without a timer")
	check(#env.errors == 0, "no Lua errors from missing functions")
end

-- Keep list command

do
	local env = boot()
	local cmd = env.S.commands.butler
	cmd("")
	check(env.out():find("Sell junk at the merchant: on", 1, true) and env.out():find("Use guild funds for repairs: off", 1, true), "state lists every option")
	check(env.out():find("Keep: nothing on the list.", 1, true), "empty keep list printed")
	env.printed = {}
	cmd("keep |cff9d9d9d|Hitem:1234::::::::|h[Rag]|h|r")
	check(env.db.keep[1234] == true and env.out():find("[Rag] is kept", 1, true), "keep by link")
	cmd("behalten 77")
	check(env.db.keep[77] == true, "keep by ID")
	env.printed = {}
	cmd("keep 77")
	check(env.out():find("already on the list", 1, true), "adding twice says so")
	env.printed = {}
	cmd("")
	check(env.out():find("Keep (2): Item77, Item1234", 1, true), "keep list printed with names: " .. env.out())
	env.printed = {}
	cmd("remove 77")
	check(env.db.keep[77] == nil and env.out():find("off the list", 1, true), "remove by ID")
	env.printed = {}
	cmd("weg 77")
	check(env.out():find("not on the list", 1, true), "removing an unknown item says so")
	env.printed = {}
	cmd("keep")
	check(env.out():find("/sempre butler keep", 1, true), "missing item prints the usage")
	env.printed = {}
	cmd("keep banana")
	check(env.out():find("not an item", 1, true), "garbage is rejected")
	env.printed = {}
	cmd("frobnicate 5")
	check(env.out():find("/sempre butler keep", 1, true), "unknown subcommand prints the usage")

	-- Kept items are really not sold, including ones added after the scan.
	env.prices = { [1234] = 100, [55] = 100 }
	env.bag(0, 2, { [1] = grey(1234, 1), [2] = grey(55, 1) })
	env.open()
	env.ticks(3)
	check(env.count("use:") == 1 and env.calls[#env.calls] == "use:0:2", "keep list protects from selling")
end

do
	local env = boot({ locale = "deDE" })
	env.S.commands.butler("behalten 5")
	check(env.out():find("wird behalten", 1, true), "German keep line")
	env.printed = {}
	env.S.commands.butler("")
	check(env.out():find("Schrott beim Händler verkaufen: an", 1, true), "German state line")
end

end
