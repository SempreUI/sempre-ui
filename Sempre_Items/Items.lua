-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Sempre_Items: remembers what every character owns and where (bags, bank,
-- mail, equipped, gold). Scans only when the game reports a change, bursts of
-- events lead to one scan, and nothing is scanned in combat.
--
-- Read-only interface on SempreUI.Items:
--   GetCount(itemID)   -> total, res. res is shared and cached, do not modify it.
--                         res.n characters, res[i] = { key, count, bags, bank,
--                         mail, equipped } (current character first, then by
--                         count), res.account = count in the account bank.
--   GetChars()         -> iterator: key, class, faction, level, money,
--                         bank snapshot age, mail snapshot age (seconds or nil)
--   GetMail(charKey)   -> mails, snapshot time, total, shown. Each mail is
--                         { kind = "ah"|"player"|"system", money, days,
--                         items = { id, count, id, count, ... } }; days is as of
--                         the snapshot time.
--   GetName(itemID)    -> name or nil; asks the client and later sends
--                         ITEM_NAME_READY(itemID).
-- Message ITEMS_CHANGED(charKey, location) after each scan; location is one of
-- bags, bank, account, equipped, mail, money.

local ADDON_NAME = ...

local S = SempreUI
local pairs, ipairs, type, format, tonumber, floor, next = pairs, ipairs, type, string.format, tonumber, math.floor, next
local time, wipe, sort = time, table.wipe, table.sort
local issecretvalue = issecretvalue
local C_Container, C_Item, C_EventUtils = C_Container, C_Item, C_EventUtils
local GetMoney, UnitClass, UnitFactionGroup, UnitLevel = GetMoney, UnitClass, UnitFactionGroup, UnitLevel
local GetInventoryItemID, GetInventoryItemLink = GetInventoryItemID, GetInventoryItemLink
local InCombatLockdown, CreateFrame, GetLocale = InCombatLockdown, CreateFrame, GetLocale

local Items = {}
S.Items = Items
Items.version = 0 -- raised after every change, lets caches know they are stale
Items.scanCount = 0 -- number of scan runs, shown by /sempre items debug

local L = setmetatable({}, { __index = function(_, k) return k end })
Items.L = L
if GetLocale() == "deDE" then
	L.bags = "Taschen"
	L.bank = "Bank"
	L.mail = "Post"
	L.equipped = "angelegt"
	L.account = "Accountbank"
	L.TOTAL = "Gesamt"
	L.MORE = "+%d weitere"
	L.NO_TOOLTIP = "Items: Tooltip-Zeilen gibt es in diesem Client nicht, der Rest läuft weiter."
	L.NO_CONTAINER = "Items: C_Container fehlt in diesem Client, Taschen und Bank werden nicht erfasst."
	L.NOT_READY = "Items: noch keine Daten, bitte nach dem Login erneut versuchen."
	L.GOLD_HEADER = "Gold pro Charakter (Alter von Bank und Post):"
	L.NO_BANK = "Die Bank wird in diesem Client nicht erfasst (Enum.BagIndex fehlt)."
	L.MAIL_HIDDEN = "%d Briefe noch nicht sichtbar"
	L.NEVER = "nie"
	L.AGE_MIN = "vor %d Min."
	L.AGE_HOUR = "vor %d Std."
	L.AGE_DAY = "vor %d Tg."
	L.AGE_NOW = "gerade eben"
	L.SCANS = "Scans seit dem Login: %d"
else
	L.bags = "bags"
	L.bank = "bank"
	L.mail = "mail"
	L.equipped = "equipped"
	L.account = "Account bank"
	L.TOTAL = "Total"
	L.MORE = "+%d more"
	L.NO_TOOLTIP = "Items: tooltip lines are not available in this client, everything else keeps working."
	L.NO_CONTAINER = "Items: C_Container is missing in this client, bags and bank are not tracked."
	L.NOT_READY = "Items: no data yet, try again after login."
	L.GOLD_HEADER = "Gold per character (age of bank and mail):"
	L.NO_BANK = "The bank is not tracked in this client (Enum.BagIndex is missing)."
	L.MAIL_HIDDEN = "%d mails not yet visible"
	L.NEVER = "never"
	L.AGE_MIN = "%d min ago"
	L.AGE_HOUR = "%d h ago"
	L.AGE_DAY = "%d d ago"
	L.AGE_NOW = "just now"
	L.SCANS = "Scans since login: %d"
end

-- Saved data

local DB_VERSION = 1
-- migrations[n] upgrades a database from version n to n + 1.
local migrations = {}

local function initDB()
	SempreItemsDB = SempreItemsDB or {}
	local db = SempreItemsDB
	if type(db.version) ~= "number" then db.version = DB_VERSION end
	while db.version < DB_VERSION do
		local fn = migrations[db.version]
		if fn then fn(db) end
		db.version = db.version + 1
	end
	if type(db.chars) ~= "table" then db.chars = {} end
	return db
end

-- A value the addon must not compute with is dropped. Item data is not secret
-- today, the guard keeps a later restriction from erroring.
local function clean(v)
	if issecretvalue and issecretvalue(v) then return nil end
	return v
end

-- Bag layout, built from Enum.BagIndex names at load time, never from numbers.
-- Assumption: names are Backpack, Bag_<n>, ReagentBag for the bags, Bank,
-- BankBag_<n>, CharacterBankTab_<n>, Reagentbank for the character bank and
-- AccountBankTab_<n> for the account bank. Slot counts are checked per scan, so
-- tabs the player has not bought cost nothing.

local KINDS = { "bags", "bank", "account" }
local LOCATIONS = { "bags", "bank", "account", "equipped", "mail" }
local kindIDs = { bags = {}, bank = {}, account = {} }
local kindOf = {}
local bankTracked = false

local function buildLayout()
	local index = Enum and Enum.BagIndex
	if type(index) == "table" then
		for name, id in pairs(index) do
			if type(name) == "string" and type(id) == "number" then
				local kind
				if name == "Backpack" or name:find("^Bag_%d") or name:find("^ReagentBag") then
					kind = "bags"
				elseif name:find("^AccountBankTab") then
					kind = "account"
				elseif name:find("^Bank") or name:find("^CharacterBankTab") or name:find("^Reagentbank") then
					kind = "bank"
				end
				if kind then
					local list = kindIDs[kind]
					list[#list + 1] = id
					kindOf[id] = kind
				end
			end
		end
		bankTracked = true
	else
		-- Without the enum only the backpack and the four bag slots are known.
		for id = 0, 4 do
			kindIDs.bags[#kindIDs.bags + 1] = id
			kindOf[id] = "bags"
		end
	end
	for _, list in pairs(kindIDs) do sort(list) end
end
buildLayout()
Items.bankTracked = bankTracked

local hasContainer = C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemInfo

-- State

local db, char, charKey
local started = false
local bankOpen, mailOpen = false, false
local perBag, perBagLinks = {}, {} -- bagID -> { itemID -> count }, bagID -> { itemID -> links }
local dirtyBag = {}
local pendingEquipped, pendingMail, pendingMoney = false, false, false
local changed = {}
local MAX_LINKS = 4

-- Links: stored only when they carry more than the item ID. Assumption: after
-- "item:<id>" come enchant, four gems and the suffix; the later fields (level,
-- spec, bonus IDs) are set on nearly every link and are not counted.

local function plain(v) return v == "" or v == "0" end

local function shortLink(link)
	if type(link) ~= "string" then return end
	local a, b, c, d, e, f = link:match("item:%d+:([^:|]*):([^:|]*):([^:|]*):([^:|]*):([^:|]*):([^:|]*)")
	if not a or (plain(a) and plain(b) and plain(c) and plain(d) and plain(e) and plain(f)) then return end
	return link:match("(item:[^|]+)")
end

local function addLink(links, id, link)
	local list = links[id]
	if not list then
		list = {}
		links[id] = list
	end
	for i = 1, #list do
		if list[i] == link then return end
	end
	if #list < MAX_LINKS then list[#list + 1] = link end
end

local function scanContainer(bagID)
	local items = perBag[bagID]
	if not items then
		items = {}
		perBag[bagID] = items
	end
	wipe(items)
	perBagLinks[bagID] = nil
	local slots = clean(C_Container.GetContainerNumSlots(bagID))
	if type(slots) ~= "number" then return end
	for slot = 1, slots do
		local info = C_Container.GetContainerItemInfo(bagID, slot)
		if info then
			local id, count = clean(info.itemID), clean(info.stackCount)
			if type(id) == "number" and id > 0 then
				items[id] = (items[id] or 0) + (type(count) == "number" and count or 1)
				local link = shortLink(clean(info.hyperlink))
				if link then
					local links = perBagLinks[bagID]
					if not links then
						links = {}
						perBagLinks[bagID] = links
					end
					addLink(links, id, link)
				end
			end
		end
	end
end

local function locFor(kind)
	if kind == "account" then
		db.account = db.account or { items = {}, time = 0 }
		return db.account
	end
	local loc = char[kind]
	if not loc then
		loc = { items = {}, time = 0 }
		char[kind] = loc
	end
	return loc
end

local function aggregate(kind)
	local loc = locFor(kind)
	local items = loc.items
	wipe(items)
	loc.links = nil
	for _, bagID in ipairs(kindIDs[kind]) do
		local src = perBag[bagID]
		if src then
			for id, count in pairs(src) do items[id] = (items[id] or 0) + count end
		end
		local srcLinks = perBagLinks[bagID]
		if srcLinks then
			loc.links = loc.links or {}
			for id, list in pairs(srcLinks) do
				for i = 1, #list do addLink(loc.links, id, list[i]) end
			end
		end
	end
	loc.time = time()
end

-- Assumption: inventory slots 1 to 19 are the worn gear; worn bags are covered
-- by the bag scan and not counted as items.
local function scanEquipped()
	if not (GetInventoryItemID and GetInventoryItemLink) then return false end
	local loc = locFor("equipped")
	wipe(loc.items)
	loc.links = nil
	for slot = 1, 19 do
		local id = clean(GetInventoryItemID("player", slot))
		if type(id) == "number" and id > 0 then
			loc.items[id] = (loc.items[id] or 0) + 1
			local link = shortLink(clean(GetInventoryItemLink("player", slot)))
			if link then
				loc.links = loc.links or {}
				addLink(loc.links, id, link)
			end
		end
	end
	loc.time = time()
	return true
end

-- Mail: the inbox functions are plain globals. Assumptions: GetInboxHeaderInfo
-- returns money as 5th, days left as 7th and canReply as 12th value;
-- GetInboxItem returns the item ID as 2nd and the count as 4th value;
-- GetInboxInvoiceInfo returns a value only for auction house sales.
-- Mail from the auction house that is no invoice (outbid, expired) counts as
-- "system". Sender names are not stored.

local function mailKind(index, canReply)
	if GetInboxInvoiceInfo and GetInboxInvoiceInfo(index) then return "ah" end
	if canReply == false then return "system" end
	return "player"
end

local function scanMail()
	if not (GetInboxNumItems and GetInboxHeaderInfo) then return false end
	local loc = locFor("mail")
	local shown, total = GetInboxNumItems()
	shown = type(shown) == "number" and shown or 0
	total = type(total) == "number" and total or shown
	local items = loc.items
	wipe(items)
	loc.links = nil
	local mails = {}
	local maxAttach = ATTACHMENTS_MAX_RECEIVE or 16
	for i = 1, shown do
		local _, _, _, _, money, _, days, itemCount, _, _, _, canReply = GetInboxHeaderInfo(i)
		local mail = { kind = mailKind(i, canReply), money = money or 0, days = days or 0, items = {} }
		local list = mail.items
		if GetInboxItem and (itemCount or 0) > 0 then
			for a = 1, maxAttach do
				local _, id, _, count = GetInboxItem(i, a)
				local link = GetInboxItemLink and GetInboxItemLink(i, a)
				if type(id) ~= "number" and type(link) == "string" then
					id = tonumber(link:match("item:(%d+)"))
				end
				if type(id) == "number" and id > 0 then
					count = type(count) == "number" and count or 1
					list[#list + 1] = id
					list[#list + 1] = count
					items[id] = (items[id] or 0) + count
					link = shortLink(link)
					if link then
						loc.links = loc.links or {}
						addLink(loc.links, id, link)
					end
				end
			end
		end
		mails[i] = mail
	end
	loc.mails = mails
	loc.shown = shown
	loc.total = total
	loc.time = time()
	return true
end

-- Scheduling: events only mark work. A hidden frame is shown, its OnUpdate runs
-- once on the next frame, so a burst within one frame costs one scan.

local ticker

local function hasWork()
	return pendingMoney or pendingEquipped or pendingMail or next(dirtyBag) ~= nil
end

local function schedule()
	if ticker then ticker:Show() end
end

local function markKind(kind)
	if not hasContainer then return end
	for _, id in ipairs(kindIDs[kind]) do dirtyBag[id] = true end
end

local function flush()
	if not (started and hasWork()) then return end
	local now = time()
	if pendingMoney then
		pendingMoney = false
		char.money = GetMoney()
		char.updated = now
		Items.version = Items.version + 1
		S:Send("ITEMS_CHANGED", charKey, "money")
	end
	-- Item data is not secret, but full scans wait for the end of combat.
	if InCombatLockdown and InCombatLockdown() then return end
	if not (pendingEquipped or pendingMail or next(dirtyBag) ~= nil) then return end
	Items.scanCount = Items.scanCount + 1
	for id in pairs(dirtyBag) do
		dirtyBag[id] = nil
		local kind = kindOf[id]
		if kind then
			scanContainer(id)
			changed[kind] = true
		end
	end
	for _, kind in ipairs(KINDS) do
		if changed[kind] then aggregate(kind) end
	end
	if pendingEquipped then
		pendingEquipped = false
		changed.equipped = scanEquipped()
	end
	if pendingMail then
		pendingMail = false
		if mailOpen then changed.mail = scanMail() end
	end
	char.updated = now
	Items.version = Items.version + 1
	for _, loc in ipairs(LOCATIONS) do
		if changed[loc] then
			changed[loc] = nil
			S:Send("ITEMS_CHANGED", charKey, loc)
		end
	end
end

-- Event handlers

local function onBagUpdate(_, bagID)
	local kind = kindOf[bagID]
	if not kind then return end
	if kind ~= "bags" and not bankOpen then return end
	dirtyBag[bagID] = true
	schedule()
end

local function setBank(open)
	if open == bankOpen then return end
	bankOpen = open
	if open then
		markKind("bank")
		markKind("account")
		schedule()
	end
end

local function setMail(open)
	if open == mailOpen then return end
	mailOpen = open
	if open then
		pendingMail = true
		schedule()
	end
end

-- Assumption: Enum.PlayerInteractionType has Banker, AccountBanker and MailInfo.
-- Missing names are nil and never match.
local function onInteraction(event, kind)
	local types = Enum and Enum.PlayerInteractionType
	if not types or kind == nil then return end
	local show = event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW"
	if kind == types.Banker or kind == types.AccountBanker then
		setBank(show)
	elseif kind == types.MailInfo then
		setMail(show)
	end
end

local function markBank()
	if not bankOpen then return end
	markKind("bank")
	markKind("account")
	schedule()
end

-- Events that this client may not know are checked first, so the core does not
-- print a warning for them.
local function onOptional(event, fn)
	if C_EventUtils and C_EventUtils.IsEventValid and not C_EventUtils.IsEventValid(event) then return end
	S:On(event, fn)
end

local requested = {}

local function updateMeta()
	local _, class = UnitClass("player")
	char.class = class
	char.faction = UnitFactionGroup("player")
	char.level = UnitLevel("player")
end

local function start()
	if started or not S.charKey then return end
	charKey = S.charKey
	db = SempreItemsDB
	char = db.chars[charKey]
	if not char then
		char = {}
		db.chars[charKey] = char
	end
	updateMeta()
	char.money = GetMoney()
	char.updated = time()
	started = true

	ticker = CreateFrame("Frame")
	ticker:Hide()
	ticker:SetScript("OnUpdate", function(self)
		self:Hide()
		flush()
	end)

	if hasContainer then
		markKind("bags")
	else
		S:Print(L.NO_CONTAINER)
	end
	pendingEquipped = true
	Items.version = Items.version + 1

	if hasContainer then S:On("BAG_UPDATE", onBagUpdate) end
	S:On("PLAYER_EQUIPMENT_CHANGED", function() pendingEquipped = true schedule() end)
	S:On("PLAYER_MONEY", function() pendingMoney = true schedule() end)
	S:On("PLAYER_LEVEL_UP", updateMeta)
	S:On("PLAYER_REGEN_ENABLED", function() if hasWork() then schedule() end end)
	onOptional("MAIL_SHOW", function() setMail(true) end)
	onOptional("MAIL_CLOSED", function() setMail(false) end)
	onOptional("MAIL_INBOX_UPDATE", function()
		if mailOpen then pendingMail = true schedule() end
	end)
	onOptional("BANKFRAME_OPENED", function() setBank(true) end)
	onOptional("BANKFRAME_CLOSED", function() setBank(false) end)
	onOptional("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", onInteraction)
	onOptional("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", onInteraction)
	onOptional("PLAYERBANKSLOTS_CHANGED", markBank)
	onOptional("PLAYERBANKBAGSLOTS_CHANGED", markBank)
	onOptional("PLAYERREAGENTBANKSLOTS_CHANGED", markBank)
	onOptional("BANK_TAB_SETTINGS_UPDATED", markBank)
	onOptional("BANK_TABS_CHANGED", markBank)
	onOptional("ITEM_DATA_LOAD_RESULT", function(_, itemID, success)
		if requested[itemID] then
			requested[itemID] = nil
			if success then S:Send("ITEM_NAME_READY", itemID) end
		end
	end)
	schedule()
end

local function onLoaded(_, name)
	if name ~= ADDON_NAME then return end
	S:Off("ADDON_LOADED", onLoaded)
	initDB()
	-- Normally the core already knows the character; if the module was loaded
	-- earlier, the login event completes the start.
	if S.charKey then
		start()
	else
		S:On("PLAYER_LOGIN", start)
	end
end
S:On("ADDON_LOADED", onLoaded)

-- Interface

local cache, cacheVersion = {}, -1
local EMPTY = { total = 0, n = 0, account = 0 }

local function countIn(loc, itemID)
	return loc and loc.items and loc.items[itemID] or 0
end

local function byCount(a, b)
	local ac, bc = a.key == charKey, b.key == charKey
	if ac ~= bc then return ac end
	if a.count ~= b.count then return a.count > b.count end
	return a.key < b.key
end

local function buildCount(itemID)
	local res, n, total
	n, total = 0, 0
	for key, rec in pairs(db.chars) do
		local bags, bank = countIn(rec.bags, itemID), countIn(rec.bank, itemID)
		local mail, equipped = countIn(rec.mail, itemID), countIn(rec.equipped, itemID)
		local count = bags + bank + mail + equipped
		if count > 0 then
			res = res or { n = 0, total = 0, account = 0 }
			n = n + 1
			res[n] = { key = key, count = count, bags = bags, bank = bank, mail = mail, equipped = equipped }
			total = total + count
		end
	end
	local account = countIn(db.account, itemID)
	if account > 0 then
		res = res or { n = 0, total = 0, account = 0 }
		res.account = account
		total = total + account
	end
	if not res then return EMPTY end
	res.n, res.total = n, total
	sort(res, byCount)
	return res
end

-- Cached until the next change; a repeated call allocates nothing.
function Items.GetCount(itemID)
	if not db then return 0, EMPTY end
	if cacheVersion ~= Items.version then
		wipe(cache)
		cacheVersion = Items.version
	end
	local res = cache[itemID]
	if not res then
		res = buildCount(itemID)
		cache[itemID] = res
	end
	return res.total, res
end

local function ageOf(loc)
	return loc and loc.time and loc.time > 0 and time() - loc.time or nil
end

function Items.GetChars()
	local keys = {}
	if db then
		for key in pairs(db.chars) do keys[#keys + 1] = key end
		sort(keys)
	end
	local i = 0
	return function()
		i = i + 1
		local key = keys[i]
		if not key then return end
		local rec = db.chars[key]
		return key, rec.class, rec.faction, rec.level, rec.money or 0, ageOf(rec.bank), ageOf(rec.mail)
	end
end

function Items.GetMail(key)
	local rec = db and db.chars[key]
	local loc = rec and rec.mail
	if not loc then return {}, nil, 0, 0 end
	return loc.mails or {}, loc.time, loc.total or 0, loc.shown or 0
end

function Items.GetName(itemID)
	if not (C_Item and C_Item.GetItemInfo) then return end
	local name = C_Item.GetItemInfo(itemID)
	if name then return name end
	if C_Item.RequestLoadItemDataByID and not requested[itemID] then
		requested[itemID] = true
		C_Item.RequestLoadItemDataByID(itemID)
	end
end

-- /sempre items

local function moneyText(copper)
	copper = floor(copper or 0)
	return format("%dg %ds %dc", floor(copper / 10000), floor(copper / 100) % 100, copper % 100)
end

local function ageText(age)
	if not age then return L.NEVER end
	if age < 60 then return L.AGE_NOW end
	if age < 3600 then return format(L.AGE_MIN, floor(age / 60)) end
	if age < 86400 then return format(L.AGE_HOUR, floor(age / 3600)) end
	return format(L.AGE_DAY, floor(age / 86400))
end

S.commands.items = function(arg)
	if not started then
		S:Print(L.NOT_READY)
		return
	end
	if arg == "debug" then
		S:Print(L.SCANS, Items.scanCount)
		return
	end
	S:Print(L.GOLD_HEADER)
	local sum = 0
	for key, _, _, _, money, bankAge, mailAge in Items.GetChars() do
		sum = sum + money
		print(format("  %s: %s (%s %s, %s %s)", key, moneyText(money), L.bank, ageText(bankAge), L.mail, ageText(mailAge)))
		local _, _, total, shown = Items.GetMail(key)
		if total > shown then print("    " .. format(L.MAIL_HIDDEN, total - shown)) end
	end
	print(format("  %s: %s", L.TOTAL, moneyText(sum)))
	if db.account and next(db.account.items) then
		print(format("  %s: %s", L.account, ageText(ageOf(db.account))))
	end
	if not bankTracked then print("  " .. L.NO_BANK) end
end
