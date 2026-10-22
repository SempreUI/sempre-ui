-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- SempreUI fonts. Interface for modules (read-only, documented here):
--   SempreUI.Fonts                      -- file path per role: title, text, bold, mono
--   SempreUI:SetFont(fs, role, size, flags)
--       Applies the role's SempreUI font to a font string. Default sizes:
--       title 14, text 12, bold 12, mono 12; flags default to none. The title
--       role gets a thin shadow, no outline. An unknown role, the option off,
--       a client language without glyphs in these fonts or a file that fails
--       to load all apply the game's standard font at the same size instead.
--       The font string is remembered (weakly), so a change of the option
--       re-applies it. Modules never hard-code font paths.
--   SempreUI:FontLockReason()           -- text when the client language has no
--       glyphs in these fonts, else nil
-- Options (core): fonts (default on), game_fonts (default off, replaces the
-- font files of the game's common font objects; originals are restored when
-- it is switched off). Command: /sempre schrift (font).

local ADDON_NAME = ...

local S = SempreUI
local L = S.L
local GetLocale = GetLocale
local pairs, ipairs, type, pcall, tostring, setmetatable = pairs, ipairs, type, pcall, tostring, setmetatable

local DE = GetLocale() == "deDE"
if DE then
	L.FONT_LOCKED = "Diese Client-Sprache hat in den SempreUI-Schriften keine Zeichen, die Spielschrift bleibt."
	L.FONT_FAILED = "Eine SempreUI-Schrift konnte nicht geladen werden (%s), die Spielschrift wird benutzt."
	L.FONT_TIP_RELOAD = "Manche Fenster ändern sich erst nach /reload."
	L.FONT_STATE_ON = "SempreUI-Schriften: an (Grenze, Atkinson Hyperlegible)."
	L.FONT_STATE_OFF = "SempreUI-Schriften: aus, die Spielschriften werden benutzt."
	L.FONT_STATE_LOCKED = "SempreUI-Schriften: nicht benutzbar. %s"
	L.FONT_STATE_FAILED = "SempreUI-Schriften: Laden fehlgeschlagen, die Spielschrift wird benutzt."
	L.FONT_LOCALE = "Client-Sprache: %s."
	L.FONT_GAME_ON = "Spielschriften ersetzt: ja (%d Schriftobjekte)."
	L.FONT_GAME_OFF = "Spielschriften ersetzt: nein."
else
	L.FONT_LOCKED = "This client language has no glyphs in the SempreUI fonts, the game font stays."
	L.FONT_FAILED = "A SempreUI font could not be loaded (%s), the game font is used."
	L.FONT_TIP_RELOAD = "Some frames only change after /reload."
	L.FONT_STATE_ON = "SempreUI fonts: on (Grenze, Atkinson Hyperlegible)."
	L.FONT_STATE_OFF = "SempreUI fonts: off, the game fonts are used."
	L.FONT_STATE_LOCKED = "SempreUI fonts: not usable. %s"
	L.FONT_STATE_FAILED = "SempreUI fonts: loading failed, the game font is used."
	L.FONT_LOCALE = "Client language: %s."
	L.FONT_GAME_ON = "Game fonts replaced: yes (%d font objects)."
	L.FONT_GAME_OFF = "Game fonts replaced: no."
end

local DIR = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Media\\Fonts\\"
S.Fonts = {
	title = DIR .. "Grenze-SemiBold.ttf",
	text = DIR .. "AtkinsonHyperlegibleNext-Regular.ttf",
	bold = DIR .. "AtkinsonHyperlegibleNext-Bold.ttf",
	mono = DIR .. "AtkinsonHyperlegibleMono-Regular.ttf",
}
local FILES = S.Fonts

local DEFAULT_SIZE = { title = 14, text = 12, bold = 12, mono = 12 }
local LAST_RESORT = "Fonts\\FRIZQT__.TTF"

-- Client languages whose scripts these fonts do not cover.
local LOCKED = { ruRU = true, koKR = true, zhCN = true, zhTW = true }
local locale = GetLocale()
local locked = LOCKED[locale] == true

local failedFile            -- set after the first failed load, then the game font is used
local registry = setmetatable({}, { __mode = "k" })   -- font string -> { role, size, flags }
local shadowed = setmetatable({}, { __mode = "k" })   -- font strings that got our title shadow

function S:FontLockReason()
	if locked then return L.FONT_LOCKED end
end

local function active()
	return not locked and not failedFile and S:GetOption(ADDON_NAME, "fonts") and true or false
end

-- Assumption: the standard text font path is the global STANDARD_TEXT_FONT.
local function gameFont()
	local path = STANDARD_TEXT_FONT
	if type(path) == "string" and path ~= "" then return path end
	return LAST_RESORT
end

-- Assumption: SetFont on a font string or font object returns true on
-- success and false when the file cannot be loaded; an error counts as failure.
local function trySet(obj, path, size, flags)
	local ok, res = pcall(obj.SetFont, obj, path, size, flags)
	return ok and res ~= false
end

local function reportFailure(path)
	if failedFile then return end
	failedFile = path
	S:Print(L.FONT_FAILED, tostring(path))
end

local function setShadow(fs, on)
	if not (fs.SetShadowOffset and fs.SetShadowColor) then return end
	if on then
		fs:SetShadowColor(0, 0, 0, 0.6)
		fs:SetShadowOffset(1, -1)
		shadowed[fs] = true
	elseif shadowed[fs] then
		fs:SetShadowOffset(0, 0)
		shadowed[fs] = nil
	end
end

local function apply(fs, role, size, flags)
	flags = flags or ""
	local path = DEFAULT_SIZE[role] and active() and FILES[role]
	if path then
		if trySet(fs, path, size, flags) then
			setShadow(fs, role == "title")
			return
		end
		reportFailure(path)
	end
	setShadow(fs, false)
	if not trySet(fs, gameFont(), size, flags) then trySet(fs, LAST_RESORT, size, flags) end
end

function S:SetFont(fs, role, size, flags)
	if not (fs and fs.SetFont) then return end
	size = size or DEFAULT_SIZE[role] or 12
	registry[fs] = { role = role, size = size, flags = flags }
	apply(fs, role, size, flags)
end

local function reapplyAll()
	for fs, r in pairs(registry) do apply(fs, r.role, r.size, r.flags) end
end

-- Game font objects: names are looked up in the game's globals and a missing
-- one is skipped. Headers and titles take the title role, the rest the text role.
local GAME_OBJECTS = {
	{ "GameFontNormal", "text" }, { "GameFontHighlight", "text" },
	{ "GameFontNormalSmall", "text" }, { "GameFontHighlightSmall", "text" },
	{ "GameFontDisable", "text" }, { "GameFontDisableSmall", "text" },
	{ "GameFontNormalMed3", "text" }, { "GameFontHighlightMedium", "text" },
	{ "GameFontNormalLarge", "title" }, { "GameFontHighlightLarge", "title" },
	{ "GameFontNormalHuge", "title" }, { "GameFontNormalHuge2", "title" },
	{ "SystemFont_Med1", "text" }, { "SystemFont_Small", "text" },
	{ "SystemFont_Large", "title" }, { "SystemFont_Huge1", "title" },
	{ "GameTooltipHeaderText", "title" }, { "GameTooltipText", "text" }, { "GameTooltipTextSmall", "text" },
	{ "ChatFontNormal", "text" }, { "ChatFontSmall", "text" }, { "ChatFontLarge", "text" },
	{ "QuestFont", "text" }, { "QuestFontNormalSmall", "text" }, { "QuestFontHighlight", "text" },
	{ "QuestFont_Large", "text" }, { "QuestTitleFont", "title" }, { "QuestFont_Huge", "title" },
}

local originals = {}   -- name -> { path, size, flags }, kept before the first change
local replacedCount = 0

local function wantGameFonts()
	return active() and S:GetOption(ADDON_NAME, "game_fonts") and true or false
end

local function lookup(name)
	local obj = _G[name]
	if type(obj) == "table" or type(obj) == "userdata" then
		if obj.GetFont and obj.SetFont then return obj end
	end
end

local function syncGameFonts()
	local want = wantGameFonts()
	local count = 0
	for _, entry in ipairs(GAME_OBJECTS) do
		local name, role = entry[1], entry[2]
		local obj = lookup(name)
		if obj then
			local orig = originals[name]
			if want then
				if not orig then
					local ok, path, size, flags = pcall(obj.GetFont, obj)
					if ok and type(path) == "string" then
						orig = { path = path, size = size, flags = flags }
						originals[name] = orig
					end
				end
				if orig then
					if trySet(obj, FILES[role], orig.size, orig.flags or "") then
						count = count + 1
					else
						reportFailure(FILES[role])
					end
				end
			elseif orig then
				trySet(obj, orig.path, orig.size, orig.flags or "")
			end
		end
	end
	replacedCount = want and count or 0
end

S:On("ADDON_LOADED", function(_, name)
	if name ~= ADDON_NAME then return end
	S:Listen("OPTION_CHANGED", function(_, moduleName, key)
		if moduleName ~= ADDON_NAME then return end
		if key == "fonts" then
			reapplyAll()
			syncGameFonts()
		elseif key == "game_fonts" then
			syncGameFonts()
		end
	end)
end)

S:On("PLAYER_LOGIN", function()
	if wantGameFonts() then syncGameFonts() end
end)

-- /sempre schrift

local function printState()
	if locked then
		S:Print(L.FONT_STATE_LOCKED, L.FONT_LOCKED)
	elseif failedFile then
		S:Print(L.FONT_STATE_FAILED)
	elseif S:GetOption(ADDON_NAME, "fonts") then
		S:Print(L.FONT_STATE_ON)
	else
		S:Print(L.FONT_STATE_OFF)
	end
	S:Print(L.FONT_LOCALE, locale)
	if replacedCount > 0 then
		S:Print(L.FONT_GAME_ON, replacedCount)
	else
		S:Print(L.FONT_GAME_OFF)
	end
end

S.commands.schrift = printState
S.commands.font = printState
