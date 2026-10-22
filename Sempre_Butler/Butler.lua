-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Sempre_Butler: small chores done for the player, each one switchable and each
-- one visible as a single chat line. At a merchant: repair, then sell grey
-- items one at a time. Also: accept resurrections, decline duels, hide the red
-- error text. A keep list protects items from being sold.
--
-- Selling goes through the container use function, one item per tick, so the
-- gold journal (Sempre_Ledger) books each sale itself; repairing goes through
-- the repair call it hooks. Repair runs first, then selling starts.
--
-- Messages: BUTLER_SOLD(count, copper) after a selling run that sold something,
-- BUTLER_REPAIRED(copper, source) after a repair, source "own" or "guild".
-- Data: SempreButlerDB = { version, keep = { [itemID] = true } }.

local ADDON_NAME = ...

local S = SempreUI
local ipairs, pairs, type, format, floor, tonumber = ipairs, pairs, type, string.format, math.floor, tonumber
local sort, concat = table.sort, table.concat
local issecretvalue = issecretvalue
local C_Container, C_Item, C_Timer, C_EventUtils = C_Container, C_Item, C_Timer, C_EventUtils
local CreateFrame, GetLocale, GetTime, GetMoney = CreateFrame, GetLocale, GetTime, GetMoney
local InCombatLockdown, IsShiftKeyDown, IsInInstance = InCombatLockdown, IsShiftKeyDown, IsInInstance

local Butler = {}
S.Butler = Butler

local INTERVAL = 0.2 -- seconds between two sales
local MAX_SALES = 60 -- per merchant visit
local LAST_BAG = 5 -- backpack, four bags, reagent bag; missing bags report 0 slots
local RES_DELAY = 1
local DUEL_LINE_GAP = 10
local KEEP_LIST_MAX = 12

local L = setmetatable({}, { __index = function(_, k) return k end })
Butler.L = L
local german = GetLocale() == "deDE"
if german then
	L.SOLD = "Butler: Schrott verkauft: %d Gegenstände für %s"
	L.REPAIRED_OWN = "Butler: Repariert für %s."
	L.REPAIRED_GUILD = "Butler: Repariert für %s aus der Gildenbank."
	L.REPAIR_MISSING = "Butler: Reparatur kostet %s, es fehlen %s."
	L.RES_ACCEPTED = "Butler: Wiederbelebung angenommen."
	L.DUEL_DECLINED = "Butler: Duell abgelehnt."
	L.UNAVAILABLE = "Dieser Client hat die nötigen Funktionen nicht."
	L.NO_API = "Butler: %s braucht Funktionen, die dieser Client nicht hat, abgeschaltet."
	L.F_SELL = "Schrott verkaufen"
	L.F_REPAIR = "Reparieren"
	L.F_RESURRECT = "Wiederbelebung annehmen"
	L.F_DUEL = "Duelle ablehnen"
	L.F_QUIET = "Fehlertext ausblenden"
	L.STATE_HEADER = "Butler:"
	L.ON = "an"
	L.OFF = "aus"
	L.KEEP_LIST = "Behalten (%d): %s"
	L.KEEP_EMPTY = "Behalten: nichts auf der Liste."
	L.KEEP_MORE = "und %d weitere"
	L.KEEP_ADDED = "Butler: %s wird behalten und nie verkauft."
	L.KEEP_HAVE = "Butler: %s ist schon auf der Liste."
	L.KEEP_REMOVED = "Butler: %s ist nicht mehr auf der Liste."
	L.KEEP_NOT = "Butler: %s steht nicht auf der Liste."
	L.KEEP_USAGE = "Butler: /sempre butler behalten <Gegenstand> oder weg <Gegenstand>, den Gegenstand als Link oder mit seiner ID."
	L.KEEP_BAD = "Butler: Das ist kein Gegenstand. Link oder ID angeben."
else
	L.SOLD = "Butler: Junk sold: %d items for %s"
	L.REPAIRED_OWN = "Butler: Repaired for %s."
	L.REPAIRED_GUILD = "Butler: Repaired for %s from the guild bank."
	L.REPAIR_MISSING = "Butler: Repair costs %s, you are missing %s."
	L.RES_ACCEPTED = "Butler: Resurrection accepted."
	L.DUEL_DECLINED = "Butler: Duel declined."
	L.UNAVAILABLE = "This client lacks the functions needed."
	L.NO_API = "Butler: %s needs functions this client does not have, switched off."
	L.F_SELL = "Sell junk"
	L.F_REPAIR = "Repair"
	L.F_RESURRECT = "Accept resurrection"
	L.F_DUEL = "Decline duels"
	L.F_QUIET = "Hide error text"
	L.STATE_HEADER = "Butler:"
	L.ON = "on"
	L.OFF = "off"
	L.KEEP_LIST = "Keep (%d): %s"
	L.KEEP_EMPTY = "Keep: nothing on the list."
	L.KEEP_MORE = "and %d more"
	L.KEEP_ADDED = "Butler: %s is kept and never sold."
	L.KEEP_HAVE = "Butler: %s is already on the list."
	L.KEEP_REMOVED = "Butler: %s is off the list."
	L.KEEP_NOT = "Butler: %s is not on the list."
	L.KEEP_USAGE = "Butler: /sempre butler keep <item> or remove <item>, the item as a link or by its ID."
	L.KEEP_BAD = "Butler: That is not an item. Give a link or an ID."
end

local db
local merchantOpen = false
local run -- the current selling run: { list, i, count, copper }
local acc = 0
local lastDuelLine
local resPending = false
local quietOn = false
local reported = {}

local function clean(v)
	if issecretvalue and issecretvalue(v) then return nil end
	return v
end

local function moneyText(copper)
	copper = floor(copper or 0)
	local g, s, c = floor(copper / 10000), floor(copper / 100) % 100, copper % 100
	if g > 0 then return format("%dg %ds %dc", g, s, c) end
	if s > 0 then return format("%ds %dc", s, c) end
	return format("%dc", c)
end

local function isFn(v) return type(v) == "function" end

-- Feature checks. Each feature needs its own set of functions; a missing one
-- switches only that feature off.

local function repairFn()
	if isFn(RepairAllItems) then return RepairAllItems end
	if C_Merchant and isFn(C_Merchant.RepairAllItems) then return C_Merchant.RepairAllItems end
end

local available = {
	sell = function()
		return C_Container and isFn(C_Container.GetContainerNumSlots) and isFn(C_Container.GetContainerItemInfo)
			and isFn(C_Container.UseContainerItem) and C_Item and isFn(C_Item.GetItemInfo) and true or false
	end,
	repair = function()
		return isFn(CanMerchantRepair) and isFn(GetRepairAllCost) and isFn(GetMoney) and repairFn() ~= nil
	end,
	resurrect = function()
		return isFn(AcceptResurrect) and C_Timer and isFn(C_Timer.After) and true or false
	end,
	duel = function() return isFn(CancelDuel) end,
	quiet = function()
		return UIErrorsFrame ~= nil and isFn(UIErrorsFrame.RegisterEvent) and isFn(UIErrorsFrame.UnregisterEvent)
	end,
}

local FEATURE_LABEL = { sell = "F_SELL", repair = "F_REPAIR", resurrect = "F_RESURRECT", duel = "F_DUEL", quiet = "F_QUIET" }

local function unavailableReason(feature)
	return function()
		if not available[feature]() then return L.UNAVAILABLE end
	end
end

-- One line per feature and session, only when the player wants the feature.
local function reportMissing(feature)
	if reported[feature] or available[feature]() then return end
	reported[feature] = true
	S:Print(L.NO_API, L[FEATURE_LABEL[feature]])
end

local function enabled(feature)
	return S:GetOption(ADDON_NAME, feature) == true and available[feature]()
end

-- Keep list

local function isKept(itemID)
	return db ~= nil and db.keep[itemID] == true
end

local function itemName(itemID)
	local name = C_Item and C_Item.GetItemInfo and clean((C_Item.GetItemInfo(itemID)))
	if type(name) == "string" and name ~= "" then return name end
	return "item:" .. itemID
end

-- Item link or plain ID to an item ID.
local function parseItem(text)
	if type(text) ~= "string" then return nil end
	local id = tonumber(text:match("item:(%d+)")) or tonumber(text:match("^%s*(%d+)%s*$"))
	if id and id > 0 then return id end
end

-- Selling

local function sellPrice(itemID)
	-- Assumption: the 11th return value of C_Item.GetItemInfo is the sell price
	-- (the gold journal reads it the same way); nil while not cached.
	local price = clean((select(11, C_Item.GetItemInfo(itemID))))
	if type(price) == "number" and price > 0 then return price end
end

-- The grey item in a slot as { id, count }, or nil for anything not to be sold.
-- Assumption: C_Container.GetContainerItemInfo returns a table with quality,
-- itemID, stackCount, isLocked and hasNoValue (nil for an empty slot).
local function greyIn(bag, slot)
	local info = C_Container.GetContainerItemInfo(bag, slot)
	if type(info) ~= "table" then return nil end
	local quality, id, count = clean(info.quality), clean(info.itemID), clean(info.stackCount)
	if quality ~= 0 or type(id) ~= "number" or id <= 0 then return nil end
	if clean(info.isLocked) or clean(info.hasNoValue) or isKept(id) then return nil end
	return id, type(count) == "number" and count > 0 and count or 1
end

local function collect()
	local list = {}
	for bag = 0, LAST_BAG do
		local slots = clean(C_Container.GetContainerNumSlots(bag))
		if type(slots) == "number" then
			for slot = 1, slots do
				local id, count = greyIn(bag, slot)
				-- Quality or price not cached yet: skip it this visit.
				local price = id and sellPrice(id)
				if price then
					list[#list + 1] = { bag = bag, slot = slot, id = id, price = price, count = count }
					if #list >= MAX_SALES then return list end
				end
			end
		end
	end
	return list
end

local ticker = CreateFrame("Frame")
ticker:Hide()

local function finish()
	ticker:Hide()
	local r = run
	run = nil
	acc = 0
	if r and r.count > 0 then
		S:Print(L.SOLD, r.count, moneyText(r.copper))
		S:Send("BUTLER_SOLD", r.count, r.copper)
	end
end

-- Sells the next valid entry; slots that changed meanwhile are skipped without
-- using up the interval.
local function sellNext()
	if not merchantOpen or InCombatLockdown() then return finish() end
	while run.i <= #run.list do
		local e = run.list[run.i]
		run.i = run.i + 1
		local id, count = greyIn(e.bag, e.slot)
		if id == e.id then
			C_Container.UseContainerItem(e.bag, e.slot)
			run.count = run.count + count
			run.copper = run.copper + e.price * count
			if run.i > #run.list then finish() end
			return
		end
	end
	finish()
end

ticker:SetScript("OnUpdate", function(_, elapsed)
	if not run then return ticker:Hide() end
	acc = acc + elapsed
	if acc >= INTERVAL then
		acc = 0
		sellNext()
	end
end)

local function startSelling()
	if IsShiftKeyDown and IsShiftKeyDown() then return end
	if InCombatLockdown() then return end
	local list = collect()
	if #list == 0 then return end
	run = { list = list, i = 1, count = 0, copper = 0 }
	acc = 0
	ticker:Show()
end

-- Repairing

-- Assumptions: CanGuildBankRepair() tells whether guild funds may pay, and
-- GetGuildBankWithdrawMoney() gives the player's remaining daily allowance
-- (-1 for unlimited). Both are optional; without them guild funds are not used.
local function guildCanPay(cost)
	if not isFn(CanGuildBankRepair) or not CanGuildBankRepair() then return false end
	if isFn(GetGuildBankWithdrawMoney) then
		local allowance = clean(GetGuildBankWithdrawMoney())
		if type(allowance) == "number" and allowance >= 0 and allowance < cost then return false end
	end
	return true
end

local function repair()
	if not CanMerchantRepair() then return end
	-- Assumption: GetRepairAllCost() returns the total cost as first value.
	local cost = clean((GetRepairAllCost()))
	if type(cost) ~= "number" or cost <= 0 then return end
	local fn = repairFn()
	if S:GetOption(ADDON_NAME, "guild_repair") == true and guildCanPay(cost) then
		fn(true)
		S:Print(L.REPAIRED_GUILD, moneyText(cost))
		S:Send("BUTLER_REPAIRED", cost, "guild")
		return
	end
	local money = clean(GetMoney())
	if type(money) ~= "number" then return end
	if money >= cost then
		fn()
		S:Print(L.REPAIRED_OWN, moneyText(cost))
		S:Send("BUTLER_REPAIRED", cost, "own")
	else
		S:Print(L.REPAIR_MISSING, moneyText(cost), moneyText(cost - money))
	end
end

-- Merchant events. Repair first, so the journal sees the repair before the
-- sales; selling starts afterwards.

local function onMerchantShow()
	if merchantOpen then return end
	merchantOpen = true
	if enabled("repair") then repair() end
	if enabled("sell") then startSelling() end
end

local function onMerchantClosed()
	merchantOpen = false
	if run then finish() end
end

-- Other chores

local function inBattleground()
	if not isFn(IsInInstance) then return false end
	local _, kind = IsInInstance()
	kind = clean(kind)
	return kind == "pvp" or kind == "arena"
end

local function onResurrect()
	-- The caster's name arrives as an argument and may be secret: not used.
	if resPending or not enabled("resurrect") or InCombatLockdown() or inBattleground() then return end
	resPending = true
	C_Timer.After(RES_DELAY, function()
		resPending = false
		if enabled("resurrect") and not InCombatLockdown() and not inBattleground() then
			AcceptResurrect()
			S:Print(L.RES_ACCEPTED)
		end
	end)
end

local function onDuel()
	if not enabled("duel") then return end
	CancelDuel()
	local now = GetTime()
	if not lastDuelLine or now - lastDuelLine >= DUEL_LINE_GAP then
		lastDuelLine = now
		S:Print(L.DUEL_DECLINED)
	end
end

-- Hiding the red error text: the game's error frame simply stops listening.
local function applyQuiet()
	local want = enabled("quiet")
	if want and not quietOn then
		UIErrorsFrame:UnregisterEvent("UI_ERROR_MESSAGE")
		quietOn = true
	elseif not want and quietOn then
		UIErrorsFrame:RegisterEvent("UI_ERROR_MESSAGE")
		quietOn = false
	end
end

-- Command

local OPTION_ORDER = { "sell", "repair", "guild_repair", "resurrect", "duel", "quiet" }
local optionList

local function optionLabel(key)
	for _, opt in ipairs(optionList) do
		if opt.key == key then return german and opt.label.de or opt.label.en end
	end
	return key
end

local function printState()
	S:Print(L.STATE_HEADER)
	for _, key in ipairs(OPTION_ORDER) do
		local on = S:GetOption(ADDON_NAME, key) == true
		local missing = FEATURE_LABEL[key] and not available[key]()
		print(format("  %s: %s%s", optionLabel(key), on and L.ON or L.OFF, missing and (" (" .. L.UNAVAILABLE .. ")") or ""))
	end
	local ids = {}
	for id in pairs(db.keep) do ids[#ids + 1] = id end
	if #ids == 0 then
		print(L.KEEP_EMPTY)
		return
	end
	sort(ids)
	local names = {}
	for i = 1, math.min(#ids, KEEP_LIST_MAX) do names[i] = itemName(ids[i]) end
	local text = concat(names, ", ")
	if #ids > KEEP_LIST_MAX then text = text .. ", " .. format(L.KEEP_MORE, #ids - KEEP_LIST_MAX) end
	print(format(L.KEEP_LIST, #ids, text))
end

local function command(rest)
	local sub, arg = (rest or ""):match("^(%S*)%s*(.-)%s*$")
	sub = sub:lower()
	if sub == "" then return printState() end
	local adding = sub == "behalten" or sub == "keep"
	local removing = sub == "weg" or sub == "remove"
	if not (adding or removing) then return S:Print(L.KEEP_USAGE) end
	local id = parseItem(arg)
	if not id then return S:Print(arg == "" and L.KEEP_USAGE or L.KEEP_BAD) end
	local label = arg:match("|h(%[.-%])|h") or itemName(id)
	if adding then
		if db.keep[id] then return S:Print(L.KEEP_HAVE, label) end
		db.keep[id] = true
		S:Print(L.KEEP_ADDED, label)
	else
		if not db.keep[id] then return S:Print(L.KEEP_NOT, label) end
		db.keep[id] = nil
		S:Print(L.KEEP_REMOVED, label)
	end
end

S.commands.butler = command

-- Start

local function isValid(event)
	return not (C_EventUtils and C_EventUtils.IsEventValid) or C_EventUtils.IsEventValid(event)
end

local function onOptional(event, fn)
	if isValid(event) then S:On(event, fn) end
end

-- The plain merchant events come with the merchant data ready, so they win; the
-- interaction manager pair is the fallback when only that one is valid. Never
-- both for the same visit.
local function registerMerchantEvents()
	if isValid("MERCHANT_SHOW") and isValid("MERCHANT_CLOSED") then
		S:On("MERCHANT_SHOW", onMerchantShow)
		S:On("MERCHANT_CLOSED", onMerchantClosed)
		return
	end
	local merchantType = Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.Merchant
	if type(merchantType) ~= "number" then return end
	local function onInteraction(event, kind)
		if clean(kind) ~= merchantType then return end
		if event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then onMerchantShow() else onMerchantClosed() end
	end
	onOptional("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", onInteraction)
	onOptional("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", onInteraction)
end

local function onLoaded(_, name)
	if name ~= ADDON_NAME then return end
	S:Off("ADDON_LOADED", onLoaded)
	SempreButlerDB = SempreButlerDB or {}
	db = SempreButlerDB
	db.version = db.version or 1
	if type(db.keep) ~= "table" then db.keep = {} end

	optionList = {
		{
			key = "sell", default = true, disabled = unavailableReason("sell"),
			label = { de = "Schrott beim Händler verkaufen", en = "Sell junk at the merchant" },
			tooltip = { de = "Verkauft graue Gegenstände mit Verkaufspreis einzeln, wenn ein Händler sich öffnet. Mit gedrückter Umschalttaste beim Öffnen wird übersprungen. Die Behalten-Liste schützt Gegenstände: /sempre butler.", en = "Sells grey items with a vendor price one at a time when a merchant opens. Hold Shift while opening to skip. The keep list protects items: /sempre butler." },
		},
		{
			key = "repair", default = true, disabled = unavailableReason("repair"),
			label = { de = "Beim Händler reparieren", en = "Repair at the merchant" },
			tooltip = { de = "Repariert alles, wenn der Händler es kann und du genug Gold hast.", en = "Repairs everything when the merchant can and you have enough gold." },
		},
		{
			key = "guild_repair", default = false, disabled = unavailableReason("repair"),
			label = { de = "Gildenbank für Reparaturen nutzen", en = "Use guild funds for repairs" },
			tooltip = { de = "Repariert zuerst aus der Gildenbank, wenn sie es erlaubt.", en = "Repairs from the guild bank first when it allows it." },
		},
		{
			key = "resurrect", default = false, disabled = unavailableReason("resurrect"),
			label = { de = "Wiederbelebung automatisch annehmen", en = "Accept resurrection automatically" },
			tooltip = { de = "Nimmt eine Wiederbelebung nach einer Sekunde an, außer im Kampf, in Schlachtfeldern und Arenen.", en = "Accepts a resurrection after one second, except in combat, battlegrounds and arenas." },
		},
		{
			key = "duel", default = false, disabled = unavailableReason("duel"),
			label = { de = "Duelle automatisch ablehnen", en = "Decline duels automatically" },
			tooltip = { de = "Lehnt jede Duellanfrage sofort ab.", en = "Declines every duel request at once." },
		},
		{
			key = "quiet", default = false, disabled = unavailableReason("quiet"),
			label = { de = "Rote Fehlertexte ausblenden", en = "Hide red error text" },
			tooltip = { de = "Blendet Meldungen wie \"Nicht genug Energie\" in der Bildschirmmitte aus.", en = "Hides messages like \"Not enough energy\" in the middle of the screen." },
		},
	}
	S:RegisterOptions(ADDON_NAME, optionList)

	registerMerchantEvents()
	onOptional("RESURRECT_REQUEST", onResurrect)
	onOptional("DUEL_REQUESTED", onDuel)
	S:On("PLAYER_REGEN_DISABLED", function()
		if run then finish() end
	end)

	S:Listen("OPTION_CHANGED", function(_, moduleName, key, value)
		if moduleName ~= ADDON_NAME then return end
		local feature = key == "guild_repair" and "repair" or key
		if value and available[feature] then reportMissing(feature) end
		if key == "quiet" then applyQuiet() end
	end)

	for feature in pairs(available) do
		if S:GetOption(ADDON_NAME, feature) == true then reportMissing(feature) end
	end
	applyQuiet()
end
S:On("ADDON_LOADED", onLoaded)
