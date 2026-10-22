-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Sempre_Map: world map helpers, part 1. A level line for the shown zone, a
-- level label at the cursor over the zones of a continent map, a coordinate
-- bar at the bottom of the map, and areas that other characters of the account
-- have explored. Own frames only; nothing of the game's map frames is changed.
--
-- Data: SempreMapDB = { version, seq, seen = { [mapID] = n }, explored = {
--   [mapID] = { { w, h, x, y, top, ids = { fileDataID, ... } }, ... } } }.
-- Game data only, no player names.

local ADDON_NAME = ...

local S = SempreUI
local type, pairs, ipairs, format, tostring = type, pairs, ipairs, string.format, tostring
local ceil = math.ceil
local issecretvalue, hooksecurefunc = issecretvalue, hooksecurefunc
local C_Map, C_MapExplorationInfo = C_Map, C_MapExplorationInfo
local CreateFrame, GetLocale, UnitLevel = CreateFrame, GetLocale, UnitLevel

local Map = {}
S.Map = Map

local L = setmetatable({}, { __index = function(_, k) return k end })
Map.L = L
if GetLocale() == "deDE" then
	L.LEVEL = "Stufe %d–%d"
	L.LEVEL_ONE = "Stufe %d"
	L.NO_LEVELS = "Map: Für dieses Gebiet ist kein Stufenbereich bekannt."
	L.ZONE_LEVELS = "Map: %s, %s"
	L.STORED = "Map: Erkundung für %d Karten gespeichert."
	L.FORGOTTEN = "Map: Gespeicherte Erkundung gelöscht."
	L.NO_MAP = "Map: Deine Position ist hier nicht bekannt."
	L.NO_API = "Map: Dieser Client bietet die nötigen Kartenfunktionen nicht, der Teil ist abgeschaltet."
	L.NOT_AVAILABLE = "–"
else
	L.LEVEL = "Level %d–%d"
	L.LEVEL_ONE = "Level %d"
	L.NO_LEVELS = "Map: no level range is known for this zone."
	L.ZONE_LEVELS = "Map: %s, %s"
	L.STORED = "Map: exploration stored for %d maps."
	L.FORGOTTEN = "Map: stored exploration cleared."
	L.NO_MAP = "Map: your position is not known here."
	L.NO_API = "Map: this client lacks the map functions needed, that part is switched off."
	L.NOT_AVAILABLE = "–"
end

local TICK = 0.1
local MAX_MAPS = 400
local TILE = 256
local MIN_FILE = 16
local OVERLAY_ALPHA = 0.6
local BAR_HEIGHT = 18
local RANGE_GREY_ABOVE = 5 -- player more than this above the maximum: grey
local RANGE_YELLOW_BELOW = 2 -- minimum up to this above the player: yellow

local COLORS = {
	grey = { 0.62, 0.62, 0.62 },
	green = { 0.3, 0.85, 0.3 },
	yellow = { 1, 0.82, 0 },
	red = { 1, 0.25, 0.25 },
}

local ui -- frames, built the first time the map opens
local driver
local refreshExplored
local accumulated = 0
local mapHooked = false
local noApiSaid = false

-- Helpers

local function clean(v)
	if issecretvalue and issecretvalue(v) then return nil end
	return v
end

local function isNum(v)
	v = clean(v)
	return type(v) == "number" and v == v
end

local function xy(v)
	if type(v) ~= "table" or not v.GetXY then return end
	local x, y = v:GetXY()
	if isNum(x) and isNum(y) then return x, y end
end

local function inside(x, y)
	return isNum(x) and isNum(y) and x >= 0 and x <= 1 and y >= 0 and y <= 1
end

local function coordText(x, y)
	return format("%.1f, %.1f", x * 100, y * 100)
end

local function option(key)
	return S:GetOption(ADDON_NAME, key)
end

local function shownMap()
	if WorldMapFrame and WorldMapFrame.GetMapID then
		local id = WorldMapFrame:GetMapID()
		if isNum(id) then return id end
	end
end

local function mapIsShown()
	return WorldMapFrame ~= nil and WorldMapFrame:IsShown() and true or false
end

-- Level ranges. Assumption: C_Map.GetMapLevels(mapID) returns player minimum,
-- player maximum, pet minimum, pet maximum; 0, 0 or nil when there is none.

local function levelsOf(id)
	if not (C_Map and C_Map.GetMapLevels and isNum(id)) then return end
	local lo, hi = C_Map.GetMapLevels(id)
	if not (isNum(lo) and isNum(hi)) then return end
	if hi <= 0 or lo > hi then return end
	return lo, hi
end
Map.LevelsOf = levelsOf

-- Colour key by the player's level, like quest difficulty.
function Map.LevelColor(playerLevel, lo, hi)
	if playerLevel - hi > RANGE_GREY_ABOVE then return "grey" end
	if lo - playerLevel > RANGE_YELLOW_BELOW then return "red" end
	if lo > playerLevel then return "yellow" end
	return "green"
end

function Map.LevelText(lo, hi)
	if lo == hi then return format(L.LEVEL_ONE, lo) end
	return format(L.LEVEL, lo, hi)
end

local function playerLevel()
	local lvl = UnitLevel and UnitLevel("player")
	if isNum(lvl) then return lvl end
	return 1
end

-- Continent, world and cosmic maps get the hover label, not the level line.
local function isContinentLike(id)
	if not (C_Map and C_Map.GetMapInfo and Enum and Enum.UIMapType) then return false end
	local info = C_Map.GetMapInfo(id)
	local kind = info and info.mapType
	return kind == Enum.UIMapType.Continent or kind == Enum.UIMapType.World or kind == Enum.UIMapType.Cosmic
end

local function paint(fs, key, text)
	local c = COLORS[key]
	fs:SetTextColor(c[1], c[2], c[3])
	fs:SetText(text)
end

-- The level line under the map title.
local function refreshLevelLine()
	if not ui then return end
	local map = shownMap()
	local lo, hi
	if option("show_levels") and map and not isContinentLike(map) then lo, hi = levelsOf(map) end
	if lo then
		paint(ui.level, Map.LevelColor(playerLevel(), lo, hi), Map.LevelText(lo, hi))
		ui.levelFrame:Show()
	else
		ui.levelFrame:Hide()
	end
end

-- The label at the cursor over a zone of a continent map: zone name and range.
local function refreshHover(cx, cy)
	local label = ui.hover
	local map = shownMap()
	if not (option("show_levels") and map and inside(cx, cy) and isContinentLike(map)
		and C_Map.GetMapInfoAtPosition) then
		label:Hide()
		return
	end
	local info = C_Map.GetMapInfoAtPosition(map, cx, cy)
	local id = info and clean(info.mapID)
	local lo, hi
	if isNum(id) and id ~= map then lo, hi = levelsOf(id) end
	if not lo then
		label:Hide()
		return
	end
	local name = clean(info.name)
	paint(ui.hoverText, Map.LevelColor(playerLevel(), lo, hi),
		(type(name) == "string" and name or "") .. "  " .. Map.LevelText(lo, hi))
	label:ClearAllPoints()
	label:SetPoint("BOTTOMLEFT", ui.canvas, "TOPLEFT", cx * ui.canvas:GetWidth() + 14, -cy * ui.canvas:GetHeight() + 14)
	label:Show()
end

-- Coordinates. Assumption: C_Map.GetPlayerMapPosition(mapID, "player") gives a
-- vector (GetXY) or nil where the player is not on that map.

local function cursorPosition()
	local container = WorldMapFrame and WorldMapFrame.ScrollContainer
	if container and container.GetNormalizedCursorPosition then
		local cx, cy = container:GetNormalizedCursorPosition()
		if inside(cx, cy) then return cx, cy end
	end
end

local function playerPosition(map)
	if not (map and C_Map and C_Map.GetPlayerMapPosition) then return end
	local x, y = xy(C_Map.GetPlayerMapPosition(map, "player"))
	if x and inside(x, y) then return x, y end
end

local function refreshBar(cx, cy)
	if not option("show_coords") then
		ui.bar:Hide()
		return
	end
	ui.bar:Show()
	local px, py = playerPosition(shownMap())
	ui.player:SetText(px and coordText(px, py) or L.NOT_AVAILABLE)
	ui.cursor:SetText(cx and coordText(cx, cy) or L.NOT_AVAILABLE)
end

-- One pass of everything that follows the cursor and the player.
local function update()
	if not (ui and mapIsShown()) then return end
	local cx, cy = cursorPosition()
	refreshBar(cx, cy)
	refreshHover(cx, cy)
end
Map.Update = update

local function refresh()
	if not (ui and mapIsShown()) then return end
	refreshLevelLine()
	refreshExplored()
	update()
end
Map.Refresh = refresh

local function onDriverUpdate(_, elapsed)
	accumulated = accumulated + (elapsed or 0)
	if accumulated < TICK then return end
	accumulated = 0
	update()
end

-- Explored areas. Offsets and sizes are in canvas units. Assumption: C_MapExplorationInfo.GetExploredMapTextures(mapID)
-- returns a list of { textureWidth, textureHeight, offsetX, offsetY,
-- fileDataIDs, isDrawOnTopLayer, isShownByMouseOver }, empty or nil where the
-- map has no overlays.

local function db()
	return SempreMapDB
end

local function overlayKey(o)
	return tostring(o.x) .. ":" .. tostring(o.y) .. ":" .. tostring(o.ids[1])
end

-- A clean copy of one overlay, or nil when it is unusable or mouse-over only.
local function normalize(t)
	if type(t) ~= "table" or clean(t.isShownByMouseOver) then return end
	local w, h, x, y = clean(t.textureWidth), clean(t.textureHeight), clean(t.offsetX), clean(t.offsetY)
	local src = t.fileDataIDs
	if not (isNum(w) and isNum(h) and isNum(x) and isNum(y) and w > 0 and h > 0 and type(src) == "table") then return end
	local ids = {}
	for i, id in ipairs(src) do
		if not isNum(id) then return end
		ids[i] = id
	end
	if #ids == 0 then return end
	return { w = w, h = h, x = x, y = y, top = clean(t.isDrawOnTopLayer) and true or false, ids = ids }
end

-- What this character has explored on a map: overlays and a set of their keys.
local function readExplored(map)
	local list, keys = {}, {}
	if not (C_MapExplorationInfo and C_MapExplorationInfo.GetExploredMapTextures and isNum(map)) then return list, keys end
	for _, t in ipairs(C_MapExplorationInfo.GetExploredMapTextures(map) or {}) do
		local o = normalize(t)
		if o then
			list[#list + 1] = o
			keys[overlayKey(o)] = true
		end
	end
	return list, keys
end

local function storedCount()
	local n = 0
	for _ in pairs(db().explored) do n = n + 1 end
	return n
end

-- Drops the least recently seen maps until the cap holds; keep is never dropped.
local function enforceCap(keep)
	local data = db()
	while storedCount() > MAX_MAPS do
		local oldest, oldestSeen
		for id in pairs(data.explored) do
			local seen = data.seen[id] or 0
			if id ~= keep and (not oldestSeen or seen < oldestSeen) then oldest, oldestSeen = id, seen end
		end
		if not oldest then return end
		data.explored[oldest], data.seen[oldest] = nil, nil
	end
end

-- Merges this character's overlays into the account-wide store: one entry per
-- overlay, so nothing is stored twice.
function Map.Record(map, list)
	local data = db()
	if not (data and isNum(map)) then return end
	local stored = data.explored[map]
	if not stored and #list == 0 then return end
	if not stored then
		stored = {}
		data.explored[map] = stored
	end
	local have = {}
	for _, o in ipairs(stored) do have[overlayKey(o)] = true end
	for _, o in ipairs(list) do
		local key = overlayKey(o)
		if not have[key] then
			have[key] = true
			stored[#stored + 1] = o
		end
	end
	data.seq = (data.seq or 0) + 1
	data.seen[map] = data.seq
	enforceCap(map)
end

-- Overlays stored for a map that the list of keys does not contain.
function Map.Foreign(map, keys)
	local out = {}
	local stored = db() and db().explored[map]
	for _, o in ipairs(stored or {}) do
		if not keys[overlayKey(o)] then out[#out + 1] = o end
	end
	return out
end

-- Tile size of the first art layer of a map. Assumption:
-- C_Map.GetMapArtLayers(mapID) returns a list of layers with tileWidth and
-- tileHeight; 256 where the call is missing or returns nothing.
local function tileSize(map)
	if C_Map and C_Map.GetMapArtLayers and isNum(map) then
		local layers = C_Map.GetMapArtLayers(map)
		local layer = type(layers) == "table" and layers[1]
		if layer and isNum(layer.tileWidth) and isNum(layer.tileHeight) and layer.tileWidth > 0 and layer.tileHeight > 0 then
			return layer.tileWidth, layer.tileHeight
		end
	end
	return TILE, TILE
end
Map.TileSize = tileSize

-- Smallest power of two that is at least 16 and not below n.
local function fileSize(n)
	local size = MIN_FILE
	while size < n do size = size * 2 end
	return size
end

-- Pixels of tile i (0 based) of n along a length: the remainder in the last
-- one, a full tile when nothing remains.
local function pixels(length, tile, i, n)
	if i < n - 1 then return tile end
	local rest = length % tile
	return rest == 0 and tile or rest
end

-- Tiles of one overlay: row-major grid of tw by th tiles. Each is { id, col,
-- row, w, h, fw, fh } (col and row in canvas units from the overlay's corner,
-- w and h the pixels used, fw and fh the size of the texture file).
function Map.Tiles(o, tw, th)
	tw, th = tw or TILE, th or TILE
	local cols, rows = ceil(o.w / tw), ceil(o.h / th)
	local out = {}
	for r = 0, rows - 1 do
		for c = 0, cols - 1 do
			local id = o.ids[r * cols + c + 1]
			if id then
				local w, h = pixels(o.w, tw, c, cols), pixels(o.h, th, r, rows)
				out[#out + 1] = { id = id, col = c * tw, row = r * th, w = w, h = h,
					fw = c < cols - 1 and tw or fileSize(w), fh = r < rows - 1 and th or fileSize(h) }
			end
		end
	end
	return out
end

local function hideOverlays()
	if not (ui and ui.tiles) then return end
	for i = 1, #ui.tiles do ui.tiles[i]:Hide() end
end

-- Part 1 draws on the first art layer only. Assumption: the scroll container
-- has :GetCurrentLayerIndex(); without it the first layer is taken as shown.
local function onFirstLayer()
	local container = ui.container
	if container and container.GetCurrentLayerIndex then
		local index = container:GetCurrentLayerIndex()
		if isNum(index) and index ~= 1 then return false end
	end
	return true
end

local function drawOverlays(map, foreign)
	hideOverlays()
	if not onFirstLayer() then return end
	local tw, th = tileSize(map)
	local used = 0
	for _, o in ipairs(foreign) do
		for _, t in ipairs(Map.Tiles(o, tw, th)) do
			used = used + 1
			local tex = ui.tiles[used]
			if not tex then
				tex = ui.overlay:CreateTexture(nil, "BACKGROUND")
				ui.tiles[used] = tex
			end
			tex:SetDrawLayer(o.top and "ARTWORK" or "BACKGROUND")
			tex:SetTexture(t.id)
			tex:SetTexCoord(0, t.w / t.fw, 0, t.h / t.fh)
			tex:SetDesaturated(true)
			tex:SetAlpha(OVERLAY_ALPHA)
			tex:SetSize(t.w, t.h)
			tex:ClearAllPoints()
			tex:SetPoint("TOPLEFT", ui.overlay, "TOPLEFT", o.x + t.col, -(o.y + t.row))
			tex:Show()
		end
	end
end

function refreshExplored()
	if not (ui and db()) then return end
	local map = shownMap()
	if not map then
		hideOverlays()
		return
	end
	local list, keys = readExplored(map)
	Map.Record(map, list)
	if option("show_explored") then
		drawOverlays(map, Map.Foreign(map, keys))
	else
		hideOverlays()
	end
end

-- Frames, built the first time the map opens.

local function raise(frame, base, by)
	if frame.SetFrameLevel and base and base.GetFrameLevel then
		local level = base:GetFrameLevel()
		if isNum(level) then frame:SetFrameLevel(level + by) end
	end
end

local function build()
	if ui then return true end
	if not (WorldMapFrame and CreateFrame) then return false end
	local container = WorldMapFrame.ScrollContainer or WorldMapFrame
	local canvas = WorldMapFrame.GetCanvas and WorldMapFrame:GetCanvas()
	if not canvas then return false end
	ui = { canvas = canvas, container = container }

	local bar = CreateFrame("Frame", nil, WorldMapFrame)
	bar:SetHeight(BAR_HEIGHT)
	bar:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 0, 0)
	bar:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
	raise(bar, container, 20)
	local back = bar:CreateTexture(nil, "BACKGROUND")
	back:SetAllPoints()
	back:SetTexture("Interface\\Buttons\\WHITE8X8")
	back:SetVertexColor(0, 0, 0, 0.55)
	ui.player = bar:CreateFontString(nil, "OVERLAY")
	ui.player:SetPoint("LEFT", bar, "LEFT", 10, 0)
	ui.cursor = bar:CreateFontString(nil, "OVERLAY")
	ui.cursor:SetPoint("RIGHT", bar, "RIGHT", -10, 0)
	S:SetFont(ui.player, "mono", 12)
	S:SetFont(ui.cursor, "mono", 12)
	ui.player:SetTextColor(0.78, 0.47, 0.29)
	ui.cursor:SetTextColor(0.9, 0.9, 0.9)
	ui.bar = bar

	local lf = CreateFrame("Frame", nil, WorldMapFrame)
	lf:SetSize(200, 20)
	lf:SetPoint("TOP", container, "TOP", 0, -8)
	raise(lf, container, 20)
	ui.level = lf:CreateFontString(nil, "OVERLAY")
	ui.level:SetPoint("CENTER", lf, "CENTER", 0, 0)
	S:SetFont(ui.level, "title", 16)
	ui.levelFrame = lf

	local hover = CreateFrame("Frame", nil, canvas)
	hover:SetSize(220, 20)
	raise(hover, canvas, 30)
	local hb = hover:CreateTexture(nil, "BACKGROUND")
	hb:SetAllPoints()
	hb:SetTexture("Interface\\Buttons\\WHITE8X8")
	hb:SetVertexColor(0, 0, 0, 0.6)
	ui.hoverText = hover:CreateFontString(nil, "OVERLAY")
	ui.hoverText:SetPoint("CENTER", hover, "CENTER", 0, 0)
	S:SetFont(ui.hoverText, "text", 12)
	hover:Hide()
	ui.hover = hover

	-- Same level as the canvas, so below the pins (children, one level up).
	local overlay = CreateFrame("Frame", nil, canvas)
	overlay:SetAllPoints(canvas)
	raise(overlay, canvas, 0)
	ui.overlay = overlay
	ui.tiles = {}

	Map.ui = ui
	return true
end

-- World map hooks. Assumptions: WorldMapFrame:GetMapID(), :GetCanvas() and
-- :OnMapChanged() exist (the last is hooked), WorldMapFrame.ScrollContainer
-- has :GetNormalizedCursorPosition() (0 to 1 over the canvas, nil outside).

local function onMapShown()
	if not build() then return end
	if driver then driver:Show() end
	refresh()
end

local function onMapHidden()
	if driver then driver:Hide() end
end

local function onMapChanged()
	if mapIsShown() then refresh() end
end

local function hookMap()
	if mapHooked or not WorldMapFrame then return end
	mapHooked = true
	WorldMapFrame:HookScript("OnShow", onMapShown)
	WorldMapFrame:HookScript("OnHide", onMapHidden)
	if type(WorldMapFrame.OnMapChanged) == "function" and hooksecurefunc then
		hooksecurefunc(WorldMapFrame, "OnMapChanged", onMapChanged)
	end
	if WorldMapFrame:IsShown() then onMapShown() end
end

-- Command

local function command(input)
	local word = (input or ""):lower():match("^%s*(%S*)")
	if word == "vergessen" or word == "forget" then
		local data = db()
		if data then
			data.explored, data.seen, data.seq = {}, {}, 0
		end
		refresh()
		S:Print(L.FORGOTTEN)
		return
	end
	local map = C_Map and C_Map.GetBestMapForUnit and clean(C_Map.GetBestMapForUnit("player"))
	if isNum(map) then
		local lo, hi = levelsOf(map)
		local info = C_Map.GetMapInfo and C_Map.GetMapInfo(map)
		if lo then
			S:Print(L.ZONE_LEVELS, info and info.name or ("#" .. map), Map.LevelText(lo, hi))
		else
			S:Print(L.NO_LEVELS)
		end
	else
		S:Print(L.NO_MAP)
	end
	S:Print(L.STORED, db() and storedCount() or 0)
end

-- Start

local function onLoaded(_, name)
	if name ~= ADDON_NAME then return end
	S:Off("ADDON_LOADED", onLoaded)
	SempreMapDB = SempreMapDB or {}
	local data = SempreMapDB
	data.version = data.version or 1
	if type(data.explored) ~= "table" then data.explored = {} end
	if type(data.seen) ~= "table" then data.seen = {} end
	if type(data.seq) ~= "number" then data.seq = 0 end

	S:RegisterOptions(ADDON_NAME, {
		{
			key = "show_levels", default = true,
			label = { de = "Stufenbereich der Gebiete zeigen", en = "Show zone level ranges" },
			tooltip = { de = "Eine Zeile mit dem Stufenbereich unter dem Kartentitel und ein Hinweis am Mauszeiger über den Gebieten einer Kontinentkarte.", en = "A line with the level range under the map title and a label at the cursor over the zones of a continent map." },
		},
		{
			key = "show_coords", default = true,
			label = { de = "Koordinaten auf der Karte", en = "Coordinates on the map" },
			tooltip = { de = "Eine schmale Leiste unten auf der Weltkarte mit deinen Koordinaten und denen des Mauszeigers.", en = "A thin bar at the bottom of the world map with your coordinates and those of the cursor." },
		},
		{
			key = "show_explored", default = true,
			label = { de = "Von anderen Charakteren erkundete Gebiete zeigen", en = "Show areas explored on other characters" },
			tooltip = { de = "Gebiete, die ein anderer Charakter deines Accounts erkundet hat, erscheinen auf der Karte blass und entsättigt.", en = "Areas another character of your account has explored show on the map, pale and desaturated." },
		},
	})

	if not (C_Map and C_Map.GetMapLevels and C_Map.GetPlayerMapPosition) and not noApiSaid then
		noApiSaid = true
		S:Print(L.NO_API)
	end

	driver = CreateFrame("Frame")
	driver:Hide()
	driver:SetScript("OnUpdate", onDriverUpdate)
	Map.driver = driver

	S.commands.karte = command
	S.commands.map = command

	S:Listen("OPTION_CHANGED", function(_, module)
		if module == ADDON_NAME then refresh() end
	end)
	S:On("PLAYER_LEVEL_UP", function() refresh() end)

	if WorldMapFrame then
		hookMap()
	else
		S:On("ADDON_LOADED", function(_, other)
			if other == "Blizzard_WorldMap" then hookMap() end
		end)
	end
end
S:On("ADDON_LOADED", onLoaded)
