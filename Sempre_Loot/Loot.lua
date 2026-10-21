-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Sempre_Loot: loot memory. Learns from the player's own looting what each mob
-- and each gathering node drops, how often, and what a kill is worth. A kill
-- counts when its corpse is opened; a later opening of the same creature with
-- different contents (skinning) is a gather of that creature. Money is booked
-- to the sources of the money slot but never into the ledger (Sempre_Ledger
-- books the same change as "loot" on its own).
--
-- Read-only interface on SempreUI.Loot (do not modify what is returned):
--   GetMob(npcID)       -> { name, minLevel, maxLevel, class, kills, money,
--                          items = {itemID = {drops, count, kept}},
--                          gather = { gathers, money, items, maps }, maps =
--                          {mapID = kills}, last } or nil.
--   GetNode(objectID)   -> { name, gathers, money, items, maps, last } or nil.
--   GetSession()        -> { start, seconds, kills, gathers, money, itemValue,
--                          unknown, total, perHour, items } or nil before
--                          login. unknown counts items without a known price,
--                          perHour is nil before 5 minutes of session.
--   WhereDrops(itemID)  -> list of { kind = "mob"|"node", id, name, gather,
--                          drops, n, rate, reliable, rare, mapID }, reliable
--                          first, then best rate first.
-- Message LOOT_RECORDED(key) after each loot window, once per source: "mob:<npcID>",
-- "node:<objectID>" or "unknown".

local ADDON_NAME = ...

local S = SempreUI
local pairs, ipairs, type, format, tonumber, tostring, floor, min, max = pairs, ipairs, type, string.format, tonumber, tostring, math.floor, math.min, math.max
local time, sort, concat = time, table.sort, table.concat
local issecretvalue = issecretvalue
local C_Item, C_Map, C_EventUtils = C_Item, C_Map, C_EventUtils
local GetMoney, GetTime, GetLocale, InCombatLockdown = GetMoney, GetTime, GetLocale, InCombatLockdown
local UnitName, UnitLevel, UnitGUID, UnitIsDead, UnitClassification = UnitName, UnitLevel, UnitGUID, UnitIsDead, UnitClassification

local Loot = {}
S.Loot = Loot

local L = setmetatable({}, { __index = function(_, k) return k end })
Loot.L = L
if GetLocale() == "deDE" then
	L.MISSING = "Loot: in diesem Client fehlt %s, die Beute wird nicht erfasst."
	L.NO_TOOLTIP = "Loot: keine Tooltip-Schnittstelle, die Zeile am Gegner fehlt."
	L.NOT_READY = "Loot: noch keine Daten, bitte nach dem Login erneut versuchen."
	L.NODE = "Fundstelle %d"
	L.UNKNOWN_MOB = "Gegner %d"
	L.UNKNOWN_ITEM = "Gegenstand %d"
	L.UNKNOWN_MAP = "Karte %d"
	L.TOOLTIP = "Beute: %s pro Kill (%d Kills)"
	L.HEADER = "Beute %s:"
	L.SESSION = "Sitzung %s: %d Kills, %d Sammlungen, Geld %s, Gegenstände %s, gesamt %s"
	L.PER_HOUR = "pro Stunde"
	L.PER_HOUR_LATER = "Gold pro Stunde erst nach 5 Minuten"
	L.GOALS = "Farmziele:"
	L.NO_GOALS = "Keine Farmziele. /sempre loot ziel <Gegenstand> <Anzahl>"
	L.GOAL_LINE = "  %s: %d / %d"
	L.GOAL_ETA = "noch ca. %s"
	L.GOAL_SET = "Farmziel: %s, %d Stück."
	L.GOAL_REMOVED = "Farmziel entfernt: %s."
	L.GOAL_NONE = "Dafür gibt es kein Farmziel."
	L.GOAL_FULL = "Es sind höchstens %d Farmziele möglich."
	L.GOAL_USAGE = "Benutzung: /sempre loot ziel <Gegenstand> <Anzahl>, /sempre loot ziel weg <Gegenstand>"
	L.GOAL_REACHED = "Farmziel erreicht: %s (%d)."
	L.WHERE_USAGE = "Benutzung: /sempre loot wo <Gegenstandslink oder Name>"
	L.WHERE_HEADER = "Fundorte von %s:"
	L.WHERE_NONE = "Noch keine Quelle für %s erfasst."
	L.WHERE_LINE = "  %s%s: %s, %s (%s)"
	L.RARE = "selten"
	L.KILLS_N = "%d Kills"
	L.GATHERS_N = "%d Sammlungen"
	L.OF_KILLS = "%d von %d Kills"
	L.OF_GATHERS = "%d von %d Sammlungen"
	L.GATHER_TAG = " (Sammeln)"
	L.MOB_NONE = "Kein Gegner bekannt. Ziel anwählen oder erst etwas looten."
	L.MOB_HEADER = "%s (Stufe %s, %s): %d Kills, %s pro Kill"
	L.MOB_MAPS = "  Karten: %s"
	L.MOB_GATHER = "  Sammeln: %d mal"
	L.TOP_HEADER = "Top 10 Gegner nach Wert pro Kill (ab 20 Kills):"
	L.TOP_NONE = "Noch kein Gegner mit 20 Kills."
	L.NORMAL = "normal"
	L.ELITE = "Elite"
	L.RARE_CLASS = "selten"
	L.HELP = "Benutzung: /sempre loot, ziel, wo, mob, top"
else
	L.MISSING = "Loot: %s is missing in this client, loot is not tracked."
	L.NO_TOOLTIP = "Loot: no tooltip interface, the line on mobs is off."
	L.NOT_READY = "Loot: no data yet, try again after login."
	L.NODE = "node %d"
	L.UNKNOWN_MOB = "mob %d"
	L.UNKNOWN_ITEM = "item %d"
	L.UNKNOWN_MAP = "map %d"
	L.TOOLTIP = "Loot: %s per kill (%d kills)"
	L.HEADER = "Loot %s:"
	L.SESSION = "Session %s: %d kills, %d gathers, money %s, items %s, total %s"
	L.PER_HOUR = "per hour"
	L.PER_HOUR_LATER = "gold per hour only after 5 minutes"
	L.GOALS = "Farm goals:"
	L.NO_GOALS = "No farm goals. /sempre loot goal <item> <count>"
	L.GOAL_LINE = "  %s: %d / %d"
	L.GOAL_ETA = "about %s left"
	L.GOAL_SET = "Farm goal: %s, %d."
	L.GOAL_REMOVED = "Farm goal removed: %s."
	L.GOAL_NONE = "There is no farm goal for that."
	L.GOAL_FULL = "At most %d farm goals are possible."
	L.GOAL_USAGE = "Usage: /sempre loot goal <item> <count>, /sempre loot goal remove <item>"
	L.GOAL_REACHED = "Farm goal reached: %s (%d)."
	L.WHERE_USAGE = "Usage: /sempre loot where <item link or name>"
	L.WHERE_HEADER = "Sources of %s:"
	L.WHERE_NONE = "No source recorded for %s yet."
	L.WHERE_LINE = "  %s%s: %s, %s (%s)"
	L.RARE = "rare"
	L.KILLS_N = "%d kills"
	L.GATHERS_N = "%d gathers"
	L.OF_KILLS = "%d of %d kills"
	L.OF_GATHERS = "%d of %d gathers"
	L.GATHER_TAG = " (gathering)"
	L.MOB_NONE = "No mob known. Target one or loot something first."
	L.MOB_HEADER = "%s (level %s, %s): %d kills, %s per kill"
	L.MOB_MAPS = "  Maps: %s"
	L.MOB_GATHER = "  Gathered: %d times"
	L.TOP_HEADER = "Top 10 mobs by value per kill (20 kills or more):"
	L.TOP_NONE = "No mob with 20 kills yet."
	L.NORMAL = "normal"
	L.ELITE = "elite"
	L.RARE_CLASS = "rare"
	L.HELP = "Usage: /sempre loot, goal, where, mob, top"
end

-- Saved data
-- SempreLootDB = { version, mobs = { [npcID] = {...} }, nodes = { [objectID] =
-- {...} }, chars = { [charKey] = { goals = { { id, target } }, session = {} } } }

local DB_VERSION = 1
local SESSION_GAP = 15 * 60
local MIN_SESSION = 5 * 60 -- gold per hour only after this
local RELIABLE = 20 -- kills or gathers from which a rate is shown as a rate
local RARE_BELOW = 100 -- kills under which a very low rate counts as an outlier
local RARE_RATE = 0.01
local MAX_GOALS = 6
local PRUNE_MIN = 5
local PRUNE_AGE = 90 * 86400
local MAX_ENTRIES = 2000
local SEEN_CAP = 300
local MONEY_WINDOW, KEPT_WINDOW = 1, 3
local migrations = {} -- migrations[n] upgrades a database from version n to n + 1

local function initDB()
	SempreLootDB = SempreLootDB or {}
	local db = SempreLootDB
	if type(db.version) ~= "number" then db.version = DB_VERSION end
	while db.version < DB_VERSION do
		local fn = migrations[db.version]
		if fn then fn(db) end
		db.version = db.version + 1
	end
	if type(db.mobs) ~= "table" then db.mobs = {} end
	if type(db.nodes) ~= "table" then db.nodes = {} end
	if type(db.chars) ~= "table" then db.chars = {} end
	return db
end

-- State

local db, rec, charKey, session
local started, disabled = false, false
local lootOpen, closedAt = false, nil
local lastMoney
local moneyGroups = {} -- one list of sources per money slot of the open window
local pending = {} -- itemID -> items of the last window waiting to show up in the bags
local seen, seenOrder, seenHead = {}, {}, 1 -- GUID -> state, session only
local lastMobID
local needName = {} -- npcID -> guid of mobs looted in combat without a readable name
local goalDone = {} -- itemID -> true while the goal is reached
local prices, requested = {}, {}

-- A value the addon must not compute with is dropped.
local function clean(v)
	if issecretvalue and issecretvalue(v) then return nil end
	return v
end

-- "Creature-0-server-instance-zone-npcID-spawn" and the same for objects.
local function parseGUID(guid)
	local kind, id = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
	id = tonumber(id)
	if not id then return end
	if kind == "Creature" or kind == "Vehicle" then return "mob", id end
	if kind == "GameObject" then return "node", id end
end

local function cleanGUID(unit)
	local guid = clean(UnitGUID and UnitGUID(unit))
	if type(guid) == "string" then return guid end
end

-- Values and items

local function itemEntry(items, id)
	local e = items[id]
	if not e then
		e = { drops = 0, count = 0, kept = 0 }
		items[id] = e
	end
	return e
end

-- Price of one piece in copper, or nil while it is not known. SempreUI.Market
-- is used when a later module provides it, never required.
local function priceOf(id)
	local p = prices[id]
	if p then return p end
	local market = S.Market
	if market and market.GetPrice then
		local ok, v = pcall(market.GetPrice, id)
		if ok and type(v) == "number" then
			prices[id] = v
			return v
		end
	end
	if C_Item and C_Item.GetItemInfo then
		local info = { C_Item.GetItemInfo(id) }
		local v = info[11]
		if type(v) == "number" then
			prices[id] = v
			return v
		end
		if C_Item.RequestLoadItemDataByID and not requested[id] then
			requested[id] = true
			C_Item.RequestLoadItemDataByID(id)
		end
	end
end

local function itemName(id)
	local name = C_Item and C_Item.GetItemInfo and C_Item.GetItemInfo(id)
	if type(name) == "string" then return name end
	if C_Item and C_Item.RequestLoadItemDataByID and not requested[id] then
		requested[id] = true
		C_Item.RequestLoadItemDataByID(id)
	end
	return format(L.UNKNOWN_ITEM, id)
end

-- A very low rate in a small sample is an outlier and stays out of the value.
local function isRare(drops, n)
	if n >= RARE_BELOW or n <= 0 then return false end
	local rate = drops / n
	if rate < RARE_RATE then return true end
	-- One drop in a sample that is big enough to call it a rate.
	return drops <= 1 and n >= RELIABLE
end

-- Money per kill plus the value of what reached the bags, without outliers.
-- The second result counts items whose price is not known yet.
local function valuePerKill(mob)
	local kills = mob.kills or 0
	if kills <= 0 then return 0, 0 end
	local total, unknown = (mob.money or 0) / kills, 0
	for id, e in pairs(mob.items) do
		if e.kept > 0 and not isRare(e.drops, kills) then
			local p = priceOf(id)
			if p then total = total + p * e.kept / kills else unknown = unknown + 1 end
		end
	end
	return total, unknown
end

local function bestMap(maps)
	local best, bestN
	if type(maps) ~= "table" then return end
	for id, n in pairs(maps) do
		if not bestN or n > bestN or (n == bestN and id < best) then best, bestN = id, n end
	end
	return best
end

-- Records

local function getMob(id)
	local m = db.mobs[id]
	if not m then
		m = { kills = 0, money = 0, items = {}, maps = {}, last = time(),
			gather = { gathers = 0, money = 0, items = {}, maps = {} } }
		db.mobs[id] = m
	end
	if type(m.gather) ~= "table" then m.gather = { gathers = 0, money = 0, items = {}, maps = {} } end
	return m
end

local function getNode(id)
	local n = db.nodes[id]
	if not n then
		n = { gathers = 0, money = 0, items = {}, maps = {}, last = time() }
		db.nodes[id] = n
	end
	return n
end

local IDENT_UNITS = { "target", "mouseover", "softinteract", "npc" }

-- The unit token that currently shows this GUID, if any.
local function findUnit(guid)
	for i = 1, #IDENT_UNITS do
		if cleanGUID(IDENT_UNITS[i]) == guid then return IDENT_UNITS[i] end
	end
	for i = 1, 40 do
		local unit = "nameplate" .. i
		if cleanGUID(unit) == guid then return unit end
	end
end

local CLASS = { elite = "elite", worldboss = "elite", rare = "rare", rareelite = "rare" }

-- Name, level and classification of a looted unit; out of combat only.
local function readIdentity(record, guid, isMob)
	if InCombatLockdown() then return false end
	local unit = findUnit(guid)
	if not unit then return false end
	local name = clean(UnitName(unit))
	if type(name) == "string" and name ~= "" then record.name = name end
	if isMob then
		local level = clean(UnitLevel(unit))
		if type(level) == "number" and level > 0 then
			record.minLevel = record.minLevel and min(record.minLevel, level) or level
			record.maxLevel = record.maxLevel and max(record.maxLevel, level) or level
		end
		local class = clean(UnitClassification and UnitClassification(unit))
		if type(class) == "string" then record.class = CLASS[class] or "normal" end
	end
	return type(record.name) == "string"
end

local function currentMap()
	local id = C_Map and C_Map.GetBestMapForUnit and clean(C_Map.GetBestMapForUnit("player"))
	if type(id) == "number" and id > 0 then return id end
end

-- What the character owns: through the read-only Sempre_Items interface when it
-- is loaded, else the bag count.
local function owned(id)
	local items = S.Items
	if items and items.GetCount then
		local _, res = items.GetCount(id)
		if type(res) == "table" then
			for i = 1, res.n or 0 do
				if res[i].key == charKey then return res[i].count end
			end
			return 0
		end
	end
	local n = C_Item and C_Item.GetItemCount and C_Item.GetItemCount(id)
	return type(n) == "number" and n or 0
end

local function checkGoals()
	local goals = rec and rec.goals
	if type(goals) ~= "table" then return end
	for _, g in ipairs(goals) do
		local have = owned(g.id)
		if have >= g.target then
			if not goalDone[g.id] then
				goalDone[g.id] = true
				S:Print(L.GOAL_REACHED, itemName(g.id), have)
			end
		else
			goalDone[g.id] = nil
		end
	end
end

-- Credits items that reached the bags to the entries of the last loot window
-- and to the session. final: this is the last look at them.
local function settle(final)
	if next(pending) == nil then return end
	local live = lootOpen or (closedAt ~= nil and GetTime() - closedAt <= KEPT_WINDOW)
	if live then
		for id, p in pairs(pending) do
			local now = C_Item.GetItemCount(id)
			if type(now) == "number" then
				local delta = min(now - p.before - p.got, p.total - p.got)
				if delta > 0 then
					p.got = p.got + delta
					session.items[id] = (session.items[id] or 0) + delta
					for _, t in ipairs(p.targets) do
						local take = min(t.amount - t.got, delta)
						if take > 0 then
							t.got = t.got + take
							if t.entry then t.entry.kept = t.entry.kept + take end
							delta = delta - take
						end
					end
				end
			end
		end
	end
	if final or not live then
		for id in pairs(pending) do pending[id] = nil end
	end
end

-- Remembers a GUID; the oldest are dropped when the set is full.
local function remember(guid, state)
	seen[guid] = state
	seenOrder[#seenOrder + 1] = guid
	if #seenOrder - seenHead + 1 > SEEN_CAP then
		seen[seenOrder[seenHead]] = nil
		seenOrder[seenHead] = nil
		seenHead = seenHead + 1
	end
end

-- Reading a loot window

local TYPE_ITEM, TYPE_MONEY = 1, 2

local function slotKinds()
	local t = Enum and Enum.LootSlotType
	if type(t) == "table" then return t.Item or TYPE_ITEM, t.Money or TYPE_MONEY end
	return TYPE_ITEM, TYPE_MONEY
end

local function missingFunctions()
	local missing = {}
	local needed = {
		{ "GetNumLootItems", GetNumLootItems }, { "GetLootSlotType", GetLootSlotType },
		{ "GetLootSlotLink", GetLootSlotLink }, { "GetLootSlotInfo", GetLootSlotInfo },
	}
	for _, def in ipairs(needed) do
		if type(def[2]) ~= "function" then missing[#missing + 1] = def[1] end
	end
	if not (C_Item and C_Item.GetItemCount) then missing[#missing + 1] = "C_Item.GetItemCount" end
	sort(missing)
	return missing
end

-- Sources of one slot: list of { guid, amount }. Only readable GUIDs of
-- creatures and objects are kept.
local function slotSources(i, count)
	local list = {}
	if GetLootSourceInfo then
		local raw = { GetLootSourceInfo(i) }
		for k = 1, #raw, 2 do
			local guid = clean(raw[k])
			if type(guid) == "string" and parseGUID(guid) then
				local amount = clean(raw[k + 1])
				list[#list + 1] = { guid = guid, amount = type(amount) == "number" and amount > 0 and amount or nil }
			end
		end
	end
	if #list == 0 then
		-- Fallback: the dead target.
		local guid = cleanGUID("target")
		local dead = guid and clean(UnitIsDead and UnitIsDead("target"))
		if guid and dead == true and parseGUID(guid) then list[1] = { guid = guid } end
	end
	for _, s in ipairs(list) do s.amount = s.amount or max(floor(count / #list), 1) end
	return list
end

local function readWindow()
	local itemKind, moneyKind = slotKinds()
	local n = clean(GetNumLootItems())
	if type(n) ~= "number" then return {}, { items = {}, money = false }, {} end
	local srcs, order, unknown = {}, {}, { items = {}, money = false }
	local groups = {}
	for i = 1, n do
		local kind = clean(GetLootSlotType(i))
		local id, count
		if kind == itemKind then
			local link = clean(GetLootSlotLink(i))
			id = type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
			count = clean(select(3, GetLootSlotInfo(i)))
			if type(count) ~= "number" or count < 1 then count = 1 end
		end
		if id or kind == moneyKind then
			local list = slotSources(i, id and count or 1)
			local group = {}
			for _, s in ipairs(list) do
				local src = srcs[s.guid]
				if not src then
					local what, key = parseGUID(s.guid)
					src = { guid = s.guid, what = what, id = key, content = {}, items = {} }
					srcs[s.guid] = src
					order[#order + 1] = src
				end
				if id then
					src.items[id] = (src.items[id] or 0) + s.amount
					src.content[id] = true
				else
					src.content.m = true
					group[#group + 1] = src
				end
			end
			if id and #list == 0 then unknown.items[id] = (unknown.items[id] or 0) + count end
			if not id then
				if #list == 0 then unknown.money = true end
				groups[#groups + 1] = group
			end
		end
	end
	return order, unknown, groups
end

local function subsetOf(content, set)
	for k in pairs(content) do
		if not set[k] then return false end
	end
	return true
end

-- Decides what a source is: fresh kill, fresh gather, or a reopened one.
-- Sets src.bucket (record that receives its items and money) and src.fresh.
local function classify(src)
	local state = seen[src.guid]
	if src.what == "node" then
		src.key = "node:" .. src.id
		if state and subsetOf(src.content, state.kill) then
			src.bucket = state.killBucket
			return
		end
		local node = getNode(src.id)
		if not state then
			state = { kill = {}, killBucket = node }
			remember(src.guid, state)
		end
		for k in pairs(src.content) do state.kill[k] = true end
		src.record, src.bucket, src.fresh = node, node, "gather"
		return
	end
	src.key = "mob:" .. src.id
	if not state then
		local mob = getMob(src.id)
		state = { kill = {}, gather = {}, killBucket = mob }
		for k in pairs(src.content) do state.kill[k] = true end
		remember(src.guid, state)
		src.record, src.bucket, src.fresh = mob, mob, "kill"
	elseif subsetOf(src.content, state.kill) then
		src.bucket = state.killBucket
	elseif state.gatherBucket and subsetOf(src.content, state.gather) then
		src.bucket = state.gatherBucket
	else
		local mob = getMob(src.id)
		state.gatherBucket = mob.gather
		for k in pairs(src.content) do state.gather[k] = true end
		src.record, src.bucket, src.fresh = mob, mob.gather, "gather"
	end
end

local function onLootOpened()
	if disabled or not started then return end
	settle(true)
	lootOpen, closedAt = true, nil
	moneyGroups = {}
	local order, unknown, groups = readWindow()
	local now = time()
	local map = currentMap()
	local keys, keyList = {}, {}
	local function addKey(key)
		if not keys[key] then
			keys[key] = true
			keyList[#keyList + 1] = key
		end
	end

	for _, src in ipairs(order) do
		classify(src)
		addKey(src.key)
		local record, bucket = src.record, src.bucket
		if src.fresh == "kill" then
			record.kills = record.kills + 1
			session.kills = session.kills + 1
			lastMobID = src.id
		elseif src.fresh == "gather" then
			bucket.gathers = (bucket.gathers or 0) + 1
			session.gathers = session.gathers + 1
			if src.what == "mob" then lastMobID = src.id end
		end
		if record then
			record.last = now
			if map then bucket.maps[map] = (bucket.maps[map] or 0) + 1 end
			local isMob = src.what == "mob"
			if not readIdentity(record, src.guid, isMob) and not record.name and isMob then
				needName[src.id] = src.guid
			end
		end
	end

	-- Items: drops once per source and item, kept targets for the bags check.
	local targets = {}
	local function target(id, entry, amount)
		local list = targets[id]
		if not list then
			list = {}
			targets[id] = list
		end
		list[#list + 1] = { entry = entry, amount = amount, got = 0 }
	end
	for _, src in ipairs(order) do
		for id, amount in pairs(src.items) do
			local entry = itemEntry(src.bucket.items, id)
			if src.fresh then
				entry.drops = entry.drops + 1
				entry.count = entry.count + amount
			end
			target(id, entry, amount)
		end
	end
	for id, amount in pairs(unknown.items) do
		target(id, nil, amount)
		addKey("unknown")
	end
	for id, list in pairs(targets) do
		local total = 0
		for _, t in ipairs(list) do total = total + t.amount end
		pending[id] = { before = C_Item.GetItemCount(id), total = total, got = 0, targets = list }
	end

	for _, group in ipairs(groups) do
		local g = {}
		for _, src in ipairs(group) do g[#g + 1] = src end
		moneyGroups[#moneyGroups + 1] = g
		if #g == 0 then addKey("unknown") end
	end
	if unknown.money and #groups == 0 then
		moneyGroups[1] = {}
		addKey("unknown")
	end
	session.last = time()
	for _, key in ipairs(keyList) do S:Send("LOOT_RECORDED", key) end
end

local function onLootClosed()
	if not lootOpen then return end
	lootOpen, closedAt = false, GetTime()
end

-- Money that comes in while the window is open, or right after it closes, is
-- booked to the sources of the money slot, split evenly.
local function onMoney()
	if not started then return end
	local money = clean(GetMoney())
	if type(money) ~= "number" then return end
	if lastMoney == nil then
		lastMoney = money
		return
	end
	local diff = money - lastMoney
	lastMoney = money
	if diff <= 0 or #moneyGroups == 0 then return end
	local now = GetTime()
	if not (lootOpen or (closedAt and now - closedAt <= MONEY_WINDOW)) then
		moneyGroups = {}
		return
	end
	local group = moneyGroups[1]
	if #moneyGroups > 1 then table.remove(moneyGroups, 1) end
	session.money = session.money + diff
	session.last = time()
	local count = #group
	if count == 0 then return end
	local share = floor(diff / count)
	local rest = diff - share * count
	for i, src in ipairs(group) do
		local bucket = src.bucket
		if bucket then bucket.money = (bucket.money or 0) + share + (i == 1 and rest or 0) end
	end
end

local function onBags()
	if not started then return end
	settle(false)
	checkGoals()
end

-- Names of mobs looted in combat are read when combat ends.
local function onRegen()
	if not started then return end
	for id, guid in pairs(needName) do
		local mob = db.mobs[id]
		if mob and (mob.name or readIdentity(mob, guid, true)) then needName[id] = nil end
	end
	checkGoals()
end

-- Goals

local function findGoal(id)
	for i, g in ipairs(rec.goals) do
		if g.id == id then return g, i end
	end
end

-- Interface

function Loot.GetMob(npcID)
	return db and db.mobs[npcID] or nil
end

function Loot.GetNode(objectID)
	return db and db.nodes[objectID] or nil
end

local function sessionValue()
	local total, unknown = 0, 0
	for id, n in pairs(session.items) do
		local p = priceOf(id)
		if p then total = total + p * n else unknown = unknown + n end
	end
	return total, unknown
end

function Loot.GetSession()
	if not session then return nil end
	local seconds = max(time() - session.start, 0)
	local itemValue, unknown = sessionValue()
	local total = session.money + itemValue
	local perHour
	if seconds >= MIN_SESSION then perHour = floor(total * 3600 / seconds) end
	return {
		start = session.start, seconds = seconds, kills = session.kills, gathers = session.gathers,
		money = session.money, itemValue = itemValue, unknown = unknown, total = total,
		perHour = perHour, items = session.items,
	}
end

local function whereEntry(kind, id, record, gather, bucket, itemEntryData)
	local n = gather and (bucket.gathers or 0) or (kind == "mob" and record.kills or record.gathers)
	if n <= 0 then return end
	local rate = itemEntryData.drops / n
	return {
		kind = kind, id = id, name = record.name, gather = gather, drops = itemEntryData.drops, n = n, rate = rate,
		reliable = n >= RELIABLE, rare = isRare(itemEntryData.drops, n), mapID = bestMap(bucket.maps),
		count = itemEntryData.count,
	}
end

local function byRank(a, b)
	if a.reliable ~= b.reliable then return a.reliable end
	if a.rate ~= b.rate then return a.rate > b.rate end
	if a.n ~= b.n then return a.n > b.n end
	if a.kind ~= b.kind then return a.kind < b.kind end
	if a.id ~= b.id then return a.id < b.id end
	return (a.gather and 1 or 0) < (b.gather and 1 or 0)
end

function Loot.WhereDrops(itemID)
	local list = {}
	if not db then return list end
	for id, mob in pairs(db.mobs) do
		local e = mob.items[itemID]
		if e then list[#list + 1] = whereEntry("mob", id, mob, false, mob, e) end
		local ge = mob.gather and mob.gather.items[itemID]
		if ge then list[#list + 1] = whereEntry("mob", id, mob, true, mob.gather, ge) end
	end
	for id, node in pairs(db.nodes) do
		local e = node.items[itemID]
		if e then list[#list + 1] = whereEntry("node", id, node, false, node, e) end
	end
	sort(list, byRank)
	return list
end

-- Text helpers

local function accent(text) return "|cffc8794a" .. text .. "|r" end
local function grey(text) return "|cff9d9d9d" .. text .. "|r" end

local function moneyText(copper)
	copper = floor(copper or 0)
	local g, s, c = floor(copper / 10000), floor(copper / 100) % 100, copper % 100
	if g > 0 then return format("%dg %ds %dc", g, s, c) end
	if s > 0 then return format("%ds %dc", s, c) end
	return format("%dc", c)
end

local function valueText(copper, unknown)
	local text = moneyText(copper)
	if unknown and unknown > 0 then text = text .. "+?" end
	return text
end

local function durationText(seconds)
	seconds = max(floor(seconds), 0)
	local h, m = floor(seconds / 3600), floor(seconds / 60) % 60
	if h > 0 then return format("%dh %02dm", h, m) end
	return format("%dm", m)
end

local function mobName(id)
	local m = db.mobs[id]
	return m and m.name or format(L.UNKNOWN_MOB, id)
end

local function nodeName(id)
	local n = db.nodes[id]
	return n and n.name or format(L.NODE, id)
end

local function mapName(id)
	if not id then return "?" end
	local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(id)
	local name = type(info) == "table" and clean(info.name)
	if type(name) == "string" and name ~= "" then return name end
	return format(L.UNKNOWN_MAP, id)
end

-- A rate from 20 kills or gathers on, else the plain count in grey.
local function rateText(drops, n, gather)
	if n >= RELIABLE then return format("%.1f%%", drops * 100 / n) end
	return grey(format(gather and L.OF_GATHERS or L.OF_KILLS, drops, n))
end

-- Tooltip

local function topItems(mob, count)
	local list = {}
	local kills = mob.kills
	for id, e in pairs(mob.items) do
		list[#list + 1] = { id = id, drops = e.drops, rate = e.drops / kills }
	end
	sort(list, function(a, b)
		if a.rate ~= b.rate then return a.rate > b.rate end
		return a.id < b.id
	end)
	while #list > count do list[#list] = nil end
	return list
end

local function onUnit(tooltip, data)
	if not started or tooltip ~= GameTooltip then return end
	if InCombatLockdown() then return end
	local guid = data and clean(data.guid)
	if type(guid) ~= "string" then return end
	local what, id = parseGUID(guid)
	if what ~= "mob" then return end
	local mob = db.mobs[id]
	if not mob or mob.kills <= 0 then return end
	local value, unknown = valuePerKill(mob)
	tooltip:AddLine(format(L.TOOLTIP, valueText(value, unknown), mob.kills), 0.78, 0.47, 0.29)
	if IsShiftKeyDown and IsShiftKeyDown() then
		for _, it in ipairs(topItems(mob, 3)) do
			tooltip:AddLine(format("  %s %s", itemName(it.id), rateText(it.drops, mob.kills, false)), 1, 1, 1)
		end
	end
end

-- Commands

local function itemIDFrom(text)
	local id = text:match("item:(%d+)")
	if id then return tonumber(id) end
	id = text:match("^%s*(%d+)%s*$")
	if id then return tonumber(id) end
end

-- All item IDs ever recorded, for finding an item by name.
local function knownItems()
	local set = {}
	for _, mob in pairs(db.mobs) do
		for id in pairs(mob.items) do set[id] = true end
		for id in pairs(mob.gather and mob.gather.items or {}) do set[id] = true end
	end
	for _, node in pairs(db.nodes) do
		for id in pairs(node.items) do set[id] = true end
	end
	return set
end

local function itemByName(text)
	text = text:gsub("^%[", ""):gsub("%]$", ""):lower()
	if text == "" then return end
	local exact, partial
	for id in pairs(knownItems()) do
		local name = C_Item and C_Item.GetItemInfo and C_Item.GetItemInfo(id)
		if type(name) == "string" then
			local lower = name:lower()
			if lower == text then
				if not exact or id < exact then exact = id end
			elseif lower:find(text, 1, true) and (not partial or id < partial) then
				partial = id
			end
		end
	end
	return exact or partial
end

local function resolveItem(text)
	return itemIDFrom(text) or itemByName(text)
end

local function printSession()
	local s = Loot.GetSession()
	print(format("  " .. L.SESSION, durationText(s.seconds), s.kills, s.gathers, moneyText(s.money),
		valueText(s.itemValue, s.unknown), accent(valueText(s.total, s.unknown))))
	if s.perHour then
		print(format("  %s %s", accent(moneyText(s.perHour)), L.PER_HOUR))
	else
		print("  " .. grey(L.PER_HOUR_LATER))
	end
end

-- Seconds until a goal is reached, from the best known source and this
-- session's rate. nil when either is not known.
local function goalEta(g, have)
	local list = Loot.WhereDrops(g.id)
	local best = list[1]
	local s = Loot.GetSession()
	if not best or best.rate <= 0 or s.seconds < MIN_SESSION then return end
	local events = best.kind == "mob" and not best.gather and s.kills or s.gathers
	if events <= 0 then return end
	local perEvent = best.rate * (best.count / best.drops)
	local perHour = events * 3600 / s.seconds
	return (g.target - have) / perEvent / perHour * 3600
end

local function printGoals()
	if #rec.goals == 0 then
		print("  " .. grey(L.NO_GOALS))
		return
	end
	print(L.GOALS)
	for _, g in ipairs(rec.goals) do
		local have = owned(g.id)
		local line = format(L.GOAL_LINE, itemName(g.id), have, g.target)
		if have < g.target then
			local eta = goalEta(g, have)
			if eta then line = line .. " (" .. format(L.GOAL_ETA, durationText(eta)) .. ")" end
		end
		print(line)
	end
end

local function goalCommand(rest)
	local removing = rest:lower():match("^weg%s") or rest:lower():match("^remove%s")
	if removing then rest = rest:gsub("^%S+%s+", "") end
	local id = rest:match("item:(%d+)")
	local remainder
	if id then
		remainder = rest:gsub("|H.-|h.-|h", "")
	else
		id = rest:match("%d+")
		remainder = rest:gsub("%d+", "", 1)
	end
	id = tonumber(id)
	if not id then
		S:Print(L.GOAL_USAGE)
		return
	end
	if removing then
		local g, index = findGoal(id)
		if g then
			table.remove(rec.goals, index)
			goalDone[id] = nil
			S:Print(L.GOAL_REMOVED, itemName(id))
		else
			S:Print(L.GOAL_NONE)
		end
		return
	end
	local target = tonumber(remainder:match("%d+"))
	if not target or target < 1 then
		S:Print(L.GOAL_USAGE)
		return
	end
	local g = findGoal(id)
	if not g then
		if #rec.goals >= MAX_GOALS then
			S:Print(L.GOAL_FULL, MAX_GOALS)
			return
		end
		g = { id = id }
		rec.goals[#rec.goals + 1] = g
	end
	g.target = target
	goalDone[id] = nil
	S:Print(L.GOAL_SET, itemName(id), target)
	checkGoals()
end

local function whereCommand(rest)
	local id = resolveItem(rest)
	if not id then
		S:Print(rest == "" and L.WHERE_USAGE or format(L.WHERE_NONE, rest))
		return
	end
	local list = Loot.WhereDrops(id)
	if #list == 0 then
		S:Print(L.WHERE_NONE, itemName(id))
		return
	end
	S:Print(L.WHERE_HEADER, itemName(id))
	for i = 1, min(5, #list) do
		local e = list[i]
		local name = e.kind == "mob" and mobName(e.id) or nodeName(e.id)
		local rate = rateText(e.drops, e.n, e.kind == "node" or e.gather)
		if e.rare and e.n < RELIABLE then rate = rate .. " " .. grey(L.RARE) end
		print(format(L.WHERE_LINE, name, e.gather and L.GATHER_TAG or "", rate, mapName(e.mapID),
			format((e.kind == "node" or e.gather) and L.GATHERS_N or L.KILLS_N, e.n)))
	end
end

local CLASS_TEXT = { normal = "NORMAL", elite = "ELITE", rare = "RARE_CLASS" }

local function mobCommand()
	local id
	local guid = cleanGUID("target")
	if guid then
		local what, key = parseGUID(guid)
		if what == "mob" and db.mobs[key] then id = key end
	end
	id = id or lastMobID
	local mob = id and db.mobs[id]
	if not mob then
		S:Print(L.MOB_NONE)
		return
	end
	local value, unknown = valuePerKill(mob)
	local level = mob.minLevel and (mob.minLevel == mob.maxLevel and tostring(mob.minLevel)
		or format("%d-%d", mob.minLevel, mob.maxLevel)) or "?"
	S:Print(L.MOB_HEADER, mobName(id), level, L[CLASS_TEXT[mob.class or "normal"]], mob.kills,
		accent(valueText(value, unknown)))
	local list = {}
	for itemID, e in pairs(mob.items) do
		list[#list + 1] = { id = itemID, drops = e.drops, rare = isRare(e.drops, mob.kills) }
	end
	sort(list, function(a, b)
		if a.drops ~= b.drops then return a.drops > b.drops end
		return a.id < b.id
	end)
	for i = 1, min(10, #list) do
		local it = list[i]
		local line = format("  %s: %s", itemName(it.id), rateText(it.drops, mob.kills, false))
		if it.rare and mob.kills < RELIABLE then line = line .. " " .. grey(L.RARE) end
		print(line)
	end
	local maps = {}
	for mapID, n in pairs(mob.maps) do maps[#maps + 1] = { id = mapID, n = n } end
	sort(maps, function(a, b)
		if a.n ~= b.n then return a.n > b.n end
		return a.id < b.id
	end)
	local parts = {}
	for i = 1, min(3, #maps) do parts[i] = format("%s (%d)", mapName(maps[i].id), maps[i].n) end
	if #parts > 0 then print(format(L.MOB_MAPS, concat(parts, ", "))) end
	if mob.gather.gathers > 0 then print(format(L.MOB_GATHER, mob.gather.gathers)) end
end

local function topCommand()
	local list = {}
	for id, mob in pairs(db.mobs) do
		if mob.kills >= RELIABLE then
			local value, unknown = valuePerKill(mob)
			list[#list + 1] = { id = id, value = value, unknown = unknown, kills = mob.kills }
		end
	end
	if #list == 0 then
		S:Print(L.TOP_NONE)
		return
	end
	sort(list, function(a, b)
		if a.value ~= b.value then return a.value > b.value end
		return a.id < b.id
	end)
	S:Print(L.TOP_HEADER)
	for i = 1, min(10, #list) do
		local e = list[i]
		print(format("  %d. %s: %s (%d)", i, mobName(e.id), accent(valueText(e.value, e.unknown)), e.kills))
	end
end

local function command(arg)
	if not started then
		S:Print(L.NOT_READY)
		return
	end
	local word, rest = (arg or ""):match("^%s*(%S*)%s*(.-)%s*$")
	word = word:lower()
	if word == "" then
		S:Print(L.HEADER, charKey)
		printSession()
		printGoals()
	elseif word == "ziel" or word == "goal" then
		goalCommand(rest)
	elseif word == "wo" or word == "where" then
		whereCommand(rest)
	elseif word == "mob" then
		mobCommand()
	elseif word == "top" then
		topCommand()
	else
		S:Print(L.HELP)
	end
end

S.commands.loot = command

-- Login work: session and pruning. Runs from ADDON_LOADED when the core already
-- knows the character, otherwise from PLAYER_LOGIN.

local function prune()
	local cutoff = time() - PRUNE_AGE
	for _, store in ipairs({ { db.mobs, "kills" }, { db.nodes, "gathers" } }) do
		local records, field = store[1], store[2]
		local count = 0
		for id, r in pairs(records) do
			if type(r) ~= "table" or type(r.items) ~= "table" then
				records[id] = nil
			elseif (r[field] or 0) < PRUNE_MIN and (r.last or 0) < cutoff then
				records[id] = nil
			else
				count = count + 1
			end
		end
		if count > MAX_ENTRIES then
			local list = {}
			for id, r in pairs(records) do list[#list + 1] = { id = id, last = r.last or 0 } end
			sort(list, function(a, b)
				if a.last ~= b.last then return a.last < b.last end
				return a.id < b.id
			end)
			for i = 1, count - MAX_ENTRIES do records[list[i].id] = nil end
		end
	end
end

local function newSession(now)
	return { start = now, last = now, kills = 0, gathers = 0, money = 0, items = {} }
end

local function start()
	if started or not S.charKey then return end
	charKey = S.charKey
	rec = db.chars[charKey]
	if type(rec) ~= "table" then
		rec = {}
		db.chars[charKey] = rec
	end
	if type(rec.goals) ~= "table" then rec.goals = {} end
	prune()

	local now = time()
	local old = rec.session
	if type(old) == "table" and type(old.start) == "number" and type(old.last) == "number"
		and now >= old.last and now - old.last < SESSION_GAP then
		session = old
		for _, field in ipairs({ "kills", "gathers", "money" }) do
			if type(session[field]) ~= "number" then session[field] = 0 end
		end
		if type(session.items) ~= "table" then session.items = {} end
	else
		session = newSession(now)
		rec.session = session
	end
	session.last = now
	local money = clean(GetMoney())
	lastMoney = type(money) == "number" and money or nil
	started = true

	local missing = missingFunctions()
	if #missing > 0 then
		disabled = true
		S:Print(L.MISSING, concat(missing, ", "))
	end
end

local function onOptional(event, fn)
	if C_EventUtils and C_EventUtils.IsEventValid and not C_EventUtils.IsEventValid(event) then return end
	S:On(event, fn)
end

local function onItemData(_, itemID)
	if requested[itemID] then requested[itemID] = nil end
end

local function onLoaded(_, name)
	if name ~= ADDON_NAME then return end
	S:Off("ADDON_LOADED", onLoaded)
	db = initDB()
	onOptional("LOOT_OPENED", onLootOpened)
	onOptional("LOOT_CLOSED", onLootClosed)
	onOptional("PLAYER_MONEY", onMoney)
	onOptional("BAG_UPDATE_DELAYED", onBags)
	onOptional("PLAYER_REGEN_ENABLED", onRegen)
	onOptional("ITEM_DATA_LOAD_RESULT", onItemData)
	S:On("PLAYER_ENTERING_WORLD", function(_, isLogin, isReload)
		if started and (isLogin or isReload) then
			local money = clean(GetMoney())
			if type(money) == "number" then lastMoney = money end
		end
	end)
	S:On("PLAYER_LOGOUT", function()
		if session then session.last = time() end
	end)
	local types = Enum and Enum.TooltipDataType
	if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and types and types.Unit then
		TooltipDataProcessor.AddTooltipPostCall(types.Unit, onUnit)
	else
		S:Print(L.NO_TOOLTIP)
	end
	if S.charKey then
		start()
	else
		S:On("PLAYER_LOGIN", start)
	end
end
S:On("ADDON_LOADED", onLoaded)
