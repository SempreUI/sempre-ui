-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Tests for the settings window (Sempre/Settings.lua) and the option
-- interface in Sempre/Core.lua, with a stubbed Settings and C_AddOns API.
-- Loaded by tests/run.lua, which passes its helpers and the boot functions of
-- the Items and Loot tests (for the tooltip options).

return function(check, same, boots)

local NAMES = { "Sempre_Items", "Sempre_Ledger", "Sempre_Lazy", "Sempre_Foreign" }

-- opts: db (preset SempreDB), noSettings, canvas (canvas API only),
-- noEnable (no EnableAddOn/DisableAddOn), locale, broken (vertical API errors)
local function boot(opts)
	opts = opts or {}
	local addons = {
		Sempre = { meta = { Title = "|cffc8794aSempre|rUI" }, enabled = 2 },
		Sempre_Items = { meta = { ["X-Sempre-Module"] = "1", ["X-Sempre-LoadWith"] = "Login", LoadOnDemand = "1",
			Title = "|cffc8794aSempre|r Items", Notes = "Items notes", ["Notes-deDE"] = "Items Notizen" }, enabled = 2 },
		Sempre_Ledger = { meta = { ["X-Sempre-Module"] = "1", ["X-Sempre-LoadWith"] = "Login", LoadOnDemand = "1",
			Title = "|cffc8794aSempre|r Ledger", Notes = "Ledger notes" }, enabled = 2 },
		Sempre_Lazy = { meta = { ["X-Sempre-Module"] = "1", LoadOnDemand = "1",
			Title = "|cffc8794aSempre|r Lazy", Notes = "Lazy notes" }, enabled = 0 },
		Sempre_Foreign = { meta = { Title = "Foreign" }, enabled = 2 },
	}
	local env = { printed = {}, errors = {}, loaded = {}, calls = {}, opened = {}, messages = {}, combat = false }
	local frames = {}
	local g = setmetatable({}, { __index = _G })
	g.table = setmetatable({ wipe = function(t) for k in pairs(t) do t[k] = nil end return t end }, { __index = table })
	g.CreateFrame = function(kind)
		local f = { scripts = {}, kind = kind, shown = true, checked = false }
		-- Canvas widgets: every other method is a no-op.
		setmetatable(f, { __index = function(_, k)
			if k == "Text" then return { SetText = function() end } end
			return function() end
		end })
		function f.RegisterEvent() end
		function f.UnregisterEvent() end
		function f.SetScript(_, name, fn) f.scripts[name] = fn end
		function f.Show() f.shown = true end
		function f.Hide() f.shown = false end
		function f.SetChecked(_, v) f.checked = v end
		function f.GetChecked() return f.checked end
		function f.CreateFontString() return f end
		frames[#frames + 1] = f
		return f
	end
	g.GetLocale = function() return opts.locale or "enUS" end
	g.GetBuildInfo = function() return "1", "", "", 16001 end
	g.UnitName = function() return "Tester" end
	g.GetRealmName = function() return "Realm" end
	g.time = os.time
	g.geterrorhandler = function() return function(err) env.errors[#env.errors + 1] = err end end
	g.SlashCmdList = {}
	g.print = function(msg) env.printed[#env.printed + 1] = msg end
	g.InCombatLockdown = function() return env.combat end
	g.ReloadUI = function() env.reloaded = (env.reloaded or 0) + 1 end
	local names = { "Sempre" }
	for _, n in ipairs(NAMES) do names[#names + 1] = n end
	g.C_AddOns = {
		GetAddOnMetadata = function(name, key) local a = addons[name]; return a and a.meta[key] end,
		GetNumAddOns = function() return #names end,
		GetAddOnInfo = function(i) return names[i] end,
		IsAddOnLoaded = function(name) return env.loaded[name] == true end,
		GetAddOnEnableState = function(name) return addons[name].enabled end,
		LoadAddOn = function(name)
			env.loaded[name] = true
			env.calls[#env.calls + 1] = "load:" .. name
			return true
		end,
	}
	if not opts.noEnable then
		g.C_AddOns.EnableAddOn = function(name, char)
			addons[name].enabled = 2
			env.calls[#env.calls + 1] = "enable:" .. name .. ":" .. tostring(char)
		end
		g.C_AddOns.DisableAddOn = function(name, char)
			addons[name].enabled = 0
			env.calls[#env.calls + 1] = "disable:" .. name .. ":" .. tostring(char)
		end
	end
	env.addons = addons

	-- Settings stub: records categories, settings, checkboxes and openings.
	local st = { vertical = 0, canvas = 0, addon = {}, subs = {}, checkboxes = {}, headers = 0 }
	env.st = st
	local function newCategory(name)
		local c = { name = name, id = #st.addon + #st.subs + st.vertical + st.canvas + 100 }
		function c.GetID() return c.id end
		return c
	end
	if not opts.noSettings then
		g.Settings = {
			VarType = { Boolean = "boolean" },
			RegisterAddOnCategory = function(c) st.addon[#st.addon + 1] = c end,
			OpenToCategory = function(id) env.opened[#env.opened + 1] = id end,
		}
		if opts.canvas then
			g.Settings.RegisterCanvasLayoutCategory = function(frame, name)
				st.canvas = st.canvas + 1
				local c = newCategory(name)
				c.frame = frame
				return c
			end
		else
			g.Settings.RegisterVerticalLayoutCategory = function(name)
				if opts.broken then error("vertical broke") end
				st.vertical = st.vertical + 1
				st.layout = { initializers = {} }
				function st.layout.AddInitializer(_, init) st.layout.initializers[#st.layout.initializers + 1] = init end
				return newCategory(name), st.layout
			end
			g.Settings.RegisterVerticalLayoutSubcategory = function(parent, name)
				local c = newCategory(name)
				c.parent = parent
				st.subs[#st.subs + 1] = c
				return c
			end
			g.Settings.RegisterProxySetting = function(cat, variable, varType, name, default, get, set)
				return { cat = cat, variable = variable, varType = varType, name = name, default = default, get = get, set = set }
			end
			g.Settings.CreateCheckbox = function(cat, setting, tip)
				local init = { cat = cat, setting = setting, tip = tip, data = { tooltip = tip } }
				function init:GetData() return self.data end
				st.checkboxes[#st.checkboxes + 1] = init
				return init
			end
			g.Settings.NotifyUpdate = function(variable) st.notified = variable end
			g.CreateSettingsListSectionHeaderInitializer = function() st.headers = st.headers + 1 return {} end
			g.CreateSettingsButtonInitializer = function(name, text, click, tip)
				local b = { name = name, text = text, click = click, tip = tip }
				function b:AddShownPredicate(fn) self.predicate = fn end
				return b
			end
		end
	end

	if opts.db then g.SempreDB = opts.db end
	local function run(path, ...)
		local chunk = assert(loadfile(path))
		setfenv(chunk, g)
		return chunk(...)
	end
	env.g = g
	run("Sempre/Core.lua", "Sempre")
	env.S = g.SempreUI
	env.core = frames[1]
	function env.fire(event, ...) env.core.scripts.OnEvent(env.core, event, ...) end
	run("Sempre/Settings.lua", "Sempre")
	env.S:Listen("OPTION_CHANGED", function(_, mod, key, value)
		env.messages[#env.messages + 1] = mod .. ":" .. key .. ":" .. tostring(value)
	end)
	env.fire("ADDON_LOADED", "Sempre")
	-- Items and Ledger start with the character, like their LoadWith line says.
	env.fire("PLAYER_LOGIN")

	-- Checkboxes of the main page by module name.
	function env.rows()
		local rows = {}
		for _, init in ipairs(st.checkboxes) do
			local mod = init.setting.variable:match("^SempreUI_module_(.+)$")
			if mod then rows[#rows + 1] = { name = mod, init = init } end
		end
		return rows
	end
	function env.row(name)
		for _, r in ipairs(env.rows()) do
			if r.name == name then return r.init end
		end
	end
	function env.sub(title)
		for _, c in ipairs(st.subs) do
			if c.name == title then return c end
		end
	end
	function env.pageBoxes(title)
		local list = {}
		for _, init in ipairs(st.checkboxes) do
			if init.cat.name == title then list[#list + 1] = init end
		end
		return list
	end
	function env.reloadButton()
		for _, init in ipairs(st.layout and st.layout.initializers or {}) do
			if init.predicate then return init end
		end
	end
	function env.out() return table.concat(env.printed, "\n") end
	return env
end

-- Login: category, one checkbox per module

do
	local env = boot()
	local st = env.st
	check(#env.errors == 0, "boots without handler errors: " .. tostring(env.errors[1]))
	check(st.vertical == 1 and #st.addon == 1, "category registered once at login")
	check(st.addon[1].name:find("Sempre", 1, true) and st.addon[1].name:find("UI", 1, true), "category is named SempreUI")
	check(st.addon[1].name:find("|cffc8794a", 1, true), "category title carries the copper accent")
	env.S.commands.optionen("")
	env.S.commands.options("")
	env.S.commands.config("")
	check(st.vertical == 1 and #st.addon == 1, "opening never registers the category again")
	check(#env.opened == 3 and env.opened[1] == st.addon[1].id, "all three commands open the category")

	local rows = env.rows()
	local order = {}
	for _, r in ipairs(rows) do order[#order + 1] = r.name end
	check(same(order, { "Sempre_Items", "Sempre_Lazy", "Sempre_Ledger" }), "one checkbox per module, sorted by title: " .. table.concat(order, ","))
	check(env.row("Sempre") == nil and env.row("Sempre_Foreign") == nil, "no checkbox for the core or for foreign addons")
	local items = env.row("Sempre_Items")
	check(items.setting.name:find("^Sempre Items") and not items.setting.name:find("|c", 1, true), "title without colour codes: " .. items.setting.name)
	check(items.setting.get() == true and env.row("Sempre_Lazy").setting.get() == false, "checkbox shows the enable state")
	check(items.tip:find("Items notes", 1, true) and items.tip:find("loaded", 1, true), "notes and state word in the tooltip")
	check(st.headers == 1, "section header for the module list")
	local btn = env.reloadButton()
	check(btn and btn.predicate() == false, "no reload button before a change")
end

-- German notes and words

do
	local env = boot({ locale = "deDE" })
	local items = env.row("Sempre_Items")
	check(items.tip:find("Items Notizen", 1, true) and items.tip:find("geladen", 1, true), "German notes and state word")
	check(env.row("Sempre_Ledger").tip:find("Ledger notes", 1, true), "notes fall back to the English text")
	check(env.sub("Allgemein") ~= nil, "core options page is titled in German")
end

-- Switching on loads a load-on-demand module without reload

do
	local env = boot()
	local lazy = env.row("Sempre_Lazy")
	lazy.setting.set(true)
	check(env.addons.Sempre_Lazy.enabled == 2 and env.loaded.Sempre_Lazy, "switching on enables and loads at once")
	local firstEnable
	for _, c in ipairs(env.calls) do
		if c:find("^enable:") then firstEnable = firstEnable or c end
	end
	check(firstEnable == "enable:Sempre_Lazy:nil", "enabled for all characters (no character given)")
	check(env.reloadButton().predicate() == false, "switching on needs no reload")
	check(lazy.data.tooltip:find("loaded", 1, true) and not lazy.data.tooltip:find("reload", 1, true), "row tooltip shows loaded")
	check(env.out():find("Lazy: loaded", 1, true), "chat line confirms: " .. env.out())
	check(env.st.notified == "SempreUI_module_Sempre_Lazy", "settings list is told about the change")
	check(lazy.setting.get() == true, "checkbox reads on")
end

-- Switching off disables, keeps running, shows the reload button

do
	local env = boot()
	local items = env.row("Sempre_Items")
	check(env.loaded.Sempre_Items, "module was loaded at login")
	items.setting.set(false)
	check(env.addons.Sempre_Items.enabled == 0 and env.calls[#env.calls] == "disable:Sempre_Items:nil", "switching off disables for all characters")
	check(env.loaded.Sempre_Items, "the module keeps running")
	check(items.data.tooltip:find("after /reload", 1, true), "state word says after /reload")
	check(env.out():find("Items: after /reload", 1, true), "chat line says after /reload")
	local btn = env.reloadButton()
	check(btn.predicate() == true, "reload button appears after the change")
	check(env.reloaded == nil, "never reloads without the click")
	btn.click()
	check(env.reloaded == 1, "the button reloads the game")
	items.setting.set(true)
	check(btn.predicate() == false and not env.calls[#env.calls]:find("^load"), "switching back on hides the button, loaded module not loaded again")
end

-- Switching off a module that was never loaded needs no reload

do
	local env = boot()
	local lazy = env.row("Sempre_Lazy")
	check(lazy.tip:find("off", 1, true) and lazy.tip:find("Not loaded", 1, true), "off module: state off, options hint")
	lazy.setting.set(false)
	check(env.reloadButton().predicate() == false, "off stays off, no reload")
end

-- Without the enable API the switch says so

do
	local env = boot({ noEnable = true })
	env.row("Sempre_Items").setting.set(false)
	check(env.out():find("cannot switch modules", 1, true) and env.addons.Sempre_Items.enabled == 2, "missing Enable/Disable is reported, nothing changes")
end

-- Options: default, storage, message

do
	local env = boot()
	local S = env.S
	check(S:GetOption("Sempre", "login_message") == true, "core registers its login option, default on")
	check(S:GetOption("Sempre_Nope", "x") == nil and S:GetOption("Sempre", "nope") == nil, "unknown option reads nil")
	S:RegisterOptions("Sempre_Items", {
		{ key = "a", default = true, label = { de = "Eins", en = "One" } },
		{ key = "b", default = false, label = { "Zwei", "Two" }, tooltip = { de = "tipp", en = "tip" } },
	})
	check(S:GetOption("Sempre_Items", "a") == true and S:GetOption("Sempre_Items", "b") == false, "GetOption returns the default")
	local global = S.db.global
	check(next(global.options) == nil or global.options.Sempre == nil, "nothing stored for defaults")
	check(S:SetOption("Sempre_Items", "a", false) == true, "SetOption accepts a known option")
	check(S:GetOption("Sempre_Items", "a") == false and global.options.Sempre_Items.a == false, "different value is stored")
	check(same(env.messages, { "Sempre_Items:a:false" }), "OPTION_CHANGED carries module, key and value")
	S:SetOption("Sempre_Items", "a", false)
	check(#env.messages == 1, "setting the same value again sends nothing")
	S:SetOption("Sempre_Items", "a", true)
	check(global.options.Sempre_Items == nil, "value equal to the default is not stored, empty table dropped")
	check(env.messages[2] == "Sempre_Items:a:true", "message for the way back")
	S:SetOption("Sempre_Items", "b", true)
	check(global.options.Sempre_Items.b == true, "non-default for a false default is stored")
	check(S:SetOption("Sempre_Items", "zzz", true) == false and S:SetOption("Sempre_Unknown", "a", true) == false, "unknown option is refused")
	S:RegisterOptions("Sempre_Items", { { key = "c", default = true, label = { de = "C", en = "C" } } })
	check(S:GetOption("Sempre_Items", "a") == nil and S:GetOption("Sempre_Items", "c") == true, "registering again replaces the list")
end

-- Option pages

do
	local env = boot()
	local S = env.S
	check(env.sub("General") and #env.pageBoxes("General") == 1, "core page holds the login option")
	local box = env.pageBoxes("General")[1]
	check(box.setting.name == "Login message in chat" and box.setting.default == true and box.tip:find("version", 1, true), "label, default and tooltip of the option")
	box.setting.set(false)
	check(S:GetOption("Sempre", "login_message") == false, "the checkbox writes the option")
	check(box.setting.get() == false, "the checkbox reads the option")
	check(env.sub("Sempre Ledger") == nil and env.sub("Sempre Items") == nil, "no page for modules without options")
	-- A module registering after login gets its page at once.
	S:RegisterOptions("Sempre_Items", { { key = "t", default = true, label = { de = "T", en = "Tee" } } })
	check(env.sub("Sempre Items") and env.sub("Sempre Items").parent == env.st.addon[1], "late registration adds a subpage under SempreUI")
	check(#env.pageBoxes("Sempre Items") == 1, "one checkbox on it")
	S:RegisterOptions("Sempre_Items", { { key = "t", default = true, label = { de = "T", en = "Tee" } } })
	check(#env.st.subs == 2, "registering again does not add a second page")
end

-- Slash fallback

do
	local env = boot()
	local cmd = env.S.commands
	cmd.modul("")
	local out = env.out()
	check(out:find("Items: loaded", 1, true) and out:find("Lazy: off", 1, true) and out:find("Ledger: loaded", 1, true), "modul alone lists the modules: " .. out)
	check(not out:find("Foreign") and not out:find("Sempre: "), "list has no core and no foreign addon")
	env.printed = {}
	cmd.modul("Lazy an")
	check(env.loaded.Sempre_Lazy and env.addons.Sempre_Lazy.enabled == 2, "modul <name> an switches on and loads")
	cmd.module("LAZY off")
	check(env.addons.Sempre_Lazy.enabled == 0 and env.loaded.Sempre_Lazy, "module <NAME> off is case-insensitive and switches off")
	check(env.reloadButton().predicate() == true, "same state as the checkbox: reload pending")
	cmd.modul("lazy aus")
	cmd.modul("lazy on")
	check(env.addons.Sempre_Lazy.enabled == 2 and env.reloadButton().predicate() == false, "on again")
	cmd.modul("sempre_ledger aus")
	check(env.addons.Sempre_Ledger.enabled == 0, "the folder name works too")
	env.printed = {}
	cmd.modul("ledger")
	check(env.out():find("Ledger: after /reload", 1, true), "name alone shows its state")
	env.printed = {}
	cmd.modul("sempre an")
	check(env.out():find("No module named sempre", 1, true) and env.addons.Sempre.enabled == 2, "the core cannot be switched")
	cmd.modul("foreign off")
	check(env.addons.Sempre_Foreign.enabled == 2, "foreign addons cannot be switched")
	env.printed = {}
	cmd.modul("lazy maybe")
	check(env.out():find("Usage", 1, true), "bad value prints usage")
	check(#env.errors == 0, "no errors")
end

-- Help line

do
	local env = boot()
	env.g.SlashCmdList.SEMPRE("")
	local out = env.out()
	check(out:find("/sempre options", 1, true) and out:find("/sempre module <name> on|off", 1, true), "English help names the new commands")
	local de = boot({ locale = "deDE" })
	de.g.SlashCmdList.SEMPRE("")
	check(de.out():find("/sempre optionen", 1, true) and de.out():find("/sempre modul <Name> an|aus", 1, true), "German help names the new commands")
end

-- Missing Settings API

do
	local env = boot({ noSettings = true })
	check(#env.errors == 0 and #env.printed == 1, "login without Settings API is quiet: " .. env.out())
	env.printed = {}
	env.S.commands.optionen("")
	local out = env.out()
	check(out:find("no settings page", 1, true) and out:find("Items: loaded", 1, true) and out:find("/sempre module <name> on|off", 1, true),
		"optionen falls back to chat with the list and the commands")
	check(#env.opened == 0, "nothing opened")
	env.S.commands.modul("lazy an")
	check(env.loaded.Sempre_Lazy, "slash switching still works")
end

do
	-- The vertical API throws: no canvas either, chat fallback, login survives.
	local env = boot({ broken = true })
	check(#env.errors == 0 and env.out():find("could not be built", 1, true), "failing Settings API is reported once")
	env.printed = {}
	env.S.commands.optionen("")
	check(env.out():find("no settings page", 1, true), "falls back to chat")
end

-- Canvas fallback

do
	local env = boot({ canvas = true })
	check(env.st.canvas == 1 and #env.st.addon == 1 and #env.errors == 0, "canvas page registered once when the vertical layout is missing")
	env.S.commands.optionen("")
	env.S.commands.optionen("")
	check(#env.opened == 2 and env.st.canvas == 1, "opens the canvas category")
	local ok, err = pcall(env.st.addon[1].frame.scripts.OnShow)
	check(ok, "canvas page refreshes on show: " .. tostring(err))
	env.S.commands.modul("items off")
	check(env.addons.Sempre_Items.enabled == 0, "canvas refresh after a switch does not error")
end

-- Opening in combat waits

do
	local env = boot()
	env.combat = true
	env.S.commands.optionen("")
	check(#env.opened == 0 and env.out():find("after combat", 1, true), "in combat: note, nothing opened")
	env.S.commands.options("")
	env.combat = false
	env.fire("PLAYER_REGEN_ENABLED")
	check(#env.opened == 1, "opens once combat ends (and only once)")
	env.fire("PLAYER_REGEN_ENABLED")
	check(#env.opened == 1, "the pending opening is gone afterwards")
	env.combat = true
	env.S.commands.config("")
	env.combat = false
	env.fire("PLAYER_REGEN_ENABLED")
	check(#env.opened == 2, "a later combat waits again")
end

-- First option: login line

do
	local env = boot()
	check(env.out():find("loaded. /sempre for commands.", 1, true), "login line shown by default")
	local hidden = boot({ db = { global = { options = { Sempre = { login_message = false } } } } })
	check(#hidden.printed == 0, "login line hidden when the option is off")
	check(hidden.S.db.global.errors ~= nil and hidden.S.db.version == 1, "stored options do not disturb the defaults")
	local plain = boot({ db = { version = 1, global = { errors = {} }, chars = {}, profiles = {} } })
	check(type(plain.S.db.global.options) == "table" and #plain.printed == 1, "saved data without options gets the table, no version bump")
end

-- First options: Items and Loot tooltips

do
	local env = boots.items({
		slots = { [0] = 1 },
		contents = { [0] = { { itemID = 900, stackCount = 4, hyperlink = "|Hitem:900|h" } } },
	})
	env.tick()
	check(env.S:GetOption("Sempre_Items", "tooltip") == true, "item tooltip option defaults on")
	env.tooltip.lines = {}
	env.postCall(env.tooltip, { id = 900 })
	check(#env.tooltip.lines >= 1, "item tooltip line shown by default")
	env.S:SetOption("Sempre_Items", "tooltip", false)
	env.tooltip.lines = {}
	env.postCall(env.tooltip, { id = 900 })
	check(#env.tooltip.lines == 0, "item tooltip lines hidden when the option is off")
	env.S:SetOption("Sempre_Items", "tooltip", true)
	env.postCall(env.tooltip, { id = 900 })
	check(#env.tooltip.lines >= 1, "item tooltip lines return when switched on")
	local list = env.S:GetOptionList("Sempre_Items")
	check(list and list[1].label.de == "Besitz im Item-Tooltip" and list[1].label.en == "Owners in the item tooltip", "item option labels in both languages")
end

do
	local env = boots.loot({ prices = { [100] = 25 } })
	local guid
	for _ = 1, 4 do guid = env.kill(8, { [100] = 1 }) end
	check(env.S:GetOption("Sempre_Loot", "tooltip") == true and #env.tooltip(guid) == 1, "loot tooltip line shown by default")
	env.S:SetOption("Sempre_Loot", "tooltip", false)
	check(#env.tooltip(guid) == 0, "loot tooltip line hidden when the option is off")
	env.S:SetOption("Sempre_Loot", "tooltip", true)
	check(#env.tooltip(guid) == 1, "loot tooltip line returns when switched on")
	local list = env.S:GetOptionList("Sempre_Loot")
	check(list and list[1].label.de == "Wert pro Kill im Gegner-Tooltip" and list[1].label.en == "Value per kill in the unit tooltip", "loot option labels in both languages")
end

-- Ledger has no options

do
	local ledger = io.open("Sempre_Ledger/Ledger.lua"):read("*a")
	check(not ledger:find("RegisterOptions", 1, true), "Ledger registers no options, so it gets no subpage")
end

end
