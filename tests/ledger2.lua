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

end
