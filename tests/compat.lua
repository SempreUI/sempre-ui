-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Tests for Sempre/Compat.lua with a stubbed addon list and frame API.
-- Loaded by tests/run.lua, which passes in its check helper.

return function(check)

local function newFrame(env, kind)
	local f = { kind = kind, scripts = {}, shown = kind == "Button", checked = false }
	env.frames[#env.frames + 1] = f
	local methods = {
		Show = function(self) self.shown = true end,
		Hide = function(self)
			if self.shown then
				self.shown = false
				if self.scripts.OnHide then self.scripts.OnHide(self) end
			end
		end,
		IsShown = function(self) return self.shown end,
		SetScript = function(self, k, fn) self.scripts[k] = fn end,
		SetText = function(self, t) self.text = t end,
		SetChecked = function(self, v) self.checked = v and true or false end,
		GetChecked = function(self) return self.checked end,
		GetStringHeight = function() return 14 end,
		CreateFontString = function() return newFrame(env, "FontString") end,
		SetFont = function() return true end,
	}
	return setmetatable(f, { __index = function(_, k) return methods[k] or function() end end })
end

local MODULES = { "Sempre_Buttons", "Sempre_Butler", "Sempre_Items", "Sempre_Map", "Sempre_Rares", "Sempre_Way" }

-- opts: addons (list of { folder, title, loaded }), db, combat, locale,
-- news (the what's new window opens too), without (module folders not installed),
-- off (module folders switched off)
local function boot(opts)
	opts = opts or {}
	local env = { printed = {}, frames = {}, timers = {}, combat = opts.combat or false, switched = {}, reloaded = 0 }
	local list = { { "Sempre", "SempreUI", true } }
	local without, off = {}, {}
	for _, n in ipairs(opts.without or {}) do without[n] = true end
	for _, n in ipairs(opts.off or {}) do off[n] = true end
	for _, n in ipairs(MODULES) do
		if not without[n] then list[#list + 1] = { n, n, false, true } end
	end
	for _, a in ipairs(opts.addons or {}) do list[#list + 1] = { a[1], a[2] or a[1], a[3] ~= false } end
	local events = {}
	local frame = { scripts = {} }
	function frame.RegisterEvent(_, e) events[e] = true end
	function frame.UnregisterEvent(_, e) events[e] = nil end
	function frame.SetScript(_, k, fn) frame.scripts[k] = fn end
	local g = setmetatable({}, { __index = _G })
	g._G = g
	g.table = setmetatable({ wipe = function(t) for k in pairs(t) do t[k] = nil end return t end }, { __index = table })
	local coreFrame = true
	g.CreateFrame = function(kind)
		if coreFrame then
			coreFrame = false
			return frame
		end
		return newFrame(env, kind)
	end
	g.GetLocale = function() return opts.locale or "enUS" end
	g.GetBuildInfo = function() return "1", "", "", 16001 end
	g.UnitName = function() return "Tester" end
	g.GetRealmName = function() return "Realm" end
	g.time = os.time
	g.geterrorhandler = function() return function() end end
	g.SlashCmdList = {}
	g.print = function(msg) env.printed[#env.printed + 1] = msg end
	g.C_AddOns = {
		GetAddOnMetadata = function(name, key)
			for _, a in ipairs(list) do
				if a[1] == name and a[4] and key == "X-Sempre-Module" then return "1" end
			end
		end,
		GetNumAddOns = function() return #list end,
		GetAddOnInfo = function(i) return list[i][1], list[i][2] end,
		IsAddOnLoaded = function(name)
			for _, a in ipairs(list) do
				if a[1] == name then return a[3] end
			end
			return false
		end,
		GetAddOnEnableState = function(name) return off[name] and 0 or 2 end,
	}
	g.InCombatLockdown = function() return env.combat end
	g.UIParent = newFrame(env, "Frame")
	g.C_Timer = { After = function(sec, fn) env.timers[#env.timers + 1] = { sec = sec, fn = fn } end }
	g.ReloadUI = function() env.reloaded = env.reloaded + 1 end
	g.SempreDB = opts.db
	-- Saved data from an older version, so the news window opens.
	if opts.news and not opts.db then g.SempreDB = { global = { options = {} } } end
	local function run(path)
		local chunk = assert(loadfile(path))
		setfenv(chunk, g)
		return chunk("Sempre")
	end
	for _, file in ipairs({ "Core", "Fonts", "News", "NewsWindow", "Compat" }) do run("Sempre/" .. file .. ".lua") end
	local S = g.SempreUI
	env.S, env.g = S, g
	-- The shared module switch of Settings.lua, recorded here.
	S.SetModuleEnabled = function(name, on, quiet)
		env.switched[#env.switched + 1] = name .. ":" .. tostring(on) .. ":" .. tostring(quiet)
		off[name] = not on or nil
		return true
	end
	function env.fire(event, ...) frame.scripts.OnEvent(frame, event, ...) end
	function env.registered(e) return events[e] == true end
	function env.flush()
		local t = env.timers
		env.timers = {}
		for _, x in ipairs(t) do x.fn() end
	end
	env.fire("ADDON_LOADED", "Sempre")
	if not opts.news then S.db.global.newsSeen = S.News[1].version end
	function env.login()
		env.fire("PLAYER_LOGIN")
		env.fire("PLAYER_ENTERING_WORLD", true, false)
		env.flush()
	end
	function env.out() return table.concat(env.printed, "\n") end
	function env.window() return S.compatFrame end
	function env.shown() return S.compatFrame ~= nil and S.compatFrame.shown end
	-- Button by its current label.
	function env.button(text)
		for _, f in ipairs(env.frames) do
			if f.kind == "Button" and f.text == text and f.shown ~= false then return f end
		end
	end
	function env.click(text)
		local b = env.button(text)
		assert(b, "no button " .. text)
		b.scripts.OnClick(b)
	end
	-- Visible rows of the window: { what, why, check = frame, box = bool }.
	function env.view()
		local rows, checks, fs = {}, {}, {}
		for _, f in ipairs(env.frames) do
			if f.kind == "CheckButton" then checks[#checks + 1] = f end
			if f.kind == "FontString" and f.shown then fs[#fs + 1] = f end
		end
		for i = 1, #fs, 2 do
			local box = checks[(i + 1) / 2]
			rows[#rows + 1] = { what = fs[i].text, why = fs[i + 1].text, check = box, box = box.shown }
		end
		return rows
	end
	function env.whats()
		local out = {}
		for _, r in ipairs(env.view()) do out[#out + 1] = r.what end
		table.sort(out)
		return table.concat(out, "|")
	end
	function env.intro()
		for _, f in ipairs(env.frames) do
			if f.kind == "FontString" and f.text and (f.text:find("^Found") or f.text:find("^Erkannt")) then return f.text end
		end
	end
	return env
end

local EUI = { { "EllesmereUI" } }
local NF = { { "NaowhForever" } }
local BOTH = { { "EllesmereUI" }, { "NaowhForever" } }

local function sortedList(t)
	local copy = {}
	for i, v in ipairs(t) do copy[i] = v end
	table.sort(copy)
	return table.concat(copy, "|")
end

local function sorted(...)
	return sortedList({ ... })
end

-- Detection (through the command, which prints what it found)

do
	local env = boot({ addons = EUI })
	env.S.commands.vertraeglich("")
	check(env.out():find("Found: EllesmereUI.", 1, true), "EllesmereUI found by folder name")
end

do
	local env = boot({ addons = { { "ErsatzFolder", "|cffff8800EllesmereUI|r - Core" } } })
	env.S.commands.vertraeglich("")
	check(env.out():find("Found: EllesmereUI.", 1, true), "EllesmereUI found by a colour-coded title")
end

do
	local env = boot({ addons = { { "EllesmereUI_Nameplates", "Nameplates" } } })
	env.S.commands.vertraeglich("")
	check(env.out():find("Found: EllesmereUI.", 1, true), "an extra part of EllesmereUI counts too")
end

for _, a in ipairs({ { "NaowhForever", "x" }, { "Folder", "Naowh Forever" }, { "NaowForever", "x" },
	{ "Folder", "|cff00ff00Naow Forever|r Discovery" }, { "naowhforever_core", "x" } }) do
	local env = boot({ addons = { a } })
	env.S.commands.vertraeglich("")
	check(env.out():find("Found: Naowh Forever.", 1, true), "Naowh Forever found as " .. a[1] .. " / " .. a[2])
end

do
	local env = boot({ addons = { { "EllesmereUI", "EllesmereUI", false } } })
	env.S.commands.vertraeglich("")
	check(env.out() == "|cffc8794aSempre|r Neither EllesmereUI nor Naowh Forever found.", "an unloaded EllesmereUI does not count: " .. env.out())
	env.login()
	check(not env.shown() and env.S.compatFrame == nil, "nothing found: no window at login")
end

do
	local env = boot({ addons = { { "Sempre_EllesmereUI_Helper", "EllesmereUI" }, { "SempreNaowhForever", "Naowh Forever" },
		{ "Other", "SempreUI EllesmereUI" } } })
	env.S.commands.vertraeglich("")
	check(env.out():find("Neither", 1, true), "Sempre folders and titles that merely contain the name are never foreign")
end

-- Rules

do
	local env = boot({ addons = EUI, db = { global = { options = { Sempre_Butler = { quiet = true } } } } })
	env.login()
	check(env.shown(), "EllesmereUI alone opens the window")
	check(env.whats() == sorted("Minimap buttons module", "Butler: sell junk", "Butler: repair", "Butler: hide error text", "Map: coordinates"),
		"EllesmereUI rules: " .. env.whats())
end

do
	local env = boot({ addons = NF })
	env.login()
	check(env.whats() == sorted("Waypoints module", "Rares module", "Butler: sell junk", "Butler: repair", "Map: explored areas", "Items: tooltip"),
		"Naowh Forever rules: " .. env.whats())
end

do
	local env = boot({ addons = BOTH, db = { global = { options = { Sempre_Butler = { quiet = true } } } } })
	env.login()
	check(#env.view() == 9, "both addons: sell and repair appear once, " .. #env.view() .. " rows")
end

do
	-- The quiet option is off by default, so its row stays hidden.
	local env = boot({ addons = EUI })
	env.login()
	check(not env.whats():find("hide error text", 1, true), "an option that is already off shows no row")
end

do
	local env = boot({ addons = BOTH, off = { "Sempre_Way" }, without = { "Sempre_Rares" },
		db = { global = { options = { Sempre_Butler = { sell = false } } } } })
	env.login()
	local w = env.whats()
	check(not w:find("Waypoints") and not w:find("sell junk") and not w:find("Rares"), "rows with targets already off or missing are hidden: " .. w)
	check(w:find("Butler: repair", 1, true) and w:find("Minimap buttons", 1, true), "other rows stay")
end

do
	local env = boot({ addons = EUI })
	env.login()
	check(env.whats():find("Map: coordinates", 1, true), "an option row of an installed module that is not loaded still shows")
end

do
	local env = boot({ addons = BOTH, off = { "Sempre_Butler" } })
	env.login()
	local w = env.whats()
	check(not w:find("Butler", 1, true) and w:find("Map: coordinates", 1, true), "option rows of a switched-off module are hidden: " .. w)
end

do
	local env = boot({ addons = EUI, off = { "Sempre_Buttons" },
		db = { global = { options = { Sempre_Butler = { sell = false, repair = false }, Sempre_Map = { show_coords = false } } } } })
	env.S.commands.compat("")
	check(env.out():find("Found: EllesmereUI.", 1, true) and env.out():find("No doubled functions.", 1, true), "nothing open: " .. env.out())
	check(not env.shown(), "nothing open: no window")
end

-- When it opens

do
	local env = boot({ addons = EUI })
	env.fire("PLAYER_LOGIN")
	check(not env.shown(), "not before entering the world")
	env.fire("PLAYER_ENTERING_WORLD", true, false)
	check(not env.shown() and #env.timers == 1 and env.timers[1].sec >= 3, "a few seconds after entering the world")
	env.flush()
	check(env.shown(), "opens after login")
	local window = env.window()
	window:Hide()
	env.fire("PLAYER_ENTERING_WORLD", false, false)
	env.flush()
	check(not window.shown and #env.timers == 0, "opens once per login")
end

do
	local env = boot({ addons = EUI, combat = true })
	env.login()
	check(not env.shown(), "not in combat")
	check(env.registered("PLAYER_REGEN_ENABLED"), "waits for combat end")
	env.combat = false
	env.fire("PLAYER_REGEN_ENABLED")
	check(env.shown(), "opens at combat end")
	check(not env.registered("PLAYER_REGEN_ENABLED"), "stops listening after combat end")
end

do
	local env = boot({ addons = EUI, news = true })
	env.login()
	check(env.S.newsFrame and env.S.newsFrame.shown, "the news window opened in this login")
	check(not env.shown(), "the compat window waits for the news window")
	env.flush()
	check(not env.shown(), "it keeps waiting while the news window is open")
	env.S.newsFrame:Hide()
	check(not env.shown() and #env.timers == 1 and env.timers[1].sec == 2, "two seconds after the news window closed")
	env.flush()
	check(env.shown(), "opens after the news window")
end

do
	local env = boot({ addons = EUI, news = true, combat = true })
	env.login()
	check(not env.shown() and not env.S.newsFrame, "news and compat both wait for combat")
	env.combat = false
	env.fire("PLAYER_REGEN_ENABLED")
	check(env.S.newsFrame and env.S.newsFrame.shown and not env.shown(), "news first, compat still waiting")
	env.S.newsFrame:Hide()
	env.flush()
	check(env.shown(), "compat after the news window")
end

do
	local env = boot({ addons = EUI })
	env.login()
	env.click("Don't ask again")
	check(not env.shown() and env.S.db.global.compatAnswered == "eui", "Don't ask again stores the set and closes")
	local again = boot({ addons = EUI, db = env.S.db })
	again.login()
	check(not again.shown(), "not asked again with the same addon set")
	local more = boot({ addons = BOTH, db = env.S.db })
	more.login()
	check(more.shown(), "asked again when Naowh Forever is added")
	more.click("Don't ask again")
	check(more.S.db.global.compatAnswered == "eui,nf", "the new set is stored")
end

do
	local env = boot({ addons = EUI })
	env.login()
	env.click("Not now")
	check(not env.shown() and env.S.db.global.compatAnswered == "", "Not now closes without storing")
	local again = boot({ addons = EUI, db = env.S.db })
	again.login()
	check(again.shown(), "asked again at the next login after Not now")
end

do
	local env = boot({ addons = EUI, db = { global = { options = { Sempre = { compat = false } } } } })
	env.login()
	check(not env.shown(), "not with the option off")
	env.S.commands.kompatibel("")
	check(env.shown(), "the command still opens it with the option off")
end

do
	local env = boot({ addons = EUI })
	check(env.S:GetOption("Sempre", "compat") == true, "the option is on by default")
	check(env.S.db.global.compatAnswered == "", "compatAnswered has a default")
end

-- Switching

do
	local env = boot({ addons = BOTH })
	env.login()
	local rows = env.view()
	local sell
	for _, r in ipairs(rows) do
		if r.what == "Butler: sell junk" then sell = r end
		if r.what == "Rares module" then r.check:SetChecked(false) end
	end
	sell.check:SetChecked(false)
	check(sell.box, "rows with a switch have a checkbox")
	env.click("Switch off selected")
	check(sortedList(env.switched) == sorted("Sempre_Buttons:false:true", "Sempre_Way:false:true"),
		"only checked modules go through the shared switch: " .. table.concat(env.switched, ","))
	local o = env.S.db.global.options
	check(o.Sempre_Butler and o.Sempre_Butler.repair == false and o.Sempre_Butler.sell == nil, "checked option off, unchecked option untouched")
	check(o.Sempre_Map and o.Sempre_Map.show_coords == false and o.Sempre_Map.show_explored == false, "options of unloaded modules are saved")
	check(env.S.db.global.compatAnswered == "eui,nf", "the answer is stored")
	check(env.out():find("/reload", 1, true), "a module was switched off: reload line")
	check(env.shown(), "the window stays for the reload button")
	check(env.button("Reload") and env.reloaded == 0, "reload button, nothing reloaded yet")
	check(not env.button("Switch off selected"), "the other buttons give way to it")
	env.click("Reload")
	check(env.reloaded == 1, "reload only on click")
end

do
	-- Registered options go through SetOption and its message.
	local env = boot({ addons = EUI, off = { "Sempre_Buttons" }, db = { global = { options = { Sempre_Butler = { quiet = true } } } } })
	env.S:RegisterOptions("Sempre_Butler", {
		{ key = "sell", default = true, label = "s" },
		{ key = "repair", default = true, label = "r" },
		{ key = "quiet", default = false, label = "q" },
	})
	local seen = {}
	env.S:Listen("OPTION_CHANGED", function(_, mod, key, value) seen[#seen + 1] = mod .. "." .. key .. "=" .. tostring(value) end)
	env.login()
	env.click("Switch off selected")
	check(env.S:GetOption("Sempre_Butler", "sell") == false and env.S:GetOption("Sempre_Butler", "quiet") == false, "loaded module: options switched with SetOption")
	check(table.concat(seen, ","):find("Sempre_Butler.sell=false", 1, true), "OPTION_CHANGED was sent")
	check(#env.switched == 0 and not env.out():find("/reload", 1, true) and not env.button("Reload"), "options only: no reload line, no reload button")
	check(not env.shown(), "options only: the window closes")
	check(env.S.db.global.compatAnswered == "eui", "answer stored")
end

do
	local env = boot({ addons = NF })
	env.login()
	local info
	for _, r in ipairs(env.view()) do
		if r.what == "Items: tooltip" then info = r end
	end
	check(info and not info.box, "info rows have no checkbox")
	check(info.why:find("owner lines", 1, true), "info row shows its text")
	env.click("Switch off selected")
	check(env.S.db.global.options.Sempre_Items == nil, "info rows switch nothing")
end

-- Command

do
	local env = boot({ addons = NF })
	env.S.commands.vertraeglich("")
	local out = env.out()
	check(out:find("Found: Naowh Forever.", 1, true) and out:find("Waypoints module: Naowh Forever has waypoint pins and routes", 1, true), "command lists the found addons and each open row: " .. out)
	check(out:find("Items: tooltip", 1, true), "command lists the info row too")
	check(env.shown(), "command opens the window")
end

do
	local env = boot({ addons = EUI, db = { global = { compatAnswered = "eui" } } })
	env.S.commands.compat("")
	check(env.shown(), "command opens the window although it was answered")
end

do
	local env = boot({ addons = { { "Foo" } } })
	env.S.commands.vertraeglich("")
	check(env.out():find("Neither EllesmereUI nor Naowh Forever found.", 1, true) and not env.shown(), "command with nothing found")
end

-- Strings

do
	local env = boot({ addons = BOTH, locale = "deDE", db = { global = { options = { Sempre_Butler = { quiet = true } } } } })
	env.login()
	check(env.intro() == "Erkannt: EllesmereUI, Naowh Forever. Diese SempreUI-Teile machen dasselbe:", "German intro: " .. tostring(env.intro()))
	check(env.button("Ausgewählte ausschalten") and env.button("Nicht jetzt") and env.button("Nicht mehr fragen"), "German buttons")
	check(env.whats():find("Modul Wegpunkte", 1, true) and env.whats():find("Butler: Schrott verkaufen", 1, true), "German row texts")
	env.S.commands.vertraeglich("")
	check(env.out():find("Erkannt: EllesmereUI, Naowh Forever.", 1, true), "German command output")
	local none = boot({ locale = "deDE" })
	none.S.commands.vertraeglich("")
	check(none.out():find("Weder EllesmereUI noch Naowh Forever gefunden.", 1, true), "German nothing found")
	local closed = boot({ addons = EUI, locale = "deDE", off = { "Sempre_Buttons" },
		db = { global = { options = { Sempre_Butler = { sell = false, repair = false }, Sempre_Map = { show_coords = false } } } } })
	closed.S.commands.vertraeglich("")
	check(closed.out():find("Keine doppelten Funktionen.", 1, true), "German nothing open")
end

do
	local env = boot({ addons = EUI })
	env.login()
	check(env.intro() == "Found: EllesmereUI. These SempreUI parts do the same:", "English intro")
	check(env.button("Switch off selected") and env.button("Not now") and env.button("Don't ask again"), "English buttons")
	local long = 0
	for _, rule in ipairs(env.S.CompatRules) do
		if #rule.why.de >= 70 or #rule.why.en >= 70 then long = long + 1 end
	end
	check(long == 0, "reasons stay under 70 characters")
end

end
