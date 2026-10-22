-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Sempre_Way: waypoints, part 1. /way X Y [text] (also /way #mapID X Y and
-- /way <zone> X Y) keeps a short list of points per character. The active
-- point is set as the game's own user waypoint and super-tracked, so the game
-- draws the marker in the world and on the minimap. Own pins exist on the
-- world map only. Reaching a point (under 10 yards) removes it and activates
-- the next one.
--
-- Interface on SempreUI.Way (read-only except Add):
--   GetPoints()  -> list of copies { map, x, y, text, created } in order added
--   GetActive()  -> copy of the active point, its number; nil when none or
--                   when the player cleared the game's waypoint by hand
--   Add(mapID, x, y, text) -> point number, or nil (bad input or list full).
--                   x, y are 0 to 1. The new point becomes active only when
--                   no point is active.
-- Message WAY_CHANGED after each change of the list or the active point.
-- Data: SempreWayDB.chars[charKey] = { points = {...}, active = n, paused = bool }.

local ADDON_NAME = ...

local S = SempreUI
local ipairs, pairs, type, format, floor, sqrt, tonumber, tostring = ipairs, pairs, type, string.format, math.floor, math.sqrt, tonumber, tostring
local time, tremove = time, table.remove
local issecretvalue, InCombatLockdown = issecretvalue, InCombatLockdown
local IsShiftKeyDown, IsControlKeyDown, hooksecurefunc = IsShiftKeyDown, IsControlKeyDown, hooksecurefunc
local C_Map, C_SuperTrack, C_EventUtils = C_Map, C_SuperTrack, C_EventUtils
local CreateFrame, GetLocale = CreateFrame, GetLocale

local Way = {}
S.Way = Way

local L = setmetatable({}, { __index = function(_, k) return k end })
Way.L = L
if GetLocale() == "deDE" then
	L.USAGE = "Benutzung: |cffc8794a/way X Y [Text]|r, |cffc8794a/way #<KartenID> X Y [Text]|r, |cffc8794a/way <Zone> X Y [Text]|r, |cffc8794a/way weg <Nr>|alle|r, |cffc8794a/way naechster|r."
	L.BAD_COORDS = "Way: Koordinaten müssen zwischen 0 und 100 liegen."
	L.NO_POSITION = "Way: Deine Position ist hier nicht bekannt."
	L.UNKNOWN_MAP = "Way: Karte %s gibt es nicht."
	L.UNKNOWN_ZONE = "Way: Zone \"%s\" nicht gefunden."
	L.AMBIGUOUS_ZONE = "Way: \"%s\" ist nicht eindeutig: %s"
	L.FULL = "Way: Die Liste ist voll (%d Punkte)."
	L.ADDED = "Punkt %d gesetzt: %s"
	L.NONE = "Way: Keine Punkte."
	L.LIST_HEADER = "Wegpunkte:"
	L.REMOVED = "Way: Punkt %d entfernt."
	L.REMOVED_ALL = "Way: Alle Punkte entfernt."
	L.NO_SUCH = "Way: Punkt %s gibt es nicht."
	L.NEXT = "Way: Aktiv ist jetzt Punkt %d: %s"
	L.REACHED = "Erreicht: %s"
	L.NO_MARKER = "Way: Die Markierung des Spiels ist in diesem Client nicht verfügbar, die Liste und die Kartenpins funktionieren."
	L.CANNOT_SHOW = "Way: Das Spiel kann diesen Punkt hier nicht markieren, die Kartenpins zeigen ihn weiter."
	L.TAKEN = "Way: /way gehört schon einem anderen Addon. Nutze /sempre way mit denselben Argumenten."
	L.PIN_CLICK = "Linksklick: aktiv, Umschalt + Rechtsklick: entfernen"
	L.YARDS = "%d Yard"
else
	L.USAGE = "Usage: |cffc8794a/way X Y [text]|r, |cffc8794a/way #<mapID> X Y [text]|r, |cffc8794a/way <zone> X Y [text]|r, |cffc8794a/way remove <n>|all|r, |cffc8794a/way next|r."
	L.BAD_COORDS = "Way: coordinates must be between 0 and 100."
	L.NO_POSITION = "Way: your position is not known here."
	L.UNKNOWN_MAP = "Way: map %s does not exist."
	L.UNKNOWN_ZONE = "Way: zone \"%s\" not found."
	L.AMBIGUOUS_ZONE = "Way: \"%s\" is ambiguous: %s"
	L.FULL = "Way: the list is full (%d points)."
	L.ADDED = "Point %d set: %s"
	L.NONE = "Way: no points."
	L.LIST_HEADER = "Waypoints:"
	L.REMOVED = "Way: point %d removed."
	L.REMOVED_ALL = "Way: all points removed."
	L.NO_SUCH = "Way: there is no point %s."
	L.NEXT = "Way: point %d is now active: %s"
	L.REACHED = "Reached: %s"
	L.NO_MARKER = "Way: the game's marker is not available in this client, the list and the map pins still work."
	L.CANNOT_SHOW = "Way: the game cannot mark this point here, the map pins still show it."
	L.TAKEN = "Way: /way belongs to another addon already. Use /sempre way with the same arguments."
	L.PIN_CLICK = "Left click: make active, Shift + right click: remove"
	L.YARDS = "%d yd"
end

local MAX_POINTS = 50
local MAX_TEXT = 60
local MAX_AGE = 30 * 86400
local ARRIVE_YARDS = 10
local CHECK_EVERY = 0.5
local PIN_SIZE = 14
local COSMIC_MAP = 946 -- root of the map tree; assumption, see the report
local MAX_CANDIDATES = 5
local DEPTH_LIMIT = 12

local char -- SempreWayDB.chars[charKey]
local lastSet -- { map, x, y } as last handed to the game, nil when none is ours
local saidNoMarker, saidCannot, saidTaken = false, false, false
local registered = false
local driver

-- Helpers

local function clean(v)
	if issecretvalue and issecretvalue(v) then return nil end
	return v
end

local function isNum(v)
	v = clean(v)
	return type(v) == "number" and v == v
end

local function vec(x, y)
	if CreateVector2D then return CreateVector2D(x, y) end
	return { x = x, y = y, GetXY = function(self) return self.x, self.y end }
end

-- Both values or nil; secret or non-numeric values count as unreadable.
local function xy(v)
	if type(v) ~= "table" or not v.GetXY then return end
	local x, y = v:GetXY()
	if isNum(x) and isNum(y) then return x, y end
end

local function mapInfo(id)
	if not (C_Map and C_Map.GetMapInfo and isNum(id)) then return end
	return C_Map.GetMapInfo(id)
end

local function mapName(id)
	local info = mapInfo(id)
	return info and info.name or ("#" .. tostring(id))
end

-- Cuts at a character border so a multi-byte letter is never split.
local function clip(text)
	text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if #text <= MAX_TEXT then return text end
	local cut = MAX_TEXT
	local b = text:byte(cut + 1)
	while b and b >= 128 and b < 192 and cut > 0 do
		cut = cut - 1
		b = text:byte(cut + 1)
	end
	return text:sub(1, cut)
end

local function coordText(x, y)
	return format("%.1f, %.1f", x * 100, y * 100)
end

local function onOptional(event, fn)
	if C_EventUtils and C_EventUtils.IsEventValid and not C_EventUtils.IsEventValid(event) then return end
	S:On(event, fn)
end

-- World positions. Assumption: C_Map.GetWorldPosFromMapPos(mapID, vector)
-- returns the continent ID and a vector (GetXY) in yards;
-- C_Map.GetMapPosFromWorldPos(continentID, worldVector, mapID) returns the map
-- ID and a vector with 0 to 1 coordinates. Anything missing gives nil.

local function worldPos(map, x, y)
	if not (C_Map and C_Map.GetWorldPosFromMapPos and isNum(map)) then return end
	local ok, continent, pos = pcall(C_Map.GetWorldPosFromMapPos, map, vec(x, y))
	if not ok or not isNum(continent) then return end
	local wx, wy = xy(pos)
	if wx then return continent, wx, wy end
end

local function mapPosFromWorld(continent, wx, wy, map)
	if not (C_Map and C_Map.GetMapPosFromWorldPos) then return end
	local ok, _, pos = pcall(C_Map.GetMapPosFromWorldPos, continent, vec(wx, wy), map)
	if not ok then return end
	return xy(pos)
end

-- Moves a position from one map to another through world coordinates.
local function translate(fromMap, x, y, toMap)
	if fromMap == toMap then return x, y end
	local continent, wx, wy = worldPos(fromMap, x, y)
	if not continent then return end
	return mapPosFromWorld(continent, wx, wy, toMap)
end

-- The player's world position: continent, x, y; nil where unreadable.
local function playerWorld()
	if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then return end
	local map = clean(C_Map.GetBestMapForUnit("player"))
	if not isNum(map) then return end
	local x, y = xy(C_Map.GetPlayerMapPosition(map, "player"))
	if not x then return end
	return worldPos(map, x, y)
end

local function parentOf(id)
	local info = mapInfo(id)
	local parent = info and info.parentMapID
	if isNum(parent) and parent > 0 then return parent end
end

local function isDescendant(map, ancestor)
	local cur = map
	for _ = 1, DEPTH_LIMIT do
		cur = parentOf(cur)
		if not cur then return false end
		if cur == ancestor then return true end
	end
	return false
end

-- Straight-line yards from the player to a point, nil when unknown or when the
-- two are on different continents.
local function distance(p)
	local pc, px, py = playerWorld()
	if not pc then return end
	local c, x, y = worldPos(p.map, p.x, p.y)
	if c ~= pc then return end
	local dx, dy = px - x, py - y
	return sqrt(dx * dx + dy * dy)
end
Way.Distance = distance

-- Points

local function points()
	return char and char.points or {}
end

local function copy(p)
	return { map = p.map, x = p.x, y = p.y, text = p.text, created = p.created }
end

function Way.GetPoints()
	local out = {}
	for i, p in ipairs(points()) do out[i] = copy(p) end
	return out
end

local function activeIndex()
	if char and char.active and not char.paused and points()[char.active] then return char.active end
end

function Way.GetActive()
	local i = activeIndex()
	if i then return copy(points()[i]), i end
end

local function changed()
	S:Send("WAY_CHANGED")
end

-- The game's waypoint

local function hasMarkerApi()
	return C_Map and C_Map.SetUserWaypoint and C_Map.ClearUserWaypoint and C_Map.GetUserWaypoint
		and C_Map.CanSetUserWaypointOnMap and C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint
end

local function sayNoMarker()
	if not saidNoMarker then
		saidNoMarker = true
		S:Print(L.NO_MARKER)
	end
end

-- The first map, from the point's own map up the tree, that takes a user
-- waypoint; its position is translated through world coordinates.
local function settable(p)
	local map, x, y = p.map, p.x, p.y
	for _ = 1, DEPTH_LIMIT do
		if C_Map.CanSetUserWaypointOnMap(map) then return map, x, y end
		local parent = parentOf(map)
		if not parent then return end
		local nx, ny = translate(map, x, y, parent)
		if not nx then return end
		map, x, y = parent, nx, ny
	end
end

local function clearMarker()
	if lastSet and hasMarkerApi() then
		C_Map.ClearUserWaypoint()
		C_SuperTrack.SetSuperTrackedUserWaypoint(false)
	end
	lastSet = nil
end

local function setMarker(p)
	if not hasMarkerApi() then
		sayNoMarker()
		return
	end
	local map, x, y = settable(p)
	if not map then
		lastSet = nil
		if not saidCannot then
			saidCannot = true
			S:Print(L.CANNOT_SHOW)
		end
		return
	end
	local point
	if UiMapPoint and UiMapPoint.CreateFromVector2D then
		point = UiMapPoint.CreateFromVector2D(map, vec(x, y))
	else
		point = { uiMapID = map, position = vec(x, y) }
	end
	C_Map.SetUserWaypoint(point)
	lastSet = { map = map, x = x, y = y }
	C_SuperTrack.SetSuperTrackedUserWaypoint(true)
end

-- Called when the game reports a change of its waypoint or of the tracking:
-- a cleared or replaced waypoint means the player took over, so our point
-- stays in the list but stops being tracked.
local function checkManual()
	if not (lastSet and char and char.active and not char.paused and hasMarkerApi()) then return end
	local mine
	if C_Map.HasUserWaypoint and not C_Map.HasUserWaypoint() then
		mine = false
	else
		local wp = C_Map.GetUserWaypoint()
		local x, y
		if wp then x, y = xy(wp.position) end
		mine = wp ~= nil and wp.uiMapID == lastSet.map and x ~= nil
			and math.abs(x - lastSet.x) < 0.0005 and math.abs(y - lastSet.y) < 0.0005
	end
	if not mine then
		lastSet = nil
		char.paused = true
		if driver then driver:Hide() end
		changed()
	end
end

-- The arrival check frame: no work while nothing is active or in combat.
local function refreshDriver()
	if not driver then return end
	if activeIndex() and not InCombatLockdown() then
		driver:Show()
	else
		driver:Hide()
	end
end

local function setActive(n, quiet)
	local p = points()[n]
	if not p then return false end
	char.active, char.paused = n, false
	setMarker(p)
	refreshDriver()
	if not quiet then changed() end
	return true
end

local function deactivate()
	clearMarker()
	if char then char.active, char.paused = nil, nil end
	refreshDriver()
end

-- Removes point n. When it was the active one, the point that moves into its
-- place becomes active if wantNext, else nothing is active.
local function removePoint(n, wantNext)
	local list = points()
	if not list[n] then return false end
	local wasActive = char.active == n
	tremove(list, n)
	if wasActive then
		deactivate()
		if wantNext and list[n] then setActive(n, true) end
	elseif char.active and char.active > n then
		char.active = char.active - 1
	end
	changed()
	return true
end

local function insertPoint(map, x, y, text, activate)
	if not (char and isNum(map) and isNum(x) and isNum(y) and x >= 0 and x <= 1 and y >= 0 and y <= 1) then return end
	local list = char.points
	if #list >= MAX_POINTS then return end
	list[#list + 1] = { map = map, x = x, y = y, text = clip(text), created = time() }
	local n = #list
	if activate or not activeIndex() then
		setActive(n, true)
	end
	changed()
	return n
end

function Way.Add(map, x, y, text)
	return insertPoint(map, x, y, text, false)
end

local function nextPoint()
	local list = points()
	if #list == 0 then
		S:Print(L.NONE)
		return
	end
	local n = (char.active or 0) + 1
	if n > #list then n = 1 end
	setActive(n)
	S:Print(L.NEXT, n, list[n].text)
end

-- Arrival

local function arrive()
	local i = activeIndex()
	if not i then return end
	local p = points()[i]
	local d = distance(p)
	if not d or d >= ARRIVE_YARDS then return end
	S:Print(L.REACHED, p.text ~= "" and p.text or mapName(p.map))
	removePoint(i, S:GetOption(ADDON_NAME, "auto_next"))
end

local accumulated = 0

local function onDriverUpdate(_, elapsed)
	accumulated = accumulated + (elapsed or 0)
	if accumulated < CHECK_EVERY then return end
	accumulated = 0
	if InCombatLockdown() then return end
	arrive()
end

-- Zone names. Assumption: C_Map.GetMapChildrenInfo(mapID, mapType, allDescendants)
-- returns a list of map info tables; Enum.UIMapType has Continent and Zone.

local function continentOf(map)
	local cur = map
	for _ = 1, DEPTH_LIMIT do
		local info = mapInfo(cur)
		if not info then return end
		if Enum and Enum.UIMapType and info.mapType == Enum.UIMapType.Continent then return cur end
		cur = parentOf(cur)
		if not cur then return end
	end
end

local function zonesUnder(root, out)
	if not (C_Map and C_Map.GetMapChildrenInfo and Enum and Enum.UIMapType and root) then return out end
	local list = C_Map.GetMapChildrenInfo(root, Enum.UIMapType.Zone, true)
	for _, info in ipairs(list or {}) do out[#out + 1] = info end
	return out
end

local function continentList()
	local out = {}
	if C_Map and C_Map.GetMapChildrenInfo and Enum and Enum.UIMapType then
		for _, info in ipairs(C_Map.GetMapChildrenInfo(COSMIC_MAP, Enum.UIMapType.Continent, true) or {}) do
			out[#out + 1] = info.mapID
		end
	end
	return out
end

-- Exact matches first, else prefix matches.
local function matchName(zones, name)
	local lower = name:lower()
	local exact, prefix = {}, {}
	for _, info in ipairs(zones) do
		local n = (info.name or ""):lower()
		if n == lower then
			exact[#exact + 1] = info
		elseif n:sub(1, #lower) == lower then
			prefix[#prefix + 1] = info
		end
	end
	if #exact > 0 then return exact end
	return prefix
end

-- Returns the map ID, or nil and the list of candidates (empty when unknown).
local function resolveZone(name)
	local scopes = {}
	local best = C_Map and C_Map.GetBestMapForUnit and clean(C_Map.GetBestMapForUnit("player"))
	local mine = best and continentOf(best)
	if mine then scopes[1] = zonesUnder(mine, {}) end
	local all = {}
	for _, c in ipairs(continentList()) do zonesUnder(c, all) end
	scopes[#scopes + 1] = all
	for _, zones in ipairs(scopes) do
		local found = matchName(zones, name)
		if #found == 1 then return found[1].mapID end
		if #found > 1 then
			-- The same map can appear twice through different continents.
			local seen, unique = {}, {}
			for _, info in ipairs(found) do
				if not seen[info.mapID] then
					seen[info.mapID] = true
					unique[#unique + 1] = info
				end
			end
			if #unique == 1 then return unique[1].mapID end
			return nil, unique
		end
	end
	return nil, {}
end

-- Command

local function number(token)
	token = token:gsub(",$", ""):gsub(",", ".")
	if token:match("^%d+%.?%d*$") or token:match("^%.%d+$") then return tonumber(token) end
end

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function listPoints()
	local list = points()
	if #list == 0 then
		S:Print(L.NONE)
		return
	end
	S:Print(L.LIST_HEADER)
	local active = activeIndex()
	for i, p in ipairs(list) do
		local d = distance(p)
		local line = format("  %s%d. %s, %s %s", i == active and "|cffc8794a*|r " or "", i,
			p.text ~= "" and p.text or "-", mapName(p.map), coordText(p.x, p.y))
		if d then line = line .. ", " .. format(L.YARDS, floor(d + 0.5)) end
		print(line)
	end
end

local function removeCommand(arg)
	arg = trim(arg):lower()
	if arg == "alle" or arg == "all" then
		local list = points()
		for i = #list, 1, -1 do list[i] = nil end
		deactivate()
		changed()
		S:Print(L.REMOVED_ALL)
		return
	end
	local n = number(arg)
	if n and n == floor(n) and removePoint(n, S:GetOption(ADDON_NAME, "auto_next")) then
		S:Print(L.REMOVED, n)
	else
		S:Print(L.NO_SUCH, arg == "" and "?" or arg)
	end
end

local function addCommand(input)
	local tokens = {}
	for t in input:gmatch("%S+") do tokens[#tokens + 1] = t end
	local mapID
	local id = tokens[1]:match("^#(%d+)$")
	local nameWords
	local x, y, textFrom
	if id then
		mapID = tonumber(id)
		x, y = number(tokens[2] or ""), number(tokens[3] or "")
		textFrom = 4
	else
		for j = 1, #tokens - 1 do
			local a, b = number(tokens[j]), number(tokens[j + 1])
			if a and b then
				x, y, textFrom = a, b, j + 2
				if j > 1 then nameWords = table.concat(tokens, " ", 1, j - 1) end
				break
			end
		end
	end
	if not x or not y then
		S:Print(L.USAGE)
		return
	end
	if x > 100 or y > 100 then
		S:Print(L.BAD_COORDS)
		return
	end
	local text = table.concat(tokens, " ", textFrom)
	if nameWords then
		local found, candidates = resolveZone(nameWords)
		if not found then
			if #candidates == 0 then
				S:Print(L.UNKNOWN_ZONE, nameWords)
			else
				local names = {}
				for i = 1, math.min(MAX_CANDIDATES, #candidates) do names[i] = candidates[i].name end
				S:Print(L.AMBIGUOUS_ZONE, nameWords, table.concat(names, ", "))
			end
			return
		end
		mapID = found
	elseif mapID then
		if not mapInfo(mapID) then
			S:Print(L.UNKNOWN_MAP, "#" .. mapID)
			return
		end
	else
		mapID = C_Map and C_Map.GetBestMapForUnit and clean(C_Map.GetBestMapForUnit("player"))
		if not isNum(mapID) then
			S:Print(L.NO_POSITION)
			return
		end
	end
	if text == "" then text = mapName(mapID) end
	if #points() >= MAX_POINTS then
		S:Print(L.FULL, MAX_POINTS)
		return
	end
	local n = insertPoint(mapID, x / 100, y / 100, text, true)
	if n then S:Print(L.ADDED, n, points()[n].text) end
end

local function command(input)
	input = trim(input or "")
	if not char then return end
	if input == "" then
		listPoints()
		return
	end
	local word, rest = input:match("^(%S+)%s*(.-)$")
	word = word:lower()
	if word == "weg" or word == "remove" then
		removeCommand(rest)
	elseif word == "naechster" or word == "nächster" or word == "next" then
		nextPoint()
	else
		addCommand(input)
	end
end
Way.Command = command

-- /way is registered only when no other addon owns it. The slash tables are
-- global variables SLASH_<NAME><n> = "/word".
local function owner()
	for key, value in pairs(_G) do
		if type(key) == "string" and type(value) == "string" and value:lower() == "/way"
			and key:match("^SLASH_") and key ~= "SLASH_SEMPREWAY1" then
			return key
		end
	end
end

local function claimSlash()
	local taken = owner() ~= nil
	if taken then
		if registered then
			SLASH_SEMPREWAY1 = nil
			SlashCmdList.SEMPREWAY = nil
			registered = false
		end
		if not saidTaken then
			saidTaken = true
			S:Print(L.TAKEN)
		end
	elseif not registered then
		SLASH_SEMPREWAY1 = "/way"
		SlashCmdList.SEMPREWAY = command
		registered = true
	end
end

S.commands.way = command

-- World map pins. Own frames on the map's canvas, built when the map first
-- opens. Assumptions: WorldMapFrame:GetMapID(), :GetCanvas() and
-- :OnMapChanged() exist (the last is hooked), WorldMapFrame.ScrollContainer
-- has :GetNormalizedCursorPosition() (0 to 1 over the canvas, nil outside).

-- Points to draw for the shown map: { index, x, y } on that map.
function Way.GetPins(shown)
	local out = {}
	if not (isNum(shown) and char) then return out end
	for i, p in ipairs(points()) do
		if p.map == shown then
			out[#out + 1] = { index = i, x = p.x, y = p.y }
		elseif isDescendant(p.map, shown) then
			local x, y = translate(p.map, p.x, p.y, shown)
			if x and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
				out[#out + 1] = { index = i, x = x, y = y }
			end
		end
	end
	return out
end

local canvas
local pinFrames = {}

local function pinTooltip(self)
	local p = points()[self.index]
	if not (p and GameTooltip) then return end
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine(p.text ~= "" and p.text or mapName(p.map), 0.78, 0.47, 0.29)
	GameTooltip:AddLine(mapName(p.map) .. " " .. coordText(p.x, p.y), 1, 1, 1)
	local d = distance(p)
	if d then GameTooltip:AddLine(format(L.YARDS, floor(d + 0.5)), 0.8, 0.8, 0.8) end
	GameTooltip:AddLine(L.PIN_CLICK, 0.6, 0.6, 0.6)
	GameTooltip:Show()
end

-- Left click activates; right click removes only with Shift held.
function Way.PinClick(index, button, shift)
	if button == "LeftButton" then
		return setActive(index)
	elseif button == "RightButton" and shift then
		return removePoint(index, false)
	end
	return false
end

local function newPin()
	local pin = CreateFrame("Button", nil, canvas)
	pin:SetSize(PIN_SIZE, PIN_SIZE)
	pin.dot = pin:CreateTexture(nil, "OVERLAY")
	pin.dot:SetAllPoints()
	pin.dot:SetTexture("Interface\\Buttons\\WHITE8X8")
	if pin.CreateMaskTexture then
		local mask = pin:CreateMaskTexture()
		mask:SetAllPoints()
		mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
		pin.dot:AddMaskTexture(mask)
	end
	pin:RegisterForClicks("AnyUp")
	pin:SetScript("OnClick", function(self, button)
		Way.PinClick(self.index, button, IsShiftKeyDown and IsShiftKeyDown())
	end)
	pin:SetScript("OnEnter", pinTooltip)
	pin:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
	return pin
end

local function refreshPins()
	if not (canvas and WorldMapFrame and WorldMapFrame:IsShown()) then return end
	local list = Way.GetPins(WorldMapFrame:GetMapID())
	local w, h = canvas:GetWidth(), canvas:GetHeight()
	local active = activeIndex()
	for i, entry in ipairs(list) do
		local pin = pinFrames[i]
		if not pin then
			pin = newPin()
			pinFrames[i] = pin
		end
		pin.index = entry.index
		pin:ClearAllPoints()
		pin:SetPoint("CENTER", canvas, "TOPLEFT", entry.x * w, -entry.y * h)
		if entry.index == active then
			pin.dot:SetVertexColor(0.78, 0.47, 0.29, 1)
		else
			pin.dot:SetVertexColor(0.95, 0.82, 0.7, 0.9)
		end
		pin:Show()
	end
	for i = #list + 1, #pinFrames do
		pinFrames[i]:Hide()
	end
end
Way.RefreshPins = refreshPins

-- Ctrl + right click adds a point. The plain right click is left alone.
function Way.MapClick(button, ctrl, cx, cy)
	if button ~= "RightButton" or not ctrl or not char then return false end
	if not S:GetOption(ADDON_NAME, "click_add") then return false end
	if not (isNum(cx) and isNum(cy) and cx >= 0 and cx <= 1 and cy >= 0 and cy <= 1) then return false end
	local map = WorldMapFrame and WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()
	if not isNum(map) then return false end
	local n = insertPoint(map, cx, cy, mapName(map) .. " " .. coordText(cx, cy), true)
	if n then S:Print(L.ADDED, n, points()[n].text) end
	return n ~= nil
end

local mapHooked = false

local function hookMap()
	if mapHooked or not WorldMapFrame then return end
	mapHooked = true
	WorldMapFrame:HookScript("OnShow", function()
		if not canvas and WorldMapFrame.GetCanvas then canvas = WorldMapFrame:GetCanvas() end
		refreshPins()
	end)
	if type(WorldMapFrame.OnMapChanged) == "function" and hooksecurefunc then
		hooksecurefunc(WorldMapFrame, "OnMapChanged", refreshPins)
	end
	local container = WorldMapFrame.ScrollContainer
	if container and container.HookScript then
		container:HookScript("OnMouseUp", function(self, button)
			local cx, cy
			if self.GetNormalizedCursorPosition then cx, cy = self:GetNormalizedCursorPosition() end
			Way.MapClick(button, IsControlKeyDown and IsControlKeyDown(), cx, cy)
		end)
	end
end

-- Start

local function restore()
	local list = char.points
	local cutoff = time() - MAX_AGE
	local kept, newIndex = {}, {}
	for i, p in ipairs(list) do
		if type(p) == "table" and isNum(p.map) and isNum(p.x) and isNum(p.y) and isNum(p.created) and p.created >= cutoff then
			kept[#kept + 1] = p
			newIndex[i] = #kept
		end
	end
	char.points = kept
	char.active = char.active and newIndex[char.active] or nil
	if not char.active then char.paused = nil end
	if char.active and not char.paused then setActive(char.active, true) end
	refreshDriver()
end

local function login()
	SempreWayDB.chars[S.charKey] = SempreWayDB.chars[S.charKey] or { points = {} }
	char = SempreWayDB.chars[S.charKey]
	if type(char.points) ~= "table" then char.points = {} end
	restore()
	Way.char = char
end

local firstWorld = true

local function onLoaded(_, name)
	if name ~= ADDON_NAME then return end
	S:Off("ADDON_LOADED", onLoaded)
	SempreWayDB = SempreWayDB or {}
	SempreWayDB.version = SempreWayDB.version or 1
	SempreWayDB.chars = SempreWayDB.chars or {}

	S:RegisterOptions(ADDON_NAME, {
		{
			key = "auto_next", default = true,
			label = { de = "Nächsten Punkt automatisch aktivieren", en = "Activate the next point automatically" },
			tooltip = { de = "Nach dem Erreichen eines Punktes wird der nächste in der Liste aktiv.", en = "After you reach a point, the next one in the list becomes active." },
		},
		{
			key = "click_add", default = true,
			label = { de = "Strg+Rechtsklick auf der Karte setzt einen Punkt", en = "Ctrl + right click on the map adds a point" },
			tooltip = { de = "Strg + Rechtsklick auf die Weltkarte fügt dort einen Wegpunkt hinzu.", en = "Ctrl + right click on the world map adds a waypoint there." },
		},
	})

	driver = CreateFrame("Frame")
	driver:Hide()
	driver:SetScript("OnUpdate", onDriverUpdate)
	Way.driver = driver

	claimSlash()

	onOptional("PLAYER_ENTERING_WORLD", function()
		if firstWorld then
			firstWorld = false
			claimSlash()
		end
		-- The game may have dropped its waypoint over a loading screen.
		local i = activeIndex()
		if i and not (lastSet and C_Map and C_Map.HasUserWaypoint and C_Map.HasUserWaypoint()) then
			setActive(i, true)
		end
		refreshDriver()
		refreshPins()
	end)
	onOptional("ZONE_CHANGED_NEW_AREA", function() refreshPins() end)
	onOptional("USER_WAYPOINT_UPDATED", checkManual)
	onOptional("SUPER_TRACKING_CHANGED", checkManual)
	onOptional("PLAYER_REGEN_DISABLED", refreshDriver)
	onOptional("PLAYER_REGEN_ENABLED", refreshDriver)
	S:Listen("WAY_CHANGED", refreshPins)

	if WorldMapFrame then
		hookMap()
	else
		S:On("ADDON_LOADED", function(_, other)
			if other == "Blizzard_WorldMap" then hookMap() end
		end)
	end

	if S.charKey then
		login()
	else
		S:On("PLAYER_LOGIN", login)
	end
end
S:On("ADDON_LOADED", onLoaded)
