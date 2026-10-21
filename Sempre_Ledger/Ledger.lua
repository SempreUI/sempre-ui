-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Sempre_Ledger: gold journal. Every change of the character's money is booked
-- once, with a source decided from the open windows at that moment. Money that
-- changed while the module did not run is never booked (the baseline is read at
-- login). Transfers between own characters are booked as "transfer" and never
-- count as income or expense in any total. Also records what was sold to
-- vendors, per item and day.
--
-- Read-only interface on SempreUI.Ledger:
--   GetDay(charKey, date)    -> day record { income = {source = copper},
--                               expense = {...}, vendorItems = {itemID =
--                               {count, copper}} } or nil. Date is YYYY-MM-DD.
--                               Do not modify it.
--   GetRange(charKey, days)  -> { income, expense, incomeTotal, expenseTotal,
--                               net, days } for today and the days-1 before.
--                               Totals and net leave out "transfer".
--   GetSession()            -> { start, startMoney, income, expense, net,
--                               seconds, perHour } or nil before login.
-- Message LEDGER_CHANGED(charKey, source) after each booking.

local ADDON_NAME = ...

local S = SempreUI
local pairs, ipairs, type, format, tonumber, floor, abs, select = pairs, ipairs, type, string.format, tonumber, math.floor, math.abs, select
local time, date, sort, max = time, date, table.sort, math.max
local issecretvalue = issecretvalue
local C_Container, C_Item, C_EventUtils, C_Merchant, C_Mail = C_Container, C_Item, C_EventUtils, C_Merchant, C_Mail
local GetMoney, GetTime, GetRealmName, GetLocale = GetMoney, GetTime, GetRealmName, GetLocale
local GetInboxHeaderInfo, hooksecurefunc = GetInboxHeaderInfo, hooksecurefunc

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
	L.ITEMS_HEADER = "Top 10 Händlererlöse der letzten 30 Tage:"
	L.NO_ITEMS = "Keine Händlerverkäufe erfasst."
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
	L.ITEMS_HEADER = "Top 10 vendor income of the last 30 days:"
	L.NO_ITEMS = "No vendor sales recorded."
end

-- Saved data
-- SempreLedgerDB = { version, chars = { [charKey] = { days = { ["YYYY-MM-DD"] =
-- { income = {}, expense = {}, vendorItems = {} } }, session = {} } } }

local DB_VERSION = 1
local KEEP_DAYS = 90
local SESSION_GAP = 15 * 60
-- migrations[n] upgrades a database from version n to n + 1.
local migrations = {}

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
local lastQuest, lastLootClose, lastFlight, lastRepair, lastSendOwn
local incoming = {} -- money in mails from own characters that is being taken: { amount, time }
local visitSales = {} -- sales of the current merchant visit, newest last
local pendingSales = {} -- itemID -> sales waiting for the item's sell price

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

local function book(source, diff)
	local day = dayRecord(dayKey(0))
	local into = diff > 0 and day.income or day.expense
	local amount = abs(diff)
	into[source] = (into[source] or 0) + amount
	if session and source ~= "transfer" then
		local field = diff > 0 and "income" or "expense"
		session[field] = (session[field] or 0) + amount
	end
	if session then session.last = time() end
	S:Send("LEDGER_CHANGED", charKey, source)
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
	if lastQuest and now - lastQuest <= QUEST_WINDOW then return "quest" end
	if open.loot or (lastLootClose and now - lastLootClose <= LOOT_WINDOW) then return "loot" end
	if open.trade then return "trade" end
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
			if rest == 0 then return end
			diff = rest
		end
	end
	book(sourceFor(diff, now), diff)
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
	if flag == "merchant" and value then visitSales = {} end
	if flag == "loot" and not value then lastLootClose = GetTime() end
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
	local sale = { id = itemID, count = count, copper = 0, day = key }
	local entry = vendorEntry(key, itemID)
	entry.count = entry.count + count
	if price then
		sale.copper = price * count
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
				local entry = vendorEntry(sale.day, itemID)
				entry.copper = entry.copper + sale.copper
			end
		end
	end
	pendingSales[itemID] = nil
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
		end
	end
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
	end
end

local function installHooks()
	local repair = hook(RepairAllItems, "RepairAllItems", onRepair)
	repair = hook(C_Merchant and C_Merchant.RepairAllItems, C_Merchant, "RepairAllItems", onRepair) or repair
	if not repair then missing[#missing + 1] = "RepairAllItems" end

	local use = hook(C_Container and C_Container.UseContainerItem, C_Container, "UseContainerItem", onUseItem)
	if not use then use = hook(UseContainerItem, "UseContainerItem", onUseItem) end
	if not use then missing[#missing + 1] = "UseContainerItem" end
	if not hook(BuybackItem, "BuybackItem", onBuyback) then missing[#missing + 1] = "BuybackItem" end

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

local function sourceLines(res)
	local list = {}
	for source, v in pairs(res.income) do list[#list + 1] = { source, v, "+" } end
	for source, v in pairs(res.expense) do list[#list + 1] = { source, v, "-" } end
	sort(list, function(a, b)
		if a[2] ~= b[2] then return a[2] > b[2] end
		if a[1] ~= b[1] then return a[1] < b[1] end
		return a[3] < b[3]
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
		print(format("    %s: %s%s", L[line[1]], line[3], moneyText(line[2])))
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

local function printItems()
	local sums = {}
	for offset = 0, 29 do
		local day = Ledger.GetDay(charKey, dayKey(offset))
		if day then
			for id, v in pairs(day.vendorItems) do
				local sum = sums[id]
				if not sum then
					sum = { id = id, count = 0, copper = 0 }
					sums[id] = sum
				end
				sum.count = sum.count + v.count
				sum.copper = sum.copper + v.copper
			end
		end
	end
	local list = {}
	for _, sum in pairs(sums) do list[#list + 1] = sum end
	sort(list, function(a, b)
		if a.copper ~= b.copper then return a.copper > b.copper end
		return a.id < b.id
	end)
	if #list == 0 then
		S:Print(L.NO_ITEMS)
		return
	end
	S:Print(L.ITEMS_HEADER)
	for i = 1, math.min(10, #list) do
		local sum = list[i]
		print(format("  %s x%d: %s", itemName(sum.id), sum.count, accent(moneyText(sum.copper))))
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
	elseif arg == "items" then
		printItems()
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
