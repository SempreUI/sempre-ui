-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Compares a fresh API dump (from tools/api-dump.lua) with the snapshot in
-- tools/api-forever.txt and with the C_ functions and events SempreUI uses
-- (minus the feature-checked names in tools/api-optional.txt).
-- Prints a Markdown report and exits with 1 when something needs a look:
-- a used name is no longer documented, or the documented API changed.
-- Usage: lua5.1 tools/api-watch.lua <fresh dump> <snapshot> <build line>

local freshPath, snapPath, build = arg[1], arg[2], arg[3] or "?"
assert(freshPath and snapPath, "usage: api-watch.lua <fresh dump> <snapshot> [build]")

local function readSet(path)
	local set, f = {}, io.open(path)
	if not f then return set, false end
	for line in f:lines() do
		if line ~= "" and not line:match("^#") then set[line] = true end
	end
	f:close()
	return set, true
end

local fresh = readSet(freshPath)
local snap, hadSnap = readSet(snapPath)
local optional = readSet("tools/api-optional.txt")

-- Names used by the addon code: C_Namespace.Function and quoted event names
-- that the documentation knows (or knew, in the snapshot).
local used = {}
local files = io.popen("ls -d Sempre*/*.lua")
for path in files:lines() do
	local f = io.open(path)
	local text = f:read("*a")
	f:close()
	for name in text:gmatch("(C_%a+%.[%w_]+)") do used["fn " .. name] = path end
	for name in text:gmatch('"([A-Z][A-Z0-9_]+)"') do
		local key = "event " .. name
		if fresh[key] or snap[key] then used[key] = path end
	end
end
files:close()

local function sorted(set)
	local list = {}
	for k in pairs(set) do list[#list + 1] = k end
	table.sort(list)
	return list
end

local missing, added, removed = {}, {}, {}
for name, path in pairs(used) do
	if not fresh[name] and not optional[name] then missing[name .. " (" .. path .. ")"] = true end
end
if hadSnap then
	for name in pairs(fresh) do if not snap[name] then added[name] = true end end
	for name in pairs(snap) do if not fresh[name] then removed[name] = true end end
end
missing, added, removed = sorted(missing), sorted(added), sorted(removed)

local out = { "API documentation of the Forever client: " .. build, "" }
local function section(title, list, limit)
	if #list == 0 then return end
	out[#out + 1] = "### " .. title .. " (" .. #list .. ")"
	out[#out + 1] = ""
	for i = 1, math.min(#list, limit) do out[#out + 1] = "- `" .. list[i] .. "`" end
	if #list > limit then out[#out + 1] = "- ... and " .. (#list - limit) .. " more" end
	out[#out + 1] = ""
end
section("Used by SempreUI but not documented", missing, 100)
section("Removed since the snapshot", removed, 100)
section("Added since the snapshot", added, 60)
if not hadSnap then out[#out + 1] = "No snapshot yet." end
if #missing + #added + #removed == 0 and hadSnap then
	out[#out + 1] = "No changes."
else
	out[#out + 1] = "Update `tools/api-forever.txt` with `lua5.1 tools/api-dump.lua <docs> > tools/api-forever.txt` once handled."
end
print(table.concat(out, "\n"))
os.exit((#missing + #added + #removed > 0 or not hadSnap) and 1 or 0)
