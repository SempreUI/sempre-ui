-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Sempre_Ledger: gold journal. Every change of the character's money is booked
-- once, with a source decided from the open windows at that moment. Money that
-- changed while the module did not run is never booked (the baseline is read at
-- login). Transfers between own characters are booked as "transfer" and never
-- count as income or expense in any total. Also records what was sold to
-- vendors, per item and day, what was sold at the auction house (from mail
-- invoices), what was paid for items at vendors and the auction house, and
-- the auction house deposits.
--
-- Read-only interface on SempreUI.Ledger:
--   GetDay(charKey, date)    -> day record { income = {source = copper},
--                               expense = {...}, vendorItems = {itemID =
--                               {count, copper}} } or nil. Date is YYYY-MM-DD.
--                               Newer fields exist only when used: auctionItems
--                               [itemID or name] = {count, gross, cut, deposit,
--                               net}, purchases[itemID] = {count, copper,
--                               source}, deposits[itemID] = {count, copper},
--                               sub = {deposit = copper}. Do not modify it.
--   GetRange(charKey, days)  -> { income, expense, incomeTotal, expenseTotal,
--                               net, days } for today and the days-1 before.
--                               Totals and net leave out "transfer".
--   GetSession()            -> { start, startMoney, income, expense, net,
--                               seconds, perHour } or nil before login.
--   GetItem(charKey, itemID, days) -> { vendor, vendorCount, auction,
--                               auctionCount, purchases, purchaseCount,
--                               deposits } in copper for today and the days-1
--                               before. auction is gross minus cut (a returned
--                               deposit is not income); deposits is extra and
--                               not part of any result.
--   GetItemAll(itemID, days) -> the same summed over all characters.
-- Messages: LEDGER_CHANGED(charKey, source) after each booking and
-- LEDGER_ITEM_CHANGED(charKey, itemID) after each item booking (a vendor sale,
-- an auction sale, a purchase, a cancelled bid).
--
-- /sempre gold: default, alle, items [ah], pruefen (alias check).

local ADDON_NAME = ...

local S = SempreUI
local pairs, ipairs, type, format, tonumber, floor, abs, select = pairs, ipairs, type, string.format, tonumber, math.floor, math.abs, select
local time, date, sort, concat, max = time, date, table.sort, table.concat, math.max
local issecretvalue = issecretvalue
local C_Container, C_Item, C_EventUtils, C_Merchant, C_Mail = C_Container, C_Item, C_EventUtils, C_Merchant, C_Mail
local GetInboxNumItems, GetInboxInvoiceInfo, C_AuctionHouse = GetInboxNumItems, GetInboxInvoiceInfo, C_AuctionHouse
local GetMoney, GetTime, GetRealmName, GetLocale = GetMoney, GetTime, GetRealmName, GetLocale
local GetInboxHeaderInfo, hooksecurefunc = GetInboxHeaderInfo, hooksecurefunc
local GetMerchantItemLink, GetMerchantItemInfo = GetMerchantItemLink, GetMerchantItemInfo

local Ledger = {}
S.Ledger = Ledger

local L = setmetatable({}, { __index = function(_, k) return k end })
Ledger.L = L
if GetLocale() == "deDE" then
	L.vendor = "Händler"
	L.repair = "Reparatur"
	L.mail = "Post"
	L.auction = "Auktionshaus"
	L.trainer = "Lehrer"
	L.flight = "Flug"
	L.quest = "Quest"
	L.loot = "Beute"
	L.trade = "Handel"
	L.guildbank = "Gildenbank"
	L.other = "Sonstiges"
	L.transfer = "Übertrag (zählt nicht)"
	L.NOT_READY = "Ledger: noch keine Daten, bitte nach dem Login erneut versuchen."
	L.MISSING = "Ledger: in diesem Client fehlt %s, dieser Teil wird nicht erfasst."
	L.HEADER = "Goldjournal %s:"
	L.SESSION = "Sitzung"
	L.TODAY = "Heute"
	L.WEEK = "Letzte 7 Tage"
	L.PER_HOUR = "pro Stunde"
	L.INCOME = "Einnahmen"
	L.EXPENSE = "Ausgaben"
	L.NO_BOOKINGS = "keine Buchungen"
	L.ALL_HEADER = "Netto der letzten 7 Tage pro Charakter:"
	L.TOTAL = "Gesamt"
	L.ITEMS_HEADER = "Top 10 Items der letzten 30 Tage nach Ergebnis:"
	L.NO_ITEMS = "Keine Item-Buchungen erfasst."
	L.AH_ITEMS_HEADER = "Top 10 Auktionshaus-Verkäufe der letzten 30 Tage nach Ergebnis:"
	L.NO_AH_ITEMS = "Keine Auktionshaus-Verkäufe erfasst."
	L.CHECK_HEADER = "Händlerprüfung: Abweichungen zwischen Itemverkäufen und Händlereinnahmen (die letzten %d):"
	L.CHECK_NONE = "Händlerprüfung: keine Abweichungen erfasst."
	L.NO_SALES = "keine Itemverkäufe"
	L.PART_VENDOR = "Händler"
	L.PART_AUCTION = "Auktion"
	L.PART_BOUGHT = "Einkauf"
else
	L.vendor = "vendor"
	L.repair = "repair"
	L.mail = "mail"
	L.auction = "auction"
	L.trainer = "trainer"
	L.flight = "flight"
	L.quest = "quest"
	L.loot = "loot"
	L.trade = "trade"
	L.guildbank = "guild bank"
	L.other = "other"
	L.transfer = "transfer (not counted)"
	L.NOT_READY = "Ledger: no data yet, try again after login."
	L.MISSING = "Ledger: %s is missing in this client, that part is not tracked."
	L.HEADER = "Gold journal %s:"
	L.SESSION = "Session"
	L.TODAY = "Today"
	L.WEEK = "Last 7 days"
	L.PER_HOUR = "per hour"
	L.INCOME = "Income"
	L.EXPENSE = "Expense"
	L.NO_BOOKINGS = "no bookings"
	L.ALL_HEADER = "Net of the last 7 days per character:"
	L.TOTAL = "Total"
	L.ITEMS_HEADER = "Top 10 items of the last 30 days by net result:"
	L.NO_ITEMS = "No item bookings recorded."
	L.AH_ITEMS_HEADER = "Top 10 auction house sales of the last 30 days by net result:"
	L.NO_AH_ITEMS = "No auction house sales recorded."
	L.CHECK_HEADER = "Vendor check: differences between item sales and vendor income (last %d):"
	L.CHECK_NONE = "Vendor check: no differences recorded."
	L.NO_SALES = "no item sales"
	L.PART_VENDOR = "vendor"
	L.PART_AUCTION = "auction"
	L.PART_BOUGHT = "bought"
end

-- Saved data
-- SempreLedgerDB = { version, chars = { [charKey] = { days = { ["YYYY-MM-DD"] =
-- { income = {}, expense = {}, vendorItems = {} } }, session = {} } } }

local DB_VERSION = 2
local KEEP_DAYS = 90
local SESSION_GAP = 15 * 60
-- migrations[n] upgrades a database from version n to n + 1.
local migrations = {
	-- 1 -> 2: days get auctionItems, purchases, deposits and sub on demand, so
	-- nothing is rewritten; only the character containers are made sure of.
	[1] = function(db)
		if type(db.chars) ~= "table" then return end
		for _, r in pairs(db.chars) do
			if type(r) == "table" and type(r.days) ~= "table" then r.days = {} end
		end
	end,
}

local function initDB()
	SempreLedgerDB = SempreLedgerDB or {}
	local db = SempreLedgerDB
	if type(db.version) ~= "number" then db.version = DB_VERSION end
	while db.version < DB_VERSION do
		local fn = migrations[db.version]
		if fn then fn(db) end
		db.version = db.version + 1
	end
	if type(db.chars) ~= "table" then db.chars = {} end
	return db
end

-- Windows in seconds (GetTime) that tie a money change to an action.
local QUEST_WINDOW, LOOT_WINDOW, FLIGHT_WINDOW = 1, 1, 5
local REPAIR_WINDOW, TRANSFER_WINDOW = 3, 10

-- State

local db, rec, charKey, session
local started = false
local lastMoney -- nil until the first reading, which only sets the baseline
local open = {} -- merchant, mail, auction, trainer, flight, trade, guildbank, loot
local lastQuest, lastFlight, lastRepair, lastSendOwn
-- Close times of windows whose money may arrive just after they close.
local closedAt = {}
local incoming = {} -- money in mails from own characters that is being taken: { amount, time }
local visitSales = {} -- sales of the current merchant visit, newest last
local visit -- the open merchant visit: { income = vendor income booked since it opened }
local pendingSales = {} -- itemID -> sales waiting for the item's sell price
local pendingSpend = {} -- purchases and deposits waiting for their money change
local mailInfo = {} -- inbox index -> auction mail read when the mailbox showed it
local incomingAuction = {} -- auction mail money that is being taken: { amount, time, info }
local seenNames = {} -- item name -> item ID, for items this session has handled
local seenCount = 0

-- A value the addon must not compute with is dropped.
local function clean(v)
	if issecretvalue and issecretvalue(v) then return nil end
	return v
end

-- Local date key. Computed from noon so a daylight saving shift never skips or
-- repeats a day when stepping back in whole days.
local function dayKey(offset)
	local t = date("*t", time())
	t.hour, t.min, t.sec, t.isdst = 12, 0, 0, nil
	return date("%Y-%m-%d", time(t) - (offset or 0) * 86400)
end

local function dayRecord(key)
	local days = rec.days
	local day = days[key]
	if not day then
		day = { income = {}, expense = {}, vendorItems = {} }
		days[key] = day
	end
	return day
end

-- A table of a day that exists only once something is booked into it.
local function daySub(key, name)
	local day = dayRecord(key)
	local t = day[name]
	if not t then
		t = {}
		day[name] = t
	end
	return t
end

local function prune()
	local cutoff = dayKey(KEEP_DAYS)
	for _, r in pairs(db.chars) do
		if type(r.days) == "table" then
			for key in pairs(r.days) do
				if key < cutoff then r.days[key] = nil end
			end
		end
	end
end

-- Own characters. Known from Sempre_Items when it is loaded (only if its saved
-- data is present, never required) and from this module's own list. Names are
-- compared without spaces and case, and a name without realm gets this realm,
-- because mail uses "Name" for the same realm and "Name-RealmName" otherwise.
local function normalize(name)
	return (name:gsub("%s", ""):lower())
end

local function isOwn(name)
	name = clean(name)
	if type(name) ~= "string" or name == "" then return false end
	local norm = normalize(name)
	if not norm:find("-", 1, true) then
		local realm = clean(GetRealmName())
		if type(realm) ~= "string" then return false end
		norm = norm .. "-" .. normalize(realm)
	end
	local sources = { db and db.chars, SempreItemsDB and SempreItemsDB.chars }
	for i = 1, 2 do
		local chars = sources[i]
		if type(chars) == "table" then
			for key in pairs(chars) do
				if type(key) == "string" and normalize(key) == norm then return true end
			end
		end
	end
	return false
end

-- Booking

local function book(source, diff, sub)
	local day = dayRecord(dayKey(0))
	local into = diff > 0 and day.income or day.expense
	local amount = abs(diff)
	into[source] = (into[source] or 0) + amount
	if visit and source == "vendor" and diff > 0 then visit.income = visit.income + amount end
	if sub then
		local t = daySub(dayKey(0), "sub")
		t[sub] = (t[sub] or 0) + amount
	end
	if session and source ~= "transfer" then
		local field = diff > 0 and "income" or "expense"
		session[field] = (session[field] or 0) + amount
	end
	if session then session.last = time() end
	S:Send("LEDGER_CHANGED", charKey, source)
end

local function itemChanged(itemKey)
	S:Send("LEDGER_ITEM_CHANGED", charKey, itemKey)
end

-- Source by context, first match wins. now is GetTime().
local function sourceFor(diff, now)
	if open.merchant then
		-- A repair marker covers the next change only.
		local repaired = lastRepair and now - lastRepair <= REPAIR_WINDOW
		lastRepair = nil
		return diff < 0 and repaired and "repair" or "vendor"
	end
	if open.mail then return "mail" end
	if open.auction then return "auction" end
	if open.trainer then return "trainer" end
	if open.flight or (lastFlight and now - lastFlight <= FLIGHT_WINDOW) then return "flight" end
	if open.quest or (lastQuest and now - lastQuest <= QUEST_WINDOW)
		or (closedAt.quest and now - closedAt.quest <= QUEST_WINDOW) then return "quest" end
	if open.loot or (closedAt.loot and now - closedAt.loot <= LOOT_WINDOW) then return "loot" end
	if open.trade or (closedAt.trade and now - closedAt.trade <= LOOT_WINDOW) then return "trade" end
	if open.guildbank then return "guildbank" end
	return "other"
end

-- Takes the part of a gain that matches mails from own characters. Returns the
-- transfer amount and what is left over.
local function takeIncoming(diff, now)
	local moved, i = 0, 1
	while i <= #incoming do
		local entry = incoming[i]
		if now - entry.time > TRANSFER_WINDOW then
			table.remove(incoming, i)
		elseif entry.amount <= diff - moved then
			moved = moved + entry.amount
			table.remove(incoming, i)
		else
			i = i + 1
		end
	end
	return moved, diff - moved
end

local takeSpend, settleSpend -- see "Purchases"
local scanInbox, takeAuctionMail -- see "Auction mail"
local checkVisit -- see "Vendor check"

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
	if diff == 0 then return end
	local now = GetTime()
	if open.mail then
		-- Postage to an own character is part of the transfer (a few copper).
		if diff < 0 and lastSendOwn and now - lastSendOwn <= TRANSFER_WINDOW then
			lastSendOwn = nil
			book("transfer", diff)
			return
		end
		if diff > 0 then
			local moved, rest = takeIncoming(diff, now)
			if moved > 0 then book("transfer", moved) end
			if rest > 0 then rest = takeAuctionMail(rest, now) end
			if rest == 0 then return end
			diff = rest
		end
	end
	local source = sourceFor(diff, now)
	local spend = diff < 0 and takeSpend(source, now)
	book(source, diff, spend and spend.kind == "deposit" and "deposit" or nil)
	if spend then settleSpend(spend, -diff) end
end

-- Windows. Interaction-manager events first, classic events as fallback; both
-- set the same flag, so a client that sends both is fine.

local interaction = {} -- interaction type number -> flag

local function buildInteraction()
	local types = Enum and Enum.PlayerInteractionType
	if type(types) ~= "table" then return end
	-- Assumption: these names exist in Enum.PlayerInteractionType; missing ones
	-- are nil and never match.
	local names = {
		Merchant = "merchant", MailInfo = "mail", Auctioneer = "auction", AuctionHouse = "auction",
		Trainer = "trainer", TaxiNode = "flight", TradePartner = "trade", GuildBanker = "guildbank",
	}
	for name, flag in pairs(names) do
		local id = types[name]
		if type(id) == "number" then interaction[id] = flag end
	end
end

local function setOpen(flag, value)
	if open[flag] == value then return end
	open[flag] = value
	if flag == "merchant" and value then
		visitSales = {}
		visit = { income = 0 }
	end
	if flag == "merchant" and not value and checkVisit then checkVisit() end
	-- The invoices are read now: a mail may be gone once its money is taken.
	if flag == "mail" and value and scanInbox then scanInbox() end
	if not value then closedAt[flag] = GetTime() end
end

local function onInteraction(event, kind)
	local flag = interaction[clean(kind)]
	if flag then setOpen(flag, event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW") end
end

local CLASSIC = {
	{ "merchant", "MERCHANT_SHOW", "MERCHANT_CLOSED" },
	{ "mail", "MAIL_SHOW", "MAIL_CLOSED" },
	{ "auction", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED" },
	{ "trainer", "TRAINER_SHOW", "TRAINER_CLOSED" },
	{ "flight", "TAXIMAP_OPENED", "TAXIMAP_CLOSED" },
	{ "trade", "TRADE_SHOW", "TRADE_CLOSED" },
	{ "guildbank", "GUILDBANKFRAME_OPENED", "GUILDBANKFRAME_CLOSED" },
	{ "loot", "LOOT_OPENED", "LOOT_CLOSED" },
	-- The reward window: the money may come before or after it closes.
	{ "quest", "QUEST_COMPLETE", "QUEST_FINISHED" },
}

-- Events that this client may not know are checked first, so the core does not
-- print a warning for them.
local function onOptional(event, fn)
	if C_EventUtils and C_EventUtils.IsEventValid and not C_EventUtils.IsEventValid(event) then return end
	S:On(event, fn)
end

-- Vendor items

local function sellPrice(itemID)
	if not (C_Item and C_Item.GetItemInfo) then return nil end
	-- Assumption: the 11th return value of C_Item.GetItemInfo is the sell price.
	return clean((select(11, C_Item.GetItemInfo(itemID))))
end

local function vendorEntry(key, itemID)
	local items = dayRecord(key).vendorItems
	local entry = items[itemID]
	if not entry then
		entry = { count = 0, copper = 0 }
		items[itemID] = entry
	end
	return entry
end

local function recordSale(itemID, count)
	local key = dayKey(0)
	local price = sellPrice(itemID)
	local sale = { id = itemID, count = count, copper = 0, day = key, origCount = count, orig = 0 }
	local entry = vendorEntry(key, itemID)
	entry.count = entry.count + count
	if price then
		sale.copper = price * count
		sale.orig = sale.copper
		entry.copper = entry.copper + sale.copper
	else
		-- Not cached yet: the price is filled in when the client has it.
		sale.pending = true
		local list = pendingSales[itemID]
		if not list then
			list = {}
			pendingSales[itemID] = list
		end
		list[#list + 1] = sale
		if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
	end
	visitSales[#visitSales + 1] = sale
	itemChanged(itemID)
end

local function onItemData(_, itemID, success)
	local list = pendingSales[itemID]
	if not list or not rec then return end
	if not success then
		pendingSales[itemID] = nil
		return
	end
	local price = sellPrice(itemID)
	if not price then
		pendingSales[itemID] = nil
		return
	end
	for _, sale in ipairs(list) do
		if sale.pending then
			sale.pending = nil
			if sale.count > 0 then
				sale.copper = price * sale.count
				sale.orig = price * sale.origCount
				local entry = vendorEntry(sale.day, itemID)
				entry.copper = entry.copper + sale.copper
			end
		end
	end
	pendingSales[itemID] = nil
	itemChanged(itemID)
end

-- A buyback in the same visit takes back the newest matching sales.
local function reverseSale(itemID, count)
	for i = #visitSales, 1, -1 do
		if count <= 0 then return end
		local sale = visitSales[i]
		if sale.id == itemID and sale.count > 0 then
			local take = sale.count < count and sale.count or count
			local copper = sale.pending and 0 or floor(sale.copper * take / sale.count + 0.5)
			local entry = vendorEntry(sale.day, itemID)
			entry.count = entry.count - take
			entry.copper = entry.copper - copper
			sale.count = sale.count - take
			sale.copper = sale.copper - copper
			if entry.count <= 0 then dayRecord(sale.day).vendorItems[itemID] = nil end
			count = count - take
			itemChanged(itemID)
		end
	end
end

-- Purchases. A hook only remembers what is being bought or posted; the money
-- change that follows (while the matching window is open and the booking has
-- the matching source) says what it cost.

local SPEND_WINDOW = 10

local function addSpend(entry)
	entry.time = GetTime()
	pendingSpend[#pendingSpend + 1] = entry
end

-- entry.kind is "buy" or "deposit"; entry.source is "vendor" or "auction", the
-- booking source the money change must have.
function takeSpend(source, now)
	local found
	local i = 1
	while i <= #pendingSpend do
		local entry = pendingSpend[i]
		if now - entry.time > SPEND_WINDOW then
			table.remove(pendingSpend, i)
		elseif not found and entry.source == source then
			found = entry
			table.remove(pendingSpend, i)
		else
			i = i + 1
		end
	end
	return found
end

local function addPurchase(itemID, count, copper, source)
	local items = daySub(dayKey(0), "purchases")
	local e = items[itemID]
	if not e then
		e = { count = 0, copper = 0, source = source }
		items[itemID] = e
	elseif e.source ~= source then
		e.source = "mixed"
	end
	e.count = e.count + count
	e.copper = e.copper + copper
end

local BID_DAYS, MAX_BIDS = 3, 30

local function nameOf(itemID)
	if not (C_Item and C_Item.GetItemInfo) then return nil end
	local name = clean((C_Item.GetItemInfo(itemID)))
	if type(name) == "string" and name ~= "" then return name end
	return nil
end

-- A bid that may still be refunded when someone outbids it. The refund mail
-- names the item and returns exactly the bid, which is how it is matched.
local function addBid(entry, copper)
	if type(rec.bids) ~= "table" then rec.bids = {} end
	local bids, now = rec.bids, time()
	for i = #bids, 1, -1 do
		if now - bids[i].time > BID_DAYS * 86400 then table.remove(bids, i) end
	end
	bids[#bids + 1] = { id = entry.id, name = nameOf(entry.id), count = entry.count, copper = copper, day = dayKey(0), time = now }
	while #bids > MAX_BIDS do table.remove(bids, 1) end
end

function settleSpend(entry, copper)
	if entry.kind == "buy" then
		addPurchase(entry.id, entry.count, copper, entry.source)
		if entry.bid then addBid(entry, copper) end
		itemChanged(entry.id)
	elseif entry.id then
		local items = daySub(dayKey(0), "deposits")
		local e = items[entry.id]
		if not e then
			e = { count = 0, copper = 0 }
			items[entry.id] = e
		end
		e.count, e.copper = e.count + entry.count, e.copper + copper
		itemChanged(entry.id)
	end
end

-- Auction mail. The invoice is read when the mailbox shows the mail. Assumed
-- return order of GetInboxInvoiceInfo: type ("seller" for a sale), item name,
-- buyer name, bid, buyout, deposit, cut, delay, then two more values, then the
-- count. The buyer is never kept. If the values do not fit, or the money of
-- the mail is not bid (or buyout) minus cut plus deposit, the mail is booked
-- as plain auction money without item details.

local subjectPatterns

local function toPattern(fmt)
	if type(fmt) ~= "string" then return nil end
	local p = fmt:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"):gsub("%%%%s", "(.+)")
	return "^" .. p .. "$"
end

local function buildPatterns()
	subjectPatterns = {}
	local function add(kind, fmt)
		local p = toPattern(fmt)
		if p then subjectPatterns[#subjectPatterns + 1] = { kind, p } end
	end
	add("sale", AUCTION_SOLD_MAIL_SUBJECT)
	add("refund", AUCTION_OUTBID_MAIL_SUBJECT)
	add("auction", AUCTION_EXPIRED_MAIL_SUBJECT)
	add("auction", AUCTION_REMOVED_MAIL_SUBJECT)
	add("auction", AUCTION_CANCELLED_MAIL_SUBJECT)
	add("auction", AUCTION_WON_MAIL_SUBJECT)
end

-- Kind of an auction mail by its subject, and the item name it carries.
local function subjectKind(subject)
	if type(subject) ~= "string" then return nil end
	if not subjectPatterns then buildPatterns() end
	for _, def in ipairs(subjectPatterns) do
		local name = subject:match(def[2])
		if name then return def[1], name end
	end
	return nil
end

local function rememberName(itemID)
	local name = nameOf(itemID)
	if not name or seenNames[name] then return end
	if seenCount >= 200 then
		seenNames, seenCount = {}, 0
	end
	seenNames[name] = itemID
	seenCount = seenCount + 1
end

-- Assumptions: C_Item.GetItemInfoInstant(name) returns the item ID first and
-- C_Item.GetItemInfo(name) the link second; both answer for a name only when
-- the client knows the item.
local function resolveItem(name)
	if seenNames[name] then return seenNames[name] end
	if C_Item and C_Item.GetItemInfoInstant then
		local id = clean((C_Item.GetItemInfoInstant(name)))
		if type(id) == "number" and id > 0 then return id end
	end
	if C_Item and C_Item.GetItemInfo then
		local link = clean((select(2, C_Item.GetItemInfo(name))))
		local id = type(link) == "string" and tonumber(link:match("item:(%d+)"))
		if id and id > 0 then return id end
	end
	-- The items of the character's mail, through the read-only Items interface.
	local items = S.Items
	if items and items.GetMail and items.GetName then
		for _, mail in ipairs(items.GetMail(charKey)) do
			local list = mail.items
			for i = 1, type(list) == "table" and #list or 0, 2 do
				if items.GetName(list[i]) == name then return list[i] end
			end
		end
	end
	return nil
end

local function isNumber(v, min)
	return type(v) == "number" and v >= min
end

-- Reads one inbox mail. Returns nil for mail that is not auction money.
local function readMail(index)
	if not GetInboxHeaderInfo then return nil end
	local _, _, _, subject, money = GetInboxHeaderInfo(index)
	money, subject = clean(money), clean(subject)
	if not isNumber(money, 1) then return nil end
	local info
	if GetInboxInvoiceInfo then
		local invType, name, _, bid, buyout, deposit, cut, _, _, _, count = GetInboxInvoiceInfo(index)
		invType, name, bid, buyout, deposit, cut, count = clean(invType), clean(name), clean(bid), clean(buyout), clean(deposit), clean(cut), clean(count)
		if invType == "seller" then
			info = { kind = "sale", money = money }
			if type(name) == "string" and name ~= "" and isNumber(bid, 0) and isNumber(buyout, 0)
				and isNumber(deposit, 0) and isNumber(cut, 0) then
				local gross = bid > 0 and bid or buyout
				if gross > 0 and gross - cut + deposit == money then
					info.invoice = {
						name = name, gross = gross, cut = cut, deposit = deposit,
						count = isNumber(count, 1) and floor(count) or 1,
					}
				end
			end
		elseif invType ~= nil then
			info = { kind = "auction", money = money }
		end
	end
	if not info then
		local kind, name = subjectKind(subject)
		if not kind then return nil end
		info = { kind = kind, money = money, name = name }
	end
	return info
end

function scanInbox()
	mailInfo = {}
	if not GetInboxNumItems then return end
	local shown = clean((GetInboxNumItems()))
	for i = 1, isNumber(shown, 1) and shown or 0 do
		mailInfo[i] = readMail(i)
	end
end

local function cancelBid(info, amount)
	local bids = rec.bids
	if type(bids) ~= "table" then return end
	local id = info.name and resolveItem(info.name)
	for i = #bids, 1, -1 do
		local b = bids[i]
		if b.copper == amount and ((id and b.id == id) or (info.name and b.name == info.name)) then
			table.remove(bids, i)
			local e = rec.days[b.day] and rec.days[b.day].purchases and rec.days[b.day].purchases[b.id]
			if e then
				e.count, e.copper = e.count - b.count, e.copper - b.copper
				if e.count <= 0 and e.copper <= 0 then rec.days[b.day].purchases[b.id] = nil end
			end
			itemChanged(b.id)
			return
		end
	end
end

local function recordAuctionSale(inv)
	local id = resolveItem(inv.name)
	local items = daySub(dayKey(0), "auctionItems")
	local k = id or inv.name
	local e = items[k]
	if not e then
		e = { count = 0, gross = 0, cut = 0, deposit = 0, net = 0 }
		items[k] = e
	end
	e.count, e.gross, e.cut = e.count + inv.count, e.gross + inv.gross, e.cut + inv.cut
	e.deposit, e.net = e.deposit + inv.deposit, e.net + inv.gross - inv.cut + inv.deposit
	itemChanged(k)
end

-- Books the auction mail money that matches taken mails. Returns what is left.
function takeAuctionMail(rest, now)
	local i = 1
	while i <= #incomingAuction do
		local entry = incomingAuction[i]
		if now - entry.time > TRANSFER_WINDOW then
			table.remove(incomingAuction, i)
		elseif entry.amount <= rest then
			rest = rest - entry.amount
			table.remove(incomingAuction, i)
			book("auction", entry.amount)
			local info = entry.info
			if info.kind == "sale" and info.invoice then
				recordAuctionSale(info.invoice)
			elseif info.kind == "refund" then
				cancelBid(info, entry.amount)
			end
		else
			i = i + 1
		end
	end
	return rest
end

-- Vendor check. At the end of a merchant visit the item sales (at vendor price,
-- before any buyback) are compared with the vendor income booked meanwhile. A
-- difference is kept silently, the last 20 per character, for /sempre gold
-- pruefen. A visit with a sale that still waits for its price is not checked.

local MAX_CHECKS, MAX_CHECK_ITEMS = 20, 10

function checkVisit()
	local v = visit
	visit = nil
	if not (v and rec) then return end
	local sum, byItem, items = 0, {}, {}
	for _, sale in ipairs(visitSales) do
		if sale.pending then return end
		sum = sum + sale.orig
		local line = byItem[sale.id]
		if not line then
			line = { id = sale.id, count = 0, copper = 0 }
			byItem[sale.id] = line
			items[#items + 1] = line
		end
		line.count, line.copper = line.count + sale.origCount, line.copper + sale.orig
	end
	if sum == v.income then return end
	if type(rec.checks) ~= "table" then rec.checks = {} end
	local list = rec.checks
	while #items > MAX_CHECK_ITEMS do items[#items] = nil end
	list[#list + 1] = { time = time(), diff = v.income - sum, items = items }
	while #list > MAX_CHECKS do table.remove(list, 1) end
end

-- Hooks. All after the original call, all installed from ADDON_LOADED, all
-- feature-detected: the first argument is the function that must exist.

local missing = {}

local function hook(exists, ...)
	if type(exists) ~= "function" or type(hooksecurefunc) ~= "function" then return false end
	hooksecurefunc(...)
	return true
end

-- Assumption: the sale is confirmed by the server later, so right after the
-- call the slot still holds the item.
local function onUseItem(bag, slot)
	if not (started and open.merchant) then return end
	local info = C_Container and C_Container.GetContainerItemInfo and C_Container.GetContainerItemInfo(bag, slot)
	if type(info) ~= "table" then return end
	local id, count, noValue = clean(info.itemID), clean(info.stackCount), clean(info.hasNoValue)
	if type(id) ~= "number" or id <= 0 or noValue then return end
	recordSale(id, type(count) == "number" and count > 0 and count or 1)
end

-- Assumptions: GetBuybackItemLink still answers for the index right after the
-- call, and GetBuybackItemInfo returns the quantity as 4th value.
local function onBuyback(index)
	if not (started and open.merchant) then return end
	local link = GetBuybackItemLink and clean(GetBuybackItemLink(index))
	local id = type(link) == "string" and tonumber(link:match("item:(%d+)"))
	if not id then return end
	local count = GetBuybackItemInfo and clean((select(4, GetBuybackItemInfo(index))))
	reverseSale(id, type(count) == "number" and count > 0 and count or 1)
end

-- Assumptions: BuyMerchantItem(index, quantity) buys quantity items (one stack
-- if nil), GetMerchantItemLink(index) answers for the index right after the
-- call and GetMerchantItemInfo returns the quantity per purchase as 4th value.
local function onBuyMerchant(index, quantity)
	if not (started and open.merchant and GetMerchantItemLink) then return end
	local link = clean(GetMerchantItemLink(index))
	local id = type(link) == "string" and tonumber(link:match("item:(%d+)"))
	if not id then return end
	quantity = clean(quantity)
	if type(quantity) ~= "number" or quantity < 1 then
		quantity = GetMerchantItemInfo and clean((select(4, GetMerchantItemInfo(index))))
	end
	addSpend({ kind = "buy", source = "vendor", id = id, count = type(quantity) == "number" and quantity >= 1 and quantity or 1 })
end

-- Assumptions: C_AuctionHouse.PostItem(itemLocation, duration, quantity, ...)
-- and PostCommodity(itemLocation, duration, quantity, ...) take the quantity
-- as 3rd argument, and C_Item.GetItemID(itemLocation) gives the item.
local function onPost(location, _, quantity)
	if not (started and open.auction) then return end
	local id = C_Item and C_Item.GetItemID and clean(C_Item.GetItemID(location))
	if type(id) ~= "number" or id <= 0 then id = nil else rememberName(id) end
	quantity = clean(quantity)
	addSpend({ kind = "deposit", source = "auction", id = id, count = type(quantity) == "number" and quantity >= 1 and quantity or 1 })
end

-- ConfirmCommoditiesPurchase(itemID, quantity): the price is the money change.
local function onConfirmCommodity(itemID, quantity)
	if not (started and open.auction) then return end
	itemID, quantity = clean(itemID), clean(quantity)
	if type(itemID) ~= "number" or itemID <= 0 then return end
	rememberName(itemID)
	addSpend({ kind = "buy", source = "auction", id = itemID, count = type(quantity) == "number" and quantity >= 1 and quantity or 1 })
end

-- Assumptions: PlaceBid(auctionID, bidAmount) is used for bids and buyouts;
-- C_AuctionHouse.GetAuctionInfoByID(auctionID) answers right after the call
-- with a table holding itemKey.itemID, quantity and buyoutAmount. A bid at or
-- above the buyout is a buyout, which no outbid refund can follow.
local function onPlaceBid(auctionID, amount)
	if not (started and open.auction and C_AuctionHouse and C_AuctionHouse.GetAuctionInfoByID) then return end
	local info = C_AuctionHouse.GetAuctionInfoByID(auctionID)
	if type(info) ~= "table" then return end
	local key, count, buyout = clean(info.itemKey), clean(info.quantity), clean(info.buyoutAmount)
	local id = type(key) == "table" and clean(key.itemID)
	if type(id) ~= "number" or id <= 0 then return end
	amount = clean(amount)
	rememberName(id)
	addSpend({
		kind = "buy", source = "auction", id = id, count = type(count) == "number" and count >= 1 and count or 1,
		bid = not (type(buyout) == "number" and buyout > 0 and type(amount) == "number" and amount >= buyout),
	})
end

local function onRepair(guildBankRepair)
	-- Guild bank repairs cost the player nothing.
	if started and open.merchant and not guildBankRepair then lastRepair = GetTime() end
end

local function onFlight()
	if started then lastFlight = GetTime() end
end

local function onSendMail(recipient)
	if started and isOwn(recipient) then lastSendOwn = GetTime() end
end

-- Assumption: GetInboxHeaderInfo returns the sender as 3rd and the money as
-- 5th value, and still does right after the take call.
local function onTakeMailMoney(index)
	if not (started and GetInboxHeaderInfo) then return end
	local _, _, sender, _, money = GetInboxHeaderInfo(index)
	money = clean(money)
	if type(money) == "number" and money > 0 and isOwn(sender) then
		incoming[#incoming + 1] = { amount = money, time = GetTime() }
		return
	end
	local info = mailInfo[index] or readMail(index)
	if info then incomingAuction[#incomingAuction + 1] = { amount = info.money, time = GetTime(), info = info } end
end

local function installHooks()
	local repair = hook(RepairAllItems, "RepairAllItems", onRepair)
	repair = hook(C_Merchant and C_Merchant.RepairAllItems, C_Merchant, "RepairAllItems", onRepair) or repair
	if not repair then missing[#missing + 1] = "RepairAllItems" end

	local use = hook(C_Container and C_Container.UseContainerItem, C_Container, "UseContainerItem", onUseItem)
	if not use then use = hook(UseContainerItem, "UseContainerItem", onUseItem) end
	if not use then missing[#missing + 1] = "UseContainerItem" end
	if not hook(BuybackItem, "BuybackItem", onBuyback) then missing[#missing + 1] = "BuybackItem" end
	local buy = hook(BuyMerchantItem, "BuyMerchantItem", onBuyMerchant)
	buy = hook(C_Merchant and C_Merchant.BuyMerchantItem, C_Merchant, "BuyMerchantItem", onBuyMerchant) or buy
	if not buy then missing[#missing + 1] = "BuyMerchantItem" end

	local ah = C_AuctionHouse
	local post = hook(ah and ah.PostItem, ah, "PostItem", onPost)
	post = hook(ah and ah.PostCommodity, ah, "PostCommodity", onPost) or post
	if not post then missing[#missing + 1] = "C_AuctionHouse.PostItem" end
	if not hook(ah and ah.ConfirmCommoditiesPurchase, ah, "ConfirmCommoditiesPurchase", onConfirmCommodity) then
		missing[#missing + 1] = "C_AuctionHouse.ConfirmCommoditiesPurchase"
	end
	if not hook(ah and ah.PlaceBid, ah, "PlaceBid", onPlaceBid) then missing[#missing + 1] = "C_AuctionHouse.PlaceBid" end

	if not hook(TakeTaxiNode, "TakeTaxiNode", onFlight) then missing[#missing + 1] = "TakeTaxiNode" end

	local send = hook(SendMail, "SendMail", onSendMail)
	send = hook(C_Mail and C_Mail.SendMail, C_Mail, "SendMail", onSendMail) or send
	if not send then missing[#missing + 1] = "SendMail" end
	local take = hook(TakeInboxMoney, "TakeInboxMoney", onTakeMailMoney)
	take = hook(AutoLootMailItem, "AutoLootMailItem", onTakeMailMoney) or take
	if not take then missing[#missing + 1] = "TakeInboxMoney" end
end

local function registerEvents()
	buildInteraction()
	S:On("PLAYER_MONEY", onMoney)
	onOptional("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", onInteraction)
	onOptional("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", onInteraction)
	for _, def in ipairs(CLASSIC) do
		local flag = def[1]
		onOptional(def[2], function() setOpen(flag, true) end)
		onOptional(def[3], function() setOpen(flag, false) end)
	end
	onOptional("QUEST_TURNED_IN", function() lastQuest = GetTime() end)
	onOptional("ITEM_DATA_LOAD_RESULT", onItemData)
	onOptional("MAIL_INBOX_UPDATE", function() if open.mail then scanInbox() end end)
	-- Login and reload read the baseline again, never a booking.
	S:On("PLAYER_ENTERING_WORLD", function(_, isLogin, isReload)
		if started and (isLogin or isReload) then
			local money = clean(GetMoney())
			if type(money) == "number" then lastMoney = money end
		end
	end)
	S:On("PLAYER_LOGOUT", function()
		if session then session.last = time() end
	end)
end

-- Login work: baseline, session, pruning. Runs from ADDON_LOADED when the core
-- already knows the character, otherwise from PLAYER_LOGIN.

local function start()
	if started or not S.charKey then return end
	charKey = S.charKey
	rec = db.chars[charKey]
	if type(rec) ~= "table" then
		rec = {}
		db.chars[charKey] = rec
	end
	if type(rec.days) ~= "table" then rec.days = {} end
	prune()

	local money = clean(GetMoney())
	lastMoney = type(money) == "number" and money or nil
	local now = time()
	local old = rec.session
	if type(old) == "table" and type(old.start) == "number" and type(old.last) == "number"
		and now >= old.last and now - old.last < SESSION_GAP then
		session = old
	else
		session = { start = now, startMoney = lastMoney or 0, income = 0, expense = 0 }
		rec.session = session
	end
	session.last = now
	started = true
	if #missing > 0 then S:Print(L.MISSING, table.concat(missing, ", ")) end
end

local function onLoaded(_, name)
	if name ~= ADDON_NAME then return end
	S:Off("ADDON_LOADED", onLoaded)
	db = initDB()
	installHooks()
	registerEvents()
	if S.charKey then
		start()
	else
		S:On("PLAYER_LOGIN", start)
	end
end
S:On("ADDON_LOADED", onLoaded)

-- Interface

function Ledger.GetDay(key, dateKey)
	local r = db and db.chars[key]
	return r and r.days and r.days[dateKey] or nil
end

function Ledger.GetRange(key, days)
	local res = { income = {}, expense = {}, incomeTotal = 0, expenseTotal = 0, net = 0, days = days }
	local r = db and db.chars[key]
	if not (r and r.days) then return res end
	for offset = 0, days - 1 do
		local day = r.days[dayKey(offset)]
		if day then
			for source, v in pairs(day.income) do
				res.income[source] = (res.income[source] or 0) + v
				if source ~= "transfer" then res.incomeTotal = res.incomeTotal + v end
			end
			for source, v in pairs(day.expense) do
				res.expense[source] = (res.expense[source] or 0) + v
				if source ~= "transfer" then res.expenseTotal = res.expenseTotal + v end
			end
		end
	end
	res.net = res.incomeTotal - res.expenseTotal
	return res
end

local function newSums()
	return { vendor = 0, vendorCount = 0, auction = 0, auctionCount = 0, purchases = 0, purchaseCount = 0, deposits = 0 }
end

-- Adds the item bookings of one day record into sums[itemKey] (or into one
-- sums table when only is given).
local function addDay(day, sums, only)
	local function at(k)
		if only ~= nil and k ~= only then return nil end
		if only ~= nil then return sums end
		local t = sums[k]
		if not t then
			t = newSums()
			sums[k] = t
		end
		return t
	end
	for k, v in pairs(day.vendorItems or {}) do
		local t = at(k)
		if t then
			t.vendor, t.vendorCount = t.vendor + v.copper, t.vendorCount + v.count
		end
	end
	for k, v in pairs(day.auctionItems or {}) do
		local t = at(k)
		if t then
			t.auction, t.auctionCount = t.auction + v.gross - v.cut, t.auctionCount + v.count
		end
	end
	for k, v in pairs(day.purchases or {}) do
		local t = at(k)
		if t then
			t.purchases, t.purchaseCount = t.purchases + v.copper, t.purchaseCount + v.count
		end
	end
	for k, v in pairs(day.deposits or {}) do
		local t = at(k)
		if t then t.deposits = t.deposits + v.copper end
	end
end

-- Item sums of one character over the last days; for one item or for all.
local function charSums(key, days, sums, only)
	local r = db and db.chars[key]
	if not (r and r.days) then return end
	for offset = 0, days - 1 do
		local day = r.days[dayKey(offset)]
		if day then addDay(day, sums, only) end
	end
end

function Ledger.GetItem(key, itemID, days)
	local sums = newSums()
	charSums(key, days, sums, itemID)
	return sums
end

function Ledger.GetItemAll(itemID, days)
	local sums = newSums()
	if db then
		for key in pairs(db.chars) do charSums(key, days, sums, itemID) end
	end
	return sums
end

function Ledger.GetSession()
	if not session then return nil end
	local income, expense = session.income or 0, session.expense or 0
	local net = income - expense
	local seconds = max(time() - session.start, 0)
	-- At least a minute, so the first copper does not show a huge hourly rate.
	local perHour = floor(net * 3600 / max(seconds, 60))
	return {
		start = session.start, startMoney = session.startMoney, income = income, expense = expense,
		net = net, seconds = seconds, perHour = perHour,
	}
end

-- /sempre gold

local function moneyText(copper)
	copper = floor(abs(copper or 0))
	return format("%dg %ds %dc", floor(copper / 10000), floor(copper / 100) % 100, copper % 100)
end

local function accent(text)
	return "|cffc8794a" .. text .. "|r"
end

local function signedText(copper)
	return (copper < 0 and "-" or "+") .. moneyText(copper)
end

-- One line per source, income and expense side by side, largest first.
local function sourceLines(res)
	local bySource, list = {}, {}
	local function add(source, v, slot)
		local line = bySource[source]
		if not line then
			line = { source = source }
			bySource[source] = line
			list[#list + 1] = line
		end
		line[slot] = v
	end
	for source, v in pairs(res.income) do add(source, v, "plus") end
	for source, v in pairs(res.expense) do add(source, v, "minus") end
	for _, line in ipairs(list) do line.size = max(line.plus or 0, line.minus or 0) end
	sort(list, function(a, b)
		if a.size ~= b.size then return a.size > b.size end
		return a.source < b.source
	end)
	return list
end

local function printPeriod(label, res)
	print(format("  %s: %s (%s %s, %s %s)", label, accent(signedText(res.net)),
		L.INCOME, moneyText(res.incomeTotal), L.EXPENSE, moneyText(res.expenseTotal)))
	local list = sourceLines(res)
	if #list == 0 then
		print("    " .. L.NO_BOOKINGS)
		return
	end
	for _, line in ipairs(list) do
		local parts = {}
		if line.plus then parts[#parts + 1] = "+" .. moneyText(line.plus) end
		if line.minus then parts[#parts + 1] = "-" .. moneyText(line.minus) end
		print(format("    %s: %s", L[line.source], concat(parts, ", ")))
	end
end

local function itemName(itemID)
	local name = C_Item and C_Item.GetItemInfo and clean((C_Item.GetItemInfo(itemID)))
	if type(name) == "string" then return name end
	if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
	return "item:" .. itemID
end

local function printAll()
	S:Print(L.ALL_HEADER)
	local keys, total = {}, 0
	for key in pairs(db.chars) do keys[#keys + 1] = key end
	sort(keys)
	for _, key in ipairs(keys) do
		local net = Ledger.GetRange(key, 7).net
		total = total + net
		print(format("  %s: %s", key, accent(signedText(net))))
	end
	print(format("  %s: %s", L.TOTAL, accent(signedText(total))))
end

-- Top 10 items of the last 30 days by net result: vendor income plus auction
-- net minus purchases. With ahOnly only items with auction sales, counted
-- without the vendor income.
local function printItems(ahOnly)
	local sums = {}
	charSums(charKey, 30, sums)
	local list = {}
	for k, t in pairs(sums) do
		if not ahOnly or t.auctionCount > 0 then
			t.key = k
			t.result = (ahOnly and 0 or t.vendor) + t.auction - t.purchases
			list[#list + 1] = t
		end
	end
	sort(list, function(a, b)
		if a.result ~= b.result then return a.result > b.result end
		return tostring(a.key) < tostring(b.key)
	end)
	if #list == 0 then
		S:Print(ahOnly and L.NO_AH_ITEMS or L.NO_ITEMS)
		return
	end
	S:Print(ahOnly and L.AH_ITEMS_HEADER or L.ITEMS_HEADER)
	for i = 1, math.min(10, #list) do
		local t = list[i]
		local name = type(t.key) == "number" and itemName(t.key) or t.key
		local parts = {}
		if not ahOnly and t.vendor ~= 0 then parts[#parts + 1] = format("%s %s", L.PART_VENDOR, signedText(t.vendor)) end
		if t.auctionCount > 0 or t.auction ~= 0 then parts[#parts + 1] = format("%s %s", L.PART_AUCTION, signedText(t.auction)) end
		if t.purchases ~= 0 then parts[#parts + 1] = format("%s %s", L.PART_BOUGHT, signedText(-t.purchases)) end
		local count = ahOnly and t.auctionCount or t.vendorCount + t.auctionCount
		print(format("  %s x%d: %s (%s)", name, count, accent(signedText(t.result)), concat(parts, ", ")))
	end
end

local function printChecks()
	local list = rec.checks
	if type(list) ~= "table" or #list == 0 then
		S:Print(L.CHECK_NONE)
		return
	end
	S:Print(L.CHECK_HEADER, #list)
	for i = #list, 1, -1 do
		local c = list[i]
		local parts = {}
		for _, it in ipairs(c.items) do
			parts[#parts + 1] = format("%s x%d (%s)", itemName(it.id), it.count, moneyText(it.copper))
		end
		print(format("  %s %s: %s", date("%Y-%m-%d %H:%M:%S", c.time), accent(signedText(c.diff)),
			#parts > 0 and concat(parts, ", ") or L.NO_SALES))
	end
end

local function command(arg)
	if not started then
		S:Print(L.NOT_READY)
		return
	end
	arg = (arg or ""):lower()
	if arg == "alle" or arg == "all" then
		printAll()
	elseif arg == "pruefen" or arg == "check" then
		printChecks()
	elseif arg:match("^items") then
		printItems(arg:match("^items%s+ah$") ~= nil)
	else
		S:Print(L.HEADER, charKey)
		local s = Ledger.GetSession()
		print(format("  %s: %s (%s %s), %s %s, %s %s", L.SESSION, accent(signedText(s.net)),
			signedText(s.perHour), L.PER_HOUR, L.INCOME, moneyText(s.income), L.EXPENSE, moneyText(s.expense)))
		printPeriod(L.TODAY, Ledger.GetRange(charKey, 1))
		printPeriod(L.WEEK, Ledger.GetRange(charKey, 7))
	end
end

S.commands.gold = command
S.commands.ledger = command
