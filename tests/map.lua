-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Tests for Sempre_Map with a stubbed WoW API. Loaded by tests/run.lua, which
-- passes in its check helper. Boots the real core and fonts, then the module's
-- file, with a stubbed world map frame, C_Map and C_MapExplorationInfo.

return function(check)

local SECRET = {}
local MAP = { Cosmic = 0, World = 1, Continent = 2, Zone = 3, Dungeon = 4, Micro = 5 }
local ZONE, OTHER_ZONE, CONT, ZONE2 = 100, 101, 12, 102

local function newFake(kind)
	local f = { kind = kind, shown = true, scripts = {}, hooks = {}, registered = {}, points = {} }
	return setmetatable(f, { __index = function() return function() end end })
end

local fakeMethods = {
	Show = function(self) self.shown = true end,
	Hide = function(self) self.shown = false end,
	IsShown = function(self) return self.shown end,
	SetText = function(self, text) self.text = text end,
	GetText = function(self) return self.text end,
	SetTextColor = function(self, r, g, b) self.color = { r, g, b } end,
	SetTexture = function(self, tex) self.texture = tex end,
	SetTexCoord = function(self, ...) self.coord = { ... } end,
	SetDesaturated = function(self, on) self.desaturated = on end,
	SetAlpha = function(self, a) self.alpha = a end,
	SetSize = function(self, w, h) self.w, self.h = w, h end,
	SetDrawLayer = function(self, layer) self.layer = layer end,
	SetFont = function(self, path, size, flags)
		self.font = { path = path, size = size, flags = flags }
		return true
	end,
	SetScript = function(self, kind, fn) self.scripts[kind] = fn end,
	HookScript = function(self, kind, fn) self.hooks[kind] = fn end,
	SetFrameLevel = function(self, n) self.level = n end,
	GetFrameLevel = function(self) return self.level or 1 end,
	GetWidth = function() return 1002 end,
	GetHeight = function() return 668 end,
	ClearAllPoints = function(self) self.points = {} end,
	SetPoint = function(self, ...) self.points[#self.points + 1] = { ... } end,
	RegisterEvent = function(self, e) self.registered[e] = true end,
	UnregisterEvent = function(self, e) self.registered[e] = nil end,
}

-- opts: options (stored options), noWorldMap, noExploration, locale
local function boot(opts)
	opts = opts or {}
	local env = { printed = {}, errors = {}, frames = {}, level = 25, mapID = ZONE, levels = {}, explored = {},
		playerMap = ZONE, px = 0.452, py = 0.618, cursor = nil, atPos = nil, calls = 0 }
	local g = setmetatable({}, { __index = _G })
	g._G = g
	g.table = setmetatable({ wipe = function(t) for k in pairs(t) do t[k] = nil end return t end }, { __index = table })
	local function make(kind, parent)
		local f = newFake(kind)
		for k, v in pairs(fakeMethods) do f[k] = v end
		f.parent = parent
		f.CreateFontString = function(self) return make("FontString", self) end
		f.CreateTexture = function(self) return make("Texture", self) end
		env.frames[#env.frames + 1] = f
		return f
	end
	g.CreateFrame = function(kind, _, parent) return make(kind, parent) end
	g.time = function() return 1000 end
	g.GetLocale = function() return opts.locale or "enUS" end
	g.GetBuildInfo = function() return "1", "", "", 16001 end
	g.UnitName = function() return "Tester" end
	g.GetRealmName = function() return "Realm" end
	g.UnitLevel = function() return env.level end
	g.issecretvalue = function(v) return v == SECRET end
	g.geterrorhandler = function() return function(err) env.errors[#env.errors + 1] = err end end
	g.SlashCmdList = {}
	g.print = function(msg) env.printed[#env.printed + 1] = msg end
	g.C_AddOns = { GetAddOnMetadata = function() return nil end, GetNumAddOns = function() return 0 end }
	g.C_EventUtils = { IsEventValid = function() return true end }
	g.hooksecurefunc = function(obj, name, fn)
		local orig = obj[name]
		obj[name] = function(...) orig(...) fn(...) end
	end
	g.Enum = { UIMapType = MAP }
	g.GetCursorPosition = function() return 0, 0 end

	local maps = {
		[946] = { name = "Cosmic", kind = MAP.Cosmic },
		[CONT] = { name = "Kalimdor", kind = MAP.Continent },
		[ZONE] = { name = "Durotar", kind = MAP.Zone },
		[OTHER_ZONE] = { name = "Mulgore", kind = MAP.Zone },
		[ZONE2] = { name = "Barrens", kind = MAP.Zone },
	}
	env.levels[ZONE], env.levels[OTHER_ZONE], env.levels[ZONE2] = { 20, 30 }, { 1, 10 }, { 0, 0 }
	env.levels[CONT] = { 1, 60 }
	g.C_Map = {
		GetMapLevels = function(id)
			local r = env.levels[id]
			if not r then return nil end
			return r[1], r[2], 0, 0
		end,
		GetMapInfo = function(id)
			local m = maps[id]
			return m and { mapID = id, name = m.name, mapType = m.kind } or nil
		end,
		GetMapInfoAtPosition = function(id, x, y)
			env.calls = env.calls + 1
			env.askedAt = { id, x, y }
			return env.atPos
		end,
		GetMapArtLayers = function() return env.layers end,
		GetBestMapForUnit = function() return env.playerMap end,
		GetPlayerMapPosition = function(map)
			if map ~= env.playerMap or not env.px then return nil end
			return { x = env.px, y = env.py, GetXY = function(self) return self.x, self.y end }
		end,
	}
	if not opts.noExploration then
		g.C_MapExplorationInfo = {
			GetExploredMapTextures = function(map) return env.explored[map] end,
		}
	end

	if not opts.noWorldMap then
		local wm = make("Frame")
		wm.shown = false
		wm.GetMapID = function() return env.mapID end
		env.canvas = make("Frame")
		wm.GetCanvas = function() return env.canvas end
		wm.OnMapChanged = function() end
		wm.ScrollContainer = make("Frame")
		wm.ScrollContainer.GetNormalizedCursorPosition = function()
			if env.cursor then return env.cursor[1], env.cursor[2] end
		end
		g.WorldMapFrame = wm
		env.wm = wm
	end

	local function run(path, ...)
		local chunk = assert(loadfile(path))
		setfenv(chunk, g)
		return chunk(...)
	end
	env.g = g
	local firstFrame = #env.frames + 1
	run("Sempre/Core.lua", "Sempre")
	run("Sempre/Fonts.lua", "Sempre")
	env.S = g.SempreUI
	env.core = env.frames[firstFrame]
	function env.fire(event, ...) env.core.scripts.OnEvent(env.core, event, ...) end
	env.fire("ADDON_LOADED", "Sempre")
	if opts.options then env.S.db.global.options.Sempre_Map = opts.options end
	env.fire("PLAYER_LOGIN")
	env.printed = {}
	if opts.db then g.SempreMapDB = opts.db end
	run("Sempre_Map/Map.lua", "Sempre_Map")
	env.fire("ADDON_LOADED", "Sempre_Map")
	env.Map = env.S.Map
	env.loadPrinted = env.printed
	env.printed = {}

	function env.out() return table.concat(env.printed, "\n") end
	function env.open(id)
		if id then env.mapID = id end
		env.wm.shown = true
		env.wm.hooks.OnShow(env.wm)
	end
	function env.close()
		env.wm.shown = false
		env.wm.hooks.OnHide(env.wm)
	end
	function env.changeTo(id)
		env.mapID = id
		env.wm:OnMapChanged()
	end
	function env.tick(dt)
		local d = env.Map.driver
		d.scripts.OnUpdate(d, dt or 0.1)
	end
	return env
end

local function near(a, b) return math.abs(a - b) < 1e-9 end

local function overlay(x, y, w, h, ids, extra)
	local t = { offsetX = x, offsetY = y, textureWidth = w, textureHeight = h, fileDataIDs = ids,
		isDrawOnTopLayer = false, isShownByMouseOver = false }
	for k, v in pairs(extra or {}) do t[k] = v end
	return t
end

local function count(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

local function shownTiles(env)
	local out = {}
	for _, t in ipairs(env.Map.ui.tiles) do
		if t.shown then out[#out + 1] = t end
	end
	return out
end

-- Loading and options

do
	local env = boot()
	check(#env.errors == 0, "map: loads without handler errors: " .. tostring(env.errors[1]))
	check(#env.loadPrinted == 0, "map: quiet at load: " .. table.concat(env.loadPrinted, "|"))
	check(#env.S:GetOptionList("Sempre_Map") == 3, "map: three options")
	for _, key in ipairs({ "show_levels", "show_coords", "show_explored" }) do
		check(env.S:GetOption("Sempre_Map", key) == true, "map: option " .. key .. " on by default")
	end
	check(env.S.commands.karte ~= nil and env.S.commands.map == env.S.commands.karte, "map: /sempre karte and map exist")
	check(env.Map.ui == nil, "map: no frames before the map first opens")
	check(not env.Map.driver.shown, "map: update frame hidden at start")
	check(env.g.SempreMapDB.version == 1 and next(env.g.SempreMapDB.explored) == nil, "map: saved data created")
	env.open()
	check(env.Map.ui ~= nil and #env.errors == 0, "map: frames built when the map first opens: " .. tostring(env.errors[1]))
	local ui = env.Map.ui
	check(ui.player.font and ui.player.font.path:find("Mono", 1, true), "map: coordinates use the mono role")
	local n = #env.frames
	env.close()
	env.open()
	check(#env.frames == n, "map: frames built only once")
end

-- Level line and its colour

do
	local env = boot()
	env.open()
	local ui = env.Map.ui
	check(ui.levelFrame.shown and ui.level.text == "Level 20–30", "map: level line on a zone map: " .. tostring(ui.level.text))
	local function colour(level)
		env.level = level
		env.changeTo(ZONE)
		return ui.level.color
	end
	local c = colour(10)
	check(c[1] == 1 and c[2] == 0.25, "map: red when the minimum is 3 or more above the player")
	c = colour(18)
	check(c[1] == 1 and c[2] == 0.82, "map: yellow when the minimum is 2 above the player")
	c = colour(19)
	check(c[1] == 1 and c[2] == 0.82, "map: yellow when the minimum is 1 above the player")
	c = colour(20)
	check(c[2] == 0.85, "map: green at the minimum")
	c = colour(25)
	check(c[2] == 0.85, "map: green inside the range")
	c = colour(30)
	check(c[2] == 0.85, "map: green at the maximum")
	c = colour(35)
	check(c[2] == 0.85, "map: green up to 5 above the maximum")
	c = colour(36)
	check(c[1] == 0.62 and c[2] == 0.62, "map: grey more than 5 above the maximum")
	check(env.Map.LevelColor(10, 20, 30) == "red" and env.Map.LevelColor(40, 20, 30) == "grey", "map: LevelColor keys")
	env.level = 25
	env.changeTo(OTHER_ZONE)
	check(ui.level.text == "Level 1–10" and ui.level.color[1] == 0.62, "map: another zone gets its own line and colour")
	env.changeTo(ZONE2)
	check(not ui.levelFrame.shown, "map: a 0–0 range shows nothing")
	env.levels[ZONE2] = nil
	env.changeTo(ZONE2)
	check(not ui.levelFrame.shown, "map: a missing result shows nothing")
	env.changeTo(CONT)
	check(not ui.levelFrame.shown, "map: no level line on a continent map")
	env.levels[ZONE] = { 15, 15 }
	env.changeTo(ZONE)
	check(ui.level.text == "Level 15" and ui.levelFrame.shown, "map: equal minimum and maximum show one level")
	env.fire("PLAYER_LEVEL_UP", 26)
	check(#env.errors == 0, "map: level up refreshes quietly")
end

do
	local env = boot({ locale = "deDE" })
	env.open()
	check(env.Map.ui.level.text == "Stufe 20–30", "map: German level line")
end

-- Continent hover label

do
	local env = boot()
	env.open(CONT)
	local ui = env.Map.ui
	check(not ui.hover.shown, "map: no hover label without cursor")
	env.cursor = { 0.3, 0.4 }
	env.atPos = { mapID = ZONE, name = "Durotar" }
	env.tick()
	check(ui.hover.shown and ui.hoverText.text == "Durotar  Level 20–30", "map: hover label shows zone and range: " .. tostring(ui.hoverText.text))
	check(env.askedAt[1] == CONT and near(env.askedAt[2], 0.3) and near(env.askedAt[3], 0.4), "map: asks the zone at the cursor position")
	local pt = ui.hover.points[#ui.hover.points]
	check(pt[2] == env.canvas and near(pt[4], 0.3 * 1002 + 14), "map: label sits at the cursor")
	env.atPos = { mapID = ZONE2, name = "Barrens" }
	env.tick()
	check(not ui.hover.shown, "map: hover with 0–0 range shows nothing")
	env.atPos = nil
	env.tick()
	check(not ui.hover.shown, "map: no zone at the cursor, no label")
	env.atPos = { mapID = OTHER_ZONE, name = "Mulgore" }
	env.cursor = nil
	env.tick()
	check(not ui.hover.shown, "map: cursor off the canvas hides the label")
	env.cursor = { 0.3, 0.4 }
	env.tick()
	check(ui.hover.shown, "map: label back when the cursor returns")
	env.changeTo(ZONE)
	env.tick()
	check(not ui.hover.shown, "map: no hover label on a zone map")
end

-- Coordinates

do
	local env = boot()
	env.open()
	local ui = env.Map.ui
	check(ui.player.text == "45.2, 61.8", "map: player coordinates: " .. tostring(ui.player.text))
	check(ui.cursor.text == "–", "map: no cursor coordinates off the canvas")
	env.cursor = { 0.5, 0.25 }
	env.tick(0.05)
	check(ui.cursor.text == "–", "map: no update before 0.1 seconds")
	env.tick(0.05)
	check(ui.cursor.text == "50.0, 25.0", "map: cursor coordinates after 0.1 seconds: " .. tostring(ui.cursor.text))
	env.playerMap = CONT
	env.tick()
	check(ui.player.text == "–", "map: player not on the shown map shows a dash")
	env.playerMap, env.px = ZONE, nil
	env.tick()
	check(ui.player.text == "–", "map: unknown player position shows a dash")
	env.px, env.py = 0.1, 0.2
	env.cursor = { 1.5, 0.2 }
	env.tick()
	check(ui.cursor.text == "–" and ui.player.text == "10.0, 20.0", "map: cursor outside the canvas shows a dash")
	env.close()
	check(not env.Map.driver.shown, "map: update frame hidden with the map")
	env.px, env.py = 0.9, 0.9
	env.cursor = { 0.1, 0.1 }
	env.tick()
	check(ui.player.text == "10.0, 20.0", "map: no updates while the map is hidden")
	env.open()
	check(env.Map.driver.shown and ui.player.text == "90.0, 90.0", "map: updates resume when the map opens")
end

-- Options switch each part off

do
	local env = boot({ options = { show_coords = false } })
	env.open()
	check(not env.Map.ui.bar.shown and env.Map.ui.levelFrame.shown, "map: coordinates option off hides the bar only")
	env.S:SetOption("Sempre_Map", "show_coords", true)
	check(env.Map.ui.bar.shown, "map: switching the option on shows the bar at once")
end

do
	local env = boot({ options = { show_levels = false } })
	env.open()
	check(not env.Map.ui.levelFrame.shown and env.Map.ui.bar.shown, "map: levels option off hides the level line only")
	env.open(CONT)
	env.cursor = { 0.3, 0.4 }
	env.atPos = { mapID = ZONE, name = "Durotar" }
	env.tick()
	check(not env.Map.ui.hover.shown and env.calls == 0, "map: levels option off, no hover label and no lookup")
	env.S:SetOption("Sempre_Map", "show_levels", true)
	env.tick()
	check(env.Map.ui.hover.shown, "map: switching levels on shows the hover label")
end

-- Exploration: storing and merging

do
	local a = overlay(10, 20, 200, 100, { 111 })
	local b = overlay(300, 40, 600, 300, { 201, 202, 203, 204, 205, 206 })
	local mouse = overlay(5, 5, 50, 50, { 999 }, { isShownByMouseOver = true })
	local env = boot()
	env.explored[ZONE] = { a, mouse }
	env.open()
	local db = env.g.SempreMapDB
	check(#db.explored[ZONE] == 1 and db.explored[ZONE][1].ids[1] == 111, "map: exploration stored per map, mouse-over overlays skipped")
	local o = db.explored[ZONE][1]
	check(o.w == 200 and o.h == 100 and o.x == 10 and o.y == 20 and o.top == false, "map: stored fields")
	env.changeTo(ZONE)
	check(#db.explored[ZONE] == 1, "map: seeing a map again stores no duplicate")
	env.explored[ZONE] = { a, b }
	env.changeTo(ZONE)
	check(#db.explored[ZONE] == 2, "map: new overlays are added")
	env.explored[OTHER_ZONE] = nil
	env.changeTo(OTHER_ZONE)
	check(db.explored[OTHER_ZONE] == nil, "map: a map without overlays stores nothing")
	check(#env.errors == 0, "map: storing is quiet")

	-- A second character with the same saved data.
	local env2 = boot({ db = db })
	env2.explored[ZONE] = { b, overlay(700, 50, 100, 100, { 301 }) }
	env2.open()
	check(#env2.g.SempreMapDB.explored[ZONE] == 3, "map: two characters merged without duplicates")
	local keys = {}
	for _, ov in ipairs(env2.g.SempreMapDB.explored[ZONE]) do keys[ov.x .. ":" .. ov.y .. ":" .. ov.ids[1]] = true end
	check(count(keys) == 3, "map: one entry per overlay key")
end

-- Exploration: drawing what another character found

do
	local a = overlay(10, 20, 200, 100, { 111 })
	local big = overlay(300, 40, 600, 300, { 201, 202, 203, 204, 205, 206 })
	local mouse = overlay(5, 5, 50, 50, { 999 }, { isShownByMouseOver = true })
	local top = overlay(0, 0, 64, 64, { 777 }, { isDrawOnTopLayer = true })
	local db = { version = 1, seq = 3, seen = { [ZONE] = 3 },
		explored = { [ZONE] = {
			{ w = 200, h = 100, x = 10, y = 20, top = false, ids = { 111 } },
			{ w = 600, h = 300, x = 300, y = 40, top = false, ids = { 201, 202, 203, 204, 205, 206 } },
			{ w = 64, h = 64, x = 0, y = 0, top = true, ids = { 777 } },
		} } }
	local env = boot({ db = db })
	env.canvas.level = 5
	env.explored[ZONE] = { a }
	env.open()
	local tiles = shownTiles(env)
	check(#tiles == 7, "map: this character's own areas are not drawn, the others are (6 tiles + 1): " .. #tiles)
	local t1 = tiles[1]
	check(t1.texture == 201 and t1.desaturated == true and t1.alpha == 0.6, "map: drawn desaturated at 60 percent alpha")
	check(t1.w == 256 and t1.h == 256 and t1.coord[2] == 1 and t1.coord[4] == 1, "map: full tile")
	check(tiles[3].w == 88 and tiles[3].h == 256 and near(tiles[3].coord[2], 88 / 128) and tiles[3].coord[4] == 1, "map: last column is 88 wide in a 128 file")
	check(tiles[4].w == 256 and tiles[4].h == 44 and tiles[4].coord[2] == 1 and near(tiles[4].coord[4], 44 / 64), "map: last row is 44 high in a 64 file")
	check(tiles[6].w == 88 and tiles[6].h == 44 and tiles[6].texture == 206, "map: corner tile is 88 by 44")
	local p = tiles[5].points[#tiles[5].points]
	check(p[1] == "TOPLEFT" and p[2] == env.Map.ui.overlay and near(p[4], 300 + 256) and near(p[5], -(40 + 256)), "map: tile offset in the grid")
	check(tiles[7].texture == 777 and tiles[7].layer == "ARTWORK" and tiles[1].layer == "BACKGROUND", "map: top overlays go on a higher layer")
	check(env.Map.ui.overlay.parent == env.canvas and env.Map.ui.overlay.level == env.canvas.level, "map: overlay frame sits on the canvas at its level, below pins")

	-- Offsets are canvas units, never scaled by the canvas size.
	env.canvas.GetWidth = function() return 3000 end
	env.canvas.GetHeight = function() return 2000 end
	env.explored[ZONE] = { a }
	env.changeTo(ZONE)
	tiles = shownTiles(env)
	p = tiles[5].points[#tiles[5].points]
	check(tiles[5].w == 256 and near(p[4], 556) and near(p[5], -296), "map: offsets and sizes are used unscaled")

	-- Tile size from the first art layer; a layer-less client falls back to 256.
	env.layers = { { tileWidth = 512, tileHeight = 128 }, { tileWidth = 64, tileHeight = 64 } }
	env.changeTo(ZONE)
	tiles = shownTiles(env)
	check(#tiles == 7 and tiles[1].w == 512 and tiles[1].h == 128 and tiles[2].w == 88 and tiles[2].coord[2] == 88 / 128, "map: tile size from the first art layer")
	env.layers = nil
	env.changeTo(ZONE)
	check(shownTiles(env)[1].w == 256, "map: no art layers, tiles of 256")

	-- Only the first art layer is drawn.
	env.Map.ui.container.GetCurrentLayerIndex = function() return 2 end
	env.changeTo(ZONE)
	check(#shownTiles(env) == 0, "map: a zoomed art layer draws nothing")
	env.Map.ui.container.GetCurrentLayerIndex = function() return 1 end
	env.changeTo(ZONE)
	check(#shownTiles(env) == 7, "map: the first art layer draws")
	env.Map.ui.container.GetCurrentLayerIndex = nil

	-- Moving to a map where nothing is stored hides the overlays.
	env.changeTo(OTHER_ZONE)
	check(#shownTiles(env) == 0, "map: overlays hidden on another map")

	-- All explored by this character: nothing to draw.
	env.explored[ZONE] = { a, big, top, mouse }
	env.changeTo(ZONE)
	check(#shownTiles(env) == 0, "map: nothing drawn when this character explored everything")

	-- Tile arithmetic on its own
	local ts = env.Map.Tiles({ w = 600, h = 300, ids = { 1, 2, 3, 4, 5, 6 } })
	check(#ts == 6 and ts[3].w == 88 and ts[6].h == 44 and ts[4].row == 256 and ts[2].col == 256, "map: tile sizes for 600 by 300")
	ts = env.Map.Tiles({ w = 600, h = 300, ids = { 1, 2 } })
	check(#ts == 2, "map: missing file data IDs are skipped")
	ts = env.Map.Tiles({ w = 512, h = 256, ids = { 1, 2 } })
	check(ts[2].w == 256 and ts[2].fw == 256 and ts[2].h == 256, "map: an exact multiple ends in a full tile")
	ts = env.Map.Tiles({ w = 10, h = 20, ids = { 1 } })
	check(ts[1].fw == 16 and ts[1].fh == 32, "map: small file sizes start at 16")
end

do
	local env = boot({ options = { show_explored = false }, db = { version = 1, seq = 1, seen = {},
		explored = { [ZONE] = { { w = 64, h = 64, x = 0, y = 0, top = false, ids = { 5 } } } } } })
	env.open()
	check(#shownTiles(env) == 0, "map: explored option off draws nothing")
	env.S:SetOption("Sempre_Map", "show_explored", true)
	check(#shownTiles(env) == 1, "map: switching the option on draws at once")
	env.explored[ZONE] = { overlay(1, 1, 64, 64, { 8 }) }
	env.S:SetOption("Sempre_Map", "show_explored", false)
	check(#env.g.SempreMapDB.explored[ZONE] == 2, "map: exploration is still stored with the option off")
end

-- Cap and forget

do
	local env = boot()
	env.open()
	local db = env.g.SempreMapDB
	for id = 1000, 1000 + 399 do
		env.Map.Record(id, { { w = 10, h = 10, x = id, y = 0, top = false, ids = { id } } })
	end
	check(count(db.explored) == 400, "map: 400 maps fit")
	env.Map.Record(1000, { { w = 10, h = 10, x = 5, y = 5, top = false, ids = { 5 } } })
	env.Map.Record(2000, { { w = 10, h = 10, x = 9, y = 9, top = false, ids = { 9 } } })
	check(count(db.explored) == 400, "map: 401st map keeps the cap")
	check(db.explored[2000] ~= nil, "map: the new map is kept")
	check(db.explored[1000] ~= nil, "map: a recently seen map is kept")
	check(db.explored[1001] == nil, "map: the least recently seen map is dropped")
	check(count(db.seen) == 400, "map: seen markers dropped with the map")
	local before = #env.out()
	env.S.commands.karte("vergessen")
	check(next(db.explored) == nil and count(db.seen) == 0 and env.out():find("cleared", 1, true) and before == 0, "map: forget clears the stored exploration")
	env.explored[ZONE] = { overlay(1, 1, 64, 64, { 8 }) }
	env.S.commands.karte("forget")
	check(env.out():find("cleared", 1, true) ~= nil, "map: forget in English")
end

-- Command output

do
	local env = boot()
	env.S.commands.karte("")
	local out = env.out()
	check(out:find("Durotar, Level 20–30", 1, true) and out:find("exploration stored for 0 maps", 1, true), "map: command prints range and count: " .. out)
	env.printed = {}
	env.Map.Record(ZONE, { { w = 10, h = 10, x = 1, y = 1, top = false, ids = { 1 } } })
	env.playerMap = ZONE2
	env.S.commands.map("")
	out = env.out()
	check(out:find("no level range", 1, true) and out:find("1 maps", 1, true), "map: command without range: " .. out)
	env.printed = {}
	env.playerMap = nil
	env.S.commands.karte("")
	check(env.out():find("not known", 1, true) ~= nil, "map: command without position")
end

-- Missing pieces and a late world map

do
	local env = boot({ noWorldMap = true })
	check(#env.errors == 0 and #env.loadPrinted == 0, "map: no world map yet, no error")
	local wm = newFake("Frame")
	for k, v in pairs(fakeMethods) do wm[k] = v end
	wm.shown = false
	wm.GetMapID = function() return ZONE end
	local canvas = newFake("Frame")
	for k, v in pairs(fakeMethods) do canvas[k] = v end
	wm.GetCanvas = function() return canvas end
	wm.ScrollContainer = newFake("Frame")
	for k, v in pairs(fakeMethods) do wm.ScrollContainer[k] = v end
	env.g.WorldMapFrame = wm
	env.fire("ADDON_LOADED", "Blizzard_Other")
	check(wm.hooks.OnShow == nil, "map: other addons loading do not hook the map")
	env.fire("ADDON_LOADED", "Blizzard_WorldMap")
	check(wm.hooks.OnShow ~= nil and wm.hooks.OnHide ~= nil, "map: hooks the world map when its addon loads later")
	wm.shown = true
	wm.hooks.OnShow(wm)
	check(env.Map.ui ~= nil and #env.errors == 0, "map: works on a late world map: " .. tostring(env.errors[1]))
end

do
	local env = boot({ noExploration = true })
	env.open()
	check(#env.errors == 0 and env.Map.ui.levelFrame.shown, "map: no exploration API, the rest still works")
end

do
	local env = boot()
	env.explored[ZONE] = { overlay(SECRET, 1, 64, 64, { 1 }), { fileDataIDs = "bad" }, overlay(1, 1, 0, 64, { 2 }),
		overlay(1, 1, 64, 64, {}) , overlay(2, 2, 64, 64, { 3 }) }
	env.open()
	check(#env.errors == 0 and #env.g.SempreMapDB.explored[ZONE] == 1, "map: unusable overlay data is skipped")
end

end
