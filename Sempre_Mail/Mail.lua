-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Sempre_Mail: mail overview. A panel next to the game's mail frame lists every
-- letter (sorted by days left), takes money and items on a click or in one run
-- ("Take all", never cash on delivery), and a warning names characters whose
-- mail is about to expire. The warning and /sempre post read the snapshots of
-- Sempre_Items through its read-only interface; the open mailbox is read live.
--
-- Message MAIL_TAKEN(itemID, count, copper) after each successful take. Money:
-- itemID nil, count 0, copper = amount. Item: copper 0.
-- Read-only helper on SempreUI.Mail: GetEntries() -> the list the panel shows.

local ADDON_NAME = ...

local S = SempreUI
local ipairs, type, format, floor, max, min = ipairs, type, string.format, math.floor, math.max, math.min
local time, sort = time, table.sort
local issecretvalue = issecretvalue
local C_Container, C_Item, C_Mail, C_EventUtils = C_Container, C_Item, C_Mail, C_EventUtils
local CreateFrame, GetLocale, GetRealmName = CreateFrame, GetLocale, GetRealmName
local GetInboxNumItems, GetInboxHeaderInfo, GetInboxItem, GetInboxItemLink = GetInboxNumItems, GetInboxHeaderInfo, GetInboxItem, GetInboxItemLink
local GetInboxInvoiceInfo = GetInboxInvoiceInfo

local Mail = {}
S.Mail = Mail

local L = setmetatable({}, { __index = function(_, k) return k end })
Mail.L = L
if GetLocale() == "deDE" then
	L.TITLE = "Post"
	L.NO_ITEMS = "Mail: Sempre_Items fehlt, die Postübersicht bleibt aus."
	L.NO_INBOX = "Mail: Die Postfach-Funktionen fehlen in diesem Client, die Liste bleibt aus."
	L.TAKE_ALL = "Alles nehmen"
	L.STOP = "Stopp"
	L.GOLD_ONLY = "nur Gold"
	L.NO_MONEY_FN = "Dieser Client hat keine Funktion, um Gold aus Briefen zu nehmen."
	L.NO_ITEM_FN = "Dieser Client hat keine Funktion, um Anhänge aus Briefen zu nehmen."
	L.MK_SALE = "|cff55dd55AH+|r"
	L.MK_AUCTION = "|cff9a9a9aAH|r"
	L.MK_PLAYER = "|cffffffffSp|r"
	L.MK_SYSTEM = "|cff66aaffSys|r"
	L.COD = "COD"
	L.TOTAL = "Gesamt: %s, %d Gegenstände, %d / %d Briefe"
	L.MORE_WAITING = "%d weitere Briefe warten und erscheinen, sobald du Post genommen hast."
	L.DAYS = "%d Tg."
	L.HOURS = "%d Std."
	L.COD_REFUSED = "Mail: Nachnahme-Briefe werden nie bezahlt."
	L.SUMMARY = "Post genommen: %s, %d Gegenstände, %d Briefe übersprungen (Nachnahme)."
	L.R_FULL = "Mail: Die Taschen sind voll, angehalten."
	L.R_STOPPED = "Mail: Abgebrochen."
	L.R_CLOSED = "Mail: Briefkasten geschlossen, angehalten."
	L.R_NORESP = "Mail: Keine Antwort vom Server, angehalten."
	L.MAIL_1 = "1 Brief"
	L.MAIL_N = "%d Briefe"
	L.WARN_DAY_1 = "erster läuft in 1 Tag ab"
	L.WARN_DAY_N = "erster läuft in %d Tagen ab"
	L.WARN_HOURS = "erster läuft in %d Std. ab"
	L.POST_HEADER = "Post pro Charakter:"
	L.NEVER_OPENED = "nie geöffnet"
	L.POST_LINE = "  %s: %s, %s, %d Gegenstände"
	L.EXPIRED = "Frist laut Stand schon abgelaufen"
	L.HIDDEN = "+%d nicht sichtbar"
	L.STAND = "Stand %s"
	L.POST_TOTAL = "  Gesamt: %s, %s, %d Gegenstände"
	L.AGE_NOW = "gerade eben"
	L.AGE_MIN = "vor %d Min."
	L.AGE_HOUR = "vor %d Std."
	L.AGE_DAY = "vor %d Tg."
else
	L.TITLE = "Mail"
	L.NO_ITEMS = "Mail: Sempre_Items is missing, the mail overview stays off."
	L.NO_INBOX = "Mail: the inbox functions are missing in this client, the list stays off."
	L.TAKE_ALL = "Take all"
	L.STOP = "Stop"
	L.GOLD_ONLY = "gold only"
	L.NO_MONEY_FN = "This client has no function to take money from mail."
	L.NO_ITEM_FN = "This client has no function to take attachments from mail."
	L.MK_SALE = "|cff55dd55AH+|r"
	L.MK_AUCTION = "|cff9a9a9aAH|r"
	L.MK_PLAYER = "|cffffffffPl|r"
	L.MK_SYSTEM = "|cff66aaffSys|r"
	L.COD = "COD"
	L.TOTAL = "Total: %s, %d items, %d / %d mails"
	L.MORE_WAITING = "%d more mails are waiting and appear after you take some."
	L.DAYS = "%dd"
	L.HOURS = "%dh"
	L.COD_REFUSED = "Mail: cash on delivery mail is never paid."
	L.SUMMARY = "Mail taken: %s, %d items, %d mails skipped (cash on delivery)."
	L.R_FULL = "Mail: the bags are full, stopped."
	L.R_STOPPED = "Mail: stopped."
	L.R_CLOSED = "Mail: mailbox closed, stopped."
	L.R_NORESP = "Mail: no answer from the server, stopped."
	L.MAIL_1 = "1 mail"
	L.MAIL_N = "%d mails"
	L.WARN_DAY_1 = "first expires in 1 day"
	L.WARN_DAY_N = "first expires in %d days"
	L.WARN_HOURS = "first expires in %d h"
	L.POST_HEADER = "Mail per character:"
	L.NEVER_OPENED = "never opened"
	L.POST_LINE = "  %s: %s, %s, %d items"
	L.EXPIRED = "deadline already passed as of the snapshot"
	L.HIDDEN = "+%d not visible"
	L.STAND = "as of %s"
	L.POST_TOTAL = "  Total: %s, %s, %d items"
	L.AGE_NOW = "just now"
	L.AGE_MIN = "%d min ago"
	L.AGE_HOUR = "%d h ago"
	L.AGE_DAY = "%d d ago"
end

local DAY = 86400
local WARN_DAYS = 3 -- warning and red days
local TIMEOUT = 3 -- seconds to wait for the inbox after a take
local MAX_FAILS = 3 -- timeouts in a row before a run gives up
local MAX_ACTIONS = 1000
local ROW_H, PANEL_W = 22, 360
local TOP_H, BOTTOM_H = 30, 78
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"

local Items

-- Helpers

-- A value the addon must not compute with is dropped.
local function clean(v)
	if issecretvalue and issecretvalue(v) then return nil end
	return v
end

local function num(v, default)
	v = clean(v)
	return type(v) == "number" and v or default or 0
end

-- 12g 34s 56c; leading zero units are left out.
local function moneyText(copper)
	copper = floor(copper or 0)
	local g, s, c = floor(copper / 10000), floor(copper / 100) % 100, copper % 100
	if g > 0 then return format("%dg %ds %dc", g, s, c) end
	if s > 0 then return format("%ds %dc", s, c) end
	return format("%dc", c)
end

local function copperText(copper)
	return "|cff" .. S.color.hex .. moneyText(copper) .. "|r"
end

local function ageText(age)
	if age < 60 then return L.AGE_NOW end
	if age < 3600 then return format(L.AGE_MIN, floor(age / 60)) end
	if age < DAY then return format(L.AGE_HOUR, floor(age / 3600)) end
	return format(L.AGE_DAY, floor(age / DAY))
end

local function daysText(days)
	if days >= 1 then return format(L.DAYS, floor(days)) end
	return format(L.HOURS, max(1, floor(days * 24)))
end

local function mailsText(n)
	return n == 1 and L.MAIL_1 or format(L.MAIL_N, n)
end

local function expiryText(days)
	if days >= 1 then
		local d = floor(days)
		return d == 1 and L.WARN_DAY_1 or format(L.WARN_DAY_N, d)
	end
	return format(L.WARN_HOURS, max(1, floor(days * 24)))
end

-- The realm part is dropped for characters of the current realm.
local function shortName(key)
	local name, realm = key:match("^(.-)%-(.+)$")
	if name and realm == GetRealmName() then return name end
	return key
end

local function onOptional(event, fn)
	if C_EventUtils and C_EventUtils.IsEventValid and not C_EventUtils.IsEventValid(event) then return end
	S:On(event, fn)
end

-- Mail kinds. Assumptions: GetInboxInvoiceInfo(index) returns the invoice type
-- ("seller" for a sale) as first value and nothing for mail without an
-- invoice. Auction mail without an invoice (outbid, expired, cancelled) is
-- recognised by its subject against the game's subject patterns
-- AUCTION_*_MAIL_SUBJECT (format strings with %s), when those exist.

local subjectPatterns

local function toPattern(fmt)
	if type(fmt) ~= "string" then return end
	local p = fmt:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"):gsub("%%%%s", ".+")
	return "^" .. p .. "$"
end

local function buildPatterns()
	subjectPatterns = { sale = {}, auction = {} }
	local function add(kind, fmt)
		local p = toPattern(fmt)
		if p then subjectPatterns[kind][#subjectPatterns[kind] + 1] = p end
	end
	add("sale", AUCTION_SOLD_MAIL_SUBJECT)
	add("auction", AUCTION_EXPIRED_MAIL_SUBJECT)
	add("auction", AUCTION_OUTBID_MAIL_SUBJECT)
	add("auction", AUCTION_REMOVED_MAIL_SUBJECT)
	add("auction", AUCTION_CANCELLED_MAIL_SUBJECT)
	add("auction", AUCTION_WON_MAIL_SUBJECT)
end

local function subjectKind(subject)
	if type(subject) ~= "string" or (issecretvalue and issecretvalue(subject)) then return end
	if not subjectPatterns then buildPatterns() end
	for _, kind in ipairs({ "sale", "auction" }) do
		for _, p in ipairs(subjectPatterns[kind]) do
			if subject:find(p) then return kind end
		end
	end
end

local function classify(index, subject, canReply)
	local invoice = GetInboxInvoiceInfo and GetInboxInvoiceInfo(index)
	if invoice ~= nil then
		if clean(invoice) == "seller" then return "sale" end
		return "auction"
	end
	local kind = subjectKind(subject)
	if kind then return kind end
	if clean(canReply) == false then return "system" end
	return "player"
end

-- Live inbox

local entries, shownN, totalN = {}, 0, 0
local stale = true
local wantIcon = {}

local function iconOf(id, texture)
	texture = clean(texture)
	if texture then return texture end
	if C_Item and C_Item.GetItemIconByID then
		local icon = C_Item.GetItemIconByID(id)
		if icon then return icon end
	end
	if C_Item and C_Item.RequestLoadItemDataByID and not wantIcon[id] then
		wantIcon[id] = true
		C_Item.RequestLoadItemDataByID(id)
	end
	return QUESTION
end

-- Assumptions: GetInboxHeaderInfo returns subject as 4th, money 5th, COD
-- amount 6th, days left 7th, attachment count (or flag) 8th and canReply 12th
-- value; GetInboxItem returns the item ID as 2nd, the texture 3rd and the
-- count as 4th value.
local function readItems(index, hasItem)
	local list = {}
	if not (GetInboxItem and (hasItem == true or num(hasItem) > 0)) then return list end
	for a = 1, ATTACHMENTS_MAX_RECEIVE or 16 do
		local _, id, texture, count = GetInboxItem(index, a)
		id = clean(id)
		if type(id) ~= "number" and GetInboxItemLink then
			local link = clean(GetInboxItemLink(index, a))
			if type(link) == "string" then id = tonumber(link:match("item:(%d+)")) end
		end
		if type(id) == "number" and id > 0 then
			list[#list + 1] = { id = id, count = num(count, 1), slot = a, icon = iconOf(id, texture) }
		end
	end
	return list
end

local function byDays(a, b)
	if a.days ~= b.days then return a.days < b.days end
	return a.index < b.index
end

local function readInbox()
	entries = {}
	stale = false
	if not (GetInboxNumItems and GetInboxHeaderInfo) then
		shownN, totalN = 0, 0
		return entries
	end
	local shown, total = GetInboxNumItems()
	shownN = num(shown)
	totalN = max(shownN, num(total, shownN))
	for i = 1, shownN do
		local _, _, sender, subject, money, cod, days, hasItem, _, _, _, canReply = GetInboxHeaderInfo(i)
		money, cod = num(money), num(cod)
		local kind = classify(i, subject, canReply)
		local list = readItems(i, hasItem)
		entries[#entries + 1] = {
			index = i, kind = kind, money = money, cod = cod, days = num(days, 30),
			marker = cod > 0 and "cod" or kind,
			items = list, extra = max(0, #list - 1),
			sender = sender, -- may be a secret value: display only
		}
	end
	sort(entries, byDays)
	return entries
end

local function inbox()
	if stale then readInbox() end
	return entries
end

function Mail.GetEntries() return inbox() end

local function byIndex(list, index)
	for i = 1, #list do
		if list[i].index == index then return list[i] end
	end
end

local function sigOf(e)
	if not e then return "gone" end
	local parts = { e.money, e.cod }
	for _, it in ipairs(e.items) do parts[#parts + 1] = it.id .. "x" .. it.count end
	return table.concat(parts, ":")
end

-- Taking

local mailOpen = false
local job, pending, waitLeft
local goldOnly = false
local ui, ticker
local dirty = false

local function schedule()
	if ticker then ticker:Show() end
end

local function itemTaker()
	if TakeInboxItem then return TakeInboxItem end
	if C_Mail and C_Mail.TakeInboxItem then return C_Mail.TakeInboxItem end
end

-- Free slots in the normal bags (backpack and four bag slots); nil when the
-- client cannot tell. Assumption: GetContainerNumFreeSlots(bag) returns the
-- free slots and the bag family (0 for a normal bag).
local function freeSlots()
	if not (C_Container and C_Container.GetContainerNumFreeSlots) then return end
	local total = 0
	for bag = 0, 4 do
		local free, family = C_Container.GetContainerNumFreeSlots(bag)
		if type(free) == "number" and (family == nil or family == 0) then total = total + free end
	end
	return total
end

local function updateButtons()
	if not ui then return end
	local btn = ui.button
	btn:SetText(job and L.STOP or L.TAKE_ALL)
	local reason
	if not job then
		if not TakeInboxMoney then
			reason = L.NO_MONEY_FN
		elseif not goldOnly and not itemTaker() then
			reason = L.NO_ITEM_FN
		end
	end
	ui.reason = reason
	if reason then btn:Disable() else btn:Enable() end
end

local function pickAction(e)
	if e.cod > 0 then return end
	if e.money > 0 and TakeInboxMoney then return "money" end
	if not (job and job.gold) and #e.items > 0 and itemTaker() then return "item" end
end

local function nextAction(list)
	if job.mode == "one" then
		if job.left <= 0 then return end
		local e = byIndex(list, job.idx)
		if e then return e, pickAction(e) end
		return
	end
	for i = 1, #list do
		local kind = pickAction(list[i])
		if kind then return list[i], kind end
	end
end

local finish

local function issue(e, kind)
	job.actions = job.actions + 1
	job.left = job.left - 1
	stale = true
	local p
	if kind == "money" then
		p = { kind = "money", idx = e.index, sig = sigOf(e), amount = e.money }
	else
		local it = e.items[1]
		p = { kind = "item", idx = e.index, sig = sigOf(e), id = it.id, count = it.count, slot = it.slot }
	end
	pending, waitLeft = p, TIMEOUT
	schedule()
	if kind == "money" then
		TakeInboxMoney(e.index)
	else
		itemTaker()(e.index, p.slot)
	end
end

local function step()
	if not job or pending then return end
	if not mailOpen then return finish("closed") end
	if job.actions >= MAX_ACTIONS then return finish("noresp") end
	local e, kind = nextAction(inbox())
	if not (e and kind) then return finish("done") end
	if kind == "item" then
		local free = freeSlots()
		if free == 0 then return finish("full") end
	end
	issue(e, kind)
end

local reasons = { full = "R_FULL", stopped = "R_STOPPED", closed = "R_CLOSED", noresp = "R_NORESP" }

function finish(reason)
	local j = job
	job, pending, waitLeft = nil, nil, nil
	updateButtons()
	if not j then return end
	if reasons[reason] then S:Print(L[reasons[reason]]) end
	if j.mode == "all" then
		stale = true
		local skipped = 0
		for _, e in ipairs(inbox()) do
			if e.cod > 0 then skipped = skipped + 1 end
		end
		S:Print(L.SUMMARY, copperText(j.money), j.items, skipped)
	end
end

local function startJob(mode, idx, left)
	left = left or 0
	job = { mode = mode, idx = idx, left = left, gold = goldOnly, money = 0, items = 0, fails = 0, actions = 0 }
	if mode == "one" then job.gold = false end
	updateButtons()
	step()
end

local function takeOne(e)
	if job or not mailOpen then return end
	if e.cod > 0 then
		S:Print(L.COD_REFUSED)
		return
	end
	local left = 0
	if e.money > 0 and TakeInboxMoney then left = left + 1 end
	if itemTaker() then left = left + #e.items end
	if left > 0 then startJob("one", e.index, left) end
end

local function takeAll()
	if job then
		finish("stopped")
		return
	end
	if ui and ui.reason then return end
	stale = true
	startJob("all")
end

-- The inbox, bags or money changed: a pending take counts as done once the
-- mail it aimed at looks different. Unchanged mail keeps waiting (the game
-- also refreshes the inbox by itself).
local function onProgress()
	if not (job and pending) then return end
	local e = byIndex(inbox(), pending.idx)
	if sigOf(e) == pending.sig then return end
	local p = pending
	pending, waitLeft = nil, nil
	job.fails = 0
	if p.kind == "money" then
		job.money = job.money + p.amount
		S:Send("MAIL_TAKEN", nil, 0, p.amount)
	else
		job.items = job.items + p.count
		S:Send("MAIL_TAKEN", p.id, p.count, 0)
	end
	step()
end

local function onTimeout()
	if not pending then return end
	pending, waitLeft = nil, nil
	job.fails = job.fails + 1
	stale = true
	if job.fails >= MAX_FAILS then
		finish("noresp")
	else
		step()
	end
end

-- Panel

local function label(parent, x, w, justify, role)
	local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	S:SetFont(fs, role or "text", 11)
	fs:SetPoint("LEFT", parent, "LEFT", x, 0)
	fs:SetWidth(w)
	fs:SetJustifyH(justify)
	return fs
end

local function newRow(n)
	local row = CreateFrame("Button", nil, ui.panel)
	row:SetHeight(ROW_H)
	row:SetPoint("TOPLEFT", ui.panel, "TOPLEFT", 10, -(TOP_H + (n - 1) * ROW_H))
	row:SetPoint("TOPRIGHT", ui.panel, "TOPRIGHT", -10, -(TOP_H + (n - 1) * ROW_H))
	row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
	row:RegisterForClicks("LeftButtonUp")
	row.marker = label(row, 0, 32, "CENTER")
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(18, 18)
	row.icon:SetPoint("LEFT", row, "LEFT", 34, 0)
	row.count = label(row, 56, 40, "LEFT", "mono")
	row.money = label(row, 98, 100, "LEFT", "mono")
	row.days = label(row, 200, 40, "LEFT", "mono")
	row.sender = label(row, 244, 96, "LEFT")
	row:SetScript("OnClick", function(self)
		if self.entry then takeOne(self.entry) end
	end)
	return row
end

local offset, visible = 0, 1

local function layout()
	local mf = MailFrame
	local height = mf and mf:GetHeight() or 400
	ui.panel:SetHeight(height)
	visible = max(1, floor((height - TOP_H - BOTTOM_H) / ROW_H))
	for n = #ui.rows + 1, visible do ui.rows[n] = newRow(n) end
	for n = visible + 1, #ui.rows do
		ui.rows[n].entry = nil
		ui.rows[n]:Hide()
	end
end

local function rowTexts(row, e)
	row.entry = e
	local m = e.marker
	row.marker:SetText(m == "sale" and L.MK_SALE or m == "auction" and L.MK_AUCTION or m == "system" and L.MK_SYSTEM
		or m == "cod" and "|cffff4040" .. L.COD .. "|r" or L.MK_PLAYER)
	local first = e.items[1]
	row.icon:SetTexture(first and first.icon or nil)
	local count = ""
	if first and first.count > 1 then count = "x" .. first.count end
	if e.extra > 0 then count = count .. " +" .. e.extra end
	row.count:SetText(count)
	if e.cod > 0 then
		row.money:SetText("|cffff4040" .. L.COD .. " " .. moneyText(e.cod) .. "|r")
	elseif e.money > 0 then
		row.money:SetText(copperText(e.money))
	else
		row.money:SetText("")
	end
	local days = daysText(e.days)
	row.days:SetText(e.days < WARN_DAYS and "|cffff4040" .. days .. "|r" or days)
	row.sender:SetText(e.sender) -- display only, never compared or joined
	row:Show()
end

local function render()
	if not (ui and ui.panel:IsShown()) then return end
	local list = inbox()
	offset = max(0, min(offset, #list - visible))
	for n = 1, visible do
		local e = list[offset + n]
		if e then rowTexts(ui.rows[n], e) else
			ui.rows[n].entry = nil
			ui.rows[n]:Hide()
		end
	end
	local money, items = 0, 0
	for _, e in ipairs(list) do
		money = money + e.money
		for _, it in ipairs(e.items) do items = items + it.count end
	end
	ui.total:SetText(format(L.TOTAL, copperText(money), items, #list, totalN))
	ui.more:SetText(totalN > shownN and format(L.MORE_WAITING, totalN - shownN) or "")
	updateButtons()
end

local function buildPanel()
	local panel = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
	ui = { panel = panel, rows = {} }
	panel:SetWidth(PANEL_W)
	panel:SetFrameStrata("HIGH")
	panel:EnableMouse(true)
	panel:EnableMouseWheel(true)
	if panel.SetBackdrop then
		panel:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			tile = true, tileSize = 32, edgeSize = 16,
			insets = { left = 4, right = 4, top = 4, bottom = 4 },
		})
	end
	local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	S:SetFont(title, "title", 14)
	title:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, -10)
	title:SetText("|cff" .. S.color.hex .. L.TITLE .. "|r")
	ui.total = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	S:SetFont(ui.total, "text", 11)
	ui.total:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 14, 56)
	ui.more = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	S:SetFont(ui.more, "text", 11)
	ui.more:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 14, 40)
	ui.more:SetWidth(PANEL_W - 28)
	ui.more:SetJustifyH("LEFT")
	ui.button = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	ui.button:SetSize(120, 22)
	ui.button:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 12, 12)
	ui.button:SetScript("OnClick", takeAll)
	ui.button:SetScript("OnEnter", function(self)
		if ui.reason and GameTooltip then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(ui.reason)
			GameTooltip:Show()
		end
	end)
	ui.button:SetScript("OnLeave", function()
		if GameTooltip then GameTooltip:Hide() end
	end)
	ui.check = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	ui.check:SetSize(24, 24)
	ui.check:SetPoint("LEFT", ui.button, "RIGHT", 12, 0)
	ui.check:SetScript("OnClick", function(self)
		goldOnly = self:GetChecked() and true or false
		updateButtons()
	end)
	local text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	S:SetFont(text, "text", 11)
	text:SetPoint("LEFT", ui.check, "RIGHT", 2, 0)
	text:SetText(L.GOLD_ONLY)
	panel:SetScript("OnMouseWheel", function(_, delta)
		offset = max(0, min(offset - delta, #inbox() - visible))
		dirty = true
		schedule()
	end)
	panel:Hide()
	Mail.ui = ui
end

local function showPanel()
	if not (S:GetOption(ADDON_NAME, "list") and GetInboxNumItems and GetInboxHeaderInfo) then return end
	local mf = MailFrame
	if not mf then return end
	if not ui then buildPanel() end
	ui.panel:ClearAllPoints()
	ui.panel:SetPoint("TOPLEFT", mf, "TOPRIGHT", 2, 0)
	ui.panel:Show()
	layout()
	stale = true
	offset = 0
	render()
end

local function hidePanel()
	if ui then ui.panel:Hide() end
end

-- Mailbox open and close

local warnCheck

local function setMail(open)
	if open == mailOpen then return end
	mailOpen = open
	if open then
		stale = true
		showPanel()
	else
		if job then finish("closed") end
		hidePanel()
	end
end

-- Assumption: Enum.PlayerInteractionType.MailInfo is the mailbox. A missing
-- name is nil and never matches.
local function onInteraction(event, kind)
	local types = Enum and Enum.PlayerInteractionType
	if not types or kind == nil or kind ~= types.MailInfo then return end
	setMail(event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
end

local function onChange()
	if not mailOpen then return end
	stale = true
	dirty = true
	onProgress()
	schedule()
end

-- Expiry warning. Days left of a mail now = days at snapshot time minus the
-- days that passed since. Only mail with time left counts.

local warned = {}

-- Summary of a character's mail snapshot, or nil without one: mails, money,
-- item count, age in seconds, count of mails running out within WARN_DAYS
-- (count), the soonest of those in days (soon) and the soonest of all
-- (earliest, may be negative when the snapshot is old).
local function snapshotOf(key)
	local mails, snap, total, shown = Items.GetMail(key)
	if not snap then return end
	local elapsed = max(0, (time() - snap) / DAY)
	local res = { count = 0, mails = #mails, money = 0, items = 0, total = total, shown = shown, age = max(0, time() - snap) }
	for _, mail in ipairs(mails) do
		local left = num(mail.days) - elapsed
		res.money = res.money + num(mail.money)
		local list = mail.items or {}
		for i = 2, #list, 2 do res.items = res.items + num(list[i], 1) end
		if not res.earliest or left < res.earliest then res.earliest = left end
		if left > 0 and left <= WARN_DAYS then
			res.count = res.count + 1
			if not res.soon or left < res.soon then res.soon = left end
		end
	end
	return res
end

function warnCheck()
	if not (Items and S:GetOption(ADDON_NAME, "warning")) then return end
	for key in Items.GetChars() do
		if not warned[key] and not (key == S.charKey and mailOpen) then
			local res = snapshotOf(key)
			if res and res.count > 0 then
				warned[key] = true
				S:Print("%s: %s, %s", shortName(key), mailsText(res.count), expiryText(res.soon))
			end
		end
	end
end

-- /sempre post

local function command()
	if not Items then
		S:Print(L.NO_ITEMS)
		return
	end
	S:Print(L.POST_HEADER)
	local sumMails, sumMoney, sumItems = 0, 0, 0
	for key in Items.GetChars() do
		local res = snapshotOf(key)
		if not res then
			print(format("  %s: %s", shortName(key), L.NEVER_OPENED))
		else
			local count = mailsText(res.mails)
			if res.total > res.shown then count = count .. " (" .. format(L.HIDDEN, res.total - res.shown) .. ")" end
			local line = format(L.POST_LINE, shortName(key), count, moneyText(res.money), res.items)
			if res.earliest then
				line = line .. ", " .. (res.earliest > 0 and expiryText(res.earliest) or L.EXPIRED)
			end
			print(line .. ", " .. format(L.STAND, ageText(res.age)))
			sumMails, sumMoney, sumItems = sumMails + res.mails, sumMoney + res.money, sumItems + res.items
		end
	end
	print(format(L.POST_TOTAL, mailsText(sumMails), moneyText(sumMoney), sumItems))
end

S.commands.post = command
S.commands.mail = command

-- Start

local function onLoaded(_, name)
	if name ~= ADDON_NAME then return end
	S:Off("ADDON_LOADED", onLoaded)
	Items = S.Items
	if not (Items and Items.GetMail and Items.GetChars) then
		Items = nil
		S:Print(L.NO_ITEMS)
		return
	end
	S:RegisterOptions(ADDON_NAME, {
		{
			key = "list", default = true,
			label = { de = "Postliste am Briefkasten", en = "Mail list at the mailbox" },
			tooltip = { de = "Zeigt neben dem Briefkasten eine Liste aller Briefe mit Schaltern zum Nehmen.", en = "Shows a list of all mails next to the mailbox with buttons to take them." },
		},
		{
			key = "warning", default = true,
			label = { de = "Warnung vor ablaufender Post", en = "Warning about expiring mail" },
			tooltip = { de = "Meldet im Chat, wenn Post eines Charakters in höchstens 3 Tagen abläuft.", en = "Tells you in chat when mail of a character expires within 3 days." },
		},
	})
	if not (GetInboxNumItems and GetInboxHeaderInfo) then S:Print(L.NO_INBOX) end

	ticker = CreateFrame("Frame")
	ticker:Hide()
	ticker:SetScript("OnUpdate", function(self, elapsed)
		if pending and waitLeft then
			waitLeft = waitLeft - (elapsed or 0)
			if waitLeft <= 0 then onTimeout() end
		end
		if dirty then
			dirty = false
			render()
		end
		if not (pending or dirty) then self:Hide() end
	end)
	Mail.ticker = ticker

	onOptional("MAIL_SHOW", function() setMail(true) end)
	onOptional("MAIL_CLOSED", function() setMail(false) end)
	onOptional("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", onInteraction)
	onOptional("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", onInteraction)
	onOptional("MAIL_INBOX_UPDATE", onChange)
	onOptional("BAG_UPDATE_DELAYED", onChange)
	onOptional("PLAYER_MONEY", onChange)
	onOptional("ITEM_DATA_LOAD_RESULT", function(_, id)
		if wantIcon[id] then
			wantIcon[id] = nil
			stale = true
			dirty = true
			schedule()
		end
	end)

	S:Listen("ITEMS_CHANGED", function(_, _, location)
		if location == "mail" then warnCheck() end
	end)
	S:Listen("OPTION_CHANGED", function(_, module, key, value)
		if module ~= ADDON_NAME then return end
		if key == "list" and mailOpen then
			if value then showPanel() else hidePanel() end
		elseif key == "warning" and value then
			warnCheck()
		end
	end)

	-- Login work: this module is loaded from inside PLAYER_LOGIN, so the
	-- character is already known.
	if S.charKey then
		warnCheck()
	else
		S:On("PLAYER_LOGIN", warnCheck)
	end
end
S:On("ADDON_LOADED", onLoaded)
