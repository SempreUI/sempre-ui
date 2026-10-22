-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Sempre_Whisper: one small window per whisper conversation, with tabs, an
-- input line, sound, unread markers and a short history in saved variables.
--
-- Secret values: while the chat is in messaging lockdown (or whenever an event
-- value is secret) text, names and IDs are never read. Only the line ID, the
-- kind of event and the time are queued; after the lockdown each line is
-- resolved through C_ChatInfo.GetChatLineSenderName / GetChatLineText and
-- filed with its original time. Nothing secret is compared, stored,
-- concatenated or measured.
--
-- Message WHISPER_RECEIVED(key) for each incoming line, never the text.
-- Read-only interface on SempreUI.Whisper: GetUnread() -> number of
-- conversations with unread lines, GetLast() -> key of the newest
-- conversation, GetConversation(key) -> the stored table (do not modify),
-- Split(text) -> list of parts of at most 255 bytes. Open(key) shows the
-- window. ui holds the window parts once built.
-- Data: SempreWhisperDB.chars[charKey] = { conversations = { [key] =
-- { name, bnet, accountID, lines = { {t, out, text} }, unread, last } },
-- window = { point, relPoint, x, y, w, h } }.
-- Options: open (window on a new whisper), sound, history.

local ADDON_NAME = ...

local S = SempreUI
local ipairs, pairs, type, pcall, tostring = ipairs, pairs, type, pcall, tostring
local format, floor, max = string.format, math.floor, math.max
local sort, tinsert, tremove = table.sort, table.insert, table.remove
local time, date = time, date
local issecretvalue = issecretvalue
local CreateFrame, GetLocale, InCombatLockdown = CreateFrame, GetLocale, InCombatLockdown

local Whisper = {}
S.Whisper = Whisper

local L = setmetatable({}, { __index = function(_, k) return k end })
if GetLocale() == "deDE" then
	L.TITLE = "Flüstern"
	L.ME = "Ich"
	L.NONE = "Whisper: Noch keine Unterhaltung."
	L.STATE = "Whisper: %d Unterhaltungen, %d ungelesen."
	L.NO_SEND = "Whisper: Dieser Client hat keine Funktion zum Senden an Spieler."
	L.NO_BN_SEND = "Whisper: Dieser Client hat keine Funktion zum Senden an Battle.net-Freunde."
	L.NO_BN_ID = "Whisper: Für diese Unterhaltung ist keine Battle.net-Kennung bekannt, antworte im Chat."
	L.INPUT_HINT = "Enter sendet, Esc beendet die Eingabe."
	L.LAST = "zuletzt %s"
	L.BN_NAME = "Battle.net"
else
	L.TITLE = "Whispers"
	L.ME = "Me"
	L.NONE = "Whisper: no conversation yet."
	L.STATE = "Whisper: %d conversations, %d unread."
	L.NO_SEND = "Whisper: this client has no function to send to players."
	L.NO_BN_SEND = "Whisper: this client has no function to send to Battle.net friends."
	L.NO_BN_ID = "Whisper: no Battle.net ID is known for this conversation, answer in the chat."
	L.INPUT_HINT = "Enter sends, Esc leaves the input."
	L.LAST = "last %s"
	L.BN_NAME = "Battle.net"
end

local DAY = 86400
local MAX_LINES, MAX_CONVS, MAX_AGE = 50, 30, 7 * DAY
local MAX_PENDING = 50
local POLL = 5 -- seconds between resolve attempts while lines are pending
local MAX_BYTES = 255
local MIN_W, MIN_H = 260, 160
local TAB_W, TAB_H = 72, 20
local PLAIN = "Interface\\Buttons\\WHITE8X8"
local COPPER = "|cff" .. S.color.hex

local SOUND_FALLBACK = 3081 -- assumption: sound kit "TELL_MESSAGE"

local char -- SempreWhisperDB.chars[charKey]
local convs = {} -- live conversations (saved when history is on)
local pending = {} -- { line, out, bn, t } queued during lockdown
local current -- key of the shown conversation
local pendingOpen -- a whisper arrived in combat with the window closed
local inCombat = false
local ui -- the window parts, built on first use
local timer, acc

-- Helpers

local function secret(v)
	return issecretvalue and issecretvalue(v) or false
end

-- A readable, non-empty string, else nil.
local function readable(v)
	if secret(v) then return nil end
	if type(v) == "string" and v ~= "" then return v end
end

local function lockdown()
	local info = C_ChatInfo
	if info and info.InChatMessagingLockdown then
		local ok, res = pcall(info.InChatMessagingLockdown)
		return ok and res and true or false
	end
	return false
end

local function combat()
	return inCombat or InCombatLockdown()
end

local function opt(key)
	return S:GetOption(ADDON_NAME, key)
end

local function shortName(name)
	return (tostring(name):match("^([^%-]+)")) or tostring(name)
end

local function whisperColor()
	local info = C_ChatInfo
	if info and info.GetColorForChatType then
		local ok, c = pcall(info.GetColorForChatType, "WHISPER")
		if ok and type(c) == "table" and type(c.r) == "number" then return c.r, c.g, c.b end
	end
	return 1, 0.5, 1
end

local function hex(r, g, b)
	return format("%02x%02x%02x", floor(r * 255 + 0.5), floor(g * 255 + 0.5), floor(b * 255 + 0.5))
end

-- Splits text into parts of at most 255 bytes, at spaces where possible and
-- never inside a UTF-8 character.
function Whisper.Split(text)
	local parts = {}
	text = tostring(text or ""):match("^%s*(.-)%s*$")
	while #text > MAX_BYTES do
		local cut
		local head = text:sub(1, MAX_BYTES + 1)
		local space = head:match("^.*() ")
		if space and space > 1 then
			cut = space - 1
		else
			cut = MAX_BYTES
			while cut > 1 do
				local b = text:byte(cut + 1)
				if b and b >= 0x80 and b < 0xC0 then cut = cut - 1 else break end
			end
		end
		parts[#parts + 1] = text:sub(1, cut)
		text = text:sub(cut + 1):match("^%s*(.-)$")
	end
	if text ~= "" then parts[#parts + 1] = text end
	return parts
end

-- Conversations

local function prune()
	local now = time()
	local cutoff = now - MAX_AGE
	local list = {}
	for key, c in pairs(convs) do
		local keep = {}
		if type(c) == "table" and type(c.lines) == "table" then
			for _, ln in ipairs(c.lines) do
				if type(ln) == "table" and type(ln.t) == "number" and ln.t >= cutoff and type(ln.text) == "string" then
					keep[#keep + 1] = ln
				end
			end
		end
		while #keep > MAX_LINES do tremove(keep, 1) end
		if #keep == 0 then
			convs[key] = nil
		else
			c.lines = keep
			c.last = keep[#keep].t
			list[#list + 1] = key
		end
	end
	if #list > MAX_CONVS then
		sort(list, function(a, b)
			if convs[a].last ~= convs[b].last then return convs[a].last > convs[b].last end
			return a < b
		end)
		for i = MAX_CONVS + 1, #list do convs[list[i]] = nil end
	end
end

local function unreadCount()
	local n = 0
	for _, c in pairs(convs) do
		if (c.unread or 0) > 0 then n = n + 1 end
	end
	return n
end

-- Keys by newest activity first.
local function orderedKeys()
	local list = {}
	for key in pairs(convs) do list[#list + 1] = key end
	sort(list, function(a, b)
		local la, lb = convs[a].last or 0, convs[b].last or 0
		if la ~= lb then return la > lb end
		return a < b
	end)
	return list
end

function Whisper.GetUnread() return unreadCount() end
function Whisper.GetLast() return orderedKeys()[1] end
function Whisper.GetConversation(key) return convs[key] end

local refresh

-- Adds one line (t = original time). The caller passes only readable values.
local function addLine(key, name, bn, accountID, out, text, t)
	local c = convs[key]
	if not c then
		c = { name = name, lines = {}, unread = 0 }
		convs[key] = c
	end
	c.name = name
	if bn then
		c.bnet = true
		c.accountID = accountID or c.accountID
	end
	local lines = c.lines
	local pos = #lines + 1
	while pos > 1 and lines[pos - 1].t > t do pos = pos - 1 end
	tinsert(lines, pos, { t = t, out = out and true or false, text = text })
	c.last = lines[#lines].t
	prune()
	return convs[key]
end

-- Window

local function savePosition()
	if not (char and ui) then return end
	local f = ui.frame
	local point, _, relPoint, x, y = f:GetPoint()
	if not point then return end
	char.window = { point = point, relPoint = relPoint, x = x, y = y, w = f:GetWidth(), h = f:GetHeight() }
end

local function renderLines()
	if not ui then return end
	local msgs = ui.msgs
	msgs:Clear()
	local c = convs[current]
	if not c then return end
	local wr, wg, wb = whisperColor()
	local theirs = "|cff" .. hex(wr, wg, wb)
	local who = shortName(c.name)
	for _, ln in ipairs(c.lines) do
		local label = ln.out and (COPPER .. L.ME .. "|r") or (theirs .. who .. "|r")
		msgs:AddMessage(format("|cff9a9a9a%s|r %s: %s", date("%H:%M", ln.t), label, ln.text))
	end
	if msgs.ScrollToBottom then msgs:ScrollToBottom() end
end

local function layoutTabs()
	if not ui then return end
	local keys = orderedKeys()
	local fit = max(1, floor((ui.frame:GetWidth() - 44) / (TAB_W + 2)))
	local shown = {}
	for _, key in ipairs(keys) do
		if #shown < fit or key == current then
			if #shown >= fit and key == current then shown[#shown] = nil end
			shown[#shown + 1] = key
		end
	end
	for i, tab in ipairs(ui.tabs) do
		local key = shown[i]
		tab.key = key
		if key then
			local c = convs[key]
			local mark = (c.unread or 0) > 0 and (COPPER .. "* |r") or ""
			tab.text:SetText(mark .. shortName(c.name))
			tab:ClearAllPoints()
			tab:SetPoint("TOPLEFT", ui.frame, "TOPLEFT", 6 + (i - 1) * (TAB_W + 2), -5)
			if tab.bg then
				if key == current then tab.bg:SetColorTexture(0.78, 0.47, 0.29, 0.35) else tab.bg:SetColorTexture(1, 1, 1, 0.06) end
			end
			tab:Show()
		else
			tab:Hide()
		end
	end
end

refresh = function()
	if not ui then return end
	local c = convs[current]
	local unread = unreadCount()
	local title = c and c.name or L.TITLE
	if unread > 0 then title = title .. " " .. COPPER .. "(" .. unread .. ")|r" end
	ui.title:SetText(title)
	ui.last:SetText(c and c.last and format(L.LAST, date("%H:%M", c.last)) or "")
	layoutTabs()
	renderLines()
end

local function selectConv(key)
	if not convs[key] then return end
	current = key
	convs[key].unread = 0
	refresh()
end

local function sendText(text)
	local c = convs[current]
	if not c then return end
	for _, part in ipairs(Whisper.Split(text)) do
		if c.bnet then
			local bn = C_BattleNet
			if not (bn and bn.SendWhisper) then
				S:Print(L.NO_BN_SEND)
				return
			end
			if not c.accountID then
				S:Print(L.NO_BN_ID)
				return
			end
			bn.SendWhisper(c.accountID, part)
		else
			local info = C_ChatInfo
			if not (info and info.SendChatMessage) then
				S:Print(L.NO_SEND)
				return
			end
			info.SendChatMessage(part, "WHISPER", nil, c.name)
		end
	end
end

local function onEnter(edit)
	local text = edit:GetText()
	if type(text) == "string" and text:match("%S") then
		sendText(text)
		edit:SetText("")
	end
end

local function newTab(parent, index)
	local tab = CreateFrame("Button", nil, parent)
	tab:SetSize(TAB_W, TAB_H)
	tab.bg = tab:CreateTexture(nil, "BACKGROUND")
	tab.bg:SetAllPoints()
	tab.text = tab:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	S:SetFont(tab.text, "text", 11)
	tab.text:SetPoint("LEFT", tab, "LEFT", 4, 0)
	tab.text:SetPoint("RIGHT", tab, "RIGHT", -4, 0)
	tab.text:SetJustifyH("LEFT")
	tab:SetScript("OnClick", function(self)
		if self.key then selectConv(self.key) end
	end)
	tab.index = index
	return tab
end

local function build()
	local f = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
	ui = { frame = f, tabs = {} }
	f:SetFrameStrata("HIGH")
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:SetResizable(true)
	f:EnableMouse(true)
	if f.SetResizeBounds then
		f:SetResizeBounds(MIN_W, MIN_H)
	elseif f.SetMinResize then
		f:SetMinResize(MIN_W, MIN_H)
	end
	if f.SetBackdrop then
		f:SetBackdrop({ bgFile = PLAIN, edgeFile = PLAIN, edgeSize = 1 })
		f:SetBackdropColor(0.06, 0.06, 0.06, 0.92)
		f:SetBackdropBorderColor(S.color.r, S.color.g, S.color.b, 1)
	end
	local w = char and char.window
	f:ClearAllPoints()
	if w and type(w.x) == "number" and type(w.y) == "number" then
		f:SetPoint(w.point or "CENTER", UIParent, w.relPoint or w.point or "CENTER", w.x, w.y)
	else
		f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	end
	f:SetSize(max(MIN_W, w and w.w or 320), max(MIN_H, w and w.h or 240))
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(self) self:StartMoving() end)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		savePosition()
	end)
	f:SetScript("OnSizeChanged", function()
		layoutTabs()
	end)

	for i = 1, 8 do ui.tabs[i] = newTab(f, i) end

	ui.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	S:SetFont(ui.title, "title", 14)
	ui.title:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -30)
	ui.title:SetJustifyH("LEFT")
	ui.last = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	S:SetFont(ui.last, "mono", 10)
	ui.last:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -33)

	ui.close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	ui.close:SetPoint("TOPRIGHT", f, "TOPRIGHT", 2, 2)
	ui.close:SetScript("OnClick", function() f:Hide() end)

	local msgs = CreateFrame("ScrollingMessageFrame", nil, f)
	ui.msgs = msgs
	msgs:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -50)
	msgs:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 34)
	msgs:SetJustifyH("LEFT")
	msgs:SetFading(false)
	msgs:SetMaxLines(MAX_LINES + 10)
	msgs:EnableMouseWheel(true)
	S:SetFont(msgs, "text", 12)
	msgs:SetScript("OnMouseWheel", function(self, delta)
		if delta > 0 then self:ScrollUp() else self:ScrollDown() end
	end)
	if msgs.SetHyperlinksEnabled then msgs:SetHyperlinksEnabled(true) end
	msgs:SetScript("OnHyperlinkClick", function(self, link, text, button)
		if SetItemRef then SetItemRef(link, text, button, self) end
	end)
	msgs:SetScript("OnHyperlinkEnter", function(self, link)
		if GameTooltip then
			GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
			pcall(GameTooltip.SetHyperlink, GameTooltip, link)
			GameTooltip:Show()
		end
	end)
	msgs:SetScript("OnHyperlinkLeave", function()
		if GameTooltip then GameTooltip:Hide() end
	end)

	local input = CreateFrame("EditBox", nil, f)
	ui.input = input
	input:SetHeight(22)
	input:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 8)
	input:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -26, 8)
	input:SetAutoFocus(false)
	input:SetMaxBytes(MAX_BYTES * 4)
	input:SetTextInsets(4, 4, 0, 0)
	S:SetFont(input, "text", 12)
	local line = input:CreateTexture(nil, "BACKGROUND")
	line:SetAllPoints()
	line:SetColorTexture(1, 1, 1, 0.07)
	input:SetScript("OnEnterPressed", onEnter)
	input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	input:SetScript("OnEnter", function(self)
		if GameTooltip then
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:SetText(L.INPUT_HINT)
			GameTooltip:Show()
		end
	end)
	input:SetScript("OnLeave", function()
		if GameTooltip then GameTooltip:Hide() end
	end)

	local grip = CreateFrame("Button", nil, f)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
	grip:SetScript("OnMouseUp", function()
		f:StopMovingOrSizing()
		savePosition()
	end)
	ui.grip = grip
	Whisper.ui = ui
end

local function windowShown()
	return ui and ui.frame:IsShown() and true or false
end

local function show(key)
	if not ui then build() end
	if not key or not convs[key] then
		if convs[current] then key = current else key = Whisper.GetLast() end
	end
	ui.frame:Show()
	if key then selectConv(key) else refresh() end
end
Whisper.Open = show

-- Incoming and outgoing lines

local function playSound()
	local snd = C_Sound
	if not (snd and snd.PlaySound) then return end
	local kit = SOUNDKIT and SOUNDKIT.TELL_MESSAGE or SOUND_FALLBACK
	pcall(snd.PlaySound, kit)
end

local function notify(key, c)
	local watching = windowShown() and current == key
	local focused = watching and ui.input:HasFocus() and true or false
	if watching then
		c.unread = 0
	else
		c.unread = (c.unread or 0) + 1
	end
	if opt("sound") and not focused then playSound() end
	if opt("open") and not windowShown() then
		if combat() then
			pendingOpen = key
		else
			show(key)
		end
	end
	S:Send("WHISPER_RECEIVED", key)
end

local function file(key, name, bn, accountID, out, text, t)
	local c = addLine(key, name, bn, accountID, out, text, t)
	if not c then return end
	if not out then notify(key, c) end
	refresh()
end

local function bnDisplayName(id, fallback)
	local bn = C_BattleNet
	if bn and bn.GetAccountInfoByID then
		local ok, info = pcall(bn.GetAccountInfoByID, id)
		if ok and type(info) == "table" then
			local name = readable(info.accountName) or readable(info.battleTag)
			if name then return name end
		end
	end
	return readable(fallback) or L.BN_NAME
end

-- Lockdown queue

local function startTimer()
	if timer then
		acc = 0
		timer:Show()
	end
end

local function queue(lineID, out, bn)
	if type(lineID) ~= "number" then return end
	pending[#pending + 1] = { line = lineID, out = out, bn = bn, t = time() }
	while #pending > MAX_PENDING do tremove(pending, 1) end
	startTimer()
end

local function lineValue(fn, lineID)
	local info = C_ChatInfo
	if not (info and info[fn]) then return nil end
	local ok, v = pcall(info[fn], lineID)
	if ok then return readable(v) end
end

local function bnIdFromLine(lineID)
	local info, bn = C_ChatInfo, C_BattleNet
	if not (info and info.GetChatLineSenderGUID and bn and bn.GetAccountInfoByGUID) then return nil end
	local ok, guid = pcall(info.GetChatLineSenderGUID, lineID)
	if not ok or secret(guid) or guid == nil then return nil end
	local ok2, acct = pcall(bn.GetAccountInfoByGUID, guid)
	if ok2 and type(acct) == "table" and type(acct.bnetAccountID) == "number" then return acct.bnetAccountID end
end

local function resolvePending()
	if #pending == 0 then
		if timer then timer:Hide() end
		return
	end
	if lockdown() then return end
	local list = pending
	pending = {}
	if timer then timer:Hide() end
	for _, p in ipairs(list) do
		local name = lineValue("GetChatLineSenderName", p.line)
		local text = lineValue("GetChatLineText", p.line)
		if name and text then
			if p.bn then
				local id = bnIdFromLine(p.line)
				local key = id and ("bn:" .. id) or ("bnname:" .. name)
				file(key, id and bnDisplayName(id, name) or name, true, id, p.out, text, p.t)
			else
				file(name, name, false, nil, p.out, text, p.t)
			end
		end
	end
end
Whisper.ResolvePending = resolvePending

local function onWhisper(event, text, name, _, _, _, _, _, _, _, _, lineID, _, bnID)
	local out = event:find("INFORM", 1, true) ~= nil
	local bn = event:find("BN_", 1, true) ~= nil
	if lockdown() or secret(text) or secret(name) or secret(bnID) or secret(lineID) then
		queue(lineID, out, bn)
		return
	end
	text = readable(text)
	if not text then return end
	local t = time()
	if bn then
		if type(bnID) ~= "number" then return end
		file("bn:" .. bnID, bnDisplayName(bnID, name), true, bnID, out, text, t)
	else
		name = readable(name)
		if not name then return end
		file(name, name, false, nil, out, text, t)
	end
end

local function onRegen(event)
	inCombat = event == "PLAYER_REGEN_DISABLED"
	if inCombat then return end
	resolvePending()
	if pendingOpen then
		local key = pendingOpen
		pendingOpen = nil
		if opt("open") and not windowShown() and not combat() then show(key) end
	end
end

local function onZone()
	resolvePending()
end

-- /sempre fluestern

local function command()
	local list = orderedKeys()
	if #list == 0 then
		S:Print(L.NONE)
		return
	end
	S:Print(L.STATE, #list, unreadCount())
	show(list[1])
end

S.commands.fluestern = command
S.commands.whisper = command

-- Start

local function applyHistory(on)
	if not char then return end
	if on then
		char.conversations = convs
	else
		char.conversations = {}
	end
end

local function start()
	if char then return end
	SempreWhisperDB = SempreWhisperDB or {}
	SempreWhisperDB.version = SempreWhisperDB.version or 1
	SempreWhisperDB.chars = SempreWhisperDB.chars or {}
	char = SempreWhisperDB.chars[S.charKey] or {}
	SempreWhisperDB.chars[S.charKey] = char
	if opt("history") then
		if type(char.conversations) ~= "table" then char.conversations = {} end
		convs = char.conversations
		prune()
	else
		convs = {}
		char.conversations = {}
	end

	timer = CreateFrame("Frame")
	timer:Hide()
	timer:SetScript("OnUpdate", function(self, elapsed)
		acc = (acc or 0) + (elapsed or 0)
		if acc >= POLL then
			acc = 0
			resolvePending()
		end
		if #pending == 0 then self:Hide() end
	end)
	Whisper.timer = timer

	S:On("CHAT_MSG_WHISPER", onWhisper)
	S:On("CHAT_MSG_WHISPER_INFORM", onWhisper)
	S:On("CHAT_MSG_BN_WHISPER", onWhisper)
	S:On("CHAT_MSG_BN_WHISPER_INFORM", onWhisper)
	S:On("PLAYER_REGEN_DISABLED", onRegen)
	S:On("PLAYER_REGEN_ENABLED", onRegen)
	S:On("ZONE_CHANGED_NEW_AREA", onZone)
end

local function onLoaded(_, name)
	if name ~= ADDON_NAME then return end
	S:Off("ADDON_LOADED", onLoaded)
	S:RegisterOptions(ADDON_NAME, {
		{
			key = "open", default = true,
			label = { de = "Fenster bei neuem Flüstern öffnen", en = "Open the window on a new whisper" },
			tooltip = { de = "Aus: nur die Markierung ungelesen am Reiter. Im Kampf öffnet sich das Fenster erst danach.", en = "Off: only the unread marker on the tab. In combat the window opens afterwards." },
		},
		{
			key = "sound", default = true,
			label = { de = "Ton bei neuem Flüstern", en = "Sound on a new whisper" },
			tooltip = { de = "Spielt einen kurzen Ton, wenn das Flüsterfenster nicht gerade den Fokus hat.", en = "Plays a short sound when the whisper window does not have focus." },
		},
		{
			key = "history", default = true,
			label = { de = "Verlauf speichern", en = "Keep history" },
			tooltip = { de = "Speichert die letzten 50 Zeilen von bis zu 30 Unterhaltungen für 7 Tage auf diesem Rechner. Aus: nur bis zum Ausloggen, gespeicherte Zeilen werden gelöscht.", en = "Stores the last 50 lines of up to 30 conversations for 7 days on this computer. Off: only until you log out, saved lines are deleted." },
		},
	})
	S:Listen("OPTION_CHANGED", function(_, module, key, value)
		if module == ADDON_NAME and key == "history" then applyHistory(value) end
	end)
	if S.charKey then
		start()
	else
		S:On("PLAYER_LOGIN", start)
	end
end
S:On("ADDON_LOADED", onLoaded)
