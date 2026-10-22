-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- "What's new" window. Interface (read-only, documented here):
--   SempreUI:ShowNews()   -- opens the window (built on first use) and stores
--                            the newest version of SempreUI.News as seen
-- Opens once by itself after an update (option "news" of the core, default
-- on), never on a first install, and not in combat (it waits for combat end).
-- The last seen version lives in SempreDB.global.newsSeen (nil: first install).
-- Command: /sempre neu (news).

local S = SempreUI
local L = S.L
local CreateFrame, GetLocale, InCombatLockdown = CreateFrame, GetLocale, InCombatLockdown
local C_Timer, UIParent, UISpecialFrames = C_Timer, UIParent, UISpecialFrames
local ipairs, type, tinsert = ipairs, type, table.insert

local DE = GetLocale() == "deDE"
local LANG = DE and "de" or "en"
if DE then
	L.NEWS_TITLE = "SempreUI – Was ist neu"
	L.NEWS_FEEDBACK = "Fehler oder Wünsche? GitHub-Issues: github.com/SempreUI/sempre-ui/issues"
	L.NEWS_CLOSE = "Schließen"
else
	L.NEWS_TITLE = "SempreUI – What's new"
	L.NEWS_FEEDBACK = "Bugs or wishes? GitHub issues: github.com/SempreUI/sempre-ui/issues"
	L.NEWS_CLOSE = "Close"
end

local PLAIN = "Interface\\Buttons\\WHITE8X8"
local FRAME_NAME = "SempreNewsFrame"   -- needed only for the game's special-frames list
local WIDTH, HEIGHT, PAD, LIST_W = 440, 380, 14, 380
local OPEN_DELAY = 3

local frame, ready
local pending, waitingCombat

local function newest()
	local first = S.News and S.News[1]
	return first and first.version
end

local function markSeen()
	local version = newest()
	if version and S.db then S.db.global.newsSeen = version end
end

local function fontString(parent, role, r, g, b)
	local fs = parent:CreateFontString(nil, "OVERLAY")
	S:SetFont(fs, role)
	fs:SetTextColor(r, g, b)
	fs:SetJustifyH("LEFT")
	return fs
end

-- Heading and bulleted points per release, stacked inside the scroll child.
local function fill(child)
	local c = S.color
	local y = 0
	for _, rel in ipairs(S.News or {}) do
		local head = fontString(child, "bold", c.r, c.g, c.b)
		head:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
		head:SetText(rel.version .. "  –  " .. rel.date)
		y = y + 20
		for _, point in ipairs(rel.points) do
			local line = fontString(child, "text", 0.9, 0.9, 0.9)
			line:SetWidth(LIST_W - 12)
			line:SetPoint("TOPLEFT", child, "TOPLEFT", 12, -y)
			line:SetText("- " .. (point[LANG] or point.en or ""))
			y = y + (line:GetStringHeight() or 14) + 4
		end
		y = y + 10
	end
	child:SetSize(LIST_W, y > 1 and y or 1)
end

local function build()
	frame = CreateFrame("Frame", FRAME_NAME, UIParent, "BackdropTemplate")
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
	frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
	if frame.SetBackdrop then
		frame:SetBackdrop({ bgFile = PLAIN, edgeFile = PLAIN, edgeSize = 1 })
		frame:SetBackdropColor(0.06, 0.06, 0.06, 0.92)
		frame:SetBackdropBorderColor(S.color.r, S.color.g, S.color.b, 1)
	end

	local title = fontString(frame, "title", S.color.r, S.color.g, S.color.b)
	title:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -PAD)
	title:SetText(L.NEWS_TITLE)

	local close = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	close:SetSize(90, 22)
	close:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, PAD)
	close:SetText(L.NEWS_CLOSE)
	close:SetScript("OnClick", function() frame:Hide() end)

	local feedback = fontString(frame, "text", 0.6, 0.6, 0.6)
	feedback:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, PAD + 30)
	feedback:SetWidth(WIDTH - 2 * PAD)
	feedback:SetText(L.NEWS_FEEDBACK)

	local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -PAD - 28)
	scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD - 24, PAD + 62)
	local child = CreateFrame("Frame", nil, scroll)
	scroll:SetScrollChild(child)
	fill(child)

	-- Escape closes it where the game keeps a special-frames list.
	if type(UISpecialFrames) == "table" then tinsert(UISpecialFrames, FRAME_NAME) end
	frame:SetScript("OnHide", markSeen)
	S.newsFrame = frame
	ready = true
end

function S:ShowNews()
	if not ready then build() end
	pending = false
	markSeen()
	frame:Show()
end

local tryOpen

local function onCombatEnd()
	S:Off("PLAYER_REGEN_ENABLED", onCombatEnd)
	waitingCombat = false
	tryOpen()
end

function tryOpen()
	if not pending then return end
	if InCombatLockdown() then
		if not waitingCombat then
			waitingCombat = true
			S:On("PLAYER_REGEN_ENABLED", onCombatEnd)
		end
		return
	end
	S:ShowNews()
end

-- Decided at login; the window itself opens a moment after entering the world.
S:On("PLAYER_LOGIN", function()
	local version = newest()
	local global = S.db and S.db.global
	if not (version and global) then return end
	local seen = global.newsSeen
	if seen == nil then
		global.newsSeen = version   -- first install: no changelog for new players
	elseif seen ~= version and S:GetOption("Sempre", "news") then
		pending = true
	end
end)

local entered
S:On("PLAYER_ENTERING_WORLD", function()
	if entered then return end
	entered = true
	if not pending then return end
	if C_Timer and C_Timer.After then
		C_Timer.After(OPEN_DELAY, tryOpen)
	else
		tryOpen()
	end
end)

S.commands.neu = function() S:ShowNews() end
S.commands.news = S.commands.neu
