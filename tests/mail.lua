-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Tests for Sempre_Mail with a stubbed WoW API. Loaded by tests/run.lua, which
-- passes in its check helpers. Boots the real core, stubs the Sempre_Items
-- interface, then loads the module's file.

return function(check, same)

local T0 = os.time({ year = 2026, month = 10, day = 22, hour = 12, min = 0, sec = 0 })
local DAY = 86400
local TYPE = { MailInfo = 17, Merchant = 5 }
local SECRET = {}

local function newFake(kind)
	local f = { kind = kind, shown = true, enabled = true, scripts = {}, registered = {} }
	return setmetatable(f, { __index = function()
		return function() end
	end })
end

local fakeMethods = {
	Show = function(self) self.shown = true end,
	Hide = function(self) self.shown = false end,
	IsShown = function(self) return self.shown end,
	SetText = function(self, text) self.text = text end,
	GetText = function(self) return self.text end,
	SetTexture = function(self, tex) self.texture = tex end,
	Enable = function(self) self.enabled = true end,
	Disable = function(self) self.enabled = false end,
	IsEnabled = function(self) return self.enabled end,
	GetChecked = function(self) return self.checked end,
	SetFont = function(self, path, size, flags)
		self.font = { path = path, size = size, flags = flags }
		return true
	end,
	SetScript = function(self, kind, fn) self.scripts[kind] = fn end,
	GetHeight = function(self) return self.height or 424 end,
	SetHeight = function(self, h) self.height = h end,
	RegisterEvent = function(self, e)
		if self.unknown and self.unknown[e] then error("unknown event") end
		self.registered[e] = true
	end,
	UnregisterEvent = function(self, e) self.registered[e] = nil end,
}

-- opts: noItems, chars (stub snapshots), options (stored options), noMoney,
-- noItemFn, noMailFrame, inbox, free, unknown
local function boot(opts)
	opts = opts or {}
	local env = { printed = {}, errors = {}, actions = {}, queue = {}, taken = {}, frames = {},
		money = 0, now = T0, free = opts.free or 20, inbox = opts.inbox or {}, chars = opts.chars or {} }
	local g = setmetatable({}, { __index = _G })
	g.table = setmetatable({ wipe = function(t) for k in pairs(t) do t[k] = nil end return t end }, { __index = table })
	g.CreateFrame = function(kind)
		local f = newFake(kind)
		for k, v in pairs(fakeMethods) do f[k] = v end
		f.CreateFontString = function() return g.CreateFrame("FontString") end
		f.CreateTexture = function() return g.CreateFrame("Texture") end
		f.unknown = opts.unknown or false
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
	g.C_EventUtils = { IsEventValid = function(e) return not (opts.unknown and opts.unknown[e]) end }
	g.Enum = { PlayerInteractionType = TYPE }
	g.UIParent = newFake("UIParent")
	if not opts.noMailFrame then g.MailFrame = newFake("MailFrame") end
	g.AUCTION_EXPIRED_MAIL_SUBJECT = "Auction expired: %s"
	g.AUCTION_OUTBID_MAIL_SUBJECT = "Outbid on %s"

	g.C_Container = {
		GetContainerNumFreeSlots = function(bag)
			if bag == 0 then return env.free, 0 end
			return 0, 0
		end,
	}
	g.C_Item = {
		GetItemIconByID = function(id)
			if env.noIcon and env.noIcon[id] then return nil end
			return "icon" .. id
		end,
		RequestLoadItemDataByID = function(id) env.requested = env.requested or {} env.requested[#env.requested + 1] = id end,
	}

	-- Inbox: env.inbox[i] = { sender, subject, money, cod, days, items = { {id, count} }, invoice, canReply }
	g.GetInboxNumItems = function() return #env.inbox, env.serverTotal or #env.inbox end
	g.GetInboxHeaderInfo = function(i)
		local m = env.inbox[i]
		local canReply = true
		if m.canReply ~= nil then canReply = m.canReply end
		return nil, nil, m.sender or "Sender" .. i, m.subject or "Subject", m.money or 0, m.cod or 0,
			m.days or 10, #(m.items or {}), nil, nil, nil, canReply
	end
	g.GetInboxItem = function(i, a)
		local it = env.inbox[i].items and env.inbox[i].items[a]
		if it then
			local tex = "tex" .. it[1]
			if env.noIcon and env.noIcon[it[1]] then tex = nil end
			return "Item" .. it[1], it[1], tex, it[2]
		end
	end
	g.GetInboxInvoiceInfo = function(i) return env.inbox[i].invoice end
	local function empty(m) return (m.money or 0) == 0 and #(m.items or {}) == 0 and (m.cod or 0) == 0 end
	if not opts.noMoney then
		g.TakeInboxMoney = function(i)
			env.actions[#env.actions + 1] = "money:" .. i
			env.queue[#env.queue + 1] = function()
				local m = env.inbox[i]
				env.money = env.money + m.money
				m.money = 0
				if empty(m) then table.remove(env.inbox, i) end
				env.fire("PLAYER_MONEY")
				env.fire("MAIL_INBOX_UPDATE")
			end
		end
	end
	if not opts.noItemFn then
		g.TakeInboxItem = function(i, a)
			env.actions[#env.actions + 1] = "item:" .. i .. ":" .. a
			env.queue[#env.queue + 1] = function()
				local m = env.inbox[i]
				table.remove(m.items, a)
				env.free = env.free - 1
				if empty(m) then table.remove(env.inbox, i) end
				env.fire("BAG_UPDATE_DELAYED")
				env.fire("MAIL_INBOX_UPDATE")
			end
		end
	end

	-- Stub of the Sempre_Items interface: chars[key] = { snap, total, shown, mails }
	local items = {}
	function items.GetChars()
		local keys = {}
		for key in pairs(env.chars) do keys[#keys + 1] = key end
		table.sort(keys)
		local i = 0
		return function()
			i = i + 1
			return keys[i]
		end
	end
	function items.GetMail(key)
		local c = env.chars[key]
		if not (c and c.snap) then return {}, nil, 0, 0 end
		return c.mails, c.snap, c.total or #c.mails, c.shown or #c.mails
	end
	function items.GetName() end

	local function run(path, ...)
		local chunk = assert(loadfile(path))
		setfenv(chunk, g)
		return chunk(...)
	end
	env.g = g
	run("Sempre/Core.lua", "Sempre")
	g._G = g
	run("Sempre/Fonts.lua", "Sempre")
	env.S = g.SempreUI
	env.core = env.frames[1]
	function env.fire(event, ...) env.core.scripts.OnEvent(env.core, event, ...) end
	env.fire("ADDON_LOADED", "Sempre")
	if opts.options then env.S.db.global.options.Sempre_Mail = opts.options end
	env.fire("PLAYER_LOGIN")
	if not opts.noItems then env.S.Items = items end
	env.sent = {}
	env.S:Listen("MAIL_TAKEN", function(_, id, count, copper)
		env.sent[#env.sent + 1] = tostring(id) .. "," .. count .. "," .. copper
	end)
	env.printed = {}
	run("Sempre_Mail/Mail.lua", "Sempre_Mail")
	env.fire("ADDON_LOADED", "Sempre_Mail")
	env.Mail = env.S.Mail
	env.loadPrinted = env.printed
	env.printed = {}

	function env.open() env.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", TYPE.MailInfo) end
	function env.close() env.fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", TYPE.MailInfo) end
	-- Applies the oldest queued server answer.
	function env.process()
		local fn = table.remove(env.queue, 1)
		if fn then fn() end
		return fn ~= nil
	end
	function env.tick(dt) env.Mail.ticker.scripts.OnUpdate(env.Mail.ticker, dt or 0.1) end
	function env.out() return table.concat(env.printed, "\n") end
	function env.rows()
		local ui = env.Mail.ui
		local list = {}
		for _, row in ipairs(ui.rows) do
			if row.shown and row.entry then list[#list + 1] = row end
		end
		return list
	end
	function env.clickAll() env.Mail.ui.button.scripts.OnClick(env.Mail.ui.button) end
	return env
end

local function kinds(env)
	local out = {}
	for _, e in ipairs(env.Mail.GetEntries()) do out[#out + 1] = e.marker end
	return table.concat(out, ",")
end

-- Loading and the missing Sempre_Items

do
	local env = boot()
	check(#env.errors == 0, "module loads without handler errors: " .. tostring(env.errors[1]))
	check(#env.loadPrinted == 0, "no output at login without expiring mail: " .. table.concat(env.loadPrinted, "|") .. tostring(env.errors[1]))
	local list = env.S:GetOptionList("Sempre_Mail")
	check(list and #list == 2 and env.S:GetOption("Sempre_Mail", "list") == true
		and env.S:GetOption("Sempre_Mail", "warning") == true, "two options, both on by default")
	check(env.S.commands.post and env.S.commands.post == env.S.commands.mail, "/sempre post with the alias mail")
	check(env.Mail.ui == nil, "the panel is not built before the mailbox opens")
end

do
	local env = boot({ noItems = true })
	check(#env.loadPrinted == 1 and env.loadPrinted[1]:find("Sempre_Items is missing", 1, true), "missing Sempre_Items: one line")
	check(env.S:GetOptionList("Sempre_Mail") == nil, "missing Sempre_Items: no options registered")
	env.open()
	check(env.Mail.ui == nil and #env.errors == 0, "missing Sempre_Items: the module stays off")
	env.S.commands.post()
	check(env.out():find("Sempre_Items is missing", 1, true), "missing Sempre_Items: command says so")
end

-- The list

local function listInbox()
	return {
		{ sender = "Bob", money = 123456, days = 10 },
		{ sender = "Auction House", subject = "Sale", money = 5000, days = 29, invoice = "seller" },
		{ sender = "Auction House", subject = "Auction expired: Sword", days = 20, items = { { 7, 1 } } },
		{ sender = "Blizzard", days = 2.5, canReply = false, items = { { 100, 20 }, { 101, 1 }, { 102, 3 } } },
		{ sender = "Trader", days = 0.5, cod = 5000, items = { { 200, 1 } } },
		{ sender = "Auction House", subject = "You won", days = 15, invoice = "buyer", items = { { 8, 2 } } },
	}
end

do
	local env = boot({ inbox = listInbox() })
	env.open()
	local ui = env.Mail.ui
	check(ui and ui.panel.shown, "the panel shows when the mailbox opens")
	check(kinds(env) == "cod,system,player,auction,auction,sale", "sorted by days left with the right markers: " .. kinds(env))
	local rows = env.rows()
	check(#rows == 6, "one row per mail")
	check(rows[1].marker.text:find("COD", 1, true) and rows[1].money.text:find("COD 50s 0c", 1, true)
		and rows[1].money.text:find("ff4040", 1, true), "COD amount in red with COD")
	check(rows[1].days.text:find("12h", 1, true) and rows[1].days.text:find("ff4040", 1, true), "hours under one day, red")
	check(rows[2].days.text:find("2d", 1, true) and rows[2].days.text:find("ff4040", 1, true), "whole days, red under 3 days")
	check(rows[2].count.text == "x20 +2" and rows[2].icon.texture == "tex100", "first item icon and count, +N for more items: " .. tostring(rows[2].count.text))
	check(rows[3].money.text == "|cffc8794a12g 34s 56c|r", "money in copper colour: " .. tostring(rows[3].money.text))
	check(rows[3].days.text == "10d" and not rows[3].days.text:find("ff4040", 1, true), "days not red from 3 days on")
	check(rows[3].count.text == "" and rows[3].entry.sender == "Bob" and rows[3].sender.text == "Bob", "sender shown")
	check(rows[6].marker.text:find("AH+", 1, true), "auction sale marker")
	check(rows[4].marker.text:find("AH", 1, true) and not rows[4].marker.text:find("AH+", 1, true), "other auction mail marker")
	check(ui.total.text:find("12g 84s 56c", 1, true)
		and ui.total.text:find("28 items", 1, true) and ui.total.text:find("6 / 6 mails", 1, true), "total row: " .. tostring(ui.total.text))
	check(ui.more.text == "", "nothing waiting")

	env.serverTotal = 9
	env.fire("MAIL_INBOX_UPDATE")
	env.tick()
	check(ui.more.text:find("3 more mails are waiting", 1, true) and ui.total.text:find("6 / 9 mails", 1, true), "more mails waiting on the server: " .. tostring(ui.more.text))

	env.close()
	check(not ui.panel.shown, "the panel hides with the mailbox")
	env.fire("MAIL_SHOW")
	check(ui.panel.shown, "classic MAIL_SHOW opens the panel as well")
	env.fire("MAIL_CLOSED")
	check(not ui.panel.shown, "classic MAIL_CLOSED hides it")
end

-- Secret sender names and uncached icons

do
	local env = boot({ inbox = { { sender = SECRET, days = 4, money = 10, items = { { 55, 1 } } } } })
	env.noIcon = { [55] = true }
	env.open()
	local row = env.rows()[1]
	check(#env.errors == 0 and row and row.sender.text == SECRET, "a secret sender is shown without error")
	check(env.requested and env.requested[1] == 55, "an uncached item is requested")
	env.noIcon = nil
	env.fire("ITEM_DATA_LOAD_RESULT", 55, true)
	env.tick()
	check(env.rows()[1].icon.texture == "icon55" or env.rows()[1].icon.texture == "tex55", "the icon is filled in when the item arrives")
end

-- Options

do
	local env = boot({ inbox = listInbox(), options = { list = false } })
	env.open()
	check(env.Mail.ui == nil, "option off: no panel at the mailbox")
	env.S:SetOption("Sempre_Mail", "list", true)
	check(env.Mail.ui and env.Mail.ui.panel.shown, "option switched on while open: the panel appears")
	env.S:SetOption("Sempre_Mail", "list", false)
	check(not env.Mail.ui.panel.shown, "option switched off while open: the panel hides")
end

do
	local env = boot({ noMailFrame = true, inbox = listInbox() })
	env.open()
	check(env.Mail.ui == nil and #env.errors == 0, "without a mail frame the panel is not built")
end

-- Taking one mail

do
	local env = boot({ inbox = { { money = 100, days = 5, items = { { 11, 2 }, { 12, 1 } } } } })
	env.open()
	env.rows()[1].scripts.OnClick(env.rows()[1])
	check(same(env.actions, { "money:1" }), "click: money first, one action")
	env.process()
	check(same(env.actions, { "money:1", "item:1:1" }), "click: then the first item after the inbox updated")
	env.process()
	check(same(env.actions, { "money:1", "item:1:1", "item:1:1" }), "click: then the next item")
	env.process()
	check(#env.actions == 3 and #env.inbox == 0, "click: stops after the mail is empty")
	check(same(env.sent, { "nil,0,100", "11,2,0", "12,1,0" }), "MAIL_TAKEN for money and every item: " .. table.concat(env.sent, " "))
	check(env.money == 100 and env.Mail.ui.button.text == "Take all", "click: button back to Take all")
	check(env.out() == "", "single take prints no summary")
end

do
	local env = boot({ inbox = { { days = 5, cod = 300, items = { { 11, 1 } } } } })
	env.open()
	env.rows()[1].scripts.OnClick(env.rows()[1])
	check(#env.actions == 0 and env.out():find("cash on delivery", 1, true), "click on a COD mail takes nothing")
end

-- Take all

do
	local env = boot({ inbox = {
		{ money = 50, days = 1, items = { { 21, 4 } } },
		{ days = 0.5, cod = 700, items = { { 22, 1 } } },
		{ days = 5, items = { { 23, 1 } } },
		{ days = 6, cod = 100, items = { { 24, 1 } } },
	} })
	env.open()
	env.clickAll()
	check(same(env.actions, { "money:1" }) , "take all: first action is money of the soonest payable mail: " .. table.concat(env.actions, ","))
	check(env.Mail.ui.button.text == "Stop", "take all: button shows Stop while running")
	env.fire("MAIL_INBOX_UPDATE")
	check(#env.actions == 1, "take all: an unchanged inbox update does not start the next action")
	env.process()
	check(#env.actions == 2 and env.actions[2] == "item:1:1", "take all: next action after the update, money before items")
	env.process()
	check(#env.actions == 3, "take all: one action per update")
	env.process()
	check(#env.actions == 3 and env.Mail.ui.button.text == "Take all", "take all: finished")
	local out = env.out()
	check(out:find("50c", 1, true) and out:find("5 items", 1, true) and out:find("2 mails skipped", 1, true), "take all: summary line: " .. out)
	check(#env.inbox == 2 and env.inbox[1].cod == 700, "take all: COD mails stay")
	check(same(env.sent, { "nil,0,50", "21,4,0", "23,1,0" }), "take all: MAIL_TAKEN for each take: " .. table.concat(env.sent, " "))
end

do
	-- Full bags: stops before an item that would not fit.
	local env = boot({ free = 1, inbox = {
		{ days = 1, items = { { 31, 1 } } },
		{ days = 2, items = { { 32, 1 } } },
	} })
	env.open()
	env.clickAll()
	env.process()
	check(#env.actions == 1 and env.free == 0, "full bags: one item taken")
	check(env.out():find("bags are full", 1, true) and env.out():find("1 items", 1, true), "full bags: stops and says so")
	check(env.Mail.ui.button.text == "Take all", "full bags: the run ended")
end

do
	-- Stop button and closing the mailbox.
	local env = boot({ inbox = { { days = 1, money = 10 }, { days = 2, money = 20 } } })
	env.open()
	env.clickAll()
	env.clickAll()
	check(env.out():find("stopped", 1, true) and env.Mail.ui.button.text == "Take all", "the Stop button ends the run")
	env.process()
	check(#env.actions == 1, "after Stop nothing more is taken")

	env = boot({ inbox = { { days = 1, money = 10 }, { days = 2, money = 20 } } })
	env.open()
	env.clickAll()
	env.close()
	check(env.out():find("mailbox closed", 1, true) and env.out():find("Mail taken", 1, true), "closing the mailbox stops the run and prints the summary")
	env.process()
	check(#env.actions == 1, "after closing nothing more is taken")
end

do
	-- No answer from the server: wait, retry, give up.
	local env = boot({ inbox = { { days = 1, money = 10 } } })
	env.open()
	env.clickAll()
	env.tick(1)
	check(#env.actions == 1, "no reaction before the timeout")
	env.tick(3)
	check(#env.actions == 2, "after the timeout the action is tried again")
	env.tick(3.5)
	env.tick(3.5)
	check(#env.actions == 3 and env.out():find("no answer", 1, true) and env.Mail.ui.button.text == "Take all", "gives up after repeated timeouts")
end

-- Gold only

do
	local env = boot({ inbox = {
		{ days = 1, items = { { 41, 1 } } },
		{ days = 2, money = 30, items = { { 42, 1 } } },
	} })
	env.open()
	local ui = env.Mail.ui
	ui.check.checked = true
	ui.check.scripts.OnClick(ui.check)
	env.clickAll()
	env.process()
	check(same(env.actions, { "money:2" }), "gold only: only money is taken")
	check(#env.inbox == 2 and #env.inbox[2].items == 1 and env.out():find("0 items", 1, true), "gold only: items stay in the mails")
end

-- Missing take functions

do
	local env = boot({ noMoney = true, inbox = { { days = 1, money = 10 } } })
	env.open()
	local ui = env.Mail.ui
	check(not ui.button.enabled and ui.reason:find("take money", 1, true), "no money function: button disabled with a reason")
	env.clickAll()
	check(#env.actions == 0, "no money function: nothing is taken")

	env = boot({ noItemFn = true, inbox = { { days = 1, money = 10, items = { { 1, 1 } } } } })
	env.open()
	ui = env.Mail.ui
	check(not ui.button.enabled and ui.reason:find("attachments", 1, true), "no item function: button disabled")
	ui.check.checked = true
	ui.check.scripts.OnClick(ui.check)
	check(ui.button.enabled, "no item function: gold only still works")
end

-- Expiry warning

local function snapshot(ageDays, mails, extra)
	local c = { snap = T0 - ageDays * DAY, mails = mails }
	for k, v in pairs(extra or {}) do c[k] = v end
	return c
end

do
	local env = boot({ chars = {
		["Tester-Realm"] = snapshot(0, { { days = 20, money = 0, items = {} } }),
		["Bankie-Realm"] = snapshot(1, {
			{ days = 3.5, money = 0, items = {} }, { days = 3.5, money = 0, items = {} },
			{ days = 3.9, money = 0, items = {} }, { days = 4, money = 0, items = {} },
			{ days = 30, money = 0, items = {} }, { days = 1, money = 0, items = {} },
		}),
		["Other-Elsewhere"] = snapshot(0, { { days = 2.2, money = 0, items = {} } }),
		["Alt-Realm"] = snapshot(0, { { days = 12, money = 0, items = {} } }),
		["Fresh-Realm"] = {},
	} })
	local out = table.concat(env.loadPrinted, "\n")
	check(out:find("Bankie: 4 mails, first expires in 2 days", 1, true), "login warning with elapsed days: " .. out)
	check(out:find("Other-Elsewhere: 1 mail, first expires in 2 days", 1, true), "other realm keeps the realm in the name")
	check(not out:find("Alt", 1, true) and not out:find("Tester", 1, true) and not out:find("Fresh", 1, true), "no warning for safe characters or without snapshot")
	check(#env.loadPrinted == 2, "one line per character")
	env.S:Send("ITEMS_CHANGED", "Tester-Realm", "mail")
	check(#env.printed == 0, "once per character per login")

	-- A mail snapshot of another character running out later, current one open.
	env.chars["Tester-Realm"] = snapshot(0, { { days = 2, money = 0, items = {} } })
	env.chars["Alt-Realm"] = snapshot(0, { { days = 5, money = 0, items = {} }, { days = 0.5, money = 0, items = {} } })
	env.open()
	env.S:Send("ITEMS_CHANGED", "Tester-Realm", "mail")
	local after = env.out()
	check(after:find("Alt: 1 mail, first expires in 12 h", 1, true), "warning after a snapshot, hours under one day: " .. after)
	check(not after:find("Tester", 1, true), "not for the character whose mailbox is open")
	env.S:Send("ITEMS_CHANGED", "Tester-Realm", "mail")
	check(#env.printed == 1, "still once per character")
end

do
	local env = boot({ options = { warning = false }, chars = {
		["Bankie-Realm"] = snapshot(0, { { days = 1, money = 0, items = {} } }),
	} })
	check(#env.loadPrinted == 0, "warning option off: silent at login")
	env.S:Send("ITEMS_CHANGED", "Tester-Realm", "mail")
	check(#env.printed == 0, "warning option off: silent after a snapshot")
	env.S:SetOption("Sempre_Mail", "warning", true)
	check(env.out():find("Bankie: 1 mail, first expires in 1 day", 1, true), "switching the warning on checks at once: " .. env.out())
end

-- /sempre post

do
	local env = boot({ chars = {
		["Tester-Realm"] = snapshot(0, { { days = 20, money = 100, items = { 5, 3 } } }),
		["Bankie-Realm"] = snapshot(3, {
			{ days = 8, money = 20000, items = { 6, 2, 7, 5 } },
			{ days = 30, money = 150, items = {} },
		}, { total = 5, shown = 2 }),
		["Fresh-Realm"] = {},
	} })
	env.printed = {}
	env.S.commands.post("")
	local out = env.out()
	check(out:find("Mail per character:", 1, true), "post: header")
	check(out:find("Bankie: 2 mails (+3 not visible), 2g 1s 50c, 7 items, first expires in 5 days, as of 3 d ago", 1, true), "post: character line: " .. out)
	check(out:find("Tester: 1 mail, 1s 0c, 3 items, first expires in 20 days, as of just now", 1, true), "post: current character line")
	check(out:find("Fresh: never opened", 1, true), "post: never opened")
	check(out:find("Total: 3 mails, 2g 2s 50c, 10 items", 1, true), "post: total line")
	check(#env.errors == 0, "post: no errors")
end

-- Fonts: title, text and mono roles

do
	local env = boot({ inbox = listInbox() })
	env.open()
	local F = env.S.Fonts
	local rows = env.rows()
	check(rows[1].count.font.path == F.mono and rows[1].money.font.path == F.mono and rows[1].days.font.path == F.mono,
		"mail rows: count, money and days use the mono role")
	check(rows[1].sender.font.path == F.text and env.Mail.ui.total.font.path == F.text, "mail rows and total line use the text role")
	local titles = 0
	for _, f in ipairs(env.frames) do
		if type(f.font) == "table" and f.font.path == F.title then titles = titles + 1 end
	end
	check(titles == 1, "mail panel has one title in the title role")
	env.S:SetOption("Sempre", "fonts", false)
	check(rows[1].money.font.path == "Fonts\\FRIZQT__.TTF" and rows[1].money.font.size == 11, "switching the option off puts the game font on open panels, same size")
end

end
