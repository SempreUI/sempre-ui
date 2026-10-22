-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Tests for Sempre_Rares with a stubbed WoW API. Loaded by tests/run.lua, which
-- passes in its check helper. Boots the real core, then the module's file, with
-- stubbed units, map position, sound, combat state and secure frames.

return function(check)

local SECRET = "<secret-value>"

local function newFake(kind, template)
	local f = { kind = kind, template = template, shown = true, scripts = {}, registered = {}, attrs = {}, level = 1 }
	return setmetatable(f, { __index = function() return function() end end })
end

local fakeMethods = {
	Show = function(self) self.shown = true end,
	Hide = function(self) self.shown = false end,
	IsShown = function(self) return self.shown end,
	SetScript = function(self, kind, fn) self.scripts[kind] = fn end,
	RegisterEvent = function(self, e) self.registered[e] = true end,
	SetAttribute = function(self, k, v) self.attrs[k] = v end,
	GetFrameLevel = function(self) return self.level end,
	SetText = function(self, t) self.text = t end,
	SetAlpha = function(self, a) self.alpha = a end,
	GetAlpha = function(self) return self.alpha end,
}

local function fake(kind, template)
	local f = newFake(kind, template)
	for k, v in pairs(fakeMethods) do f[k] = v end
	f.CreateFontString = function() return fake("FontString") end
	return f
end

-- opts: options, no (set of missing API names), locale, combat, noMap
local function boot(opts)
	opts = opts or {}
	local no = opts.no or {}
	local env = { printed = {}, errors = {}, frames = {}, timers = {}, sounds = {}, waypoints = {},
		now = 1000, epoch = 1000000, combat = opts.combat or false, units = {}, mapID = 100, px = 0.452, py = 0.618,
		shift = false }
	local g = setmetatable({}, { __index = _G })
	g.table = setmetatable({ wipe = function(t) for k in pairs(t) do t[k] = nil end return t end }, { __index = table })
	g.CreateFrame = function(kind, _, _, template)
		local f = fake(kind, template)
		env.frames[#env.frames + 1] = f
		return f
	end
	g.UIParent = fake("UIParent")
	g.GetLocale = function() return opts.locale or "enUS" end
	g.GetBuildInfo = function() return "1", "", "", 16001 end
	g.UnitName = function(unit)
		local u = env.units[unit]
		if unit == "player" then return "Tester" end
		return u and u.name
	end
	g.GetRealmName = function() return "Realm" end
	g.issecretvalue = function(v) return v == SECRET end
	g.geterrorhandler = function() return function(err) env.errors[#env.errors + 1] = err end end
	g.SlashCmdList = {}
	g.print = function(msg) env.printed[#env.printed + 1] = msg end
	g.C_AddOns = { GetAddOnMetadata = function() return nil end, GetNumAddOns = function() return 0 end }
	g.C_EventUtils = { IsEventValid = function() return true end }
	g.GetTime = function() return env.now end
	g.time = function() return env.epoch end
	g.InCombatLockdown = function() return env.combat end
	g.IsShiftKeyDown = function() return env.shift end
	g.C_Timer = no.timer and {} or { After = function(delay, fn) env.timers[#env.timers + 1] = { delay = delay, fn = fn } end }
	g.UnitClassification = function(unit) local u = env.units[unit] return u and u.class or "normal" end
	g.UnitIsDead = function(unit) local u = env.units[unit] return u and u.dead or false end
	g.UnitIsPlayer = function(unit) local u = env.units[unit] return u and u.player or false end
	g.UnitGUID = function(unit) local u = env.units[unit] return u and u.guid end
	g.UnitLevel = function(unit) local u = env.units[unit] return u and u.level end
	if not no.sound then
		g.C_Sound = { PlaySound = function(kit) env.sounds[#env.sounds + 1] = kit end }
	end
	g.SOUNDKIT = { RAID_WARNING = 8959 }
	g.C_Map = {
		GetBestMapForUnit = function() if opts.noMap then return nil end return env.mapID end,
		GetPlayerMapPosition = function()
			if env.noPos then return nil end
			return { GetXY = function() return env.px, env.py end }
		end,
		GetMapInfo = function(id) return { name = "Zone" .. id } end,
	}

	local function run(path, ...)
		local chunk = assert(loadfile(path))
		setfenv(chunk, g)
		return chunk(...)
	end
	env.g = g
	run("Sempre/Core.lua", "Sempre")
	env.S = g.SempreUI
	env.core = env.frames[1]
	function env.fire(event, ...) env.core.scripts.OnEvent(env.core, event, ...) end
	env.fire("ADDON_LOADED", "Sempre")
	if opts.options then env.S.db.global.options.Sempre_Rares = opts.options end
	env.fire("PLAYER_LOGIN")
	env.sent = {}
	env.S:Listen("RARE_SEEN", function(_, npcID) env.sent[#env.sent + 1] = npcID end)
	if opts.data then g.SempreRaresDB = opts.data end
	env.printed = {}
	run("Sempre_Rares/Rares.lua", "Sempre_Rares")
	env.fire("ADDON_LOADED", "Sempre_Rares")
	env.db = g.SempreRaresDB
	env.R = env.S.Rares
	env.loadPrinted = env.printed
	env.printed = {}

	function env.unit(token, u) env.units[token] = u end
	function env.rare(token, npc, name, extra)
		local u = { class = "rare", guid = "Creature-0-1-2-3-" .. npc .. "-0000ABCDEF", name = name or ("Rare" .. npc), level = 62 }
		for k, v in pairs(extra or {}) do u[k] = v end
		env.units[token] = u
		return u
	end
	function env.plate(token)
		local f = env.R.frame
		f.scripts.OnEvent(f, "NAME_PLATE_UNIT_ADDED", token)
	end
	function env.out() return table.concat(env.printed, "\n") end
	function env.clear() env.printed = {} end
	function env.update(dt)
		local b = env.R.banner
		if b and b.shown then b.scripts.OnUpdate(b, dt) end
	end
	function env.runTimers()
		local list = env.timers
		env.timers = {}
		for _, t in ipairs(list) do t.fn() end
	end
	return env
end

local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

-- Registration and loading

do
	local env = boot()
	check(env.db and env.db.version == 1 and next(env.db.seen) == nil, "saved data created with version and seen list")
	check(env.S:GetOption("Sempre_Rares", "announce") == true and env.S:GetOption("Sempre_Rares", "sound") == true
		and env.S:GetOption("Sempre_Rares", "banner") == true, "three options default on")
	check(#env.S:GetOptionList("Sempre_Rares") == 3, "three checkboxes registered")
	check(#env.loadPrinted == 0, "no chat line at load when everything is available")
	check(env.R.frame.registered.NAME_PLATE_UNIT_ADDED, "nameplate event on the module's own frame")
	check(env.core.registered.PLAYER_TARGET_CHANGED and env.core.registered.UPDATE_MOUSEOVER_UNIT, "target and mouseover through the core")
	check(not env.core.registered.NAME_PLATE_UNIT_ADDED, "nameplate event not on the core frame")
	check(env.S.commands.rares ~= nil, "rares command registered")
	check(env.R.banner == nil, "banner is built on the first sighting only")
end

-- Detection

do
	local env = boot()
	env.rare("nameplate1", 1001, "Alpha")
	env.plate("nameplate1")
	check(#env.sent == 1 and env.sent[1] == 1001, "rare from a nameplate is a sighting and sends RARE_SEEN")
	check(env.out() == "|cffc8794aSempre|r Rare: Alpha (level 62) at 45.2, 61.8", "chat line with coordinates: " .. env.out())
	check(#env.sounds == 1 and env.sounds[1] == 8959, "sound played")
	local e = env.R.GetSeen(1001)
	check(e and e.name == "Alpha" and e.level == 62 and e.class == "rare" and #e.places == 1
		and e.places[1].mapID == 100 and e.places[1].x == 0.452 and e.places[1].y == 0.618, "seen entry with place")

	env.rare("nameplate2", 1002, "Beta", { class = "rareelite", level = -1 })
	env.plate("nameplate2")
	check(env.R.GetSeen(1002) and env.R.GetSeen(1002).class == "rareelite", "rare elite is a sighting")
	check(env.out():find("Beta (level ??)", 1, true), "boss level shows as ??")

	env.rare("target", 1003, "Gamma")
	env.fire("PLAYER_TARGET_CHANGED")
	check(env.R.GetSeen(1003), "target is a sighting")
	env.rare("mouseover", 1004, "Delta")
	env.fire("UPDATE_MOUSEOVER_UNIT")
	check(env.R.GetSeen(1004), "mouseover is a sighting")
	check(#env.sent == 4, "four messages")
end

do
	local env = boot()
	env.unit("nameplate1", { class = "normal", guid = "Creature-0-1-2-3-50-0000ABCDEF", name = "Boar", level = 10 })
	env.unit("nameplate2", { class = "elite", guid = "Creature-0-1-2-3-51-0000ABCDEF", name = "Ogre", level = 10 })
	env.rare("nameplate3", 52, "Dead", { dead = true })
	env.rare("nameplate4", 53, "Player", { player = true })
	env.unit("nameplate5", { class = "rare", guid = "Player-1-0000ABCD", name = "Pl", level = 60 })
	env.unit("nameplate6", { class = "rare", guid = "Item-0-1-2-3-9-0000ABCDEF", name = "Odd", level = 60 })
	for i = 1, 6 do env.plate("nameplate" .. i) end
	check(count(env.db.seen) == 0 and #env.sent == 0 and env.out() == "", "normal, elite, dead, player and non-creature units are ignored")
	env.plate(nil)
	env.plate(SECRET)
	check(#env.errors == 0, "missing or secret unit token is harmless")
end

do
	-- Secret values.
	local env = boot()
	env.rare("nameplate1", 60, "A", { guid = SECRET })
	env.plate("nameplate1")
	env.rare("nameplate2", 61, SECRET)
	env.plate("nameplate2")
	env.rare("nameplate3", 62, "C", { class = SECRET })
	env.plate("nameplate3")
	check(count(env.db.seen) == 0 and #env.sent == 0 and #env.errors == 0, "secret GUID, name or classification: ignored without error")
	env.rare("nameplate4", 63, "D", { level = SECRET })
	env.plate("nameplate4")
	check(env.R.GetSeen(63) and env.R.GetSeen(63).level == nil and env.out():find("(level ?)", 1, true), "secret level is stored as unknown")
	env.rare("nameplate5", 64, "E", { dead = SECRET, player = SECRET })
	env.plate("nameplate5")
	check(env.R.GetSeen(64), "secret dead and player flags do not block")
end

-- Throttles

do
	local env = boot()
	env.rare("nameplate1", 70, "Same")
	env.plate("nameplate1")
	env.now = env.now + 59
	env.plate("nameplate1")
	check(#env.sent == 1, "same GUID inside the window is ignored")
	env.now = env.now + 2
	env.plate("nameplate1")
	check(#env.sent == 1, "same GUID is still ignored after 60 seconds")
	env.now = env.now + 245
	env.plate("nameplate1")
	check(#env.sent == 2, "same GUID counts again after 5 minutes")

	-- Same NPC, new GUID: 60 s.
	env.rare("nameplate2", 71, "Twin")
	env.plate("nameplate2")
	env.units.nameplate3 = { class = "rare", guid = "Creature-0-1-2-3-71-0000ZZZZZZ", name = "Twin", level = 62 }
	env.now = env.now + 30
	env.plate("nameplate3")
	check(#env.sent == 3, "same NPC ID with another GUID inside 60 seconds is ignored")
	env.now = env.now + 31
	env.plate("nameplate3")
	check(#env.sent == 4, "same NPC ID counts again after 60 seconds")
end

-- Alerts and options

do
	local env = boot({ locale = "deDE" })
	env.rare("nameplate1", 80, "Gruk")
	env.plate("nameplate1")
	check(env.out() == "|cffc8794aSempre|r Rare: Gruk (Stufe 62) bei 45.2, 61.8", "German chat line: " .. env.out())
end

do
	local env = boot({ options = { sound = false } })
	env.rare("nameplate1", 81, "Quiet")
	env.plate("nameplate1")
	check(#env.sounds == 0 and env.out():find("Quiet") and env.R.banner and env.R.banner.shown, "sound off: chat and banner stay")

	env = boot({ options = { banner = false } })
	env.rare("nameplate1", 82, "NoBanner")
	env.plate("nameplate1")
	check(env.R.banner == nil and #env.sounds == 1 and env.out():find("NoBanner"), "banner off: no banner built")

	env = boot({ options = { announce = false } })
	env.rare("nameplate1", 83, "Silent")
	env.plate("nameplate1")
	check(env.out() == "" and #env.sounds == 0 and env.R.banner == nil, "announce off: no chat, sound or banner")
	check(env.R.GetSeen(83) and #env.sent == 1, "announce off: still listed and RARE_SEEN sent")

	env = boot({ no = { sound = true } })
	check(env.loadPrinted[1] and env.loadPrinted[1]:find("sound is not available"), "missing sound API: message at load")
	env.rare("nameplate1", 84, "NoSound")
	env.plate("nameplate1")
	check(#env.errors == 0 and env.out():find("NoSound"), "missing sound API: rest works")

	env = boot({ noMap = true })
	env.rare("nameplate1", 85, "Instance")
	env.plate("nameplate1")
	check(env.out() == "|cffc8794aSempre|r Rare: Instance (level 62)", "unreadable position: line without coordinates")
	check(env.R.GetSeen(85) and #env.R.GetSeen(85).places == 0, "unreadable position: no place stored")
end

-- Banner

do
	local env = boot()
	env.rare("nameplate1", 90, "Banner Boss")
	env.plate("nameplate1")
	local b, s = env.R.banner, env.R.secure
	check(b and b.shown and b.title.text == "Banner Boss" and b.info.text == "Level 62  Rare", "banner shows name, level and class")
	check(s and s.template == "SecureActionButtonTemplate" and s.attrs.type1 == "macro"
		and s.attrs.macrotext1 == "/targetexact Banner Boss", "secure button with exact-name macro out of combat")
	check(not env.R.shield.shown, "shield is down while the click action is armed")
	check(b.hint.text == "Click to target", "click hint")
	env.update(10)
	check(b.shown and b.alpha == 1, "banner still shown after 10 seconds")
	env.update(4.5)
	check(b.shown and b.alpha < 1, "banner fades in its last second")
	env.update(1)
	check(not b.shown, "banner hides after 15 seconds")

	-- Hover pauses the fade.
	env.now = env.now + 400
	env.plate("nameplate1")
	check(b.shown, "banner shown again")
	s.scripts.OnEnter(s)
	env.update(30)
	check(b.shown and b.alpha == 1, "hover pauses the fade")
	s.scripts.OnLeave(s)
	env.update(14)
	check(b.shown, "after leaving, the timer starts anew")
	env.update(2)
	check(not b.shown, "banner hides after hover ends")

	-- Right click closes.
	env.now = env.now + 400
	env.plate("nameplate1")
	s.scripts.PostClick(s, "RightButton")
	check(not b.shown, "right click closes the banner")
	env.now = env.now + 400
	env.plate("nameplate1")
	s.scripts.PostClick(s, "LeftButton")
	check(b.shown, "left click leaves closing to the secure action")
end

do
	-- Shift + right click: waypoint.
	local env = boot()
	env.rare("nameplate1", 91, "Way Rare")
	env.plate("nameplate1")
	local s = env.R.secure
	env.shift = true
	s.scripts.PostClick(s, "RightButton")
	check(env.R.banner.shown and #env.waypoints == 0, "Shift + right click without Way does nothing")
	check(#env.errors == 0, "no error without Way")
	env.S.Way = { Add = function(map, x, y, text) env.waypoints[#env.waypoints + 1] = { map, x, y, text } end }
	s.scripts.PostClick(s, "RightButton")
	local w = env.waypoints[1]
	check(w and w[1] == 100 and w[2] == 0.452 and w[3] == 0.618 and w[4] == "Way Rare", "Shift + right click adds a waypoint at the player's position")
	check(env.R.banner.shown, "the banner stays after the waypoint")
	env.shift = false
	env.R.shield.scripts.OnMouseUp(env.R.shield, "RightButton")
	check(not env.R.banner.shown, "the shield closes the banner on right click too")
end

do
	-- First sighting in combat: plain banner with the hint, action at combat end.
	local env = boot({ combat = true })
	env.rare("nameplate1", 92, "Combat Rare")
	env.plate("nameplate1")
	local b = env.R.banner
	check(b and b.shown and env.R.secure == nil, "in combat: banner without secure button")
	check(env.R.shield.shown, "in combat: plain shield takes the clicks")
	for _, f in ipairs(env.frames) do
		check(f.template ~= "SecureActionButtonTemplate", "no secure frame created in combat")
	end
	check(env.R.banner.hint.text == "In combat: /tar Combat Rare", "combat hint with the name")
	env.combat = false
	env.fire("PLAYER_REGEN_ENABLED")
	local s = env.R.secure
	check(s and s.attrs.macrotext1 == "/targetexact Combat Rare", "combat end: secure button created and armed")
	check(not env.R.shield.shown, "combat end: shield removed")
	check(b.hint.text == "Click to target", "combat end: hint replaced")

	-- Banner already gone at combat end: nothing is armed.
	env = boot({ combat = true })
	env.rare("nameplate1", 93, "Gone")
	env.plate("nameplate1")
	env.update(16)
	env.combat = false
	env.fire("PLAYER_REGEN_ENABLED")
	check(env.R.secure and env.R.secure.attrs.macrotext1 == nil, "banner gone: secure button built at combat end but not armed")

	-- Second rare in combat while the button holds the first one.
	env = boot()
	env.rare("nameplate1", 94, "First")
	env.plate("nameplate1")
	env.combat = true
	env.rare("nameplate2", 95, "Second")
	env.plate("nameplate2")
	check(env.R.secure.attrs.macrotext1 == "/targetexact First", "attributes are not touched in combat")
	check(env.R.shield.shown, "stale action is covered by the shield")
	env.combat = false
	env.fire("PLAYER_REGEN_ENABLED")
	check(env.R.secure.attrs.macrotext1 == "/targetexact Second" and not env.R.shield.shown, "combat end: action follows the shown rare")
end

do
	-- Combat hint text in German.
	local env = boot({ combat = true, locale = "deDE" })
	env.rare("nameplate1", 96, "Kampf")
	env.plate("nameplate1")
	check(env.R.banner.hint.text == "Im Kampf: /tar Kampf" and env.R.banner.info.text == "Stufe 62  Rar", "German combat hint and info line")
	env.combat = false
	env.fire("PLAYER_REGEN_ENABLED")
	check(env.R.banner.hint.text == "Klicken zum Anvisieren", "German click hint")
end

-- Seen list

do
	local env = boot()
	env.rare("nameplate1", 100, "Walker")
	env.plate("nameplate1")
	env.now = env.now + 100
	env.px, env.py = 0.46, 0.62 -- within 2 %
	env.units.nameplate1.guid = "Creature-0-1-2-3-100-0000NEWGUID"
	env.plate("nameplate1")
	local e = env.R.GetSeen(100)
	check(#e.places == 1 and e.places[1].x == 0.46, "near place on the same map updates the existing one")
	env.now = env.now + 100
	env.px, env.py = 0.60, 0.20
	env.units.nameplate1.guid = "Creature-0-1-2-3-100-0000THIRDGU"
	env.plate("nameplate1")
	e = env.R.GetSeen(100)
	check(#e.places == 2 and e.places[1].x == 0.6, "far place is added, newest first")
	env.now = env.now + 100
	env.mapID = 200
	env.px, env.py = 0.60, 0.20
	env.units.nameplate1.guid = "Creature-0-1-2-3-100-0000FOURTHGU"
	env.plate("nameplate1")
	check(#env.R.GetSeen(100).places == 3, "same spot on another map is a new place")

	for i = 1, 14 do
		env.now = env.now + 100
		env.mapID = 300
		env.px, env.py = 0.05 * i, 0.9 - 0.05 * i
		env.units.nameplate1.guid = "Creature-0-1-2-3-100-" .. string.format("%010d", i)
		env.plate("nameplate1")
	end
	check(#env.R.GetSeen(100).places == 10, "places capped at 10")

	-- Copies: changing the result does not change the data.
	local copy = env.R.GetSeen(100)
	copy.places[1].x = 9
	copy.name = "Changed"
	check(env.R.GetSeen(100).places[1].x ~= 9 and env.R.GetSeen(100).name == "Walker", "GetSeen returns a copy")
	check(env.R.GetSeen(999) == nil, "unknown NPC: nil")

	local here = env.R.GetSeenOnMap(300)
	check(#here == 10 and here[1].x == 0.7 and here[1].npcID == 100 and here[1].name == "Walker", "GetSeenOnMap lists places of that map, newest first")
	check(#env.R.GetSeenOnMap(12345) == 0, "map without rares: empty list")
end

do
	-- Cap of 500 NPCs, least recently seen dropped first.
	local env = boot()
	for i = 1, 501 do
		env.now = env.now + 1
		env.epoch = env.epoch + 1
		env.rare("nameplate1", 1000 + i, "N" .. i)
		env.plate("nameplate1")
	end
	check(count(env.db.seen) == 500 and env.db.seen[1001] == nil and env.db.seen[1501] and env.db.seen[1002], "501st NPC drops the least recently seen")
	-- A re-seen NPC is protected.
	env.now = env.now + 100
	env.epoch = env.epoch + 100
	env.plate("nameplate1")
	env.epoch = env.epoch + 1
	env.rare("nameplate1", 2000, "Newest")
	env.plate("nameplate1")
	check(count(env.db.seen) == 500 and env.db.seen[1002] == nil and env.db.seen[1003], "next drop takes the next oldest")
	local last = env.R.GetSeen(1501)
	check(last and last.last > env.R.GetSeen(1003).last, "re-seen NPC has a newer time")
end

do
	-- Bad saved data is cleaned.
	local env = boot({ data = { version = 1, seen = { [5] = { name = "Ok", last = 5, places = {} }, [6] = "junk", [7] = { name = 3 } } } })
	check(count(env.db.seen) == 1 and env.db.seen[5], "invalid saved entries are dropped")
end

-- Commands

do
	local env = boot()
	env.S.commands.rares("")
	check(env.out():find("none seen yet"), "empty list message")
	env.clear()
	for i = 1, 12 do
		env.now = env.now + 100
		env.epoch = env.epoch + 120
		env.rare("nameplate1", 300 + i, "R" .. i)
		env.plate("nameplate1")
	end
	env.clear()
	env.S.commands.rares("")
	local lines = env.printed
	check(#lines == 11 and lines[2]:find("R12 (level 62), Zone100, ", 1, true) and lines[11]:find("R3 (level", 1, true), "last 10 rares, newest first: " .. #lines)
	check(lines[3]:find("2 min ago", 1, true) and lines[2]:find("just now", 1, true), "age shown: " .. tostring(lines[3]))

	env.clear()
	env.mapID = 100
	env.S.commands.rares("here")
	check(#env.printed == 13 and env.printed[2]:find("R12 (level 62) at 45.2, 61.8,", 1, true), "here: rares on this map with places")
	env.clear()
	env.mapID = 555
	env.S.commands.rares("hier")
	check(env.out():find("none seen on this map"), "hier on an empty map")
	env.clear()
	env.S.commands.rares("bogus")
	check(env.out():find("Usage:"), "unknown subcommand prints usage")
	env.clear()
	env.S.commands.rares("forget")
	check(count(env.db.seen) == 0 and env.out():find("list cleared"), "forget clears the list")
	env.rare("nameplate1", 400, "After")
	env.now = env.now + 1000
	env.plate("nameplate1")
	check(env.R.GetSeen(400), "list works after forgetting")
	env.S.commands.rares("vergessen")
	check(count(env.db.seen) == 0, "vergessen clears too")
end

do
	local env = boot({ locale = "deDE", noMap = true })
	env.S.commands.rares("hier")
	check(env.out():find("nicht lesbar"), "hier without a readable map")
	env.clear()
	env.S.commands.rares("")
	check(env.out():find("Noch keine gesehen"), "German empty message")
end

-- Nameplate hint

do
	local env = boot()
	check(#env.timers == 1 and env.timers[1].delay == 300, "hint timer of 5 minutes")
	env.runTimers()
	check(env.out():find("enemy nameplates"), "hint after 5 minutes without nameplates")
	check(#env.timers == 0, "hint is said once")

	env = boot()
	env.rare("nameplate1", 500, "Seen")
	env.plate("nameplate1")
	env.clear()
	env.runTimers()
	check(env.out() == "", "no hint once a nameplate was seen")

	env = boot({ no = { timer = true } })
	check(#env.errors == 0, "missing timer API: no error")
end

end
