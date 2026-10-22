-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Tests for Sempre_Items with a stubbed WoW API. Loaded by tests/run.lua, which
-- passes in its check helpers. Boots the real core, then the module's files.

return function(check, same)

local NEW_INDEX = {
	Backpack = 0, Bag_1 = 1, Bag_2 = 2, Bag_3 = 3, Bag_4 = 4, ReagentBag = 5, Keyring = -2,
	CharacterBankTab_1 = 6, CharacterBankTab_2 = 7, CharacterBankTab_3 = 8,
	AccountBankTab_1 = 11, AccountBankTab_2 = 12,
}
local OLD_INDEX = {
	Backpack = 0, Bag_1 = 1, Bag_2 = 2, Bag_3 = 3, Bag_4 = 4,
	Bank = -1, BankBag_1 = 5, BankBag_2 = 6, Reagentbank = -3,
}

-- opts: index, slots (bagID -> slot count), contents (bagID -> slot -> info),
-- unknown (event -> true), db (preset SempreItemsDB), noTooltip, noIsEventValid
local function boot(opts)
	opts = opts or {}
	local env = { frames = {}, printed = {}, errors = {}, calls = 0, money = 1234567, combat = false, equipped = {} }
	local g = setmetatable({}, { __index = _G })
	g.table = setmetatable({ wipe = function(t) for k in pairs(t) do t[k] = nil end return t end }, { __index = table })

	g.CreateFrame = function()
		local f = { scripts = {}, registered = {}, shown = true }
		function f.RegisterEvent(_, e)
			if opts.unknown and opts.unknown[e] then error("unknown event") end
			f.registered[e] = true
		end
		function f.UnregisterEvent(_, e) f.registered[e] = nil end
		function f.SetScript(_, k, fn) f.scripts[k] = fn end
		function f.Show() f.shown = true end
		function f.Hide() f.shown = false end
		env.frames[#env.frames + 1] = f
		return f
	end
	g.time = os.time
	g.C_Item = opts.cItem
	g.GetLocale = function() return "enUS" end
	g.GetBuildInfo = function() return "1", "", "", 16001 end
	g.UnitName = function() return "Tester" end
	g.GetRealmName = function() return "Realm" end
	g.UnitClass = function() return "Warrior", "WARRIOR" end
	g.UnitFactionGroup = function() return "Alliance" end
	g.UnitLevel = function() return 70 end
	g.GetMoney = function() return env.money end
	g.InCombatLockdown = function() return env.combat end
	g.geterrorhandler = function() return function(err) env.errors[#env.errors + 1] = err end end
	g.SlashCmdList = {}
	g.print = function(msg) env.printed[#env.printed + 1] = msg end
	g.C_AddOns = {
		GetAddOnMetadata = function() return nil end,
		GetNumAddOns = function() return 0 end,
	}
	if not opts.noIsEventValid then
		g.C_EventUtils = { IsEventValid = function(e) return not (opts.unknown and opts.unknown[e]) end }
	end
	if opts.index ~= false then g.Enum = { BagIndex = opts.index or NEW_INDEX } else g.Enum = {} end
	g.Enum.TooltipDataType = { Item = 0 }
	g.Enum.PlayerInteractionType = { Banker = 8, AccountBanker = 68, MailInfo = 17 }
	g.C_Container = {
		GetContainerNumSlots = function(id) return (opts.slots or {})[id] or 0 end,
		GetContainerItemInfo = function(id, slot)
			env.calls = env.calls + 1
			return ((opts.contents or {})[id] or {})[slot]
		end,
	}
	env.contents = opts.contents or {}
	g.GetInventoryItemID = function(_, slot) return env.equipped[slot] and env.equipped[slot].id end
	g.GetInventoryItemLink = function(_, slot) return env.equipped[slot] and env.equipped[slot].link end
	g.RAID_CLASS_COLORS = { WARRIOR = { colorStr = "ffc79c6e" }, MAGE = { r = 0.25, g = 0.78, b = 0.92 } }
	g.ATTACHMENTS_MAX_RECEIVE = 3
	env.mailbox = { shown = 0, total = 0, list = {} }
	g.GetInboxNumItems = function() return env.mailbox.shown, env.mailbox.total end
	g.GetInboxHeaderInfo = function(i)
		local m = env.mailbox.list[i]
		return nil, nil, "sender", "subject", m.money, 0, m.days, #m.items, false, false, false, m.kind ~= "system"
	end
	g.GetInboxInvoiceInfo = function(i) if env.mailbox.list[i].kind == "ah" then return "seller" end end
	g.GetInboxItem = function(i, a)
		local it = env.mailbox.list[i].items[a]
		if it then return "name", it[1], 0, it[2] end
	end
	g.GetInboxItemLink = function(i, a)
		local it = env.mailbox.list[i].items[a]
		return it and it[3]
	end

	local tooltip = { lines = {} }
	function tooltip.AddLine(_, text) tooltip.lines[#tooltip.lines + 1] = text end
	g.GameTooltip, g.ItemRefTooltip = tooltip, { AddLine = function() end }
	env.tooltip = tooltip
	if not opts.noTooltip then
		g.TooltipDataProcessor = { AddTooltipPostCall = function(_, fn) env.postCall = fn end }
	end
	if opts.db then g.SempreItemsDB = opts.db end

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
	env.fire("PLAYER_LOGIN")
	env.messages = {}
	env.S:Listen("ITEMS_CHANGED", function(_, key, loc) env.messages[#env.messages + 1] = key .. ":" .. loc end)
	run("Sempre_Items/Items.lua", "Sempre_Items")
	run("Sempre_Items/Tooltip.lua", "Sempre_Items")
	env.fire("ADDON_LOADED", "Sempre_Items")
	check(#env.errors == 0, "module loads without handler errors: " .. tostring(env.errors[1]))
	env.ticker = env.frames[2]
	env.db = g.SempreItemsDB
	env.Items = env.S.Items
	-- Runs the frame's OnUpdate once if the module asked for it.
	function env.tick()
		local t = env.ticker
		if t and t.shown then t.scripts.OnUpdate(t) return true end
		return false
	end
	return env
end

local function item(id, count, link) return { itemID = id, stackCount = count, hyperlink = link } end

-- Start, character record, command

do
	local env = boot({ slots = { [0] = 2 }, contents = { [0] = { item(100, 5), item(101, 1) } } })
	local rec = env.db.chars["Tester-Realm"]
	check(rec and rec.class == "WARRIOR" and rec.faction == "Alliance" and rec.level == 70, "character record has class, faction, level")
	check(rec.money == 1234567, "gold saved at login")
	check(env.db.version == 1, "db version set")
	check(env.tick(), "login schedules the first scan")
	check(rec.bags and rec.bags.items[100] == 5 and rec.bags.items[101] == 1, "bags scanned after login")
	check(not env.tick(), "no second scan without events")
	env.S.commands.items("")
	local out = table.concat(env.printed, "\n")
	check(out:find("Tester%-Realm") and out:find("123g 45s 67c"), "/sempre items shows the character with gold")
	check(out:find("bank never") and out:find("mail never"), "command shows snapshot ages")
	env.S.commands.items("debug")
	check(env.printed[#env.printed]:find("Scans since login: 1"), "debug shows scan count")
end

-- Coalescing: only changed bags, one scan

do
	local env = boot({ slots = { [0] = 3, [1] = 2 }, contents = { [0] = { item(100, 5), nil, item(102, 2) }, [1] = { item(103, 1) } } })
	env.tick()
	env.calls, env.messages = 0, {}
	local scans = env.Items.scanCount
	env.contents[0][2] = item(100, 3)
	for _ = 1, 20 do env.fire("BAG_UPDATE", 0) end
	check(env.ticker.shown, "bag events show the ticker")
	check(env.calls == 0, "events alone scan nothing")
	env.tick()
	check(env.Items.scanCount == scans + 1, "twenty bag events cause one scan")
	check(env.calls == 3, "only the changed bag is read: " .. env.calls)
	local rec = env.db.chars["Tester-Realm"]
	check(rec.bags.items[100] == 8 and rec.bags.items[103] == 1 and rec.bags.items[102] == 2, "other bags stay in the totals")
	check(same(env.messages, { "Tester-Realm:bags" }), "one ITEMS_CHANGED for the burst: " .. table.concat(env.messages, ","))
	env.contents[0] = {}
	env.fire("BAG_UPDATE", 0)
	env.tick()
	check(rec.bags.items[100] == nil and rec.bags.items[103] == 1, "emptied bag removes its items")
	env.fire("BAG_UPDATE", 99)
	check(not env.tick(), "unknown bag id is ignored")
end

-- Links

do
	local plainLink = "|cffffffff|Hitem:100::::::::70:262::::::|h[Plain]|h|r"
	local suffixLink = "|cffffffff|Hitem:101::::::-5:123456:70:262::::::|h[Bear]|h|r"
	local env = boot({ slots = { [0] = 2 }, contents = { [0] = { item(100, 1, plainLink), item(101, 1, suffixLink) } } })
	env.tick()
	local links = env.db.chars["Tester-Realm"].bags.links
	check(links and links[100] == nil and links[101], "plain link is not stored")
	check(links and links[101] and links[101][1] == "item:101::::::-5:123456:70:262::::::", "suffix link is stored")
end

-- Bank: new layout with account bank

do
	local env = boot({
		slots = { [0] = 1, [6] = 2, [7] = 0, [11] = 2 },
		contents = { [0] = { item(1, 1) }, [6] = { item(200, 15), item(201, 2) }, [11] = { item(300, 7) } },
	})
	env.tick()
	local rec = env.db.chars["Tester-Realm"]
	env.fire("BAG_UPDATE", 6)
	check(not env.tick(), "bank update while the bank is closed is ignored")
	check(rec.bank == nil, "no bank snapshot before the bank was opened")
	env.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 8)
	env.messages = {}
	env.tick()
	check(rec.bank and rec.bank.items[200] == 15 and rec.bank.items[201] == 2, "bank saved when it opens")
	check(rec.bank.items[300] == nil, "account tabs are kept apart")
	check(env.db.account and env.db.account.items[300] == 7, "account bank is stored once, account-wide")
	check(same(env.messages, { "Tester-Realm:bank", "Tester-Realm:account" }), "bank and account announce: " .. table.concat(env.messages, ","))
	env.contents[6] = { item(200, 14) }
	env.fire("BAG_UPDATE", 6)
	env.tick()
	check(rec.bank.items[200] == 14, "bank change while open is saved")
	env.fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 8)
	env.contents[6] = {}
	env.fire("BAG_UPDATE", 6)
	env.tick()
	check(rec.bank.items[200] == 14, "snapshot is kept after the bank closed")
	env.S.commands.items("")
	local out = table.concat(env.printed, "\n")
	check(out:find("Account bank"), "command lists the account bank")
	check(rec.bank.time > 0, "bank snapshot has a time")
end

-- Bank: old layout, no account bank

do
	local env = boot({
		index = OLD_INDEX,
		slots = { [0] = 1, [-1] = 2, [5] = 1, [6] = 0, [-3] = 1 },
		contents = { [-1] = { item(200, 4) }, [5] = { item(200, 6) }, [-3] = { item(250, 20) } },
		unknown = { PLAYER_INTERACTION_MANAGER_FRAME_SHOW = true, PLAYER_INTERACTION_MANAGER_FRAME_HIDE = true },
	})
	env.tick()
	env.fire("BANKFRAME_OPENED")
	env.tick()
	local rec = env.db.chars["Tester-Realm"]
	check(rec.bank.items[200] == 10 and rec.bank.items[250] == 20, "old layout: main bank, bank bag and reagent bank")
	check(env.db.account == nil, "missing account bank is skipped silently")
	check(#env.printed == 1, "optional events the client lacks print no warning: " .. #env.printed)
	check(not env.core.registered.PLAYER_INTERACTION_MANAGER_FRAME_SHOW, "invalid event is not registered")
	env.fire("BANKFRAME_CLOSED")
	env.fire("BAG_UPDATE", -1)
	check(not env.tick(), "closed bank ignores updates")
end

-- No Enum.BagIndex

do
	local env = boot({ index = false, slots = { [0] = 1 }, contents = { [0] = { item(5, 1) } } })
	env.tick()
	check(env.db.chars["Tester-Realm"].bags.items[5] == 1, "bags still work without Enum.BagIndex")
	env.S.commands.items("")
	check(table.concat(env.printed, "\n"):find("not tracked"), "command says the bank is not tracked")
end

-- Mail

do
	local env = boot({})
	env.tick()
	env.mailbox = {
		shown = 3, total = 5,
		list = {
			{ kind = "ah", money = 5000, days = 29.5, items = { { 400, 3 } } },
			{ kind = "player", money = 0, days = 10, items = { { 400, 2 }, { 401, 1 } } },
			{ kind = "system", money = 0, days = 1.25, items = {} },
		},
	}
	env.fire("MAIL_SHOW")
	env.messages = {}
	env.tick()
	local rec = env.db.chars["Tester-Realm"]
	check(rec.mail and rec.mail.items[400] == 5 and rec.mail.items[401] == 1, "mail items are summed")
	local mails, when, total, shown = env.Items.GetMail("Tester-Realm")
	check(#mails == 3 and total == 5 and shown == 3 and when, "mail keeps total, shown and time")
	check(mails[1].kind == "ah" and mails[1].money == 5000 and mails[1].days == 29.5, "AH mail with gold and days left")
	check(mails[2].kind == "player" and same(mails[2].items, { 400, 2, 401, 1 }), "player mail items as id/count pairs")
	check(mails[3].kind == "system" and mails[3].days == 1.25, "system mail")
	check(same(env.messages, { "Tester-Realm:mail" }), "mail announces itself")
	env.S.commands.items("")
	check(table.concat(env.printed, "\n"):find("2 mails not yet visible"), "command reports mails not yet visible")
	env.fire("MAIL_CLOSED")
	env.mailbox.list = {}
	env.mailbox.shown, env.mailbox.total = 0, 0
	env.fire("MAIL_INBOX_UPDATE")
	check(not env.tick(), "closed mailbox is not scanned")
	check(rec.mail.items[400] == 5, "mail snapshot is kept")
	local a, b, c = env.Items.GetMail("Nobody-Realm")
	check(#a == 0 and b == nil and c == 0, "GetMail for an unknown character is empty")
end

-- Equipped, money

do
	local env = boot({})
	env.tick()
	env.equipped[1] = { id = 600, link = "|Hitem:600:3000::::::::70:|h[Helm]|h" }
	env.equipped[5] = { id = 601 }
	env.fire("PLAYER_EQUIPMENT_CHANGED", 1)
	env.fire("PLAYER_EQUIPMENT_CHANGED", 5)
	env.tick()
	local rec = env.db.chars["Tester-Realm"]
	check(rec.equipped.items[600] == 1 and rec.equipped.items[601] == 1, "equipped scanned on equipment change")
	check(rec.equipped.links[600][1] == "item:600:3000::::::::70:", "enchanted gear keeps its link")
	env.money = 99
	env.messages = {}
	env.fire("PLAYER_MONEY")
	env.tick()
	check(rec.money == 99 and same(env.messages, { "Tester-Realm:money" }), "money change saved and announced")
	env.fire("PLAYER_LEVEL_UP")
	check(rec.level == 70, "level up refreshes the record")
end

-- Combat queueing

do
	local env = boot({ slots = { [0] = 1 }, contents = { [0] = { item(7, 1) } } })
	env.tick()
	env.combat = true
	env.contents[0][1] = item(7, 9)
	env.money = 55
	env.fire("BAG_UPDATE", 0)
	env.fire("PLAYER_MONEY")
	local scans = env.Items.scanCount
	env.tick()
	local rec = env.db.chars["Tester-Realm"]
	check(env.Items.scanCount == scans and rec.bags.items[7] == 1, "no scan in combat")
	check(rec.money == 55, "gold is a single read and stays current in combat")
	check(not env.ticker.shown, "queued work does not spin the ticker")
	env.combat = false
	env.fire("PLAYER_REGEN_ENABLED")
	check(env.ticker.shown, "leaving combat schedules the queued scan")
	env.tick()
	check(env.Items.scanCount == scans + 1 and rec.bags.items[7] == 9, "queued scan runs after combat")
	env.fire("PLAYER_REGEN_ENABLED")
	check(not env.ticker.shown, "no work, no schedule")
end

-- Tooltip and GetCount

local function owner(class, extra)
	local rec = { class = class, faction = "Alliance", level = 70, money = 0, updated = 1 }
	for k, v in pairs(extra) do rec[k] = { items = v, time = 1 } end
	return rec
end

do
	local env = boot({
		slots = { [0] = 1 }, contents = { [0] = { item(900, 3) } },
		db = { version = 1, chars = {
			["Bankie-Realm"] = owner("MAGE", { bank = { [900] = 15 }, mail = { [900] = 5 } }),
			["Zed-Realm"] = owner("MAGE", { bags = { [900] = 1 } }),
			["Far-Other"] = owner("MAGE", { bags = { [900] = 2 } }),
		}, account = { items = { [900] = 4 }, time = 1 } },
	})
	env.tick()
	local total, res = env.Items.GetCount(900)
	check(total == 3 + 20 + 1 + 2 + 4, "total over characters and account bank: " .. total)
	check(res.n == 4 and res[1].key == "Tester-Realm" and res[2].key == "Bankie-Realm" and res[3].key == "Far-Other" and res[4].key == "Zed-Realm",
		"current first, then by count, then name")
	check(res[2].bank == 15 and res[2].mail == 5 and res.account == 4, "split per location")
	local total2, res2 = env.Items.GetCount(900)
	check(res2 == res and total2 == total, "repeated GetCount returns the cached table")
	local _, none = env.Items.GetCount(12345)
	check(none.n == 0 and select(2, env.Items.GetCount(54321)) == none, "unowned items share one empty result")
	env.fire("BAG_UPDATE", 0)
	env.contents[0][1] = item(900, 4)
	env.tick()
	check(select(2, env.Items.GetCount(900)) ~= res, "cache is dropped after a change")
	check(env.Items.GetCount(900) == total + 1, "count follows the change")

	env.tooltip.lines = {}
	env.postCall(env.tooltip, { id = 900 })
	local lines = env.tooltip.lines
	check(#lines == 6, "four characters, account bank and total: " .. #lines)
	check(lines[1] == "|cffc79c6eTester|r: 4 (bags 4)", "current character line with class colour: " .. tostring(lines[1]))
	check(lines[2] == "|cff40c7ebBankie|r: 20 (bank 15, mail 5)" or lines[2]:find("Bankie|r: 20 %(bank 15, mail 5%)"), "location split: " .. tostring(lines[2]))
	check(lines[3]:find("Far%-Other"), "other realm keeps the realm")
	check(lines[5] == "Account bank: 4" and lines[6]:find("Total|r: 31"), "account line, then total")
	env.tooltip.lines = {}
	env.postCall(env.tooltip, { id = 424242 })
	check(#env.tooltip.lines == 0, "no line for items nobody owns")
	env.postCall(env.tooltip, {})
	env.postCall({ AddLine = function() error("must not be used") end }, { id = 900 })
	check(true, "other tooltips and tables without id are ignored")
end

do
	local chars = {}
	for i = 1, 11 do chars[string.format("Char%02d-Realm", i)] = owner("MAGE", { bags = { [901] = i } }) end
	local env = boot({ db = { version = 1, chars = chars } })
	env.tick()
	env.postCall(env.tooltip, { id = 901 })
	local lines = env.tooltip.lines
	check(#lines == 10, "eight characters, +N more and a total line: " .. #lines)
	check(lines[1]:find("Char11") and lines[8]:find("Char04"), "highest counts come first")
	check(lines[9] == "+3 more", "cap at 8 characters: " .. tostring(lines[9]))
	check(lines[10]:find("Total|r: 66"), "total includes the hidden characters")

	-- Single owner: no total line.
	env.tooltip.lines = {}
	chars["Char01-Realm"].bags.items[902] = 1
	env.Items.version = env.Items.version + 1
	env.postCall(env.tooltip, { id = 902 })
	check(#env.tooltip.lines == 1, "one owner gets no total line")
end

-- Missing APIs

do
	local env = boot({ noTooltip = true })
	check(env.printed[#env.printed]:find("tooltip lines are not available"), "missing tooltip API is announced")
	check(env.db.chars["Tester-Realm"], "module still works without the tooltip API")
end

do
	local env = boot({ noIsEventValid = true })
	check(env.core.registered.MAIL_SHOW, "events register when IsEventValid is missing")
end

-- Item names

do
	local requested = {}
	local env = boot({ cItem = { GetItemInfo = function() return nil end, RequestLoadItemDataByID = function(id) requested[#requested + 1] = id end } })
	check(env.Items.GetName(77) == nil and env.Items.GetName(77) == nil and #requested == 1, "name is requested once")
	local ready = {}
	env.S:Listen("ITEM_NAME_READY", function(_, id) ready[#ready + 1] = id end)
	env.fire("ITEM_DATA_LOAD_RESULT", 77, true)
	env.fire("ITEM_DATA_LOAD_RESULT", 78, true)
	check(same(ready, { 77 }), "late item data announces the item")
end

-- TOC and packaging

do
	local f = assert(io.open("Sempre_Items/Sempre_Items.toc"))
	local toc = f:read("*a")
	f:close()
	check(toc:find("## LoadOnDemand: 1", 1, true) and toc:find("## X-Sempre-Module: 1", 1, true), "TOC marks a module")
	check(toc:find("## X-Sempre-Budget-KB: 150", 1, true) and toc:find("## X-Sempre-LoadWith: Login", 1, true), "TOC has budget and LoadWith")
	f = assert(io.open(".pkgmeta"))
	local pkg = f:read("*a")
	f:close()
	check(pkg:find("SempreUI/Sempre_Items: Sempre_Items", 1, true), ".pkgmeta has the move-folders line")
end

return boot

end
