-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Reads the game's generated API documentation (a folder of Lua files) and
-- prints one line per documented name: "fn C_Map.GetMapInfo", "fn
-- GetInboxHeaderInfo", "event USER_WAYPOINT_UPDATED". Used by
-- tools/api-watch.lua. Usage: lua5.1 tools/api-dump.lua <docs folder>

local dir = assert(arg[1], "usage: api-dump.lua <docs folder>")
local tables = {}

local stub
stub = setmetatable({}, { __index = function() return stub end, __call = function() return stub end })
local env = setmetatable({
	APIDocumentation = { AddDocumentationTable = function(_, t) tables[#tables + 1] = t end },
}, { __index = function(_, k) return _G[k] or stub end })

local list = io.popen('ls "' .. dir .. '"')
for file in list:lines() do
	if file:match("%.lua$") then
		local chunk = loadfile(dir .. "/" .. file)
		if chunk then
			setfenv(chunk, env)
			pcall(chunk)
		end
	end
end
list:close()

local out = {}
for _, t in ipairs(tables) do
	local ns = type(t.Namespace) == "string" and t.Namespace or nil
	for _, f in ipairs(t.Functions or {}) do
		if type(f.Name) == "string" then
			out[#out + 1] = "fn " .. (ns and (ns .. ".") or "") .. f.Name
		end
	end
	for _, e in ipairs(t.Events or {}) do
		if type(e.LiteralName) == "string" then out[#out + 1] = "event " .. e.LiteralName end
	end
end
table.sort(out)
local last
for _, line in ipairs(out) do
	if line ~= last then print(line) end
	last = line
end
