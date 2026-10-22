-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Sempre_Rares: rare detection, part 1. Forever has no vignettes, so rares are
-- noticed through units the client lets us read: nameplates, target and
-- mouseover. A new rare gives a chat line, a sound and a banner with a secure
-- click-to-target button, and is remembered in an account-wide list.
-- Unit values may be secret: every one is checked before it is compared,
-- stored or put into text.
--
-- Interface on SempreUI.Rares (read-only):
--   GetSeen(npcID)      -> copy of { name, level, class, last, places } or nil;
--                          places = list of { mapID, x, y, time }, newest first
--   GetSeenOnMap(mapID) -> list of { npcID, name, level, class, x, y, time }
-- Message RARE_SEEN(npcID) for every new sighting.
-- Data: SempreRaresDB = { version, seen = { [npcID] = { name, level, class,
-- last, places } } }. Only NPCs are stored, never players.

local ADDON_NAME = ...

local S = SempreUI
local type, pairs, ipairs, format, floor, abs, tonumber, pcall = type, pairs, ipairs, string.format, math.floor, math.abs, tonumber, pcall
local sort, tremove, tinsert = table.sort, table.remove, table.insert
local issecretvalue, InCombatLockdown, GetTime, time = issecretvalue, InCombatLockdown, GetTime, time
local CreateFrame, GetLocale = CreateFrame, GetLocale
local UnitClassification, UnitIsDead, UnitIsPlayer, UnitGUID, UnitName, UnitLevel = UnitClassification, UnitIsDead, UnitIsPlayer, UnitGUID, UnitName, UnitLevel
local C_Map, C_Sound, C_Timer, C_EventUtils = C_Map, C_Sound, C_Timer, C_EventUtils

local Rares = {}
S.Rares = Rares

local L = setmetatable({}, { __index = function(_, k) return k end })
Rares.L = L
if GetLocale() == "deDE" then
	L.ALERT = "Rare: %s (Stufe %s) bei %s"
	L.ALERT_NOPOS = "Rare: %s (Stufe %s)"
	L.CLICK = "Klicken zum Anvisieren"
	L.COMBAT_HINT = "Im Kampf: /tar %s"
	L.LEVEL = "Stufe %s"
	L.RARE = "Rar"
	L.RAREELITE = "Rar-Elite"
	L.NO_SOUND = "Rares: Der Ton ist in diesem Client nicht verfügbar."
	L.NAMEPLATE_HINT = "Rares: Es wurden noch keine Namensplatten gesehen. Schalte die Namensplatten für Gegner in den Spieleinstellungen ein, dann bemerkt das Modul Rares."
	L.HEADER = "Zuletzt gesehene Rares:"
	L.HEADER_HERE = "Rares auf dieser Karte:"
	L.NONE = "Rares: Noch keine gesehen."
	L.NONE_HERE = "Rares: Auf dieser Karte wurde noch keine gesehen."
	L.NO_MAP = "Rares: Die aktuelle Karte ist nicht lesbar."
	L.FORGOTTEN = "Rares: Liste geleert."
	L.USAGE = "Benutzung: |cffc8794a/sempre rares|r, |cffc8794a/sempre rares hier|r, |cffc8794a/sempre rares vergessen|r."
	L.ROW = "%s (Stufe %s), %s, %s"
	L.ROW_HERE = "%s (Stufe %s) bei %s, %s"
	L.JUST_NOW = "gerade eben"
	L.MINUTES = "vor %d Min."
	L.HOURS = "vor %d Std."
	L.DAYS = "vor %d Tagen"
	L.MAP = "Karte %d"
	L.UNKNOWN_ZONE = "unbekanntes Gebiet"
else
	L.ALERT = "Rare: %s (level %s) at %s"
	L.ALERT_NOPOS = "Rare: %s (level %s)"
	L.CLICK = "Click to target"
	L.COMBAT_HINT = "In combat: /tar %s"
	L.LEVEL = "Level %s"
	L.RARE = "Rare"
	L.RAREELITE = "Rare Elite"
	L.NO_SOUND = "Rares: the sound is not available in this client."
	L.NAMEPLATE_HINT = "Rares: no nameplates have been seen yet. Turn on enemy nameplates in the game settings and the module will notice rares."
	L.HEADER = "Rares seen last:"
	L.HEADER_HERE = "Rares on this map:"
	L.NONE = "Rares: none seen yet."
	L.NONE_HERE = "Rares: none seen on this map yet."
	L.NO_MAP = "Rares: the current map is not readable."
	L.FORGOTTEN = "Rares: list cleared."
	L.USAGE = "Usage: |cffc8794a/sempre rares|r, |cffc8794a/sempre rares here|r, |cffc8794a/sempre rares forget|r."
	L.ROW = "%s (level %s), %s, %s"
	L.ROW_HERE = "%s (level %s) at %s, %s"
	L.JUST_NOW = "just now"
	L.MINUTES = "%d min ago"
	L.HOURS = "%d h ago"
	L.DAYS = "%d days ago"
	L.MAP = "Map %d"
	L.UNKNOWN_ZONE = "unknown zone"
end

local GUID_TTL = 300 -- seconds, same GUID
local NPC_TTL = 60 -- seconds, same NPC ID
local BANNER_SECONDS = 15
local FADE_SECONDS = 1
local NAMEPLATE_WAIT = 300
local MAX_NPCS = 500
local MAX_PLACES = 10
local NEAR = 0.02 -- same place within 2 % of the map
local LIST_LINES = 10
local SOUND_FALLBACK = 8959 -- raid warning sound kit, used when SOUNDKIT is missing
local PLAIN = "Interface\\Buttons\\WHITE8X8"

local db
local seenGUID, seenNPC = {}, {} -- throttles, session only
local guidCount, npcCount = 0, 0
local npcTotal = 0
local nameplateSeen = false
local soundAvailable = C_Sound and C_Sound.PlaySound and true or false

-- Helpers

local function clean(v)
	if issecretvalue and issecretvalue(v) then return nil end
	return v
end

local function isNum(v)
	v = clean(v)
	return type(v) == "number" and v == v
end

local function parseGUID(guid)
	local kind, id = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
	id = tonumber(id)
	if id and (kind == "Creature" or kind == "Vehicle") then return id end
end

local function levelText(level)
	if not isNum(level) then return "?" end
	if level < 0 then return "??" end
	return tostring(level)
end

local function round1(v) return floor(v * 1000 + 0.5) / 1000 end

local function coords(x, y) return format("%.1f, %.1f", x * 100, y * 100) end

local function ago(t)
	local d = time() - (t or 0)
	if d < 60 then return L.JUST_NOW end
	if d < 3600 then return format(L.MINUTES, floor(d / 60)) end
	if d < 86400 then return format(L.HOURS, floor(d / 3600)) end
	return format(L.DAYS, floor(d / 86400))
end

local function mapName(id)
	local info = C_Map and C_Map.GetMapInfo and isNum(id) and C_Map.GetMapInfo(id)
	local name = type(info) == "table" and clean(info.name)
	if type(name) == "string" and name ~= "" then return name end
	return isNum(id) and format(L.MAP, id) or L.UNKNOWN_ZONE
end

-- The player's map and position, rounded; nil where unreadable (instances).
local function playerPlace()
	if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then return end
	local map = clean(C_Map.GetBestMapForUnit("player"))
	if not isNum(map) then return end
	local pos = C_Map.GetPlayerMapPosition(map, "player")
	if type(pos) ~= "table" or not pos.GetXY then return map end
	local x, y = pos:GetXY()
	if isNum(x) and isNum(y) and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
		return map, round1(x), round1(y)
	end
	return map
end

local function playerMap()
	local map = C_Map and C_Map.GetBestMapForUnit and clean(C_Map.GetBestMapForUnit("player"))
	if isNum(map) then return map end
end

-- Seen list

local function copyEntry(npcID, e)
	local places = {}
	for i, p in ipairs(e.places) do places[i] = { mapID = p.mapID, x = p.x, y = p.y, time = p.time } end
	return { npcID = npcID, name = e.name, level = e.level, class = e.class, last = e.last, places = places }
end

function Rares.GetSeen(npcID)
	local e = db and db.seen[npcID]
	if e then return copyEntry(npcID, e) end
end

function Rares.GetSeenOnMap(mapID)
	local out = {}
	if not db then return out end
	for npcID, e in pairs(db.seen) do
		for _, p in ipairs(e.places) do
			if p.mapID == mapID then
				out[#out + 1] = { npcID = npcID, name = e.name, level = e.level, class = e.class, x = p.x, y = p.y, time = p.time }
			end
		end
	end
	sort(out, function(a, b)
		if a.time ~= b.time then return a.time > b.time end
		return a.npcID < b.npcID
	end)
	return out
end

local function dropOldest()
	local oldest, oldestTime
	for npcID, e in pairs(db.seen) do
		if not oldestTime or e.last < oldestTime then oldest, oldestTime = npcID, e.last end
	end
	if oldest then
		db.seen[oldest] = nil
		npcTotal = npcTotal - 1
	end
end

local function addPlace(e, map, x, y, now)
	if not (map and x and y) then return end
	for i, p in ipairs(e.places) do
		if p.mapID == map and abs(p.x - x) <= NEAR and abs(p.y - y) <= NEAR then
			tremove(e.places, i)
			break
		end
	end
	tinsert(e.places, 1, { mapID = map, x = x, y = y, time = now })
	while #e.places > MAX_PLACES do e.places[#e.places] = nil end
end

local function remember(npcID, name, level, class, map, x, y)
	local now = time()
	local e = db.seen[npcID]
	if not e then
		e = { places = {} }
		db.seen[npcID] = e
		npcTotal = npcTotal + 1
	end
	e.name, e.level, e.class, e.last = name, level, class, now
	addPlace(e, map, x, y, now)
	while npcTotal > MAX_NPCS do dropOldest() end
end

-- Alerts

local function playSound()
	if not soundAvailable then return end
	local kit = SOUNDKIT and clean(SOUNDKIT.RAID_WARNING) or SOUND_FALLBACK
	pcall(C_Sound.PlaySound, kit)
end

local banner, shield, secure
local current -- the rare the banner shows: { name, level, class }
local armedName -- name the secure button's macro holds
local elapsed, hovering = 0, false

local function classLabel(class)
	return class == "rareelite" and L.RAREELITE or L.RARE
end

local function macroName(name)
	return (name:gsub("[|\r\n]", ""))
end

local function updateShield()
	if not shield then return end
	if secure and current and armedName == current.name then shield:Hide() else shield:Show() end
end

-- Creates the secure click button; never in combat. Returns true when it exists.
local function ensureSecure()
	if secure then return true end
	if InCombatLockdown() or not banner then return false end
	secure = CreateFrame("Button", nil, banner, "SecureActionButtonTemplate")
	secure:SetAllPoints(banner)
	secure:SetFrameLevel(banner:GetFrameLevel() + 1)
	secure:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	secure:SetScript("OnEnter", function() hovering = true end)
	secure:SetScript("OnLeave", function() hovering = false end)
	secure:SetScript("PostClick", function(_, mouse) Rares.BannerClick(mouse) end)
	Rares.secure = secure
	return true
end

-- Sets the macro for the shown rare; only out of combat.
local function arm()
	if not (current and banner and banner:IsShown()) then return end
	if InCombatLockdown() or not ensureSecure() then return end
	secure:SetAttribute("type1", "macro")
	secure:SetAttribute("macrotext1", "/targetexact " .. macroName(current.name))
	armedName = current.name
	updateShield()
	banner.hint:SetText(L.CLICK)
end

function Rares.BannerClick(mouse)
	if mouse ~= "RightButton" then return end
	if IsShiftKeyDown and IsShiftKeyDown() and current then
		local way = S.Way
		local map, x, y = playerPlace()
		if way and way.Add and map and x and y then way.Add(map, x, y, current.name) end
		return
	end
	if banner then banner:Hide() end
end

local function build()
	banner = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
	banner:SetSize(320, 64)
	banner:SetPoint("TOP", UIParent, "TOP", 0, -120)
	banner:SetFrameStrata("HIGH")
	banner:SetClampedToScreen(true)
	if banner.SetBackdrop then
		banner:SetBackdrop({ bgFile = PLAIN, edgeFile = PLAIN, edgeSize = 1 })
		banner:SetBackdropColor(0.06, 0.06, 0.06, 0.92)
		banner:SetBackdropBorderColor(0.78, 0.47, 0.29, 1)
	end
	banner.title = banner:CreateFontString(nil, "OVERLAY")
	banner.title:SetPoint("TOP", banner, "TOP", 0, -8)
	banner.info = banner:CreateFontString(nil, "OVERLAY")
	banner.info:SetPoint("TOP", banner.title, "BOTTOM", 0, -3)
	banner.hint = banner:CreateFontString(nil, "OVERLAY")
	banner.hint:SetPoint("BOTTOM", banner, "BOTTOM", 0, 7)
	if S.SetFont then
		S:SetFont(banner.title, "title", 18)
		S:SetFont(banner.info, "text", 12)
		S:SetFont(banner.hint, "text", 11)
	end
	banner.title:SetTextColor(0.78, 0.47, 0.29)
	banner.info:SetTextColor(1, 1, 1)
	banner.hint:SetTextColor(0.7, 0.7, 0.7)

	shield = CreateFrame("Frame", nil, banner)
	shield:SetAllPoints(banner)
	shield:SetFrameLevel(banner:GetFrameLevel() + 3)
	shield:EnableMouse(true)
	shield:SetScript("OnEnter", function() hovering = true end)
	shield:SetScript("OnLeave", function() hovering = false end)
	shield:SetScript("OnMouseUp", function(_, mouse) Rares.BannerClick(mouse) end)

	banner:SetScript("OnUpdate", function(self, dt)
		if hovering then
			self:SetAlpha(1)
			return
		end
		elapsed = elapsed + (dt or 0)
		local left = BANNER_SECONDS - elapsed
		if left <= 0 then
			self:Hide()
		elseif left < FADE_SECONDS then
			self:SetAlpha(left / FADE_SECONDS)
		else
			self:SetAlpha(1)
		end
	end)
	banner:SetScript("OnHide", function() hovering = false end)
	banner:Hide()
	Rares.banner, Rares.shield = banner, shield
end

local function showBanner(rare)
	if not banner then build() end
	current = rare
	elapsed, hovering = 0, false
	banner:SetAlpha(1)
	banner.title:SetText(rare.name)
	banner.info:SetText(format("%s  %s", format(L.LEVEL, levelText(rare.level)), classLabel(rare.class)))
	banner:Show()
	if not InCombatLockdown() and ensureSecure() then
		arm()
	elseif secure and armedName == rare.name then
		banner.hint:SetText(L.CLICK)
	else
		banner.hint:SetText(format(L.COMBAT_HINT, rare.name))
	end
	updateShield()
end

local function afterCombat()
	if not banner then return end
	if ensureSecure() and banner:IsShown() then arm() end
end

local function alert(rare, map, x, y)
	if not S:GetOption(ADDON_NAME, "announce") then return end
	if map and x and y then
		S:Print(L.ALERT, rare.name, levelText(rare.level), coords(x, y))
	else
		S:Print(L.ALERT_NOPOS, rare.name, levelText(rare.level))
	end
	if S:GetOption(ADDON_NAME, "sound") then playSound() end
	if S:GetOption(ADDON_NAME, "banner") then showBanner(rare) end
end

-- Detection

local function prune(set, ttl, now)
	local n = 0
	for k, t in pairs(set) do
		if now - t >= ttl then set[k] = nil else n = n + 1 end
	end
	return n
end

local function check(unit)
	if not db or type(clean(unit)) ~= "string" then return end
	local class = clean(UnitClassification(unit))
	if class ~= "rare" and class ~= "rareelite" then return end
	if clean(UnitIsPlayer and UnitIsPlayer(unit)) == true then return end
	if clean(UnitIsDead(unit)) == true then return end
	local guid = clean(UnitGUID(unit))
	if type(guid) ~= "string" then return end
	local npcID = parseGUID(guid)
	if not npcID then return end
	local name = clean(UnitName(unit))
	if type(name) ~= "string" or name == "" then return end
	local level = clean(UnitLevel(unit))
	if not isNum(level) then level = nil end

	local now = GetTime()
	local g, n = seenGUID[guid], seenNPC[npcID]
	if (g and now - g < GUID_TTL) or (n and now - n < NPC_TTL) then return end
	seenGUID[guid], seenNPC[npcID] = now, now
	guidCount, npcCount = guidCount + 1, npcCount + 1
	if guidCount > 100 then guidCount = prune(seenGUID, GUID_TTL, now) end
	if npcCount > 100 then npcCount = prune(seenNPC, NPC_TTL, now) end

	local map, x, y = playerPlace()
	remember(npcID, name, level, class, map, x, y)
	alert({ npcID = npcID, name = name, level = level, class = class }, map, x, y)
	S:Send("RARE_SEEN", npcID)
end

-- Commands

local function sortedByLast()
	local list = {}
	for npcID, e in pairs(db.seen) do list[#list + 1] = { npcID = npcID, e = e } end
	sort(list, function(a, b)
		if a.e.last ~= b.e.last then return a.e.last > b.e.last end
		return a.npcID < b.npcID
	end)
	return list
end

local function printRecent()
	local list = sortedByLast()
	if #list == 0 then
		S:Print(L.NONE)
		return
	end
	S:Print(L.HEADER)
	for i = 1, math.min(LIST_LINES, #list) do
		local e = list[i].e
		local p = e.places[1]
		print(format(L.ROW, e.name, levelText(e.level), p and mapName(p.mapID) or L.UNKNOWN_ZONE, ago(e.last)))
	end
end

local function printHere()
	local map = playerMap()
	if not map then
		S:Print(L.NO_MAP)
		return
	end
	local list = Rares.GetSeenOnMap(map)
	if #list == 0 then
		S:Print(L.NONE_HERE)
		return
	end
	S:Print(L.HEADER_HERE)
	for _, r in ipairs(list) do
		print(format(L.ROW_HERE, r.name, levelText(r.level), coords(r.x, r.y), ago(r.time)))
	end
end

local function command(input)
	if not db then return end
	local sub = (input or ""):match("^%s*(%S*)"):lower()
	if sub == "" then
		printRecent()
	elseif sub == "hier" or sub == "here" then
		printHere()
	elseif sub == "vergessen" or sub == "forget" then
		db.seen = {}
		npcTotal = 0
		S:Print(L.FORGOTTEN)
	else
		S:Print(L.USAGE)
	end
end
S.commands.rares = command

-- Setup

local function onLoaded(_, name)
	if name ~= ADDON_NAME then return end
	S:Off("ADDON_LOADED", onLoaded)
	SempreRaresDB = SempreRaresDB or {}
	db = SempreRaresDB
	db.version = db.version or 1
	if type(db.seen) ~= "table" then db.seen = {} end
	npcTotal = 0
	for npcID, e in pairs(db.seen) do
		if type(npcID) ~= "number" or type(e) ~= "table" or type(e.name) ~= "string" or not isNum(e.last) then
			db.seen[npcID] = nil
		else
			if type(e.places) ~= "table" then e.places = {} end
			npcTotal = npcTotal + 1
		end
	end

	S:RegisterOptions(ADDON_NAME, {
		{
			key = "announce", default = true,
			label = { de = "Rares melden", en = "Announce rares" },
			tooltip = { de = "Aus: Rares werden nur still in der Liste vermerkt, ohne Chatzeile, Ton oder Banner.", en = "Off: rares are only noted in the list quietly, with no chat line, sound or banner." },
		},
		{
			key = "sound", default = true,
			label = { de = "Ton bei Rares", en = "Sound for rares" },
			tooltip = { de = "Spielt einen Ton, wenn ein neues Rare gesehen wird.", en = "Plays a sound when a new rare is seen." },
			disabled = function() if not soundAvailable then return L.NO_SOUND end end,
		},
		{
			key = "banner", default = true,
			label = { de = "Banner zeigen", en = "Show the banner" },
			tooltip = { de = "Zeigt oben am Bildschirm ein Banner, das mit einem Klick das Rare anvisiert.", en = "Shows a banner at the top of the screen that targets the rare with one click." },
		},
	})
	if not soundAvailable then S:Print(L.NO_SOUND) end

	-- High-frequency nameplate event on the module's own frame.
	local frame = CreateFrame("Frame")
	frame:SetScript("OnEvent", function(_, _, unit)
		nameplateSeen = true
		check(unit)
	end)
	if not (C_EventUtils and C_EventUtils.IsEventValid and not C_EventUtils.IsEventValid("NAME_PLATE_UNIT_ADDED")) then
		pcall(frame.RegisterEvent, frame, "NAME_PLATE_UNIT_ADDED")
	end
	Rares.frame = frame

	S:On("PLAYER_TARGET_CHANGED", function() check("target") end)
	S:On("UPDATE_MOUSEOVER_UNIT", function() check("mouseover") end)
	S:On("PLAYER_REGEN_ENABLED", afterCombat)

	if C_Timer and C_Timer.After then
		C_Timer.After(NAMEPLATE_WAIT, function()
			if not nameplateSeen then S:Print(L.NAMEPLATE_HINT) end
		end)
	end
end
S:On("ADDON_LOADED", onLoaded)
