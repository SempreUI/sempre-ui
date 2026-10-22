-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Tests for Sempre_Ledger part 2 (auction house and purchases) with the stubbed
-- API of tests/ledger.lua, whose boot function is passed in.

return function(check, boot)

local T0 = os.time({ year = 2026, month = 10, day = 21, hour = 12, min = 0, sec = 0 })
local DAY = 86400
local function key(offset) return os.date("%Y-%m-%d", T0 - offset * DAY) end

-- Migration

do
	local old = { version = 1, chars = { ["Tester-Realm"] = { days = {
		[key(0)] = { income = { vendor = 50 }, expense = {}, vendorItems = { [100] = { count = 2, copper = 50 } } },
	} } } }
	local env = boot({ db = old })
	check(env.db.version == 2, "version 1 data is migrated to version 2")
	check(env.today().income.vendor == 50 and env.today().vendorItems[100].count == 2, "migrated days keep their data")
	check(env.today().purchases == nil and env.today().auctionItems == nil, "new tables are not created up front")
	env.show("Merchant")
	env.merchant[1] = { "|Hitem:100:|h", 1 }
	env.g.BuyMerchantItem(1, 3)
	env.pay(-90)
	check(env.today().purchases[100].count == 3 and #env.errors == 0, "new tables appear on demand in an old day")
	local fresh = boot({ db = { version = 2, chars = {} } })
	check(fresh.db.version == 2, "current data is left alone")
end

-- Vendor purchases

do
	local env = boot()
	env.merchant[1] = { "|cffffffff|Hitem:100::::::::70|h[Item]|h|r", 5 }
	env.g.BuyMerchantItem(1, 2)
	env.pay(-40)
	check(env.today() and env.today().purchases == nil, "no merchant window, no purchase")
	env.show("Merchant")
	env.g.BuyMerchantItem(1, 2)
	env.pay(-40)
	local p = env.today().purchases[100]
	check(p and p.count == 2 and p.copper == 40 and p.source == "vendor", "purchase: item, count, copper, source")
	check(env.today().expense.vendor == 40, "the money is still booked as vendor expense")
	env.g.BuyMerchantItem(1)
	env.pay(-25)
	check(p.count == 7 and p.copper == 65, "no quantity buys the stack the vendor sells")
	env.g.BuyMerchantItem(1, 1)
	env.clock = env.clock + 30
	env.pay(-9)
	check(p.count == 7 and env.today().expense.vendor == 74, "a purchase marker expires")
	env.g.RepairAllItems()
	env.g.BuyMerchantItem(1, 1)
	env.pay(-300)
	check(p.count == 7 and env.today().expense.repair == 300, "a repair change is not taken for the purchase")
	env.pay(-12)
	check(p.count == 8 and p.copper == 77, "the purchase waits for its own change")
	env.buyback[1] = { "|Hitem:100:|h", 1 }
	env.g.BuybackItem(1)
	env.pay(-25)
	check(p.count == 8, "buyback is not a purchase")
	check(env.changes[#env.changes] == "Tester-Realm:vendor", "bookings are still announced")
end

do
	local env = boot()
	local seen = {}
	env.S:Listen("LEDGER_ITEM_CHANGED", function(_, charKey, id) seen[#seen + 1] = charKey .. ":" .. id end)
	env.show("Merchant")
	env.merchant[1] = { "|Hitem:100:|h", 1 }
	env.g.BuyMerchantItem(1, 1)
	env.pay(-10)
	env.bag["0:1"] = { itemID = 101, stackCount = 1 }
	env.g.C_Container.UseContainerItem(0, 1)
	check(seen[1] == "Tester-Realm:100" and seen[2] == "Tester-Realm:101", "item bookings send LEDGER_ITEM_CHANGED")
end

-- Item interface and profit list

local function profitEnv()
	local env = boot()
	local days = env.rec.days
	days[key(0)] = {
		income = {}, expense = {},
		vendorItems = { [100] = { count = 4, copper = 1000 }, [102] = { count = 1, copper = 100 } },
		purchases = { [100] = { count = 4, copper = 400, source = "vendor" }, [103] = { count = 1, copper = 5000, source = "auction" } },
		auctionItems = { [101] = { count = 2, gross = 10000, cut = 500, deposit = 200, net = 9700 }, Mystery = { count = 1, gross = 700, cut = 35, deposit = 0, net = 665 } },
		deposits = { [101] = { count = 2, copper = 200 } },
	}
	days[key(10)] = {
		income = {}, expense = {},
		vendorItems = { [100] = { count = 1, copper = 250 } },
		auctionItems = { [100] = { count = 1, gross = 3000, cut = 150, deposit = 50, net = 2900 } },
	}
	days[key(40)] = { income = {}, expense = {}, vendorItems = { [104] = { count = 9, copper = 99999999 } } }
	return env
end

do
	local env = profitEnv()
	local it = env.Ledger.GetItem("Tester-Realm", 100, 30)
	check(it.vendor == 1250 and it.vendorCount == 5 and it.auction == 2850 and it.auctionCount == 1
		and it.purchases == 400 and it.purchaseCount == 4, "GetItem sums vendor, auction net and purchases over the range")
	local one = env.Ledger.GetItem("Tester-Realm", 100, 1)
	check(one.vendor == 1000 and one.auction == 0, "GetItem honours the day range")
	check(env.Ledger.GetItem("Tester-Realm", 101, 30).deposits == 200, "deposits are reported")
	check(env.Ledger.GetItem("Nobody-Realm", 100, 30).vendor == 0, "unknown character is empty")
	env.db.chars["Alt-Realm"] = { days = { [key(1)] = { income = {}, expense = {}, vendorItems = { [100] = { count = 2, copper = 600 } } } } }
	local all = env.Ledger.GetItemAll(100, 30)
	check(all.vendor == 1850 and all.vendorCount == 7 and all.purchases == 400, "GetItemAll sums over all characters")

	env.S.commands.gold("items")
	local out = env.out()
	local order = {}
	for line in out:gmatch("[^\n]+") do order[#order + 1] = line end
	check(order[1]:find("Top 10 items of the last 30 days by net result"), "profit list header")
	-- results: 101 = 9500, 100 = 1250 + 2850 - 400 = 3700, Mystery = 665, 102 = 100, 103 = -5000
	check(#order == 6, "five items listed: " .. #order)
	check(order[2]:find("Item101 x2") and order[2]:find("%+0g 95s 0c"), "best item first: " .. tostring(order[2]))
	check(order[3]:find("Item100 x6") and order[3]:find("%+0g 37s 0c"), "vendor plus auction minus purchases: " .. tostring(order[3]))
	check(order[3]:find("vendor %+0g 12s 50c") and order[3]:find("auction %+0g 28s 50c") and order[3]:find("bought %-0g 4s 0c"), "each part is listed: " .. tostring(order[3]))
	check(order[4]:find("Mystery x1"), "an item stored by name is listed by name")
	check(order[6] and order[6]:find("item:103") and order[6]:find("%-0g 50s 0c"), "a loss sorts last and is negative: " .. tostring(order[6]))
	check(not out:find("Item104"), "bookings older than 30 days are left out")

	env.printed = {}
	env.S.commands.gold("items ah")
	order = {}
	for line in env.out():gmatch("[^\n]+") do order[#order + 1] = line end
	check(order[1]:find("auction house sales"), "ah header")
	check(#order == 4, "ah lists only items with auction sales: " .. #order)
	check(order[2]:find("Item101") and order[3]:find("Item100 x1") and order[3]:find("%+0g 28s 50c %(") == nil, "ah ranks by auction net minus purchases")
	check(not env.out():find("vendor"), "ah leaves out the vendor part")
	env.printed = {}
	env.S.commands.gold("items AH")
	check(#env.printed == 4, "ah is case-insensitive")
end

do
	local env = boot()
	env.S.commands.gold("items ah")
	check(env.printed[#env.printed]:find("No auction house sales recorded"), "ah list without sales")
end

-- Auction mail

-- Mail with a sale invoice: type, item, buyer, bid, buyout, deposit, cut, delay, 0, 0, count.
local function saleMail(name, gross, cut, deposit, count)
	return {
		sender = "Auction House", subject = "Auction successful: " .. name, money = gross - cut + deposit,
		invoice = { "seller", name, "BuyerSecretName", gross, gross, deposit, cut, 0, 0, 0, count },
	}
end

-- Walks a deep copy-free search for a string anywhere in a table.
local function contains(t, needle, seen)
	seen = seen or {}
	if seen[t] then return false end
	seen[t] = true
	for k, v in pairs(t) do
		if k == needle or v == needle then return true end
		if type(v) == "string" and v:find(needle, 1, true) then return true end
		if type(k) == "string" and k:find(needle, 1, true) then return true end
		if type(v) == "table" and contains(v, needle, seen) then return true end
	end
	return false
end

do
	local env = boot()
	env.nameLinks.Item101 = 101
	env.inbox[1] = saleMail("Item101", 10000, 500, 200, 2)
	env.show("MailInfo")
	-- The mail is gone from the inbox once the money is taken; the invoice was read before.
	env.inbox[1] = { sender = "Auction House", subject = "Auction successful: Item101", money = 0 }
	env.g.TakeInboxMoney(1)
	env.pay(9700)
	local day = env.today()
	check(day.income.auction == 9700 and not day.income.mail, "sale money is booked as auction, not mail")
	local e = day.auctionItems and day.auctionItems[101]
	check(e and e.count == 2 and e.gross == 10000 and e.cut == 500 and e.deposit == 200 and e.net == 9700,
		"sale: count, gross, cut, deposit and net per item")
	check(env.changes[#env.changes] == "Tester-Realm:auction", "LEDGER_CHANGED says auction")

	-- A second sale of the same item adds up; the mailbox stays open.
	env.inbox[1] = saleMail("Item101", 3000, 150, 50, 1)
	env.fire("MAIL_INBOX_UPDATE")
	local mail = env.inbox[1]
	env.g.TakeInboxMoney(1)
	env.pay(mail.money)
	check(e.count == 3 and e.gross == 13000 and e.cut == 650 and e.net == 12600, "sales of one item add up")
	check(env.Ledger.GetItem("Tester-Realm", 101, 1).auction == 12350, "interface: auction net is gross minus cut")
	check(not contains(env.db, "BuyerSecretName"), "the buyer name is stored nowhere")
	check(env.Ledger.GetRange("Tester-Realm", 1).income.auction == 12600, "the booking counts as income")

	-- A plain mail from a stranger is still mail.
	env.inbox[1] = { sender = "Stranger", money = 400 }
	env.fire("MAIL_INBOX_UPDATE")
	env.g.TakeInboxMoney(1)
	env.pay(400)
	check(day.income.mail == 400, "plain mail money stays mail")
	check(#env.errors == 0, "no handler errors")
	check(mail ~= nil, "fixture used")
end

do
	-- Item resolved through the other ways.
	local env = boot()
	env.instant.Instant = 300
	env.inbox[1] = saleMail("Instant", 1000, 50, 10, 1)
	env.show("MailInfo")
	env.g.TakeInboxMoney(1)
	env.pay(960)
	check(env.today().auctionItems[300] and env.today().auctionItems[300].gross == 1000, "name resolved by GetItemInfoInstant")

	-- The player's own mail through the Items interface.
	local env2 = boot()
	env2.S.Items = {
		GetMail = function() return { { items = { 555, 1 } } }, 0, 1, 1 end,
		GetName = function(id) return id == 555 and "FromMail" or nil end,
	}
	env2.inbox[1] = saleMail("FromMail", 1000, 50, 0, 1)
	env2.show("MailInfo")
	env2.g.TakeInboxMoney(1)
	env2.pay(950)
	check(env2.today().auctionItems[555], "name resolved through SempreUI.Items mail items")
end

do
	-- Unresolved name is stored under the name.
	local env = boot()
	env.inbox[1] = saleMail("Unknown Thing", 800, 40, 0, 1)
	env.show("MailInfo")
	env.g.TakeInboxMoney(1)
	env.pay(760)
	local e = env.today().auctionItems["Unknown Thing"]
	check(e and e.count == 1 and e.gross == 800 and e.net == 760, "unresolved item is stored by name")
	check(env.today().income.auction == 760, "and the money is auction income")
end

do
	-- Other auction mail is auction money, never a sale.
	local env = boot()
	env.inbox[1] = { sender = "Auction House", subject = "Outbid on Thing", money = 300 }
	env.inbox[2] = { sender = "Auction House", subject = "Auction cancelled: Thing", money = 40 }
	env.inbox[3] = { sender = "Auction House", subject = "Auction expired: Thing", money = 5 }
	env.inbox[4] = { sender = "Auction House", subject = "Auction won: Thing", money = 0, invoice = { "buyer", "Thing", "SellerX", 100, 100, 0, 0 } }
	env.inbox[5] = { sender = "Auction House", subject = "Something", money = 70, invoice = { "buyer", "Thing", "SellerX", 100, 100, 0, 0 } }
	env.show("MailInfo")
	for i = 1, 5 do
		env.g.TakeInboxMoney(i)
		env.pay(env.inbox[i].money)
	end
	check(env.today().income.auction == 415 and not env.today().income.mail, "outbid, cancelled, expired and buyer invoices are auction money")
	check(env.today().auctionItems == nil, "none of them is a sale")
	check(env.Ledger.GetItem("Tester-Realm", 100, 1).auction == 0, "no sale in the item sums")
end

do
	-- Malformed invoices fall back to a plain auction booking.
	local bad = {
		{ "seller" },
		{ "seller", "Item101", "B", "x", 10, 0, 1 },
		{ "seller", "", "B", 1000, 1000, 0, 50 },
		{ "seller", "Item101", "B", 1000, 1000, 0, 50, 0, 0, 0, "n" },
		{ "seller", "Item101", "B", -5, 0, 0, 0 },
		{ "seller", 42, "B", 1000, 1000, 0, 50 },
		{ "seller", "Item101", "B", 1000, 1000, 0, 60 }, -- money does not fit
	}
	for i, inv in ipairs(bad) do
		local env = boot()
		env.nameLinks.Item101 = 101
		env.inbox[1] = { sender = "Auction House", subject = "Auction successful: Item101", money = 950, invoice = inv }
		env.show("MailInfo")
		env.g.TakeInboxMoney(1)
		env.pay(950)
		local ok = env.today().income.auction == 950 and env.today().auctionItems == nil and #env.errors == 0
		if i == 4 then ok = env.today().income.auction == 950 and #env.errors == 0 end
		check(ok, "malformed invoice " .. i .. " is booked as plain auction money")
	end
	-- A count that is no number falls back to one only when everything else fits.
	local env = boot()
	env.inbox[1] = { sender = "A", subject = "x", money = 950, invoice = { "seller", "Z", "B", 1000, 1000, 0, 50, 0, 0, 0, "n" } }
	env.show("MailInfo")
	env.g.TakeInboxMoney(1)
	env.pay(950)
	check(env.today().auctionItems.Z.count == 1, "a missing count is one")

	-- No invoice function at all: the subject still makes it auction money.
	local plain = boot({ noInvoice = true })
	plain.inbox[1] = { sender = "A", subject = "Auction successful: Item101", money = 500 }
	plain.show("MailInfo")
	plain.g.TakeInboxMoney(1)
	plain.pay(500)
	check(plain.today().income.auction == 500 and plain.today().auctionItems == nil, "without invoices a sold-subject mail is plain auction money")
end

-- Deposits

do
	local env = boot()
	env.g.C_AuctionHouse.PostItem({ itemID = 101 }, 2, 5, 100, 200)
	env.pay(-30)
	check(env.today().expense.other == 30 and env.today().deposits == nil, "posting without the auction house open books nothing special")
	env.show("Auctioneer")
	env.g.C_AuctionHouse.PostItem({ itemID = 101 }, 2, 5, 100, 200)
	env.pay(-30)
	check(env.today().expense.auction == 30 and env.today().sub.deposit == 30, "deposit: auction expense with sub-kind deposit")
	local d = env.today().deposits[101]
	check(d and d.count == 5 and d.copper == 30, "deposit per posted item")
	env.g.C_AuctionHouse.PostCommodity({ itemID = 101 }, 2, 10, 55)
	env.pay(-45)
	check(d.count == 15 and d.copper == 75 and env.today().sub.deposit == 75, "commodity posts add up")
	env.g.C_AuctionHouse.PostItem({}, 1, 1, 1, 1)
	env.pay(-8)
	check(env.today().sub.deposit == 83 and env.today().expense.auction == 83, "unknown posted item: deposit without item")
	env.pay(-4)
	check(env.today().expense.auction == 87 and env.today().sub.deposit == 83, "only the next change is a deposit")
	check(env.Ledger.GetItem("Tester-Realm", 101, 1).deposits == 75, "deposits per item through the interface")
	check(env.Ledger.GetRange("Tester-Realm", 1).expense.auction == 87, "deposits are auction expense in the range")
end

-- Auction purchases and outbid refunds

do
	local env = boot()
	env.show("Auctioneer")
	env.g.C_AuctionHouse.ConfirmCommoditiesPurchase(103, 20)
	env.pay(-5000)
	local p = env.today().purchases[103]
	check(p and p.count == 20 and p.copper == 5000 and p.source == "auction", "commodity purchase: item, count, copper, source")
	check(env.today().expense.auction == 5000 and not env.today().sub, "booked as auction expense, no deposit")
	env.merchant[1] = { "|Hitem:103:|h", 1 }
	env.hide("Auctioneer")
	env.show("Merchant")
	env.g.BuyMerchantItem(1, 1)
	env.pay(-7)
	check(p.count == 21 and p.copper == 5007 and p.source == "mixed", "one item from both sources is mixed")
	env.hide("Merchant")
	env.show("Auctioneer")
	env.g.C_AuctionHouse.ConfirmCommoditiesPurchase(103, 5)
	env.show("Merchant")
	env.pay(-3)
	check(p.count == 21, "an auction purchase waits for an auction booking")
end

do
	local env = boot()
	env.nameLinks.Item104 = 104
	env.auctions[7] = { itemKey = { itemID = 104 }, quantity = 3, buyoutAmount = 9000 }
	env.show("Auctioneer")
	env.g.C_AuctionHouse.PlaceBid(7, 4000)
	env.pay(-4000)
	local p = env.today().purchases[104]
	check(p and p.count == 3 and p.copper == 4000 and p.source == "auction", "a bid is a purchase when the money leaves")
	env.hide("Auctioneer")

	-- Another bid for the same price on another item is not cancelled by this refund.
	env.inbox[1] = { sender = "Auction House", subject = "Outbid on Other", money = 4000 }
	env.show("MailInfo")
	env.g.TakeInboxMoney(1)
	env.pay(4000)
	check(p.count == 3, "a refund for another item cancels nothing")
	env.inbox[1] = { sender = "Auction House", subject = "Outbid on Item104", money = 3999 }
	env.fire("MAIL_INBOX_UPDATE")
	env.g.TakeInboxMoney(1)
	env.pay(3999)
	check(p.count == 3, "a refund of another amount cancels nothing")
	env.inbox[1] = { sender = "Auction House", subject = "Outbid on Item104", money = 4000 }
	env.fire("MAIL_INBOX_UPDATE")
	env.g.TakeInboxMoney(1)
	env.pay(4000)
	check(env.today().purchases[104] == nil, "the outbid refund cancels the bid purchase")
	check(env.Ledger.GetItem("Tester-Realm", 104, 1).purchases == 0, "and the item sums show it")
	check(env.today().income.auction == 4000 + 3999 + 4000 and env.today().auctionItems == nil, "the refund is auction money, not a sale")
	env.g.TakeInboxMoney(1)
	env.pay(4000)
	check(env.today().purchases[104] == nil and #env.errors == 0, "a refund cancels a bid once")
end

do
	-- A buyout is not refunded; a bid refund a day later cancels yesterday's purchase.
	local env = boot()
	env.nameLinks.Item104 = 104
	env.auctions[7] = { itemKey = { itemID = 104 }, quantity = 1, buyoutAmount = 9000 }
	env.show("Auctioneer")
	env.g.C_AuctionHouse.PlaceBid(7, 9000)
	env.pay(-9000)
	env.g.C_AuctionHouse.PlaceBid(7, 5000)
	env.pay(-5000)
	local first = env.today().purchases[104]
	check(first.count == 2 and first.copper == 14000, "buyout and bid both count as purchases")
	env.hide("Auctioneer")
	local yesterday = env.today()
	env.now = env.now + DAY
	env.inbox[1] = { sender = "Auction House", subject = "Outbid on Item104", money = 9000 }
	env.show("MailInfo")
	env.g.TakeInboxMoney(1)
	env.pay(9000)
	check(first.count == 2, "a buyout cannot be refunded")
	env.inbox[1] = { sender = "Auction House", subject = "Outbid on Item104", money = 5000 }
	env.fire("MAIL_INBOX_UPDATE")
	env.g.TakeInboxMoney(1)
	env.pay(5000)
	check(yesterday.purchases[104].count == 1 and yesterday.purchases[104].copper == 9000, "the refund reaches back to the day of the bid")
	local seen
	env.S:Listen("LEDGER_ITEM_CHANGED", function(_, _, id) seen = id end)
	env.inbox[1] = { sender = "Auction House", subject = "Outbid on Item104", money = 5000 }
	env.fire("MAIL_INBOX_UPDATE")
	env.g.TakeInboxMoney(1)
	env.pay(5000)
	check(seen == nil, "no matching bid, no item change")
end

do
	-- Bid by name when the refund name cannot be resolved.
	local env = boot()
	env.prices[104] = 1
	env.g.C_Item.GetItemInfo = function(id)
		if id == 104 then return "Bidded Thing", "link" end
	end
	env.auctions[7] = { itemKey = { itemID = 104 }, quantity = 1, buyoutAmount = 0 }
	env.show("Auctioneer")
	env.g.C_AuctionHouse.PlaceBid(7, 700)
	env.pay(-700)
	env.hide("Auctioneer")
	env.inbox[1] = { sender = "Auction House", subject = "Outbid on Bidded Thing", money = 700 }
	env.show("MailInfo")
	env.g.TakeInboxMoney(1)
	env.pay(700)
	check(env.today().purchases[104] == nil, "the bid remembers the item name for the refund")
end

-- Vendor check

do
	local env = boot()
	env.bag["0:1"] = { itemID = 100, stackCount = 3 }
	env.show("Merchant")
	env.g.C_Container.UseContainerItem(0, 1)
	env.pay(75)
	env.hide("Merchant")
	check(env.rec.checks == nil, "matching sales and income leave no record")

	env.show("Merchant")
	env.g.C_Container.UseContainerItem(0, 1)
	env.bag["0:2"] = { itemID = 101, stackCount = 1 }
	env.g.C_Container.UseContainerItem(0, 2)
	env.pay(80) -- 75 + 7 expected
	env.hide("Merchant")
	local c = env.rec.checks and env.rec.checks[1]
	check(c and c.diff == -2 and c.time == T0, "a difference is kept with time and size")
	check(c and #c.items == 2 and c.items[1].id == 100 and c.items[1].count == 3 and c.items[1].copper == 75, "and the items sold in that visit")
	check(#env.printed == 0, "nothing is printed during play")

	-- Buyback: income stays, the expense is not income.
	env.show("Merchant")
	env.g.C_Container.UseContainerItem(0, 1)
	env.pay(75)
	env.buyback[1] = { "|Hitem:100:|h", 3 }
	env.g.BuybackItem(1)
	env.pay(-75)
	env.hide("Merchant")
	check(#env.rec.checks == 1, "a buyback does not make a difference")

	-- Income with no recorded sale.
	env.show("Merchant")
	env.pay(50)
	env.hide("Merchant")
	check(#env.rec.checks == 2 and env.rec.checks[2].diff == 50 and #env.rec.checks[2].items == 0, "income without sales is a difference too")

	-- A visit without money or sales is nothing.
	env.show("Merchant")
	env.hide("Merchant")
	check(#env.rec.checks == 2, "an empty visit is no difference")

	-- Repairs and purchases are not income.
	env.show("Merchant")
	env.g.RepairAllItems()
	env.pay(-200)
	env.hide("Merchant")
	check(#env.rec.checks == 2, "expenses are not compared")
end

do
	-- Sales whose price arrives late are not checked.
	local env = boot()
	env.prices[100] = nil
	env.bag["0:1"] = { itemID = 100, stackCount = 2 }
	env.show("Merchant")
	env.g.C_Container.UseContainerItem(0, 1)
	env.pay(61)
	env.hide("Merchant")
	check(env.rec.checks == nil, "a visit with a missing price is not checked")
end

do
	-- Only the last 20 are kept.
	local env = boot()
	for i = 1, 25 do
		env.show("Merchant")
		env.pay(i)
		env.hide("Merchant")
	end
	check(#env.rec.checks == 20 and env.rec.checks[1].diff == 6 and env.rec.checks[20].diff == 25, "the newest 20 differences are kept")
	local saved = env.rec
	local again = boot({ db = env.db })
	check(again.rec.checks == saved.checks or #again.rec.checks == 20, "the list is part of the saved data")
end

do
	local env = boot()
	env.S.commands.gold("pruefen")
	check(env.printed[#env.printed]:find("no differences recorded"), "pruefen without records says so")
	env.bag["0:1"] = { itemID = 100, stackCount = 3 }
	env.show("Merchant")
	env.g.C_Container.UseContainerItem(0, 1)
	env.pay(73)
	env.hide("Merchant")
	env.show("Merchant")
	env.pay(5)
	env.hide("Merchant")
	env.printed = {}
	env.S.commands.gold("pruefen")
	local out = env.out()
	check(out:find("Vendor check: differences between item sales and vendor income %(last 2%)"), "pruefen header")
	check(out:find("%-0g 0s 2c") and out:find("Item100 x3 %(0g 0s 75c%)"), "pruefen lists the difference and the items: " .. out)
	check(out:find("%+0g 0s 5c") and out:find("no item sales"), "newest first, empty sales marked")
	check(out:find("2026%-10%-21 12:00:00"), "with the time")
	check(out:find("5c.*2c") ~= nil, "newest first order")
	env.printed = {}
	env.S.commands.ledger("CHECK")
	check(#env.printed == 3, "check is an alias")
end

-- Degraded clients

do
	local env = boot({ noHooks = true, noInvoice = true })
	local warned = false
	for _, line in ipairs(env.bootPrinted) do
		if line:find("C_AuctionHouse.PlaceBid") and line:find("BuyMerchantItem") then warned = true end
	end
	check(warned and #env.errors == 0, "missing auction and merchant hooks are reported")
	env.show("Merchant")
	env.pay(-5)
	check(env.today().expense.vendor == 5 and env.today().purchases == nil, "without hooks money is still booked")
	env.show("MailInfo")
	env.inbox[1] = { sender = "A", subject = "Outbid on X", money = 9 }
	env.g.TakeInboxMoney(1)
	env.pay(9)
	check(#env.errors == 0, "no hooks, no errors")
end

do
	-- A subject that is not a string never reaches a pattern match.
	local env = boot()
	env.inbox[1] = { sender = "A", subject = "S", money = 10, invoice = { "seller", "N", "B", 12, 12, 0, 2 } }
	env.g.GetInboxHeaderInfo = function() return nil, nil, "A", {}, 10 end
	env.show("MailInfo")
	env.g.TakeInboxMoney(1)
	env.pay(10)
	check(#env.errors == 0, "a non-string subject is ignored without errors")
end

end
