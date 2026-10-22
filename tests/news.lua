-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Tests for Sempre/News.lua and Sempre/NewsWindow.lua with a stubbed frame API.
-- Loaded by tests/run.lua, which passes in its check helper.

return function(check)

local function newFrame(env, kind)
	local f = { kind = kind, scripts = {}, texts = {}, shown = false }
	env.frames[#env.frames + 1] = f
	local methods = {
		Show = function(self) if not self.shown then self.shown = true end end,
		Hide = function(self)
			if self.shown then
				self.shown = false
				if self.scripts.OnHide then self.scripts.OnHide(self) end
			end
		end,
		IsShown = function(self) return self.shown end,
		SetScript = function(self, k, fn) self.scripts[k] = fn end,
		SetText = function(self, t) self.text = t; env.texts[#env.texts + 1] = t end,
		GetStringHeight = function() return 14 end,
		CreateFontString = function() return newFrame(env, "FontString") end,
		SetFont = function(self, p, s) self.font = p; self.fontSize = s; return true end,
	}
	return setmetatable(f, { __index = function(_, k) return methods[k] or function() end end })
end

-- opts: locale, db (saved data), combat, noTimer, noSpecial
local function boot(opts)
	opts = opts or {}
	local env = { printed = {}, frames = {}, texts = {}, timers = {}, combat = opts.combat or false, regs = {} }
	local events = {}
	local frame = { scripts = {} }
	function frame.RegisterEvent(_, e) events[e] = true end
	function frame.UnregisterEvent(_, e) events[e] = nil end
	function frame.SetScript(_, k, fn) frame.scripts[k] = fn end
	local g = setmetatable({}, { __index = _G })
	g._G = g
	g.table = setmetatable({ wipe = function(t) for k in pairs(t) do t[k] = nil end return t end }, { __index = table })
	local coreFrame = true
	g.CreateFrame = function(kind, name, _, template)
		if coreFrame then
			coreFrame = false
			return frame
		end
		local f = newFrame(env, kind)
		f.name, f.template = name, template
		return f
	end
	g.GetLocale = function() return opts.locale or "enUS" end
	g.GetBuildInfo = function() return "1", "", "", 16001 end
	g.UnitName = function() return "Tester" end
	g.GetRealmName = function() return "Realm" end
	g.time = os.time
	g.geterrorhandler = function() return function() end end
	g.SlashCmdList = {}
	g.print = function(msg) env.printed[#env.printed + 1] = msg end
	g.C_AddOns = { GetAddOnMetadata = function() return nil end, GetNumAddOns = function() return 0 end }
	g.InCombatLockdown = function() return env.combat end
	g.UIParent = newFrame(env, "Frame")
	if not opts.noTimer then
		g.C_Timer = { After = function(sec, fn) env.timers[#env.timers + 1] = { sec = sec, fn = fn } end }
	end
	if not opts.noSpecial then g.UISpecialFrames = {} end
	if opts.db then g.SempreDB = opts.db end
	local function run(path)
		local chunk = assert(loadfile(path))
		setfenv(chunk, g)
		return chunk("Sempre")
	end
	run("Sempre/Core.lua")
	run("Sempre/Fonts.lua")
	run("Sempre/News.lua")
	run("Sempre/NewsWindow.lua")
	env.S, env.g = g.SempreUI, g
	function env.fire(event, ...) frame.scripts.OnEvent(frame, event, ...) end
	function env.registered(e) return events[e] == true end
	function env.window()
		for _, f in ipairs(env.frames) do
			if f.name == "SempreNewsFrame" then return f end
		end
	end
	function env.shown() local w = env.window() return w ~= nil and w.shown end
	function env.flush()
		local t = env.timers
		env.timers = {}
		for _, x in ipairs(t) do x.fn() end
	end
	env.fire("ADDON_LOADED", "Sempre")
	function env.login()
		env.fire("PLAYER_LOGIN")
		env.fire("PLAYER_ENTERING_WORLD", true, false)
		env.flush()
	end
	return env
end

local function old() return { global = { newsSeen = "0.1.0-alpha1", options = {} } } end

-- Opens once after an update

do
	local env = boot({ db = old() })
	local newestVersion = env.S.News[1].version
	env.login()
	check(env.shown(), "window opens after an update")
	check(env.S.db.global.newsSeen == newestVersion, "opening stores the newest version")
	env.window():Hide()
	env.fire("PLAYER_ENTERING_WORLD", false, false)
	env.flush()
	check(not env.shown(), "window does not come back after closing")
	local again = boot({ db = { global = { newsSeen = newestVersion } } })
	again.login()
	check(not again.window(), "no window when the newest version was seen (not even built)")
end

do
	local env = boot({ db = old() })
	env.fire("PLAYER_LOGIN")
	check(not env.shown(), "not before entering the world")
	env.fire("PLAYER_ENTERING_WORLD", true, false)
	check(not env.shown() and #env.timers == 1 and env.timers[1].sec > 0, "a short delay after entering the world")
	env.flush()
	check(env.shown(), "opens after the delay")
	env.fire("PLAYER_ENTERING_WORLD", false, false)
	env.flush()
	check(#env.timers == 0, "later zone changes schedule nothing")
end

do
	local env = boot({ db = old(), noTimer = true })
	env.login()
	check(env.shown(), "without C_Timer it opens at once")
end

-- First install

do
	local env = boot()
	env.login()
	check(not env.window(), "first install: no window")
	check(env.S.db.global.newsSeen == env.S.News[1].version, "first install: newest version is stored")
	local again = boot({ db = env.S.db })
	again.login()
	check(not again.window(), "second start after first install: still no window")
end

-- Option

do
	local db = old()
	db.global.options.Sempre = { news = false }
	local env = boot({ db = db })
	env.login()
	check(not env.window() and db.global.newsSeen == "0.1.0-alpha1", "option off: no window, nothing stored")
	env.S.commands.neu()
	check(env.shown() and db.global.newsSeen == env.S.News[1].version, "option off: command still opens and stores the version")
	check(boot().S:GetOption("Sempre", "news") == true, "option defaults to on")
	local list = boot().S:GetOptionList("Sempre")
	local found
	for _, o in ipairs(list) do if o.key == "news" then found = o end end
	check(found and found.label.de:find("Neuigkeiten") and found.label.en:find("what's new"), "option has German and English labels")
end

-- Combat

do
	local env = boot({ db = old(), combat = true })
	env.login()
	check(not env.shown() and env.registered("PLAYER_REGEN_ENABLED"), "in combat it waits for combat end")
	env.fire("PLAYER_REGEN_ENABLED")
	check(not env.shown(), "still closed while combat lockdown is on")
	env.combat = false
	env.fire("PLAYER_REGEN_ENABLED")
	check(env.shown(), "opens at combat end")
	env.window():Hide()
	env.fire("PLAYER_REGEN_ENABLED")
	check(not env.shown(), "a later combat end does not reopen it")
end

-- Command

do
	local db = old()
	local env = boot({ db = db })
	check(env.S.commands.neu and env.S.commands.news == env.S.commands.neu, "neu and news are the same command")
	env.g.SlashCmdList.SEMPRE("NEU")
	check(env.shown() and db.global.newsSeen == env.S.News[1].version, "/sempre neu opens it and stores the version")
	env.window():Hide()
	env.g.SlashCmdList.SEMPRE("news")
	check(env.shown(), "/sempre news opens it again")
	check(env.window().template == "BackdropTemplate" and #env.g.UISpecialFrames == 1 and env.g.UISpecialFrames[1] == "SempreNewsFrame",
		"registered in the special frames list")
	local before = 0
	for _, f in ipairs(env.frames) do if f.name == "SempreNewsFrame" then before = before + 1 end end
	env.g.SlashCmdList.SEMPRE("neu")
	local after = 0
	for _, f in ipairs(env.frames) do if f.name == "SempreNewsFrame" then after = after + 1 end end
	check(before == 1 and after == 1 and #env.g.UISpecialFrames == 1, "the window is built only once")
	local plain = boot({ db = old(), noSpecial = true })
	plain.g.SlashCmdList.SEMPRE("neu")
	check(plain.shown(), "works without a special-frames list")
end

-- Texts by language

local function hasText(env, needle)
	for _, t in ipairs(env.texts) do
		if t:find(needle, 1, true) then return true end
	end
	return false
end

do
	local de = boot({ db = old(), locale = "deDE" })
	de.g.SlashCmdList.SEMPRE("neu")
	local first = de.S.News[1].points[1]
	check(hasText(de, first.de) and not hasText(de, first.en), "German client shows German points")
	check(hasText(de, "Was ist neu") and hasText(de, "Fehler oder Wünsche? GitHub-Issues: github.com/SempreUI/sempre-ui/issues"), "German title and feedback line")
	local en = boot({ db = old() })
	en.g.SlashCmdList.SEMPRE("neu")
	check(hasText(en, first.en) and not hasText(en, first.de), "English client shows English points")
	check(hasText(en, "What's new") and hasText(en, "Bugs or wishes? GitHub issues: github.com/SempreUI/sempre-ui/issues"), "English title and feedback line")
	local fr = boot({ db = old(), locale = "frFR" })
	fr.g.SlashCmdList.SEMPRE("neu")
	check(hasText(fr, first.en), "other languages fall back to English")
	for _, rel in ipairs(en.S.News) do
		check(hasText(en, rel.version) and hasText(en, rel.date), "heading with version and date for " .. rel.version)
	end
end

-- Data

do
	local S = boot().S
	local News = S.News
	check(News[1].version == "0.1.0-alpha2" and News[2].version == "0.1.0-alpha1" and #News >= 2, "entries newest first")
	local ok = true
	for _, rel in ipairs(News) do
		if not (rel.version and rel.date and #rel.points >= 1 and #rel.points <= 8) then ok = false end
		for _, p in ipairs(rel.points) do
			if not (p.de and p.en and #p.de <= 90 and #p.en <= 90) then ok = false end
			if p.de:find("%d%d%.%d%d%.") then ok = false end
		end
	end
	check(ok, "each entry has 1 to 8 points with German and English texts, each under 90 bytes")
end

-- The link rule: no URL anywhere except the GitHub issues text

do
	local files = {}
	local pipe = io.popen("find Sempre Sempre_* -name '*.lua' 2>/dev/null")
	for path in pipe:lines() do files[#files + 1] = path end
	pipe:close()
	check(#files >= 10, "link scan found the Lua files")
	local ALLOWED = "github.com/SempreUI/sempre-ui/issues"
	local bad
	for _, path in ipairs(files) do
		local fh = assert(io.open(path, "r"))
		local text = fh:read("*a")
		fh:close()
		-- Only string literals can reach the screen (code like S.commands holds ".com").
		local strings = {}
		for lit in text:gmatch('"[^"\n]*"') do strings[#strings + 1] = lit end
		local stripped = table.concat(strings, "\n"):gsub(ALLOWED:gsub("%p", "%%%0"), "")
		local lower = stripped:lower()
		for _, pat in ipairs({ "http", "www%.", "%.com" }) do
			if lower:find(pat) then bad = (bad and bad .. ", " or "") .. path .. " (" .. pat .. ")" end
		end
	end
	check(not bad, "no link text outside the GitHub issues line" .. (bad and ": " .. bad or ""))
	local count = 0
	for _, path in ipairs(files) do
		local fh = assert(io.open(path, "r"))
		local text = fh:read("*a")
		fh:close()
		if text:find(ALLOWED, 1, true) then count = count + 1 end
	end
	check(count == 1, "the GitHub issues text lives in exactly one file")
end

end
