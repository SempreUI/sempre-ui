-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Tests for Sempre_Buttons with a stubbed WoW API. Loaded by tests/run.lua,
-- which passes in its check helper. Boots the real core, then the module's
-- file, with a stubbed minimap and fake frames that keep parent, points,
-- strata and level like the real ones.

return function(check)

local SECRET = {}

local frameMethods = {}
local function newFrame(env, kind, name, parent, w, h)
	local f = setmetatable({ kind = kind, name = name, parentFrame = parent, w = w or 0, h = h or 0,
		shown = true, scripts = {}, hooks = {}, pts = {}, strata = "MEDIUM", level = 1,
		clicks = {} }, { __index = frameMethods })
	f.env = env
	env.all[#env.all + 1] = f
	return f
end

function frameMethods:GetName() return self.name end
function frameMethods:GetObjectType() return self.kind end
function frameMethods:GetSize() return self.w, self.h end
function frameMethods:SetSize(w, h) self.w, self.h = w, h end
function frameMethods:GetWidth() return self.w end
function frameMethods:GetHeight() return self.h end
function frameMethods:GetParent() return self.parentFrame end
function frameMethods:SetParent(p) self.parentFrame = p end
function frameMethods:IsProtected() return self.protected or false end
function frameMethods:GetFrameStrata() return self.strata end
function frameMethods:SetFrameStrata(s) self.strata = s end
function frameMethods:GetFrameLevel() return self.level end
function frameMethods:SetFrameLevel(l) self.level = l end
function frameMethods:Show() self.shown = true end
function frameMethods:Hide() self.shown = false end
function frameMethods:IsShown() return self.shown end
function frameMethods:ClearAllPoints() self.pts = {} end
function frameMethods:SetPoint(...) self.pts[#self.pts + 1] = { ... } end
function frameMethods:GetNumPoints() return #self.pts end
function frameMethods:GetPoint(i) local p = self.pts[i] return p[1], p[2], p[3], p[4], p[5] end
function frameMethods:SetScript(kind, fn) self.scripts[kind] = fn end
function frameMethods:GetScript(kind) return self.scripts[kind] end
function frameMethods:HasScript() return true end
function frameMethods:HookScript(kind, fn) self.hooks[kind] = fn end
function frameMethods:GetChildren()
	local out = {}
	for _, f in ipairs(self.env.all) do
		if f.parentFrame == self then out[#out + 1] = f end
	end
	return unpack(out)
end
function frameMethods:IsMouseOver() return self.env.over[self] or false end
function frameMethods:GetCenter() return self.cx, self.cy end
function frameMethods:GetEffectiveScale() return 1 end
function frameMethods:CreateTexture() return setmetatable({}, { __index = function() return function() end end }) end
function frameMethods:GetHighlightTexture() end
function frameMethods:SetBackdrop() end
function frameMethods:SetBackdropColor() end
function frameMethods:SetBackdropBorderColor() end
function frameMethods:SetClampedToScreen() end
function frameMethods:EnableMouse() end
function frameMethods:RegisterForClicks() end
function frameMethods:RegisterForDrag() end
function frameMethods:SetHighlightTexture() end
function frameMethods:RegisterEvent() end
function frameMethods:UnregisterEvent() end

-- opts: noMinimap, db, options, combat, square, noMouseEvent, noTimer
local function boot(opts)
	opts = opts or {}
	local env = { printed = {}, errors = {}, all = {}, over = {}, timers = {}, combat = opts.combat or false,
		settings = 0, tip = {} }
	local g = setmetatable({}, { __index = _G })
	g._G = g
	g.table = setmetatable({ wipe = function(t) for k in pairs(t) do t[k] = nil end return t end }, { __index = table })
	g.CreateFrame = function(kind, _, parent)
		return newFrame(env, kind, nil, parent)
	end
	g.GetLocale = function() return "enUS" end
	g.GetBuildInfo = function() return "1", "", "", 16001 end
	g.UnitName = function() return "Tester" end
	g.GetRealmName = function() return "Realm" end
	g.time = os.time
	g.issecretvalue = function(v) return v == SECRET end
	g.geterrorhandler = function() return function(err) env.errors[#env.errors + 1] = err end end
	g.SlashCmdList = {}
	g.print = function(msg) env.printed[#env.printed + 1] = msg end
	g.C_AddOns = { GetAddOnMetadata = function() return nil end, GetNumAddOns = function() return 0 end }
	g.C_EventUtils = { IsEventValid = function(e) return not (opts.noMouseEvent and e == "GLOBAL_MOUSE_UP") end }
	if not opts.noTimer then
		g.C_Timer = { After = function(sec, fn) env.timers[#env.timers + 1] = { sec = sec, fn = fn } end }
	end
	g.InCombatLockdown = function() return env.combat end
	g.GameTooltip = setmetatable({ lines = {} }, { __index = function(t, k)
		if k == "AddLine" then return function(_, text) t.lines[#t.lines + 1] = text end end
		if k == "Hide" then return function() t.lines = {} end end
		return function() end
	end })
	g.GetCursorPosition = function() return env.cursorX or 0, env.cursorY or 0 end
	if opts.square then g.GetMinimapShape = function() return "SQUARE" end end
	g.UIParent = newFrame(env, "Frame", "UIParent")
	g.UIParent.cx, g.UIParent.cy = 960, 540
	if not opts.noMinimap then
		g.Minimap = newFrame(env, "Frame", "Minimap", g.UIParent, 140, 140)
		g.Minimap.cx, g.Minimap.cy = 1000, 500
		g.MinimapCluster = newFrame(env, "Frame", "MinimapCluster", g.UIParent, 200, 200)
		env.minimap = g.Minimap
	end
	if opts.db then g.SempreButtonsDB = opts.db end

	local function run(path, ...)
		local chunk = assert(loadfile(path))
		setfenv(chunk, g)
		return chunk(...)
	end
	env.g = g
	run("Sempre/Core.lua", "Sempre")
	env.S = g.SempreUI
	env.core = env.all[#env.all]
	for _, f in ipairs(env.all) do
		if f.scripts.OnEvent then env.core = f end
	end
	function env.fire(event, ...) env.core.scripts.OnEvent(env.core, event, ...) end
	env.fire("ADDON_LOADED", "Sempre")
	if opts.options then env.S.db.global.options.Sempre_Buttons = opts.options end
	env.fire("PLAYER_LOGIN")
	env.changed = {}
	env.S:Listen("BUTTONS_CHANGED", function(_, n) env.changed[#env.changed + 1] = n end)

	-- An addon button on the minimap, created before the module loads or later.
	function env.addon(name, w, h, o)
		o = o or {}
		local f = newFrame(env, o.kind or "Button", name, o.parent or env.minimap, w or 31, h or w or 31)
		f.pts = { { "TOPLEFT", env.minimap, "TOPLEFT", 3, -4 } }
		f.strata, f.level = "LOW", 5
		f.protected = o.protected
		if o.noScripts then
			f.HasScript = function() return false end
		end
		return f
	end
	if opts.setup then opts.setup(env) end

	run("Sempre_Buttons/Buttons.lua", "Sempre_Buttons")
	env.fire("ADDON_LOADED", "Sempre_Buttons")
	env.B = env.S.Buttons
	env.loadPrinted = table.concat(env.printed, "\n")
	env.printed = {}
	function env.out() return table.concat(env.printed, "\n") end
	function env.world() env.fire("PLAYER_ENTERING_WORLD") end
	function env.flush()
		local t = env.timers
		env.timers = {}
		for _, timer in ipairs(t) do timer.fn() end
	end
	return env
end

local function names(list)
	local out = {}
	for i, f in ipairs(list) do out[i] = type(f) == "string" and f or f:GetName() end
	return table.concat(out, ",")
end

-- Collecting and skipping

do
	local env = boot({ setup = function(e)
		e.addon("ZedButton")
		e.addon("AlphaButton", 24)
		e.addon("MinimapZoomIn")
		e.addon("GameTimeFrame")
		e.addon("QueueStatusButton")
		e.addon("MailButton")
		e.addon("AddonCompartmentFrame")
		e.addon("ProtectedThing", 30, 30, { protected = true })
		e.addon(nil, 30, 30)
		e.addon("TooBig", 60)
		e.addon("TooSmall", 10)
		e.addon("NotAButton", 30, 30, { kind = "Frame", noScripts = true })
		e.addon("ClusterChild", 30, 30, { parent = e.g.MinimapCluster })
		e.addon("Elsewhere", 30, 30, { parent = e.g.UIParent })
	end })
	env.world()
	check(names(env.B.GetCollected()) == "AlphaButton,ClusterChild,ZedButton", "addon buttons collected, sorted: " .. names(env.B.GetCollected()))
	local skipped = true
	for _, f in ipairs(env.all) do
		local n = f:GetName()
		if n and (n:find("^Minimap") or n == "GameTimeFrame" or n == "QueueStatusButton" or n == "MailButton"
			or n == "AddonCompartmentFrame" or n == "ProtectedThing" or n == "TooBig" or n == "TooSmall"
			or n == "NotAButton" or n == "Elsewhere") and f ~= env.g.Minimap and f ~= env.g.MinimapCluster
			and f:GetParent() == env.B.panel then
			skipped = false
		end
	end
	check(skipped, "game, protected, wrong-sized, script-less and foreign frames stay put")
	local nameless = false
	for _, f in ipairs(env.all) do
		if f.name == nil and f:GetParent() == env.B.panel and f ~= env.B.button then nameless = true end
	end
	check(not nameless, "nameless frames are skipped")
	check(#env.changed == 1 and env.changed[1] == 3, "BUTTONS_CHANGED carries the count")
	check(env.B.button:GetParent() == env.minimap, "own button is not collected")
end

-- Grid

do
	local env = boot({ setup = function(e)
		for i = 1, 8 do e.addon(string.format("Btn%d", i), 30) end
	end })
	env.world()
	local panel = env.B.panel
	local list = {}
	for _, f in ipairs(env.all) do
		if f:GetParent() == panel and f.name then list[#list + 1] = f end
	end
	table.sort(list, function(a, b) return a.name < b.name end)
	check(#list == 8, "all eight are in the panel")
	local ok = true
	for i, f in ipairs(list) do
		local p = f.pts[1]
		local col, row = (i - 1) % 6, math.floor((i - 1) / 6)
		if p[1] ~= "TOPLEFT" or p[2] ~= panel or p[4] ~= 4 + col * 34 or p[5] ~= -(4 + row * 34) then ok = false end
	end
	check(ok, "grid: 6 columns, 4 px gaps, sorted by name")
	check(panel.w == 4 * 2 + 6 * 30 + 5 * 4 and panel.h == 4 * 2 + 2 * 30 + 4, "panel size fits 6 x 2 cells")
	check(list[1].pts[1][4] == 4 and list[7].pts[1][5] == -38, "second row starts at the left")
end

do
	local env = boot({ setup = function(e) e.addon("A", 30) e.addon("B", 30) end })
	env.world()
	check(env.B.panel.w == 8 + 2 * 30 + 4, "fewer than 6 buttons: columns shrink to the count")
end

-- Original data kept; raus and rein

do
	local env
	env = boot({ setup = function(e) e.addon("AlphaButton") e.addon("BetaButton") end })
	env.world()
	local alpha
	for _, f in ipairs(env.all) do if f.name == "AlphaButton" then alpha = f end end
	check(alpha:GetParent() == env.B.panel and alpha.strata ~= "LOW", "collected: reparented, strata of the panel")
	env.S.commands.knoepfe("")
	check(env.out():find("1. AlphaButton") and env.out():find("2. BetaButton"), "list shows numbers")
	env.printed = {}
	env.S.commands.knoepfe("raus 1")
	check(alpha:GetParent() == env.minimap, "raus: original parent at once")
	local p = alpha.pts[1]
	check(#alpha.pts == 1 and p[1] == "TOPLEFT" and p[2] == env.minimap and p[3] == "TOPLEFT" and p[4] == 3 and p[5] == -4, "raus: original points")
	check(alpha.strata == "LOW" and alpha.level == 5, "raus: original strata and level")
	check(env.g.SempreButtonsDB.outside.AlphaButton == true, "outside list saved")
	check(names(env.B.GetCollected()) == "BetaButton" and env.B.GetOutside()[1] == "AlphaButton", "interface lists both")
	env.printed = {}
	env.S.commands.buttons("")
	check(env.out():find("1. BetaButton") and env.out():find("2. AlphaButton %(outside%)"), "outside buttons listed after collected ones")
	env.S.commands.knoepfe("neu")
	check(alpha:GetParent() == env.minimap, "rescan respects the outside list")
	env.S.commands.knoepfe("rein alphabutton")
	check(alpha:GetParent() == env.B.panel and env.g.SempreButtonsDB.outside.AlphaButton == nil, "rein by name collects it again")
	check(names(env.B.GetCollected()) == "AlphaButton,BetaButton", "back in the sorted list")
	env.S.commands.knoepfe("out Nope")
	check(env.out():find("no button Nope"), "unknown name is reported")
	env.S.commands.knoepfe("in 1")
	check(env.out():find("not on the outside list"), "rein on a collected button is reported")
	env.S.commands.knoepfe("bogus")
	check(env.out():find("Usage"), "usage on unknown subcommand")
	-- Moving itself back is repaired on the next open.
	alpha:SetParent(env.minimap)
	alpha:ClearAllPoints()
	alpha:SetPoint("CENTER", env.minimap, "CENTER", 50, 50)
	env.B.button.scripts.OnClick(env.B.button, "LeftButton")
	check(env.B.panel:IsShown() and alpha:GetParent() == env.B.panel and alpha.pts[1][1] == "TOPLEFT" and alpha.pts[1][4] == 4,
		"button that moved itself is put back on open")
	-- Returning after a self-move still restores the first original place.
	env.S.commands.knoepfe("raus AlphaButton")
	check(alpha.pts[1][4] == 3 and alpha.pts[1][5] == -4, "original place survives a self-move")
end

-- Combat

do
	local env = boot({ combat = true, setup = function(e) e.addon("AlphaButton") end })
	env.world()
	check(names(env.B.GetCollected()) == "", "no scan in combat")
	check(#env.changed == 0, "no message while queued")
	env.combat = false
	env.fire("PLAYER_REGEN_ENABLED")
	check(names(env.B.GetCollected()) == "AlphaButton", "queued scan runs at combat end")
	-- raus during combat is deferred.
	local alpha
	for _, f in ipairs(env.all) do if f.name == "AlphaButton" then alpha = f end end
	env.combat = true
	env.S.commands.knoepfe("raus AlphaButton")
	check(alpha:GetParent() == env.B.panel and env.g.SempreButtonsDB.outside.AlphaButton, "raus in combat: listed now, moved later")
	env.combat = false
	env.fire("PLAYER_REGEN_ENABLED")
	check(alpha:GetParent() == env.minimap, "release done at combat end")
	-- panel closes at combat start and does not open in combat
	env.S.commands.knoepfe("rein AlphaButton")
	env.S.commands.knoepfe("zeigen")
	check(env.B.panel:IsShown(), "panel opens through zeigen")
	env.fire("PLAYER_REGEN_DISABLED")
	check(not env.B.panel:IsShown(), "panel closes when combat starts")
	env.combat = true
	env.B.button.scripts.OnClick(env.B.button, "LeftButton")
	check(not env.B.panel:IsShown(), "panel does not open in combat")
end

-- Late buttons

do
	local env = boot({ setup = function(e) e.addon("EarlyButton") end })
	env.world()
	check(#env.timers == 1 and env.timers[1].sec == 5, "second scan is scheduled 5 seconds later")
	env.addon("LateButton")
	env.flush()
	check(names(env.B.GetCollected()) == "EarlyButton,LateButton", "second scan picks up a late button")
	check(#env.changed == 2 and env.changed[2] == 2, "BUTTONS_CHANGED after each scan")
	env.world()
	check(#env.timers == 0, "later loading screens do not rescan")
	env.addon("ManualButton")
	env.S.commands.knoepfe("neu")
	check(#env.B.GetCollected() == 3, "neu scans again")
end

-- Panel closing

do
	local env = boot({ setup = function(e) e.addon("AlphaButton") end })
	env.world()
	local alpha
	for _, f in ipairs(env.all) do if f.name == "AlphaButton" then alpha = f end end
	local function open() env.B.button.scripts.OnClick(env.B.button, "LeftButton") end
	open()
	check(env.B.panel:IsShown(), "left click opens")
	open()
	check(not env.B.panel:IsShown(), "second click closes")

	open()
	env.over[alpha], env.over[env.B.panel] = true, true
	env.fire("GLOBAL_MOUSE_UP")
	check(env.B.panel:IsShown(), "close waits one frame so the button gets its click")
	env.flush()
	check(not env.B.panel:IsShown(), "panel closes after a click on a collected button")

	env.g.SempreUI.db.global.options.Sempre_Buttons = { close_on_click = false }
	open()
	env.fire("GLOBAL_MOUSE_UP")
	env.flush()
	check(env.B.panel:IsShown(), "option off: panel stays open after a button click")
	env.over = {}
	env.over[env.minimap] = true
	env.fire("GLOBAL_MOUSE_UP")
	env.flush()
	check(not env.B.panel:IsShown(), "click on the minimap outside the panel closes it")

	open()
	env.over = { [env.B.button] = true, [env.minimap] = true }
	env.fire("GLOBAL_MOUSE_UP")
	env.flush()
	check(env.B.panel:IsShown(), "click on the SempreUI button is left to its own toggle")
end

-- SempreUI button: right click, drag, tooltip

do
	local env = boot({ setup = function(e) e.addon("AlphaButton") end })
	env.world()
	env.S.OpenSettings = function() env.settings = env.settings + 1 end
	env.B.button.scripts.OnClick(env.B.button, "RightButton")
	check(env.settings == 1 and not env.B.panel:IsShown(), "right click opens the settings")
	env.B.button.scripts.OnEnter(env.B.button)
	local tip = table.concat(env.g.GameTooltip.lines, "|")
	check(tip:find("SempreUI") and tip:find("1 buttons collected") and tip:find("Left click") and tip:find("Right click"), "tooltip: name, count, hints")

	-- drag: cursor straight above the minimap centre = 90 degrees
	env.B.button.scripts.OnDragStart(env.B.button)
	check(env.B.button.scripts.OnUpdate ~= nil, "drag starts an update")
	env.cursorX, env.cursorY = 1000, 800
	env.B.button.scripts.OnUpdate(env.B.button)
	env.B.button.scripts.OnDragStop(env.B.button)
	check(math.abs(env.g.SempreButtonsDB.angle - 90) < 1e-6, "drag angle saved")
	check(env.B.button.scripts.OnUpdate == nil, "drag stop removes the update")
	local p = env.B.button.pts[1]
	check(p[1] == "CENTER" and p[2] == env.minimap and math.abs(p[4]) < 1e-6 and math.abs(p[5] - 75) < 1e-6, "button sits on the circle: radius + 5")
end

do
	local env = boot({ db = { version = 1, angle = 180, outside = { Gone = true } } })
	env.world()
	local p = env.B.button.pts[1]
	check(math.abs(p[4] + 75) < 1e-6 and math.abs(p[5]) < 1e-6, "saved angle restored")
	check(env.B.GetOutside()[1] == "Gone", "saved outside list restored")
	env.S.commands.knoepfe("")
	check(env.out():find("1. Gone %(outside%)"), "outside name without a frame is listed")
	env.S.commands.knoepfe("rein Gone")
	check(#env.B.GetOutside() == 0, "rein works for a name whose frame is not around")
end

do
	local env = boot({ square = true, db = { version = 1, angle = 45, outside = {} } })
	env.world()
	local p = env.B.button.pts[1]
	check(math.abs(p[4] - 75) < 1e-6 and math.abs(p[5] - 75) < 1e-6, "square minimap: button goes to the corner")
	local env2 = boot({ db = { version = 1, angle = "bad", outside = "bad" } })
	check(env2.g.SempreButtonsDB.angle == 225 and type(env2.g.SempreButtonsDB.outside) == "table", "bad saved data is repaired")
end

-- Option: button hidden

do
	local env = boot({ options = { show_button = false }, setup = function(e) e.addon("AlphaButton") end })
	env.world()
	check(not env.B.button:IsShown(), "option off hides the SempreUI button")
	env.S.commands.knoepfe("zeigen")
	check(env.B.panel:IsShown(), "panel reachable through zeigen")
	local a = env.B.panel.pts[1]
	check(a[2] == env.minimap, "panel anchors to the minimap when the button is hidden")
	env.S.commands.buttons("show")
	check(not env.B.panel:IsShown(), "show toggles")
	env.S:SetOption("Sempre_Buttons", "show_button", true)
	check(env.B.button:IsShown(), "switching the option on shows the button")
	env.S:SetOption("Sempre_Buttons", "show_button", false)
	check(not env.B.button:IsShown(), "and off hides it again")
	check(env.S:GetOption("Sempre_Buttons", "close_on_click") == true, "close_on_click defaults on")
end

-- Missing pieces

do
	local env = boot({ noMinimap = true })
	check(env.loadPrinted:find("minimap is not available"), "no minimap: clear message")
	env.world()
	env.S.commands.knoepfe("neu")
	check(env.B.panel == nil, "no minimap: nothing built")
end

do
	local env = boot({ noMouseEvent = true, noTimer = true, setup = function(e) e.addon("AlphaButton") end })
	env.world()
	check(#env.B.GetCollected() == 1, "works without timers and event checks")
	env.B.button.scripts.OnClick(env.B.button, "LeftButton")
	env.over[env.minimap] = true
	env.minimap.hooks.OnMouseUp()
	check(not env.B.panel:IsShown(), "fallback: minimap hook closes the panel")
end

do
	local env = boot({ setup = function(e)
		local f = e.addon("SecretButton")
		f.GetName = function() return SECRET end
		e.addon("Fine")
	end })
	env.world()
	check(names(env.B.GetCollected()) == "Fine", "secret name is skipped")
end

end
