-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Item tooltip lines: one line per character that owns the item, with the
-- split by location. Lines are built once per item and kept until the data
-- changes, so showing a tooltip allocates nothing.

local ADDON_NAME = ...

local S = SempreUI
local Items = S.Items
local L = Items.L
local format, concat, type, ipairs = string.format, table.concat, type, ipairs
local wipe = table.wipe
local issecretvalue = issecretvalue
local RAID_CLASS_COLORS = RAID_CLASS_COLORS

local MAX_CHARS = 8
local SPLIT = { "bags", "bank", "mail", "equipped" }
local NONE = { n = 0 }

local cache, cacheVersion = {}, -1

local function classHex(class)
	local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if not c then return "ffffffff" end
	return c.colorStr or format("ff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
end

-- The realm is dropped for characters of the current realm.
local function shortName(key)
	local name, realm = key:match("^([^-]+)-(.*)$")
	local _, myRealm = (S.charKey or ""):match("^([^-]+)-(.*)$")
	if name and realm == myRealm then return name end
	return key
end

local function charLine(entry)
	local parts = {}
	for _, loc in ipairs(SPLIT) do
		if entry[loc] > 0 then parts[#parts + 1] = format("%s %d", L[loc], entry[loc]) end
	end
	local rec = SempreItemsDB.chars[entry.key]
	return format("|c%s%s|r: %d (%s)", classHex(rec and rec.class), shortName(entry.key), entry.count, concat(parts, ", "))
end

local function buildLines(itemID)
	local total, res = Items.GetCount(itemID)
	if total <= 0 then return NONE end
	local lines = { n = 0 }
	local function add(text)
		lines.n = lines.n + 1
		lines[lines.n] = text
	end
	local shown = res.n < MAX_CHARS and res.n or MAX_CHARS
	for i = 1, shown do add(charLine(res[i])) end
	if res.n > shown then add(format(L.MORE, res.n - shown)) end
	if res.account > 0 then add(format("%s: %d", L.account, res.account)) end
	local owners = res.n + (res.account > 0 and 1 or 0)
	if owners > 1 then add(format("|cffc8794a%s|r: %d", L.TOTAL, total)) end
	return lines
end

-- Item tooltips carry no secret values; the guard keeps a later restriction
-- from erroring.
local function onItem(tooltip, data)
	if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
	if not S:GetOption(ADDON_NAME, "tooltip") then return end
	local id = data and data.id
	if type(id) ~= "number" or (issecretvalue and issecretvalue(id)) then return end
	if cacheVersion ~= Items.version then
		wipe(cache)
		cacheVersion = Items.version
	end
	local lines = cache[id]
	if not lines then
		lines = buildLines(id)
		cache[id] = lines
	end
	for i = 1, lines.n do tooltip:AddLine(lines[i], 1, 1, 1) end
end

-- Hooked from the module's own ADDON_LOADED. Without the tooltip processor the
-- tooltip feature is off and the rest of the module keeps working.
local function onLoaded(_, name)
	if name ~= ADDON_NAME then return end
	S:Off("ADDON_LOADED", onLoaded)
	S:RegisterOptions(ADDON_NAME, {
		{
			key = "tooltip", default = true,
			label = { de = "Besitz im Item-Tooltip", en = "Owners in the item tooltip" },
			tooltip = { de = "Zeigt im Tooltip eines Gegenstands, welche Charaktere ihn besitzen.", en = "Shows in an item tooltip which characters own it." },
		},
	})
	local types = Enum and Enum.TooltipDataType
	if not (TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and types and types.Item) then
		S:Print(L.NO_TOOLTIP)
		return
	end
	TooltipDataProcessor.AddTooltipPostCall(types.Item, onItem)
end
S:On("ADDON_LOADED", onLoaded)
