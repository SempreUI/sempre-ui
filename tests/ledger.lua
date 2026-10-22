-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Tests for Sempre_Ledger with a stubbed WoW API. Loaded by tests/run.lua, which
-- passes in its check helpers. Boots the real core, then the module's file.

return function(check)

local T0 = os.time({ year = 2026, month = 10, day = 21, hour = 12, min = 0, sec = 0 })
local DAY = 86400

-- Interaction types as the stub enum knows them.
local TYPE = { Merchant = 5, TaxiNode = 6, Trainer = 7, MailInfo = 17, Auctioneer = 21, TradePartner = 3, GuildBanker = 10 }
local SECRET = {}

-- opts: db (preset SempreLedgerDB), itemsDB (SempreItemsDB), money, now, early
-- (module loads before PLAYER_LOGIN), noInteraction (classic events only),
-- noHooks (no hooksecurefunc), noInvoice (no GetInboxInvoiceInfo), unknown (event -> true)
local function boot(opts)
	opts = opts or {}
	local env = { frames = {}, printed = {}, errors = {}, money = opts.money or 1000000, now = opts.now or T0, clock = 100 }
	local g = setmetatable({}, { __index = _G })
	g.table = setmetatable({ wipe = function(t) for k in pairs(t) do t[k] = nil end return t end }, { __index = table })
	g.CreateFrame = function()
		local f = { registered = {}, scripts = {} }
		function f.RegisterEvent(_, e)
			if opts.unknown and opts.unknown[e] then error("unknown event") end
			f.registered[e] = true
		end
		function f.UnregisterEvent(_, e) f.registered[e] = nil end
		function f.SetScript(_, k, fn) f.scripts[k] = fn end
		env.frames[#env.frames + 1] = f
		return f
	end
	g.time = function(t) if t then return os.time(t) end return env.now end
	g.date = os.date
	g.GetTime = function() return env.clock end
	g.GetLocale = function() return "enUS" end
	g.GetBuildInfo = function() return "1", "", "", 16001 end
	g.UnitName = function() return "Tester" end
	g.GetRealmName = function() return "Realm" end
	g.GetMoney = function() return env.money end
	g.issecretvalue = function(v) return v == SECRET end
	g.geterrorhandler = function() return function(err) env.errors[#env.errors + 1] = err end end
	g.SlashCmdList = {}
	g.print = function(msg) env.printed[#env.printed + 1] = msg end
	g.C_AddOns = { GetAddOnMetadata = function() return nil end, GetNumAddOns = function() return 0 end }
	g.C_EventUtils = { IsEventValid = function(e) return not (opts.unknown and opts.unknown[e]) end }
	g.Enum = opts.noInteraction and {} or { PlayerInteractionType = TYPE }

	-- Original functions that the module hooks; hooksecurefunc wraps them.
	env.prices = { [100] = 25, [101] = 7 }
	env.requested = {}
	env.bag = {} -- "bag:slot" -> info
	env.buyback = {} -- index -> { link, qty }
	env.nameLinks = {} -- item name -> item ID, answered by GetItemInfo(name)
	env.instant = {} -- item name -> item ID, answered by GetItemInfoInstant(name)
	g.C_Item = {
		GetItemInfoInstant = function(name) return env.instant[name] end,
		GetItemInfo = function(id)
			if type(id) == "string" then
				local found = env.nameLinks[id]
				if found then return id, "|cffffffff|Hitem:" .. found .. "::::|h[" .. id .. "]|h|r" end
				return nil
			end
			local price = env.prices[id]
			if price then return "Item" .. id, "link", 1, 1, 1, "", "", 20, "", 0, price end
		end,
		RequestLoadItemDataByID = function(id) env.requested[#env.requested + 1] = id end,
	}
	env.auctions = {} -- auctionID -> auction info
	g.C_AuctionHouse = {
		PostItem = function() end, PostCommodity = function() end,
		ConfirmCommoditiesPurchase = function() end, PlaceBid = function() end,
		GetAuctionInfoByID = function(id) return env.auctions[id] end,
	}
	g.C_Item.GetItemID = function(location) return location.itemID end
	g.C_Container = {
		UseContainerItem = function() end,
		GetContainerItemInfo = function(bag, slot) return env.bag[bag .. ":" .. slot] end,
	}
	g.RepairAllItems = function() end
	g.BuybackItem = function() end
	g.GetBuybackItemLink = function(i) return env.buyback[i] and env.buyback[i][1] end
	g.GetBuybackItemInfo = function(i) return "n", 0, 0, env.buyback[i] and env.buyback[i][2] end
	g.TakeTaxiNode = function() end
	env.merchant = {} -- index -> { link, perPurchase }
	g.BuyMerchantItem = function() end
	g.GetMerchantItemLink = function(i) return env.merchant[i] and env.merchant[i][1] end
	g.GetMerchantItemInfo = function(i) return "n", 0, 0, env.merchant[i] and env.merchant[i][2] or 1 end
	g.SendMail = function() end
	g.TakeInboxMoney = function() end
	env.inbox = {} -- index -> { sender, money }
	g.GetInboxHeaderInfo = function(i)
		local m = env.inbox[i]
		return nil, nil, m.sender, m.subject or "subject", m.money
	end
	g.GetInboxNumItems = function() return #env.inbox end
	-- invoice = { type, name, buyer, bid, buyout, deposit, cut, delay, a, b, count }
	g.GetInboxInvoiceInfo = function(i)
		local inv = env.inbox[i] and env.inbox[i].invoice
		if inv then return unpack(inv, 1, 11) end
	end
	if opts.noInvoice then g.GetInboxInvoiceInfo = nil end
	g.AUCTION_SOLD_MAIL_SUBJECT = "Auction successful: %s"
	g.AUCTION_OUTBID_MAIL_SUBJECT = "Outbid on %s"
	g.AUCTION_EXPIRED_MAIL_SUBJECT = "Auction expired: %s"
	g.AUCTION_CANCELLED_MAIL_SUBJECT = "Auction cancelled: %s"
	g.AUCTION_REMOVED_MAIL_SUBJECT = "Auction removed: %s"
	g.AUCTION_WON_MAIL_SUBJECT = "Auction won: %s"
	if not opts.noHooks then
		g.hooksecurefunc = function(a, b, c)
			local tbl, name, fn = g, a, b
			if type(a) == "table" then tbl, name, fn = a, b, c end
			local orig = tbl[name]
			tbl[name] = function(...)
				local r = orig(...)
				fn(...)
				return r
			end
		end
	end
	if opts.db then g.SempreLedgerDB = opts.db end
	if opts.itemsDB then g.SempreItemsDB = opts.itemsDB end

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
	env.changes = {}
	env.S:Listen("LEDGER_CHANGED", function(_, key, source) env.changes[#env.changes + 1] = key .. ":" .. source end)
	if opts.early then
		run("Sempre_Ledger/Ledger.lua", "Sempre_Ledger")
		env.fire("ADDON_LOADED", "Sempre_Ledger")
		env.fire("PLAYER_LOGIN")
	else
		env.fire("PLAYER_LOGIN")
		run("Sempre_Ledger/Ledger.lua", "Sempre_Ledger")
		env.fire("ADDON_LOADED", "Sempre_Ledger")
	end
	env.bootPrinted = env.printed
	env.printed = {}
	env.db = g.SempreLedgerDB
	env.Ledger = env.S.Ledger
	env.rec = env.db and env.db.chars["Tester-Realm"]

	function env.pay(delta)
		env.money = env.money + delta
		env.fire("PLAYER_MONEY")
	end
	-- Opens or closes a window through the interaction manager.
	function env.show(name) env.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", TYPE[name]) end
	function env.hide(name) env.fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", TYPE[name]) end
	function env.today() return env.rec.days[os.date("%Y-%m-%d", env.now)] end
	function env.out() return table.concat(env.printed, "\n") end
	return env
end
-- Shared with tests/ledger2.lua.
local bootShared = boot

local function key(offset) return os.date("%Y-%m-%d", T0 - offset * DAY) end

-- Baseline and saved data

do
	local env = boot()
	check(#env.errors == 0, "module loads without handler errors: " .. tostring(env.errors[1]))
	check(env.db.version == 2 and env.rec and next(env.rec.days) == nil, "login books nothing")
	check(env.rec.session.startMoney == 1000000, "session starts with the login money")
	env.pay(500)
	check(env.today().income.other == 500, "first change after login is booked")
	check(env.changes[1] == "Tester-Realm:other", "LEDGER_CHANGED carries char key and source")
end

do
	-- Money that changed while the module did not run is not income.
	local first = boot()
	first.pay(100)
	local env = boot({ db = first.db, money = 9999999 })
	check(env.rec.days[os.date("%Y-%m-%d", T0)].income.other == 100, "old bookings stay")
	check(env.today().income.other == 100 and env.today().expense.other == nil, "difference while away is not booked")
	env.pay(-50)
	check(env.today().expense.other == 50, "the next change counts from the new baseline")
	-- Login and reload read the baseline again.
	env.money = env.money + 777
	env.fire("PLAYER_ENTERING_WORLD", true, false)
	env.pay(1)
	check(env.today().income.other == 101, "entering the world resets the baseline silently")
	env.money = env.money + 777
	env.fire("PLAYER_ENTERING_WORLD", false, false)
	env.pay(1)
	check(env.today().income.other == 101 + 778, "plain zoning does not reset it")
end

do
	-- A module loaded before PLAYER_LOGIN starts at login and has its hooks.
	local env = boot({ early = true })
	check(env.rec and env.rec.session, "start waits for the login event")
	env.show("Merchant")
	env.g.RepairAllItems()
	env.pay(-80)
	check(env.today().expense.repair == 80, "hooks from ADDON_LOADED work after a late start")
end

-- Source by context

local sources = {
	{ "vendor", function(e) e.show("Merchant") end, 10 },
	{ "mail", function(e) e.show("MailInfo") end, 10 },
	{ "auction", function(e) e.show("Auctioneer") end, 10 },
	{ "trainer", function(e) e.show("Trainer") end, -10 },
	{ "flight", function(e) e.show("TaxiNode") end, -10 },
	{ "trade", function(e) e.show("TradePartner") end, 10 },
	{ "guildbank", function(e) e.show("GuildBanker") end, 10 },
	{ "loot", function(e) e.fire("LOOT_OPENED") end, 10 },
	{ "other", function() end, 10 },
}
for _, case in ipairs(sources) do
	local env = boot()
	case[2](env)
	env.pay(case[3])
	local side = case[3] > 0 and "income" or "expense"
	check(env.today()[side][case[1]] == 10, "source " .. case[1])
end

do
	-- Classic events only (no interaction manager).
	local classic = {
		{ "vendor", "MERCHANT_SHOW", "MERCHANT_CLOSED" }, { "mail", "MAIL_SHOW", "MAIL_CLOSED" },
		{ "auction", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED" }, { "trainer", "TRAINER_SHOW", "TRAINER_CLOSED" },
		{ "flight", "TAXIMAP_OPENED", "TAXIMAP_CLOSED" }, { "trade", "TRADE_SHOW", "TRADE_CLOSED" },
		{ "guildbank", "GUILDBANKFRAME_OPENED", "GUILDBANKFRAME_CLOSED" },
	}
	for _, case in ipairs(classic) do
		local env = boot({ noInteraction = true })
		env.fire(case[2])
		env.pay(10)
		env.fire(case[3])
		env.clock = env.clock + 5
		env.pay(10)
		check(env.today().income[case[1]] == 10 and env.today().income.other == 10, "classic events: " .. case[1])
	end
end

do
	-- Money that arrives just after the trade or quest reward window closed.
	for _, case in ipairs({ { "trade", "TRADE_SHOW", "TRADE_CLOSED" }, { "quest", "QUEST_COMPLETE", "QUEST_FINISHED" } }) do
		local env = boot({ noInteraction = true })
		env.fire(case[2])
		env.fire(case[3])
		env.pay(10)
		check(env.today().income[case[1]] == 10, "money right after closing: " .. case[1])
	end
end

do
	local env = boot()
	env.show("Merchant")
	env.pay(10)
	env.hide("Merchant")
	env.pay(10)
	check(env.today().income.vendor == 10 and env.today().income.other == 10, "closing the window ends the context")
	env.show("Merchant")
	env.show("MailInfo")
	env.pay(5)
	check(env.today().income.vendor == 15 and not env.today().income.mail, "first match wins: vendor before mail")
end

do
	-- Repair split.
	local env = boot()
	env.show("Merchant")
	env.g.RepairAllItems()
	env.pay(-300)
	check(env.today().expense.repair == 300, "money after a repair is a repair")
	env.pay(-40)
	check(env.today().expense.vendor == 40 and env.today().expense.repair == 300, "next change is a plain vendor change")
	env.g.RepairAllItems()
	env.clock = env.clock + 10
	env.pay(-5)
	check(env.today().expense.vendor == 45, "a repair marker expires")
	env.g.RepairAllItems()
	env.pay(200)
	check(env.today().income.vendor == 200, "a gain after a repair is not a repair")
	env.g.RepairAllItems(true)
	env.clock = env.clock + 1
	env.pay(-7)
	check(env.today().expense.vendor == 52, "guild bank repair sets no marker")
	env.hide("Merchant")
	env.g.RepairAllItems()
	env.pay(-9)
	check(env.today().expense.other == 9, "repair marker needs the merchant window")
end

do
	-- Flight: window and the seconds after taking a flight.
	local env = boot()
	env.g.TakeTaxiNode(3)
	env.clock = env.clock + 4
	env.pay(-120)
	check(env.today().expense.flight == 120, "change within a few seconds of taking a flight")
	env.clock = env.clock + 6
	env.pay(-5)
	check(env.today().expense.other == 5, "later changes are not flights")
end

do
	-- Quest and loot windows.
	local env = boot()
	env.fire("QUEST_TURNED_IN", 1234)
	env.clock = env.clock + 0.5
	env.pay(800)
	check(env.today().income.quest == 800, "reward within a second of the turn-in")
	env.clock = env.clock + 1.5
	env.pay(8)
	check(env.today().income.other == 8, "quest window is a second")
	env.fire("LOOT_OPENED")
	env.pay(30)
	env.fire("LOOT_CLOSED")
	env.clock = env.clock + 0.5
	env.pay(4)
	env.clock = env.clock + 2
	env.pay(2)
	check(env.today().income.loot == 34 and env.today().income.other == 10, "loot while open and a second after closing")
	env.show("MailInfo")
	env.fire("QUEST_TURNED_IN", 1)
	env.pay(1)
	check(env.today().income.mail == 1, "mail outranks quest")
end

-- Transfers between own characters

do
	local items = { chars = { ["Alt-Some Realm"] = {}, ["Tester-Realm"] = {} } }
	local env = boot({ itemsDB = items })
	env.show("MailInfo")
	env.g.SendMail("Alt-SomeRealm", "s", "b")
	env.pay(-10000)
	check(env.today().expense.transfer == 10000 and not env.today().expense.mail, "money to an own character is a transfer")
	check(env.Ledger.GetSession().expense == 0, "transfer is not a session expense")
	env.g.SendMail("Stranger", "s", "b")
	env.pay(-2000)
	check(env.today().expense.mail == 2000, "money to someone else is a mail expense")
	env.g.SendMail("Alt-SomeRealm", "s", "b")
	env.clock = env.clock + 20
	env.pay(-30)
	check(env.today().expense.mail == 2030, "send marker expires")

	-- Receiving side.
	env.inbox[1] = { sender = "Alt-SomeRealm", money = 5000 }
	env.inbox[2] = { sender = "Stranger", money = 200 }
	env.g.TakeInboxMoney(1)
	env.pay(5000)
	check(env.today().income.transfer == 5000 and not env.today().income.mail, "money from an own character is a transfer")
	env.g.TakeInboxMoney(2)
	env.pay(200)
	check(env.today().income.mail == 200, "money from a stranger is income")
	env.g.TakeInboxMoney(1)
	env.g.TakeInboxMoney(2)
	env.pay(5200)
	check(env.today().income.transfer == 10000 and env.today().income.mail == 400, "one combined change is split")
	local range = env.Ledger.GetRange("Tester-Realm", 1)
	check(range.incomeTotal == 400 and range.expenseTotal == 2030 and range.net == 400 - 2030, "transfers never count in totals")
	check(env.Ledger.GetSession().income == 400, "nor in the session")
	env.inbox[3] = { sender = SECRET, money = 50 }
	env.g.TakeInboxMoney(3)
	env.pay(50)
	check(env.today().income.mail == 450 and #env.errors == 0, "secret sender is just income")
end

do
	-- Own characters from the ledger's own list when Sempre_Items is absent.
	local env = boot({ db = { version = 1, chars = { ["Mule-Realm"] = { days = {} } } } })
	env.show("MailInfo")
	env.g.SendMail("Mule", "s", "b")
	env.pay(-500)
	check(env.today().expense.transfer == 500, "recipient without realm gets this realm")
	env.inbox[1] = { sender = "mule", money = 900 }
	env.g.TakeInboxMoney(1)
	env.pay(900)
	check(env.today().income.transfer == 900, "own list recognises the sender, case ignored")
	env.g.TakeInboxMoney(1)
	env.clock = env.clock + 30
	env.pay(900)
	check(env.today().income.mail == 900, "take marker expires")
	env.hide("MailInfo")
	env.g.SendMail("Mule", "s", "b")
	env.pay(-1)
	check(env.today().expense.transfer == 500 and env.today().expense.other == 1, "transfer needs the mailbox")
end

-- Vendor items

do
	local env = boot()
	env.bag["0:1"] = { itemID = 100, stackCount = 3 }
	env.g.C_Container.UseContainerItem(0, 1)
	check(next(env.today() or {}) == nil or not env.today().vendorItems[100], "no merchant, no vendor item")
	env.show("Merchant")
	env.g.C_Container.UseContainerItem(0, 1)
	local entry = env.today().vendorItems[100]
	check(entry and entry.count == 3 and entry.copper == 75, "sale records count and sell price times count")
	env.bag["0:2"] = { itemID = 101, stackCount = 1, hasNoValue = true }
	env.g.C_Container.UseContainerItem(0, 2)
	check(env.today().vendorItems[101] == nil, "items without value are skipped")
	env.bag["0:1"] = { itemID = 100, stackCount = 2 }
	env.g.C_Container.UseContainerItem(0, 1)
	check(entry.count == 5 and entry.copper == 125, "sales of one item add up")

	env.buyback[1] = { "|cffffffff|Hitem:100::::::::70|h[Item]|h|r", 2 }
	env.g.BuybackItem(1)
	check(entry.count == 3 and entry.copper == 75, "buyback reverses the newest sale")
	env.buyback[1] = { "|Hitem:100:|h", 3 }
	env.g.BuybackItem(1)
	check(env.today().vendorItems[100] == nil, "full buyback removes the entry")
	env.hide("Merchant")
	env.show("Merchant")
	env.buyback[1] = { "|Hitem:100:|h", 1 }
	env.g.BuybackItem(1)
	check(env.today().vendorItems[100] == nil, "a new visit starts without sales to reverse")
end

do
	-- Late item price.
	local env = boot()
	env.prices[100] = nil
	env.bag["0:1"] = { itemID = 100, stackCount = 2 }
	env.show("Merchant")
	env.g.C_Container.UseContainerItem(0, 1)
	local entry = env.today().vendorItems[100]
	check(entry.count == 2 and entry.copper == 0 and env.requested[1] == 100, "uncached item: count now, price requested")
	env.prices[100] = 30
	env.fire("ITEM_DATA_LOAD_RESULT", 100, true)
	check(entry.copper == 60, "price arrives and is filled in")
	env.fire("ITEM_DATA_LOAD_RESULT", 100, true)
	check(entry.copper == 60, "a second result changes nothing")

	env.prices[101] = nil
	env.bag["0:2"] = { itemID = 101, stackCount = 4 }
	env.g.C_Container.UseContainerItem(0, 2)
	env.buyback[1] = { "|Hitem:101:|h", 4 }
	env.g.BuybackItem(1)
	env.prices[101] = 5
	env.fire("ITEM_DATA_LOAD_RESULT", 101, true)
	check(env.today().vendorItems[101] == nil, "buyback before the price arrived leaves nothing behind")
end

-- Days, range, pruning

do
	local env = boot()
	env.now = T0 + 11 * 3600 + 59 * 60 -- 23:59
	env.pay(100)
	env.now = env.now + 120
	env.pay(40)
	check(env.rec.days[key(0)].income.other == 100 and env.rec.days[key(-1)].income.other == 40, "booking after midnight goes to the new day")
	check(env.Ledger.GetRange("Tester-Realm", 1).net == 40, "range of one day is today")
	check(env.Ledger.GetRange("Tester-Realm", 2).net == 140, "range of two days includes yesterday")
	check(env.Ledger.GetDay("Tester-Realm", key(0)).income.other == 100, "GetDay returns a day record")
	check(env.Ledger.GetDay("Nobody-Realm", key(0)) == nil and env.Ledger.GetRange("Nobody-Realm", 3).net == 0, "unknown character is empty")
end

do
	local function rec() return { income = { other = 1 }, expense = {}, vendorItems = {} } end
	local db = { version = 1, chars = {
		["Tester-Realm"] = { days = { [key(100)] = rec(), [key(91)] = rec(), [key(90)] = rec(), [key(89)] = rec(), [key(0)] = rec() } },
		["Old-Realm"] = { days = { [key(120)] = rec(), [key(3)] = rec() } },
	} }
	local env = boot({ db = db })
	local days = env.rec.days
	check(days[key(100)] == nil and days[key(91)] == nil, "days older than 90 are dropped at login")
	check(days[key(90)] and days[key(89)] and days[key(0)], "90 days are kept")
	check(db.chars["Old-Realm"].days[key(120)] == nil and db.chars["Old-Realm"].days[key(3)], "other characters are pruned too")
end

-- Session

do
	local env = boot()
	env.pay(3000)
	env.pay(-1000)
	env.now = T0 + 3600
	local s = env.Ledger.GetSession()
	check(s.income == 3000 and s.expense == 1000 and s.net == 2000 and s.seconds == 3600 and s.perHour == 2000, "session totals and gold per hour")
	env.now = T0 + 10
	check(env.Ledger.GetSession().perHour == 120000, "first minute counts as a minute")

	-- Reload within 15 minutes continues the session.
	env.now = T0 + 899
	env.fire("PLAYER_LOGOUT")
	local again = boot({ db = env.db, money = env.money, now = T0 + 899 + 60 })
	local s2 = again.Ledger.GetSession()
	check(s2.start == T0 and s2.income == 3000 and s2.expense == 1000 and s2.startMoney == 1000000, "reload keeps start time, start money and totals")
	again.pay(500)
	check(again.Ledger.GetSession().income == 3500, "the continued session keeps counting")

	local later = boot({ db = env.db, money = env.money, now = T0 + 899 + 60 + 15 * 60 })
	local s3 = later.Ledger.GetSession()
	check(s3.start == T0 + 899 + 60 + 15 * 60 and s3.income == 0 and s3.startMoney == env.money, "15 minutes later a new session starts")
end

-- /sempre gold

do
	local env = boot()
	env.show("Merchant")
	env.pay(123456)
	env.g.RepairAllItems()
	env.pay(-5000)
	env.hide("Merchant")
	env.pay(50)
	check(env.S.commands.gold == env.S.commands.ledger, "ledger is an alias of gold")
	env.S.commands.gold("")
	local out = env.out()
	check(out:find("Gold journal Tester%-Realm"), "default shows the character")
	check(out:find("Session: |cffc8794a%+11g 85s 6c|r"), "session net in copper colour: " .. out)
	check(out:find("12g 34s 56c"), "money is formatted as g s c")
	check(out:find("Today: |cffc8794a%+11g 85s 6c|r"), "today line")
	check(out:find("Last 7 days: |cffc8794a%+11g 85s 6c|r"), "week line")
	local vendor, repair, other = out:find("vendor: %+12g"), out:find("repair: %-0g 50s"), out:find("other: %+0g 0s 50c")
	check(vendor and repair and other and vendor < repair and repair < other, "sources are listed largest first")
	check(out:find("per hour"), "gold per hour is shown")

	env.printed = {}
	env.S.commands.gold("ALLE")
	out = env.out()
	check(out:find("Tester%-Realm: |cffc8794a%+11g 85s 6c|r") and out:find("Total: |cffc8794a%+11g 85s 6c|r"), "alle: net per character and total")

	env.printed = {}
	env.show("Merchant")
	env.pay(-10)
	env.hide("Merchant")
	env.S.commands.gold("")
	out = env.out()
	check(out:find("vendor: %+12g 34s 56c, %-0g 0s 10c"), "income and expense of one source share a line: " .. out)
	local _, vendorLines = out:gsub("vendor:", "")
	check(vendorLines == 2, "one vendor line per period")
end

do
	local function rec(net, transfer)
		return { income = { vendor = net + 5, transfer = transfer or nil }, expense = { repair = 5 }, vendorItems = {} }
	end
	local db = { version = 1, chars = {
		["Tester-Realm"] = { days = { [key(0)] = rec(1000, 99999), [key(8)] = rec(7777) } },
		["Alt-Realm"] = { days = { [key(6)] = rec(20000) } },
	} }
	local env = boot({ db = db })
	env.S.commands.gold("all")
	local out = env.out()
	check(out:find("Alt%-Realm: |cffc8794a%+2g 0s 0c|r"), "other character, transfers and days outside the week excluded")
	check(out:find("Tester%-Realm: |cffc8794a%+0g 10s 0c|r"), "transfer is not part of the net")
	check(out:find("Total: |cffc8794a%+2g 10s 0c|r"), "total over characters")
end

do
	local env = boot()
	env.S.commands.gold("items")
	check(env.printed[#env.printed] == "|cffc8794aSempre|r No item bookings recorded.", "items without sales")
	env.printed = {}
	env.show("Merchant")
	for id = 200, 211 do
		env.prices[id] = id
		env.bag["0:1"] = { itemID = id, stackCount = id - 199 }
		env.g.C_Container.UseContainerItem(0, 1)
	end
	-- An older day inside 30 days counts, one outside does not.
	env.rec.days[key(20)] = { income = {}, expense = {}, vendorItems = { [211] = { count = 1, copper = 100000 } } }
	env.rec.days[key(40)] = { income = {}, expense = {}, vendorItems = { [200] = { count = 1, copper = 9999999 } } }
	env.S.commands.ledger("items")
	local lines = {}
	for _, line in ipairs(env.printed) do lines[#lines + 1] = line end
	check(#lines == 11 and lines[1]:find("Top 10 items of the last 30 days"), "header plus ten lines")
	check(lines[2]:find("Item211 x13") and lines[2]:find("10g 25s 32c") and lines[2]:find("vendor %+10g 25s 32c"), "largest first, days within 30 added: " .. tostring(lines[2]))
	check(not env.out():find("Item200 "), "item 200 (40 days ago and the smallest) is cut")
	env.g.C_Item.GetItemInfo = function(id) return "Name" .. id end
	env.printed = {}
	env.S.commands.gold("items")
	check(env.printed[2]:find("Name211 x13"), "item names come from item info")
end

do
	local env = boot()
	env.S.commands.gold("")
	check(env.out():find("no bookings"), "empty periods say so")
	local before = boot({ unknown = { PLAYER_MONEY = false } })
	check(before.Ledger ~= nil, "module without any journal data still loads")
end

-- Degraded clients

do
	local env = boot({ noHooks = true, noInteraction = true, unknown = {
		PLAYER_INTERACTION_MANAGER_FRAME_SHOW = true, PLAYER_INTERACTION_MANAGER_FRAME_HIDE = true,
		TAXIMAP_OPENED = true, TAXIMAP_CLOSED = true, QUEST_TURNED_IN = true, ITEM_DATA_LOAD_RESULT = true,
	} })
	check(#env.errors == 0, "no hooks and unknown events: no errors")
	local warned = false
	for _, line in ipairs(env.bootPrinted) do
		if line:find("RepairAllItems") then warned = true end
		check(not line:find("does not exist"), "no unknown-event warning from the module")
	end
	check(warned, "missing hooks are reported once")
	env.pay(75)
	check(env.today().income.other == 75, "booking still works without hooks")
end

do
	-- Secret money is never computed with.
	local env = boot()
	env.money = SECRET
	env.fire("PLAYER_MONEY")
	env.money = 1000100
	env.fire("PLAYER_MONEY")
	check(env.today() and env.today().income.other == 100 and #env.errors == 0, "unreadable money keeps the old baseline")
end

do
	-- The command before login says so.
	local env = boot()
	env.fire("PLAYER_LOGOUT")
	check(#env.errors == 0, "logout is harmless")
end

return bootShared

end
