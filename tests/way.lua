-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Tests for Sempre_Way with a stubbed WoW API. Loaded by tests/run.lua, which
-- passes in its check helper. Boots the real core, then the module's file.
-- The stub world: every map sits at an offset on continent 1 and is 1000 x
-- 1000 yards, so world coordinates are easy to reason about.

return function(check)

local T0 = os.time({ year = 2026, month = 10, day = 22, hour = 12, min = 0, sec = 0 })
local DAY = 86400
local SECRET = {}
local MAP = { Cosmic = 0, World = 1, Continent = 2, Zone = 3, Dungeon = 4, Micro = 5 }

-- id -> name, parent, type, ox, oy, canWaypoint
local function newMaps()
	local function m(name, parent, kind, ox, oy, can)
		return { name = name, parent = parent, kind = kind, ox = ox, oy = oy, can = can ~= false }
	end
	return {
		[946] = m("Cosmic", 0, MAP.Cosmic, 0, 0, false),
		[12] = m("Kalimdor", 946, MAP.Continent, 0, 0, false),
		[13] = m("Eastern Kingdoms", 946, MAP.Continent, 0, 0, false),
		[100] = m("Elwynn Forest", 13, MAP.Zone, 2000, 2000),
		[102] = m("Dun Morogh", 13, MAP.Zone, 5000, 2000),
		[103] = m("Dun Algaz", 13, MAP.Zone, 7000, 2000),
		[104] = m("Durotar", 12, MAP.Zone, 2000, 2000),
		[105] = m("Mulgore", 12, MAP.Zone, 5000, 2000),
		[106] = m("Elwynn Forest", 12, MAP.Zone, 9000, 9000),
		[110] = m("Goldshire", 100, MAP.Micro, 2400, 2400, false),
	}
end

local function newFake()
	local f = { shown = true, scripts = {}, hooks = {} }
	return setmetatable(f, { __index = function()
		return function() end
	end })
end

local fakeMethods = {
	Show = function(self) self.shown = true end,
	Hide = function(self) self.shown = false end,
	IsShown = function(self) return self.shown end,
	SetScript = function(self, kind, fn) self.scripts[kind] = fn end,
	HookScript = function(self, kind, fn) self.hooks[kind] = fn end,
	GetWidth = function() return 1000 end,
	GetHeight = function() return 500 end,
	SetPoint = function(self, ...) self.point = { ... } end,
	CreateTexture = function() return newFake() end,
	CreateMaskTexture = function() return newFake() end,
}

-- opts: noMarker, noWorld, otherWay, db, options, combat, noPlayer, noWorldMap,
-- noEventUtils
local function boot(opts)
	opts = opts or {}
	local env = { printed = {}, errors = {}, frames = {}, now = T0, maps = newMaps(),
		combat = opts.combat or false, super = false, calls = {} }
	local g = setmetatable({}, { __index = _G })
	g._G = g
	g.table = setmetatable({ wipe = function(t) for k in pairs(t) do t[k] = nil end return t end }, { __index = table })
	g.CreateFrame = function()
		local f = newFake()
		for k, v in pairs(fakeMethods) do f[k] = v end
		env.frames[#env.frames + 1] = f
		return f
	end
	g.time = function() return env.now end
	g.GetLocale = function() return "enUS" end
	g.GetBuildInfo = function() return "1", "", "", 16001 end
	g.UnitName = function() return "Tester" end
	g.GetRealmName = function() return "Realm" end
	g.issecretvalue = function(v) return v == SECRET end
	g.geterrorhandler = function() return function(err) env.errors[#env.errors + 1] = err end end
	g.SlashCmdList = {}
	g.print = function(msg) env.printed[#env.printed + 1] = msg end
	g.C_AddOns = { GetAddOnMetadata = function() return nil end, GetNumAddOns = function() return 0 end }
	if not opts.noEventUtils then
		g.C_EventUtils = { IsEventValid = function() return true end }
	end
	g.InCombatLockdown = function() return env.combat end
	g.IsShiftKeyDown = function() return env.shift or false end
	g.IsControlKeyDown = function() return env.ctrl or false end
	g.hooksecurefunc = function(obj, name, fn)
		local orig = obj[name]
		obj[name] = function(...) orig(...) fn(...) end
	end
	g.Enum = { UIMapType = MAP }
	g.GameTooltip = newFake()
	if opts.otherWay then g.SLASH_OTHER1 = "/WAY" end
	if opts.db then g.SempreWayDB = opts.db end

	g.CreateVector2D = function(x, y)
		return { x = x, y = y, GetXY = function(self) return self.x, self.y end }
	end
	local function world(map, x, y)
		local m = env.maps[map]
		return m.ox + x * 1000, m.oy + y * 1000
	end
	if not opts.noMarker then
		g.UiMapPoint = { CreateFromVector2D = function(map, v) return { uiMapID = map, position = v } end }
		g.C_SuperTrack = {
			SetSuperTrackedUserWaypoint = function(on) env.super = on end,
			IsSuperTrackingUserWaypoint = function() return env.super end,
		}
	end
	local C = {}
	g.C_Map = C
	function C.GetBestMapForUnit() return not opts.noPlayer and env.playerMap or nil end
	function C.GetPlayerMapPosition(map)
		if opts.noPlayer or not env.px or map ~= env.playerMap then return nil end
		return g.CreateVector2D(env.px, env.py)
	end
	function C.GetMapInfo(id)
		local m = env.maps[id]
		if not m then return nil end
		return { mapID = id, name = m.name, parentMapID = m.parent, mapType = m.kind }
	end
	function C.GetMapChildrenInfo(root, kind)
		local out = {}
		local ids = {}
		for id in pairs(env.maps) do ids[#ids + 1] = id end
		table.sort(ids)
		for _, id in ipairs(ids) do
			local cur, below = env.maps[id].parent, false
			while cur and cur ~= 0 do
				if cur == root then below = true break end
				cur = env.maps[cur] and env.maps[cur].parent
			end
			if below and (not kind or env.maps[id].kind == kind) then
				out[#out + 1] = { mapID = id, name = env.maps[id].name, parentMapID = env.maps[id].parent, mapType = env.maps[id].kind }
			end
		end
		return out
	end
	function C.GetWorldPosFromMapPos(map, v)
		if env.noWorld or not env.maps[map] then return nil end
		local wx, wy = world(map, v.x, v.y)
		-- Kalimdor (12) is continent 2, everything else continent 1.
		local c, cur = 1, map
		while cur and cur ~= 0 do
			if cur == 12 then c = 2 end
			cur = env.maps[cur].parent
		end
		return c, g.CreateVector2D(wx, wy)
	end
	function C.GetMapPosFromWorldPos(_, v, map)
		local m = env.maps[map]
		return map, g.CreateVector2D((v.x - m.ox) / 1000, (v.y - m.oy) / 1000)
	end
	if not opts.noMarker then
		function C.CanSetUserWaypointOnMap(map) return env.maps[map] ~= nil and env.maps[map].can end
		function C.SetUserWaypoint(p) env.wp = p env.calls[#env.calls + 1] = "set" end
		function C.GetUserWaypoint() return env.wp end
		function C.HasUserWaypoint() return env.wp ~= nil end
		function C.ClearUserWaypoint() env.wp = nil env.calls[#env.calls + 1] = "clear" end
	end

	if not opts.noWorldMap then
		local wm = newFake()
		for k, v in pairs(fakeMethods) do wm[k] = v end
		wm.shown = false
		wm.mapID = 100
		wm.GetMapID = function(self) return self.mapID end
		wm.GetCanvas = function() return env.canvas end
		wm.OnMapChanged = function() end
		wm.ScrollContainer = newFake()
		wm.ScrollContainer.HookScript = fakeMethods.HookScript
		env.canvas = newFake()
		for k, v in pairs(fakeMethods) do env.canvas[k] = v end
		g.WorldMapFrame = wm
		env.wm = wm
	end

	local function run(path, ...)
		local chunk = assert(loadfile(path))
		setfenv(chunk, g)
		return chunk(...)
	end
	env.g = g
	env.playerMap, env.px, env.py = 100, 0.1, 0.1
	run("Sempre/Core.lua", "Sempre")
	env.S = g.SempreUI
	env.core = env.frames[1]
	function env.fire(event, ...) env.core.scripts.OnEvent(env.core, event, ...) end
	env.fire("ADDON_LOADED", "Sempre")
	if opts.options then env.S.db.global.options.Sempre_Way = opts.options end
	env.fire("PLAYER_LOGIN")
	env.changed = 0
	env.S:Listen("WAY_CHANGED", function() env.changed = env.changed + 1 end)
	env.printed = {}
	run("Sempre_Way/Way.lua", "Sempre_Way")
	env.fire("ADDON_LOADED", "Sempre_Way")
	env.Way = env.S.Way
	env.loadPrinted = env.printed
	env.printed = {}

	function env.out() return table.concat(env.printed, "\n") end
	function env.cmd(text) env.Way.Command(text) end
	function env.driverTick() local d = env.Way.driver d.scripts.OnUpdate(d, 0.5) end
	-- Player on the same map at yards from the origin of map 100.
	function env.moveTo(x, y) env.playerMap, env.px, env.py = 100, x, y end
	return env
end

local function near(a, b) return math.abs(a - b) < 1e-9 end

-- Loading

do
	local env = boot()
	check(#env.errors == 0, "way: loads without handler errors: " .. tostring(env.errors[1]))
	check(#env.loadPrinted == 0, "way: quiet at load: " .. table.concat(env.loadPrinted, "|"))
	check(env.g.SlashCmdList.SEMPREWAY ~= nil and env.g.SLASH_SEMPREWAY1 == "/way", "way: /way registered when free")
	check(env.S.commands.way ~= nil, "way: /sempre way exists")
	check(env.S:GetOption("Sempre_Way", "auto_next") == true and env.S:GetOption("Sempre_Way", "click_add") == true, "way: both options on by default")
	check(#env.S:GetOptionList("Sempre_Way") == 2, "way: two options")
	check(env.driver == nil and not env.Way.driver.shown, "way: arrival frame hidden while nothing is active")
	check(env.Way.GetActive() == nil and #env.Way.GetPoints() == 0, "way: empty at start")
	env.fire("PLAYER_ENTERING_WORLD")
	check(#env.errors == 0, "way: entering world without points is quiet")
end

-- /way forms

do
	local env = boot()
	env.cmd("45.2 61.8 Camp")
	local pts = env.Way.GetPoints()
	check(#pts == 1 and pts[1].map == 100 and near(pts[1].x, 0.452) and near(pts[1].y, 0.618) and pts[1].text == "Camp", "way: X Y Text on the current map")
	check(select(2, env.Way.GetActive()) == 1, "way: a command-added point becomes active")
	env.cmd("45,2 61,8")
	pts = env.Way.GetPoints()
	check(#pts == 2 and near(pts[2].x, 0.452) and near(pts[2].y, 0.618), "way: comma decimals")
	check(pts[2].text == "Elwynn Forest", "way: default text is the zone name")
	env.cmd("45,5, 61,5, Mine")
	check(near(env.Way.GetPoints()[3].x, 0.455), "way: trailing comma after a number is ignored")
	env.cmd("#104 10 20 Orgrimmar road")
	pts = env.Way.GetPoints()
	check(pts[4].map == 104 and near(pts[4].x, 0.1) and pts[4].text == "Orgrimmar road", "way: #mapID form")
	env.cmd("#9999 10 20")
	check(env.out():find("does not exist", 1, true) and #env.Way.GetPoints() == 4, "way: unknown map ID rejected")
	env.cmd("DUROTAR 33 44")
	check(env.Way.GetPoints()[5].map == 104, "way: zone name, case-insensitive, exact")
	env.cmd("mulg 33 44 Bull")
	check(env.Way.GetPoints()[6].map == 105 and env.Way.GetPoints()[6].text == "Bull", "way: unique prefix")
	env.printed = {}
	env.cmd("dun 1 2")
	check(#env.Way.GetPoints() == 6 and env.out():find("ambiguous", 1, true) and env.out():find("Dun Morogh", 1, true)
		and env.out():find("Dun Algaz", 1, true), "way: ambiguous prefix lists candidates, adds nothing")
	env.printed = {}
	env.cmd("Nowhere 1 2")
	check(#env.Way.GetPoints() == 6 and env.out():find("not found", 1, true), "way: unknown zone adds nothing")
	env.cmd("Elwynn Forest 10 10")
	check(env.Way.GetPoints()[7].map == 100, "way: zone name with two words, own continent first (map 100, not 106)")
	env.playerMap = 104
	env.cmd("Elwynn Forest 10 10")
	check(env.Way.GetPoints()[8].map == 106, "way: own continent first for a duplicate name")
	env.playerMap = 100
	env.printed = {}
	env.cmd("Mulgore 1 2 Text with 3 4 numbers")
	check(env.Way.GetPoints()[9].text == "Text with 3 4 numbers", "way: text keeps later numbers")
	env.printed = {}
	env.cmd("0 100")
	env.cmd("100 0")
	check(#env.Way.GetPoints() == 11, "way: limits 0 and 100 accepted")
end

do
	local env = boot()
	env.cmd("101 50")
	env.cmd("50 100.5")
	env.cmd("abc")
	env.cmd("45")
	check(#env.Way.GetPoints() == 0, "way: out-of-range and malformed input adds nothing")
	check(env.out():find("between 0 and 100", 1, true) and env.out():find("Usage", 1, true), "way: messages for range and usage")
	local before = env.changed
	env.cmd("1 2 " .. ("x"):rep(100))
	check(#env.Way.GetPoints()[1].text == 60 and env.changed > before, "way: text capped at 60 characters")
	env.cmd("1 2 " .. ("ä"):rep(40))
	local t = env.Way.GetPoints()[2].text
	check(#t <= 60 and (#t % 2 == 0) and not t:find("\195$"), "way: text cut keeps multi-byte letters whole")
	env.playerMap = nil
	env.printed = {}
	env.cmd("1 2")
	check(#env.Way.GetPoints() == 2 and env.out():find("not known", 1, true), "way: unknown position, no point, no error")
end

-- list, remove, next

do
	local env = boot()
	env.cmd("")
	check(env.out():find("no points", 1, true), "way: empty list says so")
	env.cmd("10 10 A")
	env.cmd("20 20 B")
	env.cmd("30 30 C")
	env.printed = {}
	env.moveTo(0.1, 0.1)
	env.cmd("")
	local out = env.out()
	check(out:find("1. A", 1, true) and out:find("2. B", 1, true) and out:find("3. C", 1, true), "way: list shows numbers and texts")
	check(out:find("10.0, 10.0", 1, true) and out:find("Elwynn Forest", 1, true), "way: list shows zone and coordinates")
	check(out:find("0 yd", 1, true) and out:find("141 yd", 1, true), "way: list shows distances: " .. out)
	local n = env.Way.GetActive()
	check(n and n.text == "C", "way: last added is active")
	env.printed = {}
	env.cmd("next")
	check(select(2, env.Way.GetActive()) == 1 and env.out():find("point 1", 1, true), "way: next wraps to the first")
	env.cmd("naechster")
	check(select(2, env.Way.GetActive()) == 2, "way: naechster moves on")
	env.cmd("weg 1")
	check(#env.Way.GetPoints() == 2 and select(2, env.Way.GetActive()) == 1 and env.Way.GetPoints()[1].text == "B", "way: remove one, active index follows")
	env.cmd("remove 5")
	check(#env.Way.GetPoints() == 2 and env.out():find("no point 5", 1, true), "way: removing a missing number says so")
	env.cmd("remove 2")
	check(#env.Way.GetPoints() == 1 and select(2, env.Way.GetActive()) == 1, "way: removing a later point keeps the active one")
	env.cmd("remove 1")
	check(#env.Way.GetPoints() == 0 and env.Way.GetActive() == nil and env.wp == nil and env.super == false, "way: removing the active point clears the game waypoint")
	env.cmd("1 1")
	env.cmd("2 2")
	env.cmd("ALLE".. "")
	env.cmd("weg alle")
	check(#env.Way.GetPoints() == 0 and env.wp == nil, "way: remove all (weg alle)")
	env.cmd("1 1")
	env.cmd("remove ALL")
	check(#env.Way.GetPoints() == 0, "way: remove all (English)")
	env.printed = {}
	env.cmd("next")
	check(env.out():find("no points", 1, true), "way: next without points")
end

-- cap

do
	local env = boot()
	for i = 1, 50 do env.cmd(("%d 5"):format(i)) end
	check(#env.Way.GetPoints() == 50, "way: 50 points fit")
	env.printed = {}
	env.cmd("60 60")
	check(#env.Way.GetPoints() == 50 and env.out():find("full", 1, true), "way: the 51st is refused")
	check(env.Way.Add(100, 0.5, 0.5, "x") == nil, "way: Add refuses when full")
end

-- game waypoint

do
	local env = boot()
	env.cmd("50 50 Spot")
	check(env.wp and env.wp.uiMapID == 100 and near(env.wp.position.x, 0.5) and near(env.wp.position.y, 0.5), "way: active point set as user waypoint")
	check(env.super == true, "way: and super-tracked")
	check(env.Way.driver.shown, "way: arrival frame runs while a point is active")
	-- manual clear
	env.wp, env.super = nil, false
	env.fire("USER_WAYPOINT_UPDATED")
	check(env.Way.GetActive() == nil and #env.Way.GetPoints() == 1, "way: manual clear stops tracking, keeps the point")
	check(not env.Way.driver.shown, "way: no arrival checks after a manual clear")
	env.moveTo(0.5, 0.5)
	env.driverTick()
	check(#env.Way.GetPoints() == 1, "way: paused point is not consumed by arrival")
	env.cmd("next")
	check(env.Way.GetActive() and env.wp and env.super, "way: next makes it active again after a manual clear")
	-- replaced by hand
	env.wp = { uiMapID = 104, position = env.g.CreateVector2D(0.3, 0.3) }
	env.fire("USER_WAYPOINT_UPDATED")
	check(env.Way.GetActive() == nil and #env.Way.GetPoints() == 1, "way: replaced waypoint stops tracking, keeps the point")
	-- own set does not look like a manual change
	env.cmd("next")
	env.fire("USER_WAYPOINT_UPDATED")
	env.fire("SUPER_TRACKING_CHANGED")
	check(env.Way.GetActive() ~= nil, "way: our own waypoint event keeps tracking")
	-- pin click makes active
	env.wp = nil
	env.fire("USER_WAYPOINT_UPDATED")
	check(env.Way.GetActive() == nil, "way: cleared again")
	env.Way.PinClick(1, "LeftButton", false)
	check(env.Way.GetActive() ~= nil and env.wp ~= nil, "way: click on a pin activates again")
end

do
	local env = boot()
	env.cmd("#110 50 50 Inn")
	local wp = env.wp
	check(wp and wp.uiMapID == 100, "way: parent map used when the zone does not allow a waypoint")
	check(wp and near(wp.position.x, 0.4 + 0.5 * 1) and near(wp.position.y, 0.9), "way: position translated through world coordinates: " .. tostring(wp and wp.position.x))
	check(env.super, "way: parent fallback is super-tracked")
	env.maps[100].can = false
	env.maps[13].can = false
	env.cmd("#110 10 10 Nope")
	check(#env.Way.GetPoints() == 2 and env.out():find("cannot mark", 1, true), "way: no map allows it, point kept, said once")
	env.printed = {}
	env.cmd("#110 20 20 Nope again")
	check(not env.out():find("cannot mark", 1, true), "way: said only once")
	check(env.Way.GetActive() and env.Way.GetActive().text == "Nope again", "way: the point is still active without a marker")
end

do
	local env = boot({ noMarker = true })
	env.cmd("10 10 A")
	check(#env.Way.GetPoints() == 1 and #env.errors == 0, "way: without marker functions the list still works")
	check(env.out():find("not available", 1, true), "way: says once the marker is not available")
	env.printed = {}
	env.cmd("20 20 B")
	check(not env.out():find("not available", 1, true), "way: not repeated")
	env.moveTo(0.2, 0.2)
	env.driverTick()
	check(#env.Way.GetPoints() == 1, "way: arrival still works without marker functions")
end

-- arrival

do
	local env = boot()
	env.cmd("10 10 First")
	env.cmd("50 50 Second")
	env.cmd("next")
	check(select(2, env.Way.GetActive()) == 1, "way: setup, first active")
	env.moveTo(0.1, 0.1 + 11 / 1000)
	env.driverTick()
	check(#env.Way.GetPoints() == 2, "way: 11 yards is not there yet")
	env.moveTo(0.1, 0.1 + 9 / 1000)
	env.printed = {}
	local acc = env.Way.driver
	acc.scripts.OnUpdate(acc, 0.2)
	check(#env.Way.GetPoints() == 2, "way: checks only every 0.5 seconds")
	acc.scripts.OnUpdate(acc, 0.3)
	local pts = env.Way.GetPoints()
	check(#pts == 1 and pts[1].text == "Second" and env.out():find("Reached: First", 1, true), "way: arrival removes the point and says so")
	check(select(2, env.Way.GetActive()) == 1 and env.wp and near(env.wp.position.x, 0.5), "way: the next point is active and set as waypoint")
	env.moveTo(0.5, 0.5)
	env.driverTick()
	check(#env.Way.GetPoints() == 0 and env.Way.GetActive() == nil and env.wp == nil and not env.Way.driver.shown, "way: last point reached, nothing active, frame idle")
end

do
	local env = boot({ options = { auto_next = false } })
	env.cmd("10 10 First")
	env.cmd("50 50 Second")
	env.cmd("next")
	env.moveTo(0.1, 0.1)
	env.driverTick()
	check(#env.Way.GetPoints() == 1 and env.Way.GetActive() == nil, "way: option off, arrival removes but activates nothing")
end

do
	local env = boot()
	env.cmd("10 10 A")
	env.moveTo(0.1, 0.1)
	env.combat = true
	env.fire("PLAYER_REGEN_DISABLED")
	check(not env.Way.driver.shown, "way: arrival frame idle in combat")
	env.driverTick()
	check(#env.Way.GetPoints() == 1, "way: no arrival check in combat, even if the frame ran")
	env.combat = false
	env.fire("PLAYER_REGEN_ENABLED")
	check(env.Way.driver.shown, "way: arrival frame resumes after combat")
	env.driverTick()
	check(#env.Way.GetPoints() == 0, "way: arrival after combat")
end

do
	local env = boot()
	env.cmd("10 10 A")
	env.noWorld = true
	env.driverTick()
	env.noWorld = false
	env.px = nil
	env.driverTick()
	env.px = SECRET
	env.driverTick()
	env.px = 0.1
	env.playerMap = nil
	env.driverTick()
	check(#env.Way.GetPoints() == 1 and #env.errors == 0 and #env.printed == 1, "way: unreadable position skips arrival quietly")
	env.playerMap = 104
	env.px, env.py = 0.1, 0.1
	env.driverTick()
	check(#env.Way.GetPoints() == 1, "way: another continent never arrives")
end

-- slash ownership

do
	local env = boot({ otherWay = true })
	check(env.g.SlashCmdList.SEMPREWAY == nil and env.g.SLASH_SEMPREWAY1 == nil, "way: /way not registered when another addon owns it")
	check(#env.loadPrinted == 1 and env.loadPrinted[1]:find("/sempre way", 1, true), "way: one line points to /sempre way")
	env.fire("PLAYER_ENTERING_WORLD")
	check(#env.loadPrinted == 1 and #env.printed == 0, "way: said once only")
	env.S.commands.way("10 10 Here")
	check(#env.Way.GetPoints() == 1, "way: /sempre way still works")
end

do
	local env = boot()
	env.g.SLASH_LATE1 = "/way"
	env.fire("PLAYER_ENTERING_WORLD")
	check(env.g.SlashCmdList.SEMPREWAY == nil and env.g.SLASH_SEMPREWAY1 == nil and env.out():find("/sempre way", 1, true), "way: a later owner found at login makes us step back")
	env.S.commands.way("10 10 Here")
	check(#env.Way.GetPoints() == 1, "way: /sempre way works after stepping back")
end

-- persistence

do
	local old = T0 - 31 * DAY
	local recent = T0 - 5 * DAY
	local db = { version = 1, chars = { ["Tester-Realm"] = {
		points = {
			{ map = 100, x = 0.1, y = 0.1, text = "Old", created = old },
			{ map = 100, x = 0.2, y = 0.2, text = "Keep A", created = recent },
			{ map = 100, x = 0.3, y = 0.3, text = "Keep B", created = recent },
		},
		active = 3,
	} } }
	local env = boot({ db = db })
	local pts = env.Way.GetPoints()
	check(#pts == 2 and pts[1].text == "Keep A" and pts[2].text == "Keep B", "way: points older than 30 days dropped at login")
	local a, n = env.Way.GetActive()
	check(a and a.text == "Keep B" and n == 2, "way: active index follows the dropped point")
	check(env.wp and near(env.wp.position.x, 0.3) and env.super, "way: active point set as game waypoint again at login")
	check(env.g.SempreWayDB.chars["Tester-Realm"].points == env.Way.char.points, "way: data lives in SempreWayDB per character")

	db.chars["Tester-Realm"].points[1].created = old
	local env2 = boot({ db = { version = 1, chars = { ["Tester-Realm"] = { points = { { map = 100, x = 0.1, y = 0.1, text = "Old", created = old } }, active = 1 } } } })
	check(#env2.Way.GetPoints() == 0 and env2.Way.GetActive() == nil and env2.wp == nil, "way: dropping the active point leaves nothing active")

	local env3 = boot({ db = { version = 1, chars = { ["Tester-Realm"] = { points = { { map = 100, x = 0.1, y = 0.1, text = "P", created = recent } }, active = 1, paused = true } } } })
	check(env3.wp == nil and env3.Way.GetActive() == nil and #env3.Way.GetPoints() == 1, "way: a paused point stays paused after login")

	local env4 = boot({ db = { version = 1, chars = { ["Tester-Realm"] = { points = { "junk", { map = 100 } } } } } })
	check(#env4.errors == 0 and #env4.Way.GetPoints() == 0, "way: damaged saved points are dropped without errors")
end

-- interface

do
	local env = boot()
	local before = env.changed
	local n = env.Way.Add(100, 0.25, 0.75, "From loot")
	check(n == 1 and env.changed == before + 1, "way: Add returns the number and sends WAY_CHANGED")
	check(env.Way.GetActive() and env.Way.GetActive().text == "From loot", "way: Add activates when nothing is active")
	local m = env.Way.Add(100, 0.5, 0.5, "Second")
	check(m == 2 and select(2, env.Way.GetActive()) == 1, "way: Add keeps the current active point")
	check(env.Way.Add(100, 1.5, 0.5) == nil and env.Way.Add("x", 0.5, 0.5) == nil and env.Way.Add(100, SECRET, 0.5) == nil, "way: Add rejects bad input")
	local list = env.Way.GetPoints()
	list[1].text = "changed"
	list[1].x = 0
	check(env.Way.GetPoints()[1].text == "From loot" and near(env.Way.GetPoints()[1].x, 0.25), "way: GetPoints returns copies")
	before = env.changed
	env.cmd("remove 2")
	check(env.changed > before, "way: WAY_CHANGED after a removal")
	before = env.changed
	env.cmd("next")
	check(env.changed > before, "way: WAY_CHANGED after next")
end

-- map pins

do
	local env = boot()
	env.cmd("50 50 Here")
	env.cmd("#110 50 50 Inn")
	env.cmd("#104 50 50 Far")
	env.cmd("#102 50 50 Beyond")
	local pins = env.Way.GetPins(100)
	check(#pins == 2 and pins[1].index == 1 and pins[2].index == 2, "way: pins for a map include points on child maps")
	check(near(pins[2].x, 0.9) and near(pins[2].y, 0.9), "way: child map points are translated to the shown map")
	check(#env.Way.GetPins(104) == 1 and #env.Way.GetPins(999) == 0 and #env.Way.GetPins(nil) == 0, "way: pins only on the right map")
	env.maps[110].oy = 9000
	check(#env.Way.GetPins(100) == 1, "way: a child point outside the shown map has no pin")
end

do
	local env = boot()
	env.cmd("50 50 Here")
	env.cmd("20 20 There")
	check(rawget(env.canvas, "point") == nil, "way: no pin layer before the map opens")
	local before = #env.frames
	local wm = env.wm
	wm.shown = true
	wm.hooks.OnShow()
	check(#env.frames == before + 2 and env.canvas.shown, "way: pins are built when the map first opens")
	wm.OnMapChanged(wm)
	check(#env.frames == before + 2, "way: pins are reused")
	local pin = env.frames[before + 1]
	check(pin.index == 1 and pin.point and pin.point[1] == "CENTER" and pin.point[4] == 500 and pin.point[5] == -250, "way: pin placed relative to the canvas")
	env.shift = false
	pin.scripts.OnClick(pin, "RightButton")
	check(#env.Way.GetPoints() == 2, "way: right click without Shift does not delete")
	env.shift = true
	pin.scripts.OnClick(pin, "RightButton")
	check(#env.Way.GetPoints() == 1 and env.Way.GetPoints()[1].text == "There", "way: Shift + right click removes")
	wm.mapID = 104
	wm.OnMapChanged(wm)
	check(not env.frames[before + 1].shown and not env.frames[before + 2].shown, "way: pins hide on a map without points")
	local p2 = env.frames[before + 2]
	wm.mapID = 100
	wm.OnMapChanged(wm)
	check(env.frames[before + 1].shown, "way: pins come back with the map")
	env.cmd("30 30 More")
	check(p2.shown or env.frames[before + 1].shown, "way: list changes refresh the pins")
	pin.scripts.OnClick(pin, "LeftButton")
	check(select(2, env.Way.GetActive()) == 1, "way: left click makes the pin's point active")
	pin.scripts.OnEnter(pin)
	check(#env.errors == 0, "way: pin tooltip without errors")
end

do
	local env = boot()
	local wm = env.wm
	wm.mapID = 100
	local scroll = wm.ScrollContainer
	check(scroll.hooks.OnMouseUp ~= nil, "way: map click hook installed")
	scroll.GetNormalizedCursorPosition = function() return 0.3, 0.4 end
	env.ctrl = true
	scroll.hooks.OnMouseUp(scroll, "RightButton")
	local pts = env.Way.GetPoints()
	check(#pts == 1 and pts[1].map == 100 and near(pts[1].x, 0.3) and near(pts[1].y, 0.4), "way: Ctrl + right click adds a point")
	check(pts[1].text == "Elwynn Forest 30.0, 40.0" and env.Way.GetActive(), "way: its text is zone name and coordinates")
	env.ctrl = false
	scroll.hooks.OnMouseUp(scroll, "RightButton")
	env.ctrl = true
	scroll.hooks.OnMouseUp(scroll, "LeftButton")
	check(#env.Way.GetPoints() == 1, "way: plain right click and Ctrl + left click add nothing")
	scroll.GetNormalizedCursorPosition = function() return nil end
	scroll.hooks.OnMouseUp(scroll, "RightButton")
	check(#env.Way.GetPoints() == 1, "way: a click without a cursor position adds nothing")
	scroll.GetNormalizedCursorPosition = function() return 1.2, 0.4 end
	scroll.hooks.OnMouseUp(scroll, "RightButton")
	check(#env.Way.GetPoints() == 1, "way: a click outside the canvas adds nothing")

	local env2 = boot({ options = { click_add = false } })
	local s2 = env2.wm.ScrollContainer
	s2.GetNormalizedCursorPosition = function() return 0.3, 0.4 end
	env2.ctrl = true
	s2.hooks.OnMouseUp(s2, "RightButton")
	check(#env2.Way.GetPoints() == 0, "way: option off, Ctrl + right click adds nothing")
end

do
	local env = boot({ noWorldMap = true })
	check(#env.errors == 0 and #env.loadPrinted == 0, "way: no world map yet, no error")
	local wm = newFake()
	for k, v in pairs(fakeMethods) do wm[k] = v end
	wm.ScrollContainer = newFake()
	wm.ScrollContainer.HookScript = fakeMethods.HookScript
	env.g.WorldMapFrame = wm
	env.fire("ADDON_LOADED", "Blizzard_WorldMap")
	check(wm.hooks.OnShow ~= nil and wm.ScrollContainer.hooks.OnMouseUp ~= nil, "way: hooks the world map when its addon loads later")
end

do
	local env = boot({ noEventUtils = true })
	check(#env.errors == 0, "way: loads without C_EventUtils")
end

end
