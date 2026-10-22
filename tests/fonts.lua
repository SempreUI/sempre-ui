-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Tests for Sempre/Fonts.lua with stubbed font strings and font objects.
-- Loaded by tests/run.lua, which passes in its check helper. The mail panel
-- roles are checked in tests/mail.lua, the greyed option in tests/settings.lua.

return function(check)

local GAME = "Fonts\\GAME.TTF"

local function newFont(path, size, flags, opts)
	local f = { path = path, size = size, flags = flags, calls = 0 }
	function f:SetFont(p, s, fl)
		self.calls = self.calls + 1
		if opts and opts.fail and opts.fail[p] then return false end
		self.path, self.size, self.flags = p, s, fl
		return true
	end
	function f:GetFont() return self.path, self.size, self.flags end
	function f:SetShadowOffset(x, y) self.shadow = { x, y } end
	function f:SetShadowColor() end
	return f
end

-- opts: locale, fail (set of paths that fail to load), noStd, objects (name -> font object),
-- options (stored options), noFonts (Fonts.lua not loaded is not covered)
local function boot(opts)
	opts = opts or {}
	local env = { printed = {}, errors = {} }
	local frame = { scripts = {} }
	function frame.RegisterEvent() end
	function frame.UnregisterEvent() end
	function frame.SetScript(_, kind, fn) frame.scripts[kind] = fn end
	local g = setmetatable({}, { __index = _G })
	g._G = g
	g.table = setmetatable({ wipe = function(t) for k in pairs(t) do t[k] = nil end return t end }, { __index = table })
	g.CreateFrame = function() return frame end
	g.GetLocale = function() return opts.locale or "enUS" end
	g.GetBuildInfo = function() return "1", "", "", 16001 end
	g.UnitName = function() return "Tester" end
	g.GetRealmName = function() return "Realm" end
	g.time = os.time
	g.geterrorhandler = function() return function(err) env.errors[#env.errors + 1] = err end end
	g.SlashCmdList = {}
	g.print = function(msg) env.printed[#env.printed + 1] = msg end
	g.C_AddOns = { GetAddOnMetadata = function() return nil end, GetNumAddOns = function() return 0 end }
	if not opts.noStd then g.STANDARD_TEXT_FONT = GAME end
	for name, obj in pairs(opts.objects or {}) do g[name] = obj end
	if opts.fail then env.fail = opts.fail end
	local function run(path)
		local chunk = assert(loadfile(path))
		setfenv(chunk, g)
		return chunk("Sempre")
	end
	run("Sempre/Core.lua")
	run("Sempre/Fonts.lua")
	env.S, env.g = g.SempreUI, g
	function env.fire(event, ...) frame.scripts.OnEvent(frame, event, ...) end
	env.fire("ADDON_LOADED", "Sempre")
	if opts.options then env.S.db.global.options.Sempre = opts.options end
	env.fire("PLAYER_LOGIN")
	env.printed = {}
	function env.fs() return newFont(nil, nil, nil, { fail = opts.fail }) end
	function env.out() return table.concat(env.printed, "\n") end
	return env
end

-- Roles: path and default size

do
	local env = boot()
	local S = env.S
	local F = S.Fonts
	check(F.title:find("Grenze-SemiBold.ttf", 1, true) and F.text:find("AtkinsonHyperlegibleNext-Regular.ttf", 1, true)
		and F.bold:find("AtkinsonHyperlegibleNext-Bold.ttf", 1, true) and F.mono:find("AtkinsonHyperlegibleMono-Regular.ttf", 1, true),
		"each role points at its font file")
	check(F.title:find("Media\\Fonts\\", 1, true) and F.title:find("^Interface\\AddOns\\Sempre\\"), "paths live in the Sempre addon folder")
	local sizes = { title = 14, text = 12, bold = 12, mono = 12 }
	for role, size in pairs(sizes) do
		local fs = env.fs()
		S:SetFont(fs, role)
		check(fs.path == F[role] and fs.size == size and fs.flags == "", role .. ": own file, default size " .. size .. ", no flags")
	end
	local fs = env.fs()
	S:SetFont(fs, "text", 20, "OUTLINE")
	check(fs.size == 20 and fs.flags == "OUTLINE", "size and flags are passed on")
	local t = env.fs()
	S:SetFont(t, "title")
	check(t.shadow and t.shadow[1] == 1 and t.shadow[2] == -1 and t.flags == "", "title: thin shadow, no outline")
	local x = env.fs()
	S:SetFont(x, "text")
	check(x.shadow == nil, "text: no shadow")
	local u = env.fs()
	S:SetFont(u, "nonsense", 9)
	check(u.path == GAME and u.size == 9, "unknown role: game font at the same size")
	S:SetFont(u, "nonsense")
	check(u.size == 12, "unknown role without size: 12")
	S:SetFont(nil, "text")
	S:SetFont({}, "text")
	check(#env.errors == 0, "a missing font string or one without SetFont is ignored")
end

-- Option off

do
	local env = boot({ options = { fonts = false } })
	local fs = env.fs()
	env.S:SetFont(fs, "title", 16, "OUTLINE")
	check(fs.path == GAME and fs.size == 16 and fs.flags == "OUTLINE" and fs.shadow == nil, "option off: game font, same size and flags, no shadow")
end

-- Game font path: global, then last resort

do
	local env = boot({ noStd = true, options = { fonts = false } })
	local fs = env.fs()
	env.S:SetFont(fs, "text")
	check(fs.path == "Fonts\\FRIZQT__.TTF", "without the standard font global the last resort is used")
end

-- Language guard

for _, loc in ipairs({ "ruRU", "koKR", "zhCN", "zhTW" }) do
	local env = boot({ locale = loc })
	local fs = env.fs()
	env.S:SetFont(fs, "text", 13)
	check(fs.path == GAME and fs.size == 13, loc .. ": game font")
	check(env.S:FontLockReason() ~= nil, loc .. ": lock reason exists")
	local opts = env.S:GetOptionList("Sempre")
	local greyed = 0
	for _, o in ipairs(opts) do
		if (o.key == "fonts" or o.key == "game_fonts") and o.disabled() then greyed = greyed + 1 end
	end
	check(greyed == 2, loc .. ": both font options are greyed out")
end

do
	local env = boot({ locale = "deDE" })
	check(env.S:FontLockReason() == nil, "deDE: not locked")
	for _, o in ipairs(env.S:GetOptionList("Sempre")) do
		check(not o.disabled or o.disabled() == nil, "deDE: option " .. o.key .. " is not greyed")
	end
	local fs = env.fs()
	env.S:SetFont(fs, "text")
	check(fs.path == env.S.Fonts.text, "deDE: own fonts")
end

-- Failed load falls back once

do
	local env
	env = boot({ fail = {} })
	env.fail["Interface\\AddOns\\Sempre\\Media\\Fonts\\AtkinsonHyperlegibleNext-Regular.ttf"] = true
	local fs = env.fs()
	env.S:SetFont(fs, "text", 12)
	check(fs.path == GAME and fs.size == 12, "failed load: game font at the same size")
	check(#env.printed == 1 and env.printed[1]:find("could not be loaded", 1, true), "failed load: one line")
	local fs2 = env.fs()
	env.S:SetFont(fs2, "title")
	env.S:SetFont(env.fs(), "text")
	check(#env.printed == 1, "failed load: the line is printed only once")
	check(fs2.path == GAME, "after a failure the game font is used for all roles")
	env.S.commands.schrift("")
	check(env.out():find("loading failed", 1, true), "/sempre schrift reports the failure")
end

-- Option change re-applies to registered font strings

do
	local env = boot()
	local S = env.S
	local a, b = env.fs(), env.fs()
	S:SetFont(a, "title")
	S:SetFont(b, "mono", 10, "OUTLINE")
	S:SetOption("Sempre", "fonts", false)
	check(a.path == GAME and a.size == 14 and a.shadow[1] == 0, "off: registered title string gets the game font, shadow removed")
	check(b.path == GAME and b.size == 10 and b.flags == "OUTLINE", "off: registered mono string keeps size and flags")
	S:SetOption("Sempre", "fonts", true)
	check(a.path == S.Fonts.title and b.path == S.Fonts.mono and b.size == 10, "on again: own fonts back")
	local c = env.fs()
	S:SetOption("Sempre", "fonts", false)
	S:SetFont(c, "text")
	check(c.path == GAME, "a window built while off gets the game font")
	S:SetOption("Sempre", "fonts", true)
	check(c.path == S.Fonts.text, "and the own font once on")
end

-- Game font replacement

do
	local objects = {
		GameFontNormal = newFont("Fonts\\ORIG1.TTF", 12, ""),
		GameFontNormalLarge = newFont("Fonts\\ORIG2.TTF", 16, "OUTLINE"),
		GameTooltipHeaderText = newFont("Fonts\\ORIG3.TTF", 14, "THICKOUTLINE"),
		ChatFontNormal = newFont("Fonts\\ORIG4.TTF", 14, ""),
	}
	local env = boot({ objects = objects })
	local S = env.S
	local F = S.Fonts
	check(objects.GameFontNormal.path == "Fonts\\ORIG1.TTF" and objects.GameFontNormal.calls == 0, "default: game fonts untouched")
	S:SetOption("Sempre", "game_fonts", true)
	check(objects.GameFontNormal.path == F.text and objects.GameFontNormal.size == 12 and objects.GameFontNormal.flags == "", "normal font object: text role, size and flags kept")
	check(objects.GameFontNormalLarge.path == F.title and objects.GameFontNormalLarge.size == 16 and objects.GameFontNormalLarge.flags == "OUTLINE", "large font object: title role, size and flags kept")
	check(objects.GameTooltipHeaderText.path == F.title and objects.GameTooltipHeaderText.flags == "THICKOUTLINE", "tooltip header: title role")
	check(objects.ChatFontNormal.path == F.text and objects.ChatFontNormal.size == 14, "chat font object: text role")
	check(#env.errors == 0, "missing objects are skipped silently")
	S.commands.font("")
	check(env.out():find("replaced: yes (4 font objects)", 1, true), "/sempre font counts the replaced objects: " .. env.out())
	S:SetOption("Sempre", "game_fonts", false)
	check(objects.GameFontNormal.path == "Fonts\\ORIG1.TTF" and objects.GameFontNormalLarge.path == "Fonts\\ORIG2.TTF"
		and objects.GameFontNormalLarge.flags == "OUTLINE" and objects.ChatFontNormal.size == 14, "off: original files restored with size and flags")
	-- Second round restores the very first originals, not our own files.
	S:SetOption("Sempre", "game_fonts", true)
	S:SetOption("Sempre", "game_fonts", false)
	check(objects.GameFontNormal.path == "Fonts\\ORIG1.TTF", "originals are remembered before the first change only")
	-- The master option off also puts the game fonts back.
	S:SetOption("Sempre", "game_fonts", true)
	S:SetOption("Sempre", "fonts", false)
	check(objects.GameFontNormal.path == "Fonts\\ORIG1.TTF", "SempreUI fonts off: game fonts restored")
	S:SetOption("Sempre", "fonts", true)
	check(objects.GameFontNormal.path == F.text, "SempreUI fonts on again: replaced again")
end

do
	local objects = { GameFontNormal = newFont("Fonts\\ORIG1.TTF", 12, "") }
	local env = boot({ objects = objects, options = { game_fonts = true } })
	check(objects.GameFontNormal.path == env.S.Fonts.text, "stored option is applied at login")
	local locked = { GameFontNormal = newFont("Fonts\\ORIG1.TTF", 12, "") }
	boot({ objects = locked, options = { game_fonts = true }, locale = "ruRU" })
	check(locked.GameFontNormal.path == "Fonts\\ORIG1.TTF" and locked.GameFontNormal.calls == 0, "guarded language: game fonts never replaced")
end

-- /sempre schrift

do
	local env = boot()
	env.S.commands.schrift("")
	local out = env.out()
	check(out:find("SempreUI fonts: on", 1, true) and out:find("Client language: enUS", 1, true) and out:find("Game fonts replaced: no", 1, true), "/sempre schrift: default state: " .. out)
	env.printed = {}
	env.S:SetOption("Sempre", "fonts", false)
	env.S.commands.font("")
	check(env.out():find("SempreUI fonts: off", 1, true), "/sempre font: off")
	local ru = boot({ locale = "ruRU" })
	ru.S.commands.schrift("")
	check(ru.out():find("not usable", 1, true) and ru.out():find("Client language: ruRU", 1, true), "/sempre schrift: guarded language")
	local de = boot({ locale = "deDE" })
	de.S.commands.schrift("")
	check(de.out():find("Client-Sprache: deDE", 1, true) and de.out():find("SempreUI-Schriften: an", 1, true), "/sempre schrift: German")
end

end
