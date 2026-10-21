-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Tests for Sempre_Loot with a stubbed WoW API. Loaded by tests/run.lua, which
-- passes in its check helper. Boots the real core, then the module's file.

return function(check)

local T0 = os.time({ year = 2026, month = 10, day = 21, hour = 12, min = 0, sec = 0 })
local DAY = 86400
local SECRET = {}

local function creature(npc, n) return string.format("Creature-0-1-2-3-%d-%010X", npc, n or 1) end
local function object(id, n) return string.format("GameObject-0-1-2-3-%d-%010X", id, n or 1) end

-- opts: db (preset SempreLootDB), now, noLootApi, noTooltip, items (a stub
-- SempreUI.Items), prices (itemID -> copper), unknown (event -> true)
local function boot(opts)
	opts = opts or {}
	local env = { frames = {}, printed = {}, errors = {}, now = opts.now or T0, clock = 100, money = 5000000 }
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
	g.UnitName = function(unit)
		if unit == "player" then return "Tester" end
		local u = env.units[unit]
		return u and u.name
	end
	g.GetRealmName = function() return "Realm" end
	g.GetMoney = function() return env.money end
	g.issecretvalue = function(v) return v == SECRET end
	g.InCombatLockdown = function() return env.combat == true end
	g.geterrorhandler = function() return function(err) env.errors[#env.errors + 1] = err end end
	g.SlashCmdList = {}
	g.print = function(msg) env.printed[#env.printed + 1] = msg end
	g.C_AddOns = { GetAddOnMetadata = function() return nil end, GetNumAddOns = function() return 0 end }
	g.C_EventUtils = { IsEventValid = function(e) return not (opts.unknown and opts.unknown[e]) end }
	g.Enum = { LootSlotType = { Item = 1, Money = 2, Currency = 3 }, TooltipDataType = { Unit = 2 } }
	g.IsShiftKeyDown = function() return env.shift == true end

	-- Units: name, level, class, guid, dead
	env.units = {}
	g.UnitGUID = function(unit) local u = env.units[unit]; return u and u.guid end
	g.UnitLevel = function(unit) local u = env.units[unit]; return u and u.level end
	g.UnitClassification = function(unit) local u = env.units[unit]; return u and u.class end
	g.UnitIsDead = function(unit) local u = env.units[unit]; return u and u.dead or false end

	env.map = 100
	env.mapNames = { [100] = "Elwynn", [200] = "Westfall", [300] = "Duskwood" }
	g.C_Map = {
		GetBestMapForUnit = function() return env.map end,
		GetMapInfo = function(id) return env.mapNames[id] and { name = env.mapNames[id] } end,
	}

	env.prices = opts.prices or { [100] = 25, [101] = 7, [200] = 100, [300] = 4000 }
	env.prices[998] = 0
	env.names = { [100] = "Linen", [101] = "Wool", [200] = "Leather", [300] = "Peacebloom", [400] = "Gem", [998] = "Junk" }
	env.requested = {}
	env.bags = {}
	g.C_Item = {
		GetItemInfo = function(id)
			local name = env.names[id]
			if not name or env.hidden == id then return end
			return name, "link", 1, 1, 1, "", "", 20, "", 0, env.prices[id]
		end,
		RequestLoadItemDataByID = function(id) env.requested[#env.requested + 1] = id end,
		GetItemCount = function(id) return env.bags[id] or 0 end,
	}

	-- Loot window
	env.slots = {}
	if not opts.noLootApi then
		g.GetNumLootItems = function() return #env.slots end
		g.GetLootSlotType = function(i) return env.slots[i].kind == "money" and 2 or 1 end
		g.GetLootSlotLink = function(i)
			local s = env.slots[i]
			if s.secretLink then return SECRET end
			return "|cffffffff|Hitem:" .. s.id .. "::::::::|h[Item " .. s.id .. "]|h|r"
		end
		g.GetLootSlotInfo = function(i) return "icon", "name", env.slots[i].count or 1 end
		g.GetLootSourceInfo = function(i)
			local out = {}
			for _, src in ipairs(env.slots[i].src or {}) do
				out[#out + 1] = src[1]
				out[#out + 1] = src[2] or 1
			end
			return unpack(out)
		end
	end

	-- Tooltips
	env.processors = {}
	if not opts.noTooltip then
		g.TooltipDataProcessor = { AddTooltipPostCall = function(kind, fn) env.processors[kind] = fn end }
	end
	g.GameTooltip = { lines = {}, AddLine = function(self, text) self.lines[#self.lines + 1] = text end }

	if opts.db then g.SempreLootDB = opts.db end

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
	env.printed = {}
	if opts.items then env.S.Items = opts.items end
	env.records = {}
	env.S:Listen("LOOT_RECORDED", function(_, key) env.records[#env.records + 1] = key end)
	run("Sempre_Loot/Loot.lua", "Sempre_Loot")
	env.fire("ADDON_LOADED", "Sempre_Loot")
	env.bootPrinted = env.printed
	env.printed = {}
	env.db = g.SempreLootDB
	env.Loot = env.S.Loot

	-- Opens a loot window with the given slots, items are not taken yet.
	function env.open(slots)
		env.slots = slots
		env.records = {}
		env.fire("LOOT_OPENED")
	end
	function env.close()
		env.fire("LOOT_CLOSED")
		env.clock = env.clock + 0.1
	end
	function env.take(id, n)
		env.bags[id] = (env.bags[id] or 0) + (n or 1)
		env.fire("BAG_UPDATE_DELAYED")
	end
	function env.pay(delta)
		env.money = env.money + delta
		env.fire("PLAYER_MONEY")
	end
	-- Kill loot of one fresh corpse; items = { itemID = count }; taken into the bags.
	local serial = 0
	function env.kill(npc, items, money)
		serial = serial + 1
		-- A corpse with nothing in it opens no window, so an empty kill gets junk.
		if next(items or {}) == nil and not money then items = { [998] = 1 } end
		local guid = creature(npc, serial + 1000)
		local slots = {}
		for id, n in pairs(items or {}) do slots[#slots + 1] = { id = id, count = n, src = { { guid, n } } } end
		if money then slots[#slots + 1] = { kind = "money", src = { { guid, 1 } } } end
		env.open(slots)
		for id, n in pairs(items or {}) do env.take(id, n) end
		if money then env.pay(money) end
		env.close()
		env.clock = env.clock + 5
		return guid
	end
	function env.out() return table.concat(env.printed, "\n") end
	function env.cmd(arg)
		env.printed = {}
		env.S.commands.loot(arg)
		return env.out()
	end
	function env.tooltip(guid)
		env.g.GameTooltip.lines = {}
		env.processors[2](env.g.GameTooltip, { guid = guid })
		return env.g.GameTooltip.lines
	end
	return env
end

-- Baseline

do
	local env = boot()
	check(#env.errors == 0, "module loads without handler errors: " .. tostring(env.errors[1]))
	check(env.Loot and env.S.commands.loot, "interface and command exist")
	check(env.db.version == 1 and env.db.mobs and env.db.nodes and env.db.chars["Tester-Realm"], "saved data layout")
	check(#env.bootPrinted == 0, "nothing printed at load")
	check(env.core.registered.LOOT_OPENED and env.core.registered.BAG_UPDATE_DELAYED
		and env.core.registered.PLAYER_REGEN_ENABLED, "events registered")
	check(env.processors[2] ~= nil, "unit tooltip hook installed")
	check(env.Loot.GetSession().kills == 0, "session starts empty")
end

-- One kill is counted once when the corpse is reopened

do
	local env = boot()
	local guid = creature(1234, 1)
	local slots = function() return { { id = 100, count = 2, src = { { guid, 2 } } } } end
	env.units.target = { guid = guid, name = "Defias Thug", level = 12, class = "elite" }
	env.open(slots())
	env.take(100, 2)
	env.close()
	local mob = env.Loot.GetMob(1234)
	check(mob and mob.kills == 1, "first opening counts one kill")
	check(mob.items[100].drops == 1 and mob.items[100].count == 2 and mob.items[100].kept == 2, "drops, count and kept")
	check(mob.name == "Defias Thug" and mob.minLevel == 12 and mob.maxLevel == 12 and mob.class == "elite",
		"name, level and classification from the matching target")
	check(mob.maps[100] == 1, "kill stored for the map")
	check(env.records[1] == "mob:1234", "LOOT_RECORDED names the source")
	env.clock = env.clock + 10
	env.open(slots())
	env.close()
	mob = env.Loot.GetMob(1234)
	check(mob.kills == 1 and mob.items[100].drops == 1 and mob.items[100].count == 2, "reopening the corpse counts nothing")
	check(env.Loot.GetSession().kills == 1, "session counts the kill once")
	check(mob.gather.gathers == 0, "reopening is not a gather")
	env.kill(1234, { [100] = 1 })
	check(env.Loot.GetMob(1234).kills == 2, "another corpse of the same mob counts")
	check(mob.name == "Defias Thug", "name stays")
end

-- Items left behind and taken after reopening still reach the bags

do
	local env = boot()
	local guid = creature(1234, 5)
	env.open({ { id = 100, count = 1, src = { { guid } } }, { id = 101, count = 1, src = { { guid } } } })
	env.take(100, 1)
	env.close()
	env.clock = env.clock + 20
	env.open({ { id = 101, count = 1, src = { { guid } } } })
	env.take(101, 1)
	env.close()
	local mob = env.Loot.GetMob(1234)
	check(mob.kills == 1 and mob.items[101].drops == 1 and mob.items[101].kept == 1, "item taken at the second opening is kept")
	check(mob.items[100].kept == 1, "first item kept")
end

-- Area loot: two sources in one slot

do
	local env = boot()
	local a, b = creature(10, 1), creature(11, 1)
	env.open({ { id = 100, count = 3, src = { { a, 1 }, { b, 2 } } } })
	env.take(100, 3)
	env.close()
	check(env.Loot.GetMob(10).kills == 1 and env.Loot.GetMob(11).kills == 1, "both sources are kills")
	check(env.Loot.GetMob(10).items[100].count == 1 and env.Loot.GetMob(11).items[100].count == 2, "amount per source")
	check(env.Loot.GetMob(10).items[100].kept == 1 and env.Loot.GetMob(11).items[100].kept == 2, "kept split by source")
	check(env.Loot.GetSession().kills == 2, "session counts both")
	check(#env.records == 2, "one message per source")
end

-- Skinning after looting is a gather of the same mob

do
	local env = boot()
	local guid = creature(77, 1)
	env.open({ { id = 100, count = 1, src = { { guid } } } })
	env.take(100)
	env.close()
	env.clock = env.clock + 30
	env.open({ { id = 200, count = 2, src = { { guid, 2 } } } })
	env.take(200, 2)
	env.close()
	local mob = env.Loot.GetMob(77)
	check(mob.kills == 1, "skinning does not add a kill")
	check(mob.gather.gathers == 1 and mob.gather.items[200].drops == 1 and mob.gather.items[200].count == 2
		and mob.gather.items[200].kept == 2, "skinning is stored as a gather")
	check(mob.items[200] == nil, "kill loot is not mixed with gathering")
	check(env.Loot.GetSession().gathers == 1, "session counts the gather")
	env.clock = env.clock + 10
	env.open({ { id = 200, count = 2, src = { { guid, 2 } } } })
	env.close()
	check(mob.gather.gathers == 1, "reopening the skinning loot counts nothing")
	local out = env.cmd("mob")
	check(out:find("Gathered: 1 times", 1, true), "mob command shows gathers")
end

-- Herb node keyed by object ID

do
	local env = boot()
	local node = object(5001, 1)
	env.units.softinteract = { guid = node, name = "Peacebloom Patch" }
	env.open({ { id = 300, count = 1, src = { { node } } } })
	env.take(300)
	env.close()
	local n = env.Loot.GetNode(5001)
	check(n and n.gathers == 1 and n.name == "Peacebloom Patch", "node keyed by object ID with its name")
	check(n.items[300].drops == 1 and n.items[300].kept == 1 and n.maps[100] == 1, "node items and map")
	check(env.Loot.GetMob(5001) == nil, "an object is no mob")
	check(env.records[1] == "node:5001", "message for the node")
	env.clock = env.clock + 10
	env.open({ { id = 300, count = 1, src = { { node } } } })
	env.close()
	check(env.Loot.GetNode(5001).gathers == 1, "same node opened again counts once")
	env.units.softinteract = nil
	env.kill(1, {})
	env.open({ { id = 300, count = 1, src = { { object(5002, 1) } } } })
	env.close()
	check(env.Loot.GetNode(5002).name == nil, "no readable name stays empty")
	env.names[300] = "Peacebloom"
	local out = env.cmd("wo Peacebloom")
	check(out:find("node 5002", 1, true), "unnamed node is shown as node <id>")
	check(out:find("Peacebloom Patch", 1, true), "named node is shown by name")
end

-- Money split to the money slot's sources

do
	local env = boot()
	local a, b = creature(20, 1), creature(21, 1)
	env.open({ { kind = "money", src = { { a }, { b } } } })
	env.pay(1000)
	check(env.Loot.GetMob(20).money == 500 and env.Loot.GetMob(21).money == 500, "money split evenly")
	env.pay(1)
	env.close()
	check(env.Loot.GetSession().money == 1001, "session money")
	check(env.Loot.GetMob(20).money + env.Loot.GetMob(21).money == 1001, "the whole change is booked, remainder to the first")
	check(env.S.Ledger == nil and env.db.chars["Tester-Realm"].days == nil, "nothing is booked into a ledger")
	-- Money within one second after closing counts, later money does not.
	env.clock = env.clock + 10
	local c = creature(22, 1)
	env.open({ { kind = "money", src = { { c } } } })
	env.close()
	env.clock = env.clock + 0.5
	env.pay(70)
	check(env.Loot.GetMob(22).money == 70, "money right after closing is booked")
	env.clock = env.clock + 2
	env.pay(33)
	check(env.Loot.GetMob(22).money == 70 and env.Loot.GetSession().money == 1071, "later money is not loot")
	env.pay(-10)
	env.pay(5)
	check(env.Loot.GetMob(22).money == 70, "money outside a loot window is ignored")
	-- Gain without a money slot.
	env.open({ { id = 100, src = { { creature(23, 1) } } } })
	env.pay(500)
	env.close()
	check(env.Loot.GetSession().money == 1071, "no money slot, no booking")
end

-- Money slot of a reopened corpse and of a gather

do
	local env = boot()
	local a = creature(30, 1)
	env.open({ { id = 100, src = { { a } } }, { kind = "money", src = { { a } } } })
	env.take(100)
	env.close()
	env.clock = env.clock + 10
	env.open({ { kind = "money", src = { { a } } } })
	env.pay(40)
	env.close()
	check(env.Loot.GetMob(30).money == 40 and env.Loot.GetMob(30).kills == 1, "money of a reopened corpse is booked to the kill")
end

-- Item value from the sell price, and the late price

do
	local env = boot()
	env.hidden = 101
	env.prices[101] = nil
	env.kill(1, { [100] = 4 })
	env.kill(1, { [101] = 2 })
	local s = env.Loot.GetSession()
	check(s.itemValue == 100 and s.unknown == 2, "known price counted, unknown item waits")
	check(env.requested[1] == 101, "item data is requested")
	check(env.cmd(""):find("%+%?"), "unknown value is shown with a question mark")
	env.hidden = nil
	env.prices[101] = 7
	env.fire("ITEM_DATA_LOAD_RESULT", 101, true)
	s = env.Loot.GetSession()
	check(s.itemValue == 114 and s.unknown == 0, "late price is used once the data arrived")
	-- Market price wins when it exists.
	local fresh = boot({ prices = { [100] = 25 } })
	fresh.S.Market = { GetPrice = function(id) if id == 100 then return 50 end end }
	fresh.kill(1, { [100] = 2 })
	check(fresh.Loot.GetSession().itemValue == 100, "SempreUI.Market overrides the vendor price")
end

-- Rolled items: dropped but not kept do not count for the value

do
	local env = boot()
	local guid = creature(40, 1)
	env.open({ { id = 100, count = 1, src = { { guid } } }, { id = 200, count = 1, src = { { guid } } } })
	env.take(100)
	env.close()
	env.clock = env.clock + 5
	env.fire("BAG_UPDATE_DELAYED")
	local mob = env.Loot.GetMob(40)
	check(mob.items[200].drops == 1 and mob.items[200].kept == 0, "lost roll counts as drop, not kept")
	check(env.Loot.GetSession().itemValue == 25, "session value only counts what reached the bags")
	-- Bag changes long after closing are not loot.
	env.clock = env.clock + 60
	env.take(200)
	check(mob.items[200].kept == 0 and env.Loot.GetSession().itemValue == 25, "late bag change is ignored")
end

-- Reliability threshold and rare outliers

do
	local env = boot({ prices = { [100] = 100, [300] = 1000000 } })
	for i = 1, 19 do
		env.kill(5, i % 2 == 0 and { [100] = 1 } or {})
	end
	env.units.target = { guid = creature(5, 1001), name = "Boar" }
	local out = env.cmd("mob")
	check(out:find("9 of 19 kills", 1, true) and out:find("|cff9d9d9d", 1, true), "below 20 kills: grey count only: " .. out)
	check(not out:find("%%"), "no percentage below 20 kills")
	env.kill(5, { [100] = 1 })
	out = env.cmd("mob")
	check(out:find("50.0%%") and not out:find("of 20 kills", 1, true), "from 20 kills a rate is shown")
	-- One lucky drop in 20+ kills is an outlier: not in the value per kill.
	env.kill(5, { [300] = 1 })
	local guid = creature(5, 1001)
	local lines = env.tooltip(guid)
	check(lines[1] == "Loot: 47c per kill (21 kills)", "rare drop left out of the value: " .. tostring(lines[1]))
	check(env.Loot.GetMob(5).items[300].kept == 1, "the drop itself is stored")
	-- 100 kills: reliable, the item counts.
	for _ = 1, 79 do env.kill(5, {}) end
	lines = env.tooltip(guid)
	check(lines[1] and lines[1]:find("(100 kills)", 1, true) and lines[1]:find("1g 0s 10c", 1, true), "from 100 kills the item counts: " .. tostring(lines[1]))
	-- Very low rate below 100 kills is rare too.
	local env2 = boot({ prices = { [100] = 100 } })
	for i = 1, 3 do env2.kill(6, i == 3 and { [100] = 1 } or {}) end
	local mob = env2.Loot.GetMob(6)
	local list = env2.Loot.WhereDrops(100)
	check(list[1].rare == false and list[1].reliable == false, "3 of 3 kills is neither rare nor reliable")
	mob.items[100].drops = 1
	mob.kills = 60
	list = env2.Loot.WhereDrops(100)
	check(list[1].rare == true and list[1].reliable == true, "1 drop in 60 kills is a rare outlier")
	mob.kills = 250
	list = env2.Loot.WhereDrops(100)
	check(list[1].rare == false, "from 100 kills nothing is an outlier")
end

-- wo ranking

do
	local env = boot()
	-- Mob A: 100 in 4 of 25 kills (16%), mob B: 10 of 25 (40%), mob C: 3 of 3 (unreliable 100%)
	for i = 1, 25 do
		env.kill(1, i <= 4 and { [100] = 1 } or {})
		env.kill(2, i <= 10 and { [100] = 1 } or {})
	end
	for _ = 1, 3 do env.kill(3, { [100] = 1 }) end
	env.units.target = nil
	env.map = 200
	env.kill(4, { [100] = 2 })
	env.db.mobs[1].name, env.db.mobs[2].name, env.db.mobs[3].name = "Alpha", "Bravo", "Charlie"
	env.db.mobs[2].maps = { [100] = 5, [200] = 20 }
	local list = env.Loot.WhereDrops(100)
	check(#list == 4, "four sources")
	check(list[1].id == 2 and list[2].id == 1, "reliable sources first, best rate first")
	check(list[3].id == 3 and list[4].id == 4, "unreliable sources after, best rate first")
	check(list[1].mapID == 200, "best map is the one with most kills")
	local out = env.cmd("wo Linen")
	local a, b = out:find("Bravo", 1, true), out:find("Alpha", 1, true)
	check(a and b and a < b, "wo prints the best first")
	check(out:find("Westfall", 1, true) and out:find("40.0%%") and out:find("25 kills", 1, true), "map name, rate and kills")
	check(out:find("3 of 3 kills", 1, true), "unreliable shown as count")
	out = env.cmd("where |cffffffff|Hitem:100::::::::|h[Linen]|h|r")
	check(out:find("Bravo", 1, true), "wo accepts an item link")
	out = env.cmd("wo 100")
	check(out:find("Bravo", 1, true), "wo accepts an item ID")
	out = env.cmd("wo linen")
	check(out:find("Bravo", 1, true), "wo matches names without case")
	out = env.cmd("wo Gem")
	check(out:find("No source recorded"), "no source message")
	env.cmd("wo")
	check(env.out():find("Usage"), "wo without argument prints usage")
	-- top 5 only
	for id = 10, 16 do
		env.kill(id, { [101] = 1 })
		env.db.mobs[id].name = "M" .. id
	end
	out = env.cmd("wo Wool")
	local lines = 0
	for _ in out:gmatch("\n") do lines = lines + 1 end
	check(lines == 5, "wo lists at most 5 sources (" .. lines .. ")")
end

-- top command

do
	local env = boot({ prices = { [100] = 10, [200] = 500 } })
	for _ = 1, 20 do env.kill(1, { [100] = 1 }) end
	for _ = 1, 20 do env.kill(2, { [200] = 1 }) end
	for _ = 1, 19 do env.kill(3, { [200] = 3 }) end
	env.db.mobs[1].name, env.db.mobs[2].name = "Cheap", "Rich"
	local out = env.cmd("top")
	check(out:find("Rich", 1, true) and out:find("Cheap", 1, true) and out:find("Rich", 1, true) < out:find("Cheap", 1, true),
		"top ranks by value per kill")
	check(not out:find("mob 3", 1, true), "mobs under 20 kills are left out")
	check(env.cmd("mob"):find("level"), "mob command falls back to the last looted mob")
end

-- Tooltip

do
	local env = boot({ prices = { [100] = 25, [200] = 100, [101] = 7 } })
	local guid
	for i = 1, 4 do guid = env.kill(8, { [100] = 1, [200] = i == 1 and 1 or nil, [101] = i <= 2 and 1 or nil }) end
	local lines = env.tooltip(guid)
	check(#lines == 1 and lines[1]:find("^Loot: ") and lines[1]:find("(4 kills)", 1, true), "one tooltip line: " .. tostring(lines[1]))
	check(lines[1]:find("per kill", 1, true), "value per kill in the line")
	env.shift = true
	lines = env.tooltip(guid)
	check(#lines == 4, "shift adds the top 3 items")
	check(lines[2]:find("Linen") and lines[3]:find("Wool") and lines[4]:find("Leather"), "top items by rate")
	env.shift = false
	env.combat = true
	check(#env.tooltip(guid) == 0, "nothing in combat")
	env.combat = false
	check(#env.tooltip(creature(9999, 1)) == 0, "unknown mob gets no line")
	check(#env.tooltip(SECRET) == 0 and #env.tooltip(nil) == 0, "secret or missing GUID gets no line")
	check(#env.tooltip(object(5, 1)) == 0, "objects get no line")
	check(#env.errors == 0, "tooltip raised nothing")
end

-- Farm goals

do
	local env = boot()
	local out = env.cmd("")
	check(out:find("No farm goals"), "empty goals shown")
	out = env.cmd("ziel |cffffffff|Hitem:100::::::::|h[Linen]|h|r 5")
	check(out:find("Farm goal: Linen, 5"), "goal set from a link: " .. out)
	local goals = env.db.chars["Tester-Realm"].goals
	check(#goals == 1 and goals[1].id == 100 and goals[1].target == 5, "goal stored per character")
	env.cmd("goal 100 8")
	check(#goals == 1 and goals[1].target == 8, "same item changes the target")
	env.cmd("goal 100 3")
	env.bags[100] = 2
	check(env.cmd(""):find("Linen: 2 / 3", 1, true), "progress from bag count")
	env.printed = {}
	env.take(100, 1)
	local reached = 0
	for _, line in ipairs(env.printed) do if line:find("Farm goal reached: Linen (3)", 1, true) then reached = reached + 1 end end
	check(reached == 1, "reached message once")
	env.printed = {}
	env.take(100, 1)
	check(#env.printed == 0, "no repeat message")
	env.bags[100] = 0
	env.fire("BAG_UPDATE_DELAYED")
	env.printed = {}
	env.bags[100] = 3
	env.fire("BAG_UPDATE_DELAYED")
	check(env.out():find("reached"), "message again after dropping below and reaching")
	check(env.cmd("goal remove 100"):find("Farm goal removed: Linen"), "goal removed")
	check(#goals == 0, "removed")
	check(env.cmd("ziel weg 100"):find("no farm goal"), "removing a missing goal says so")
	for id = 1, 6 do env.cmd("goal " .. id .. " 10") end
	check(#goals == 6, "six goals")
	check(env.cmd("goal 7 10"):find("At most 6"), "seventh goal refused")
	check(#goals == 6, "still six")
	check(env.cmd("goal"):find("Usage"), "goal without item prints usage")
	check(env.cmd("goal 3"):find("Usage"), "goal without count prints usage")
end

do
	-- Progress through the Sempre_Items interface, other characters ignored.
	local items = { GetCount = function()
		return 30, { n = 2, { key = "Other-Realm", count = 20 }, { key = "Tester-Realm", count = 7 } }
	end }
	local env = boot({ items = items })
	env.cmd("goal 100 10")
	check(env.cmd(""):find("Linen: 7 / 10", 1, true), "progress uses the character's count from Sempre_Items")
end

do
	-- Time left from drop rate and the session's kills per hour.
	local env = boot()
	for _ = 1, 20 do env.kill(1, { [100] = 1 }) end
	env.now = env.now + 3600
	env.cmd("goal 100 100")
	env.bags[100] = 20
	local out = env.cmd("")
	check(out:find("100 ", 1, true) or out:find("20 / 100", 1, true), "goal line")
	check(out:find("about 4h 00m left"), "time left: " .. out)
	local env2 = boot()
	env2.kill(1, { [100] = 1 })
	env2.cmd("goal 100 100")
	check(not env2.cmd(""):find("left"), "no estimate in a short session")
end

-- Session over /reload and a new session after 15 minutes

do
	local env = boot()
	env.kill(1, { [100] = 1 }, 300)
	local db = env.g.SempreLootDB
	local reload = boot({ db = db, now = T0 + 14 * 60 })
	check(reload.Loot.GetSession().kills == 1 and reload.Loot.GetSession().money == 300, "session survives a reload within 15 minutes")
	check(reload.Loot.GetSession().start == T0, "same start")
	local later = boot({ db = db, now = T0 + 31 * 60 })
	check(later.Loot.GetSession().kills == 0 and later.Loot.GetSession().start == T0 + 31 * 60, "new session after 15 minutes")
	check(later.db.mobs[1].kills == 1, "knowledge stays")
	check(env.Loot.GetSession().perHour == nil, "no gold per hour before 5 minutes")
	local s
	reload.now = T0 + 14 * 60 + 360
	reload.kill(2, { [100] = 1 }, 1000)
	reload.now = T0 + 3600
	s = reload.Loot.GetSession()
	check(s.perHour == s.total and s.total == 300 + 1000 + 25 * 2, "gold per hour after 5 minutes: " .. tostring(s.perHour))
	check(reload.cmd(""):find("per hour"), "per hour line")
end

-- Secret values are ignored

do
	local env = boot()
	env.units.target = { guid = creature(60, 1), name = SECRET, level = SECRET, class = SECRET }
	env.open({ { id = 100, count = 1, src = { { creature(60, 1) } } } })
	env.close()
	check(#env.errors == 0, "secret name raises nothing")
	check(env.Loot.GetMob(60).kills == 1 and env.Loot.GetMob(60).name == nil and env.Loot.GetMob(60).minLevel == nil,
		"secret name and level are not stored")
	env.open({ { id = 100, count = 1, src = { { SECRET } } }, { id = 101, secretLink = true, src = { { SECRET } } },
		{ kind = "money", src = { { SECRET } } } })
	env.take(100)
	env.pay(10)
	env.close()
	check(#env.errors == 0, "secret GUID and link raise nothing")
	check(next(env.db.mobs, next(env.db.mobs)) == nil, "no mob created from a secret GUID")
	check(env.Loot.GetSession().kills == 1, "secret source is no kill")
	check(env.Loot.GetSession().itemValue == 25, "unknown source still counts for the session value")
	check(env.Loot.GetSession().money == 10, "unknown source money counts for the session")
	check(env.records[1] == "unknown", "unknown source message")
	-- In combat the name is read later.
	local e2 = boot()
	e2.combat = true
	e2.units.target = { guid = creature(61, 1), name = "Wolf", level = 5 }
	e2.open({ { id = 100, src = { { creature(61, 1) } } } })
	e2.close()
	check(e2.Loot.GetMob(61).name == nil, "no name read in combat")
	e2.combat = false
	e2.fire("PLAYER_REGEN_ENABLED")
	check(e2.Loot.GetMob(61).name == "Wolf" and e2.Loot.GetMob(61).minLevel == 5, "name read when combat ends")
end

-- Source fallback to the dead target; no source at all

do
	local env = boot()
	local guid = creature(70, 1)
	env.units.target = { guid = guid, dead = true }
	env.open({ { id = 100, count = 1 } })
	env.take(100)
	env.close()
	check(env.Loot.GetMob(70) and env.Loot.GetMob(70).kills == 1, "dead target is the source when slots have none")
	env.units.target = { guid = creature(71, 1), dead = false }
	env.open({ { id = 100, count = 1 } })
	env.take(100)
	env.close()
	check(env.Loot.GetMob(71) == nil and env.Loot.GetSession().itemValue == 50, "living target: unknown source, session only")
	check(env.records[1] == "unknown", "unknown message")
end

-- Pruning at login

do
	local env = boot()
	env.kill(1, { [100] = 1 })
	local db = env.g.SempreLootDB
	db.mobs[2] = { kills = 3, money = 0, items = {}, maps = {}, last = T0 - 100 * DAY, gather = { gathers = 0, money = 0, items = {}, maps = {} } }
	db.mobs[3] = { kills = 3, money = 0, items = {}, maps = {}, last = T0 - 10 * DAY, gather = { gathers = 0, money = 0, items = {}, maps = {} } }
	db.mobs[4] = { kills = 9, money = 0, items = {}, maps = {}, last = T0 - 200 * DAY, gather = { gathers = 0, money = 0, items = {}, maps = {} } }
	db.nodes[5] = { gathers = 2, money = 0, items = {}, maps = {}, last = T0 - 95 * DAY }
	db.nodes[6] = { gathers = 2, money = 0, items = {}, maps = {}, last = T0 - 5 * DAY }
	db.nodes[7] = { gathers = 8, money = 0, items = {}, maps = {}, last = T0 - 95 * DAY }
	local again = boot({ db = db, now = T0 + 3600 })
	check(again.db.mobs[2] == nil and again.db.mobs[3] and again.db.mobs[4] and again.db.mobs[1], "few kills and old are pruned")
	check(again.db.nodes[5] == nil and again.db.nodes[6] and again.db.nodes[7], "nodes pruned the same way")
	-- More than 2000 mobs: the least recently seen go first.
	local big = { version = 1, mobs = {}, nodes = {}, chars = {} }
	for i = 1, 2010 do
		big.mobs[i] = { kills = 10, money = 0, items = {}, maps = {}, last = T0 - i, gather = { gathers = 0, money = 0, items = {}, maps = {} } }
	end
	local capped = boot({ db = big })
	local n = 0
	for _ in pairs(capped.db.mobs) do n = n + 1 end
	check(n == 2000, "capped at 2000 mobs")
	check(capped.db.mobs[2010] == nil and capped.db.mobs[2001] == nil and capped.db.mobs[2000] and capped.db.mobs[1],
		"least recently seen dropped first")
end

-- Missing API and missing optional events

do
	local env = boot({ noLootApi = true })
	check(env.bootPrinted[1] and env.bootPrinted[1]:find("GetLootSlotInfo"), "missing loot API is reported")
	env.open({})
	check(#env.errors == 0 and env.Loot.GetSession().kills == 0, "module is off without errors")
	local noTip = boot({ noTooltip = true })
	check(noTip.bootPrinted[1] and noTip.bootPrinted[1]:find("tooltip"), "missing tooltip interface is reported")
	noTip.kill(1, { [100] = 1 })
	check(noTip.Loot.GetMob(1).kills == 1, "the rest works without tooltips")
	local unk = boot({ unknown = { PLAYER_REGEN_ENABLED = true } })
	check(#unk.bootPrinted == 0 and #unk.errors == 0, "unknown optional event is skipped quietly")
end

-- Commands

do
	local env = boot()
	check(env.cmd("bogus"):find("Usage"), "unknown argument prints usage")
	check(env.cmd("mob"):find("No mob known"), "mob without data")
	check(env.cmd("top"):find("No mob with 20 kills"), "top without data")
	env.kill(1, { [100] = 1 }, 150)
	local out = env.cmd("")
	check(out:find("1 kills") and out:find("money 1s 50c"), "session summary: " .. out)
	check(env.Loot.GetMob(1).money == 150, "money booked to the mob")
	check(env.Loot.GetNode(1) == nil, "unknown node is nil")
end

end
