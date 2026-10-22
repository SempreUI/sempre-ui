-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Tests for Sempre_Whisper with a stubbed WoW API. Loaded by tests/run.lua, which
-- passes in its check helper. Boots the real core, then the module's file, with
-- stubbed chat, Battle.net and sound calls and secret values that raise an
-- error as soon as the module compares, concatenates or measures them.

return function(check)

local DAY = 86400
local T0 = os.time({ year = 2026, month = 10, day = 22, hour = 12, min = 0, sec = 0 })

local function newFake(kind)
	local f = { kind = kind, shown = true, scripts = {}, registered = {}, w = 320, h = 240, lines = {} }
	return setmetatable(f, { __index = function() return function() end end })
end

local fakeMethods = {
	Show = function(self) self.shown = true end,
	Hide = function(self) self.shown = false end,
	IsShown = function(self) return self.shown end,
	SetScript = function(self, kind, fn) self.scripts[kind] = fn end,
	RegisterEvent = function(self, e) self.registered[e] = true end,
	UnregisterEvent = function(self, e) self.registered[e] = nil end,
	SetText = function(self, t) self.text = t end,
	GetText = function(self) return self.text or "" end,
	SetSize = function(self, w, h) self.w, self.h = w, h end,
	GetWidth = function(self) return self.w end,
	GetHeight = function(self) return self.h end,
	SetPoint = function(self, ...) self.point = { ... } end,
	GetPoint = function() return "TOPLEFT", nil, "TOPLEFT", 10, -20 end,
	SetFont = function() return true end,
	Clear = function(self) self.lines = {} end,
	AddMessage = function(self, m) self.lines[#self.lines + 1] = m end,
	HasFocus = function(self) return self.focus or false end,
	ClearFocus = function(self) self.focus = false end,
	CreateFontString = nil,
}

local function secretValue(label)
	local function bad() error("secret value used: " .. label) end
	return setmetatable({}, {
		__concat = bad, __len = bad, __eq = bad, __lt = bad, __le = bad, __call = bad,
		__tostring = bad, __index = bad, __newindex = bad, __unm = bad, __add = bad,
	})
end

-- opts: options, db (saved data), no (set of missing API names), locale
local function boot(opts)
	opts = opts or {}
	local no = opts.no or {}
	local env = { printed = {}, errors = {}, frames = {}, sent = {}, bnSent = {}, sounds = {}, received = {},
		now = T0, combat = false, lockdown = false, secrets = setmetatable({}, { __mode = "k" }), lineData = {} }
	local g = setmetatable({}, { __index = _G })
	g.table = setmetatable({ wipe = function(t) for k in pairs(t) do t[k] = nil end return t end }, { __index = table })
	g.CreateFrame = function(kind)
		local f = newFake(kind)
		for k, v in pairs(fakeMethods) do f[k] = v end
		f.CreateFontString = function() return g.CreateFrame("FontString") end
		f.CreateTexture = function() return g.CreateFrame("Texture") end
		env.frames[#env.frames + 1] = f
		return f
	end
	g.GetLocale = function() return opts.locale or "enUS" end
	g.GetBuildInfo = function() return "1", "", "", 16001 end
	g.UnitName = function() return "Tester" end
	g.GetRealmName = function() return "Realm" end
	g.time = function() return env.now end
	g.date = os.date
	g.issecretvalue = function(v) return env.secrets[v] == true end
	g.InCombatLockdown = function() return env.combat end
	g.geterrorhandler = function() return function(err) env.errors[#env.errors + 1] = err end end
	g.SlashCmdList = {}
	g.print = function(msg) env.printed[#env.printed + 1] = msg end
	g.C_AddOns = { GetAddOnMetadata = function() return nil end, GetNumAddOns = function() return 0 end }
	g.C_EventUtils = { IsEventValid = function() return true end }
	g.UIParent = newFake("UIParent")
	g.C_ChatInfo = {
		InChatMessagingLockdown = function() return env.lockdown end,
		GetChatLineSenderName = function(id) local d = env.lineData[id] return d and d.name end,
		GetChatLineText = function(id) local d = env.lineData[id] return d and d.text end,
		GetChatLineSenderGUID = function(id) local d = env.lineData[id] return d and d.guid end,
		SendChatMessage = function(text, kind, lang, target)
			env.sent[#env.sent + 1] = { text, kind, lang, target }
		end,
		GetColorForChatType = function() return { r = 1, g = 0.5, b = 1 } end,
	}
	g.C_BattleNet = {
		GetAccountInfoByID = function(id) return { accountName = "Friend" .. id } end,
		GetAccountInfoByGUID = function(guid) return guid == "guid-bn" and { bnetAccountID = 77 } or nil end,
		SendWhisper = function(id, text) env.bnSent[#env.bnSent + 1] = { id, text } end,
	}
	g.C_Sound = { PlaySound = function(kit) env.sounds[#env.sounds + 1] = kit end }
	for name in pairs(no) do
		local lib, fn = name:match("^(.-)%.(.+)$")
		if lib then g[lib][fn] = nil else g[name] = nil end
	end
	if opts.db then g.SempreWhisperDB = opts.db end

	local function run(path, ...)
		local chunk = assert(loadfile(path))
		setfenv(chunk, g)
		return chunk(...)
	end
	env.g = g
	run("Sempre/Core.lua", "Sempre")
	run("Sempre/Fonts.lua", "Sempre")
	env.S = g.SempreUI
	env.core = env.frames[1]
	function env.fire(event, ...) env.core.scripts.OnEvent(env.core, event, ...) end
	env.fire("ADDON_LOADED", "Sempre")
	if opts.options then env.S.db.global.options.Sempre_Whisper = opts.options end
	env.fire("PLAYER_LOGIN")
	env.S:Listen("WHISPER_RECEIVED", function(msg, ...)
		env.received[#env.received + 1] = { msg, select("#", ...), ... }
	end)
	env.printed = {}
	run("Sempre_Whisper/Whisper.lua", "Sempre_Whisper")
	env.fire("ADDON_LOADED", "Sempre_Whisper")
	env.W = env.S.Whisper
	env.timer = env.W.timer
	env.errors = {}

	function env.secret(label)
		local v = secretValue(label)
		env.secrets[v] = true
		return v
	end
	-- Game whisper: fire(event, text, name, lineID)
	function env.whisper(event, text, name, lineID)
		env.fire(event, text, name, "", "", name, "", 0, 0, "", 0, lineID or 1, "guid", 0)
	end
	function env.bn(event, text, name, id, lineID)
		env.fire(event, text, name, "", "", name, "", 0, 0, "", 0, lineID or 1, "guid", id)
	end
	function env.conv(key) return env.W.GetConversation(key) end
	function env.out() return table.concat(env.printed, "\n") end
	return env
end

local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

-- Scans saved data for any value that is a secret marker.
local function hasSecret(env, t, seen)
	seen = seen or {}
	if seen[t] then return false end
	seen[t] = true
	for k, v in pairs(t) do
		if env.secrets[k] or env.secrets[v] then return true end
		if type(v) == "table" and not env.secrets[v] and hasSecret(env, v, seen) then return true end
	end
	return false
end

-- Splitting

do
	local env = boot()
	local split = env.W.Split
	local p = split("hello world")
	check(#p == 1 and p[1] == "hello world", "short text is one part")
	local words = {}
	for i = 1, 80 do words[i] = "word" .. i end
	local long = table.concat(words, " ")
	p = split(long)
	local ok = #p > 1
	for _, part in ipairs(p) do
		if #part > 255 or part:find("^%s") or part:find("%s$") then ok = false end
	end
	check(ok, "long text is split into parts of at most 255 bytes")
	check(table.concat(p, " ") == long, "split at word boundaries loses nothing")
	local joined = {}
	for _, part in ipairs(p) do joined[#joined + 1] = part:match("%S+$") end
	check(joined[1]:match("^word%d+$") ~= nil, "parts end on whole words")
	p = split(string.rep("x", 600))
	check(#p == 3 and #p[1] == 255 and #p[3] == 90, "text without spaces is cut at 255 bytes")
	p = split(string.rep("\195\164", 200))
	local intact = #p == 2
	for _, part in ipairs(p) do
		if #part > 255 or #part % 2 ~= 0 then intact = false end
	end
	check(intact, "a UTF-8 character is never cut")
	check(#split("   ") == 0, "blank text gives no part")
end

-- Incoming and outgoing game whispers

do
	local env = boot()
	env.whisper("CHAT_MSG_WHISPER", "hi there", "Anna-Realm", 11)
	local c = env.conv("Anna-Realm")
	check(c and c.name == "Anna-Realm" and #c.lines == 1 and c.lines[1].text == "hi there" and c.lines[1].out == false,
		"incoming whisper filed under the partner")
	check(c.lines[1].t == T0 and c.unread == 0, "line has the event time; shown conversation is read")
	check(env.W.ui and env.W.ui.frame.shown, "window opens out of combat")
	check(#env.received == 1 and env.received[1][3] == "Anna-Realm" and env.received[1][2] == 1,
		"WHISPER_RECEIVED carries the key only")
	check(#env.sounds == 1, "sound on an incoming whisper")
	env.whisper("CHAT_MSG_WHISPER_INFORM", "hello Anna", "Anna-Realm", 12)
	check(#c.lines == 2 and c.lines[2].out == true and c.lines[2].text == "hello Anna", "outgoing whisper filed from the inform event")
	check(#env.received == 1, "outgoing line sends no WHISPER_RECEIVED")
	env.whisper("CHAT_MSG_WHISPER", "other", "Bob", 13)
	check(env.conv("Anna-Realm") and env.conv("Bob"), "second partner has its own conversation")
	check(env.conv("Bob").unread == 1 and env.W.GetUnread() == 1, "other conversation is unread while another is shown")
	check(env.W.ui.tabs[1].key and env.W.ui.tabs[2].key, "tabs for both partners")
	check(env.W.ui.title.text:find("(1)", 1, true), "unread count in the title")
	check(#env.errors == 0, "no errors")
end

-- Battle.net

do
	local env = boot()
	env.bn("CHAT_MSG_BN_WHISPER", "hey", "Whatever", 42)
	local c = env.conv("bn:42")
	check(c and c.bnet and c.accountID == 42 and c.name == "Friend42", "Battle.net whisper keyed by account ID with display name")
	env.bn("CHAT_MSG_BN_WHISPER_INFORM", "yo", "Whatever", 42)
	check(#c.lines == 2 and c.lines[2].out, "Battle.net inform filed into the same conversation")
	env.W.ui.input:SetText("answer")
	env.W.ui.input.scripts.OnEnterPressed(env.W.ui.input)
	check(#env.bnSent == 1 and env.bnSent[1][1] == 42 and env.bnSent[1][2] == "answer" and #env.sent == 0,
		"Enter sends a Battle.net partner through C_BattleNet.SendWhisper")
	check(env.W.ui.input.text == "", "input is cleared after sending")
end

-- Sending

do
	local env = boot()
	env.whisper("CHAT_MSG_WHISPER", "hi", "Anna-Realm", 1)
	local ui = env.W.ui
	local before = #ui.msgs.lines
	ui.input:SetText("reply")
	ui.input.scripts.OnEnterPressed(ui.input)
	check(#env.sent == 1 and env.sent[1][1] == "reply" and env.sent[1][2] == "WHISPER" and env.sent[1][3] == nil
		and env.sent[1][4] == "Anna-Realm", "Enter sends through C_ChatInfo.SendChatMessage")
	check(#ui.msgs.lines == before, "sent text is not shown before the inform event")
	env.whisper("CHAT_MSG_WHISPER_INFORM", "reply", "Anna-Realm", 2)
	check(#ui.msgs.lines == before + 1 and ui.msgs.lines[#ui.msgs.lines]:find("reply", 1, true), "text shows when the inform event arrives")
	local words = {}
	for i = 1, 90 do words[i] = "w" .. i end
	ui.input:SetText(table.concat(words, " "))
	ui.input.scripts.OnEnterPressed(ui.input)
	check(#env.sent >= 3, "long text goes out in several sends")
	local fine = true
	for i = 2, #env.sent do
		if #env.sent[i][1] > 255 or env.sent[i][1]:find("^%s") then fine = false end
	end
	check(fine, "every part is at most 255 bytes")
	local n = #env.sent
	ui.input:SetText("   ")
	ui.input.scripts.OnEnterPressed(ui.input)
	check(#env.sent == n, "blank input sends nothing")
	ui.input.focus = true
	ui.input.scripts.OnEscapePressed(ui.input)
	check(ui.input.focus == false, "Escape clears focus")
end

do
	local env = boot({ no = { ["C_ChatInfo.SendChatMessage"] = true } })
	env.whisper("CHAT_MSG_WHISPER", "hi", "Anna", 1)
	env.W.ui.input:SetText("x")
	env.W.ui.input.scripts.OnEnterPressed(env.W.ui.input)
	check(env.out():find("no function to send", 1, true) and #env.errors == 0, "missing send function prints a message")
end

-- Lockdown

do
	local env = boot()
	env.lockdown = true
	env.fire("CHAT_MSG_WHISPER", env.secret("text"), env.secret("name"), "", "", env.secret("name2"), "", 0, 0, "", 0, 21, env.secret("guid"), 0)
	env.fire("CHAT_MSG_WHISPER_INFORM", env.secret("text"), env.secret("name"), "", "", "", "", 0, 0, "", 0, 22, env.secret("guid"), 0)
	env.fire("CHAT_MSG_BN_WHISPER", env.secret("text"), env.secret("name"), "", "", "", "", 0, 0, "", 0, 23, env.secret("guid"), env.secret("id"))
	check(#env.errors == 0, "secret values are never compared, concatenated or measured: " .. tostring(env.errors[1]))
	check(env.W.GetLast() == nil, "nothing is filed during lockdown")
	check(env.timer.shown, "the resolve timer runs while lines are pending")
	check(not (env.W.ui and env.W.ui.frame.shown), "no window during lockdown")
	check(#env.received == 0, "no message during lockdown")
	check(not hasSecret(env, env.g.SempreWhisperDB), "no secret value in the saved data")

	-- Still locked: nothing happens.
	env.fire("PLAYER_REGEN_ENABLED")
	check(env.W.GetLast() == nil and env.timer.shown, "lines wait while the lockdown lasts")

	env.lockdown = false
	env.now = T0 + 90
	env.lineData[21] = { name = "Carl-Realm", text = "late hello" }
	env.lineData[22] = { name = "Carl-Realm", text = "my answer" }
	-- line 23 is gone
	env.fire("PLAYER_REGEN_ENABLED")
	local c = env.conv("Carl-Realm")
	check(c and #c.lines == 2, "queued lines are filed after the lockdown")
	check(c.lines[1].t == T0 and c.lines[2].t == T0 and c.lines[1].text == "late hello" and c.lines[2].out == true,
		"queued lines keep their original time")
	check(env.W.GetLast() == "Carl-Realm" and env.conv("bn:77") == nil, "unreadable line is dropped silently")
	check(not env.timer.shown, "timer stops when the list is empty")
	check(#env.received == 1 and env.received[1][3] == "Carl-Realm", "WHISPER_RECEIVED for the resolved incoming line")
	check(#env.errors == 0 and #env.printed == 0, "no errors or chat lines")
end

do
	-- Timer path, zone change, Battle.net resolved through the sender GUID.
	local env = boot()
	env.lockdown = true
	env.fire("CHAT_MSG_BN_WHISPER", env.secret("t"), env.secret("n"), "", "", "", "", 0, 0, "", 0, 31, env.secret("g"), env.secret("i"))
	env.lineData[31] = { name = "Dora", text = "bn text", guid = "guid-bn" }
	env.timer.scripts.OnUpdate(env.timer, 2)
	check(env.W.GetLast() == nil, "timer waits for 5 seconds")
	env.timer.scripts.OnUpdate(env.timer, 2)
	env.timer.scripts.OnUpdate(env.timer, 2)
	check(env.W.GetLast() == nil and env.timer.shown, "timer does not file during lockdown")
	env.lockdown = false
	env.timer.scripts.OnUpdate(env.timer, 5)
	local c = env.conv("bn:77")
	check(c and c.bnet and c.accountID == 77 and c.lines[1].text == "bn text", "Battle.net line resolved to its account ID")
	check(not env.timer.shown, "timer hidden after resolving")

	env.lockdown = true
	env.fire("CHAT_MSG_WHISPER", env.secret("t"), env.secret("n"), "", "", "", "", 0, 0, "", 0, 32, env.secret("g"), 0)
	env.lineData[32] = { name = "Emil", text = "zone text" }
	env.lockdown = false
	env.fire("ZONE_CHANGED_NEW_AREA")
	check(env.conv("Emil") and env.conv("Emil").lines[1].text == "zone text", "zone change resolves pending lines")
end

do
	-- A secret value outside lockdown is queued as well; the cap is 50.
	local env = boot()
	env.fire("CHAT_MSG_WHISPER", env.secret("t"), "Plain", "", "", "", "", 0, 0, "", 0, 41, "g", 0)
	check(env.W.GetLast() == nil and env.timer.shown and #env.errors == 0, "a secret value queues the line even without lockdown")
	env.lockdown = true
	for i = 1, 60 do
		env.fire("CHAT_MSG_WHISPER", env.secret("t"), env.secret("n"), "", "", "", "", 0, 0, "", 0, 100 + i, env.secret("g"), 0)
		env.lineData[100 + i] = { name = "P" .. i, text = "t" .. i }
	end
	local asked = {}
	local orig = env.g.C_ChatInfo.GetChatLineText
	env.g.C_ChatInfo.GetChatLineText = function(id) asked[#asked + 1] = id return orig(id) end
	env.lockdown = false
	env.fire("PLAYER_REGEN_ENABLED")
	check(#asked == 50 and asked[1] == 111 and asked[50] == 160, "pending list is capped at 50, oldest dropped: " .. #asked)
end

-- Opening, combat and options

do
	local env = boot()
	env.combat = true
	env.fire("PLAYER_REGEN_DISABLED")
	env.whisper("CHAT_MSG_WHISPER", "in combat", "Anna", 1)
	check(not (env.W.ui and env.W.ui.frame.shown), "no window in combat")
	check(env.conv("Anna").unread == 1 and env.W.GetUnread() == 1, "tab is marked unread in combat")
	env.combat = false
	env.fire("PLAYER_REGEN_ENABLED")
	check(env.W.ui and env.W.ui.frame.shown and env.W.ui.title.text:find("Anna", 1, true), "window opens at combat end")
	check(env.conv("Anna").unread == 0, "opened conversation is read")
end

do
	local env = boot({ options = { open = false } })
	env.whisper("CHAT_MSG_WHISPER", "quiet", "Anna", 1)
	check(not (env.W.ui and env.W.ui.frame.shown) and env.conv("Anna").unread == 1, "option off: only the unread marker")
	env.fire("PLAYER_REGEN_DISABLED")
	env.fire("PLAYER_REGEN_ENABLED")
	check(not (env.W.ui and env.W.ui.frame.shown), "option off: no window at combat end")
end

-- Sound

do
	local env = boot()
	env.whisper("CHAT_MSG_WHISPER", "one", "Anna", 1)
	check(#env.sounds == 1 and env.sounds[1] == 3081, "sound kit fallback is used without SOUNDKIT")
	env.W.ui.input.focus = true
	env.whisper("CHAT_MSG_WHISPER", "two", "Anna", 2)
	check(#env.sounds == 1, "no sound while the shown conversation has focus")
	env.W.ui.input.focus = false
	env.whisper("CHAT_MSG_WHISPER", "three", "Anna", 3)
	check(#env.sounds == 2, "sound again when the window is not focused")
	env.whisper("CHAT_MSG_WHISPER", "four", "Bob", 4)
	check(#env.sounds == 3, "sound for another conversation")
	env.whisper("CHAT_MSG_WHISPER_INFORM", "mine", "Bob", 5)
	check(#env.sounds == 3, "no sound for an outgoing whisper")

	local quiet = boot({ options = { sound = false } })
	quiet.whisper("CHAT_MSG_WHISPER", "one", "Anna", 1)
	check(#quiet.sounds == 0, "sound option off")

	local none = boot({ no = { ["C_Sound.PlaySound"] = true } })
	none.whisper("CHAT_MSG_WHISPER", "one", "Anna", 1)
	check(#none.errors == 0 and #none.sounds == 0, "missing sound function is harmless")
end

-- History

do
	local env = boot()
	for i = 1, 60 do
		env.now = T0 + i
		env.whisper("CHAT_MSG_WHISPER", "m" .. i, "Anna", i)
	end
	local c = env.conv("Anna")
	check(#c.lines == 50 and c.lines[1].text == "m11" and c.lines[50].text == "m60", "last 50 lines per conversation")
	check(env.g.SempreWhisperDB.chars["Tester-Realm"].conversations["Anna"] == c, "conversation is in the saved data")

	env.now = T0 + 100
	for i = 1, 35 do
		env.now = T0 + 100 + i
		env.whisper("CHAT_MSG_WHISPER", "x", "P" .. i, 200 + i)
	end
	local n = count(env.g.SempreWhisperDB.chars["Tester-Realm"].conversations)
	check(n == 30 and not env.conv("Anna") and not env.conv("P5") and env.conv("P6") and env.conv("P35"),
		"at most 30 conversations, oldest dropped: " .. n)

	env.now = T0 + 100 + 8 * DAY
	env.whisper("CHAT_MSG_WHISPER", "fresh", "Zed", 300)
	check(env.conv("P35") == nil and env.conv("Zed") and env.W.GetLast() == "Zed", "lines older than 7 days are dropped")
	local saved = count(env.g.SempreWhisperDB.chars["Tester-Realm"].conversations)
	check(saved == 1, "only the fresh conversation remains saved")
end

do
	-- Saved data survives a reload; old and broken entries are cleaned up.
	local db = { version = 1, chars = { ["Tester-Realm"] = { conversations = {
		Old = { name = "Old", lines = { { t = T0 - 9 * DAY, out = false, text = "ancient" } } },
		Keep = { name = "Keep", unread = 2, lines = { { t = T0 - 100, out = false, text = "saved" } } },
		Broken = { name = "Broken", lines = "oops" },
	}, window = { point = "CENTER", relPoint = "CENTER", x = 5, y = 6, w = 400, h = 300 } } } }
	local env = boot({ db = db })
	check(env.conv("Keep") and env.conv("Keep").lines[1].text == "saved" and not env.conv("Old") and not env.conv("Broken"),
		"saved conversations load, expired and broken ones are removed")
	check(env.W.GetUnread() == 1, "unread count survives a reload")
	env.S.commands.fluestern("")
	check(env.W.ui.frame.shown and env.W.ui.frame.w == 400 and env.W.ui.frame.h == 300, "window size is restored")
	check(env.W.ui.frame.point[1] == "CENTER" and env.W.ui.frame.point[4] == 5, "window position is restored")
	env.W.ui.frame.scripts.OnDragStop(env.W.ui.frame)
	local w = db.chars["Tester-Realm"].window
	check(w.point == "TOPLEFT" and w.x == 10 and w.y == -20 and w.w == 400, "position and size are saved")
end

do
	local db = { version = 1, chars = { ["Tester-Realm"] = { conversations = {
		Keep = { name = "Keep", lines = { { t = T0 - 100, out = false, text = "saved" } } },
	} } } }
	local env = boot({ db = db, options = { history = false } })
	check(not env.conv("Keep") and next(db.chars["Tester-Realm"].conversations) == nil, "history off deletes saved lines at start")
	env.whisper("CHAT_MSG_WHISPER", "session", "Anna", 1)
	check(env.conv("Anna") and next(db.chars["Tester-Realm"].conversations) == nil, "history off keeps lines only in the session")
end

do
	local env = boot()
	env.whisper("CHAT_MSG_WHISPER", "one", "Anna", 1)
	local saved = env.g.SempreWhisperDB.chars["Tester-Realm"]
	check(next(saved.conversations) ~= nil, "history on saves")
	env.S:SetOption("Sempre_Whisper", "history", false)
	check(next(saved.conversations) == nil and env.conv("Anna"), "switching history off deletes saved lines, keeps the session")
	env.whisper("CHAT_MSG_WHISPER", "two", "Anna", 2)
	check(next(saved.conversations) == nil and #env.conv("Anna").lines == 2, "nothing saved while off")
	env.S:SetOption("Sempre_Whisper", "history", true)
	check(saved.conversations.Anna and #saved.conversations.Anna.lines == 2, "switching history on saves the session again")
end

-- Command

do
	local env = boot()
	env.S.commands.fluestern("")
	check(env.out():find("no conversation yet", 1, true) and not env.W.ui, "command without conversations prints a note")
	env.whisper("CHAT_MSG_WHISPER", "a", "Anna", 1)
	env.now = T0 + 10
	env.whisper("CHAT_MSG_WHISPER", "b", "Bob", 2)
	env.W.ui.frame:Hide()
	env.printed = {}
	env.S.commands.whisper("")
	check(env.W.ui.frame.shown and env.W.ui.title.text:find("Bob", 1, true), "/sempre whisper opens the last conversation")
	check(env.out():find("2 conversations, 1 unread", 1, true), "command prints the counts: " .. env.out())
end

do
	local env = boot({ locale = "deDE" })
	env.S.commands.fluestern("")
	check(env.out():find("Noch keine Unterhaltung", 1, true), "German command text")
end

-- Texts are not secret and links stay in the text

do
	local env = boot()
	env.whisper("CHAT_MSG_WHISPER", "see |cff0070dd|Hitem:19019|h[Thunderfury]|h|r", "Anna", 1)
	check(env.W.ui.msgs.lines[1]:find("|Hitem:19019|h[Thunderfury]|h", 1, true), "links stay in the message text")
	check(env.W.ui.msgs.scripts.OnHyperlinkClick ~= nil, "message frame handles link clicks")
end

end
