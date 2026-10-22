# Briefing: Sempre_Map (world map helpers), part 1

Status: ready to build, 2026-10-22. Owner's pick after the addon video
review: a solid, not overloaded world map helper. All `C_` names and events
below are in `tools/api-forever.txt` (build 1.60.1); return shapes are taken
from the generated documentation.

Not in this part: showing areas nobody on the account has explored (needs
the game's full overlay data, which an addon cannot read and which is not
reachable from our build machine now), library book pins and rare pins (need
location data first), map links and arrows. Those are later parts.

## Purpose

Open the map and see at a glance which zones fit the character's level,
where the cursor and the player are, and which areas the account has already
explored on other characters.

## Behaviour

1. **Level range of zones.** `C_Map.GetMapLevels(uiMapID)` returns player
   minimum and maximum level (plus pet levels, ignored).
   - On a zone map: a line under the map title, e.g. "Stufe 20–30" /
     "Level 20–30".
   - On a continent map: while the cursor is over a zone
     (`C_Map.GetMapInfoAtPosition(continentID, x, y)` returns that zone's
     info), a small label at the cursor with the zone name and its range.
   - Colour by the player's level, like quest difficulty: grey when the
     player's level is more than 5 above the maximum, green when it lies in the
     range, yellow when the minimum is up to 2 above the player, red beyond.
   - A range of 0–0 or a missing result shows nothing.
2. **Coordinates.** A thin bar at the bottom of the world map: player
   coordinates on the shown map (`C_Map.GetPlayerMapPosition`) and cursor
   coordinates over the canvas, both as `45.2, 61.8`. Updated by an own
   frame's update with a 0.1 second time accumulator only while the map is
   shown. Where the player is not on the shown map, show "–". Mono font role
   (`SempreUI:SetFont(fs, "mono")`).
3. **Explored by the account.** Each time the world map shows a zone, read
   `C_MapExplorationInfo.GetExploredMapTextures(uiMapID)` (a list of overlays:
   texture width and height, offset x and y, file data IDs, draw-on-top flag,
   mouse-over flag; all sizes and offsets in map canvas units) and store them account-wide per map in the module's saved
   data, merged with what other characters stored (one entry per overlay,
   keyed by its offsets and first file data ID). When another character opens
   the same map, draw the stored overlays this character has not explored
   yet on the map canvas, desaturated and at 60 % alpha, so the player sees
   "explored on another character". Skip overlays marked as shown by mouse
   over. Tile large overlays by the tile size of the map's first art layer
   (`C_Map.GetMapArtLayers`), row-major, with partial last tiles in a
   power-of-two file (at least 16); draw nothing on other art layers.
   Option "Von anderen Charakteren erkundete Gebiete zeigen / Show areas
   explored on other characters" (default on).
4. **Command** `/sempre karte` (alias `map`): prints the level range of the
   current zone and how many maps have stored exploration data;
   `/sempre karte vergessen` / `forget` clears the stored exploration.
5. **Options** via `SempreUI:RegisterOptions`: the option of 3, "Stufenbereich
   der Gebiete zeigen / Show zone level ranges" (default on), "Koordinaten auf
   der Karte / Coordinates on the map" (default on).

## Saved data

Own SavedVariables `SempreMapDB` with `version` and `explored[uiMapID] =
{ { w, h, x, y, top, ids = { fileDataID, ... } }, ... }`. Game data only, no
player names. Cap: 400 maps; drop the least recently seen first.

## Loading

Needed only when the world map opens, but the map frame may open any time:
`## X-Sempre-LoadWith: Login`, login work in its own `ADDON_LOADED` (see
CLAUDE.md). The world map addon may load later: hook it on its own
`ADDON_LOADED` if it is not loaded yet. Build every frame only the first time
the map opens. Budget 60 KB plus the stored overlays (budget 120 KB total).
Folder `Sempre_Map`, TOC `Sempre_Map.toc` with IconTexture and notes in both
languages, `.pkgmeta` line, LICENSE and NAMING.md copies.

## World map integration

Same approach as Sempre_Way (study `Sempre_Way/Way.lua`): own frames on the
world map's canvas child for overlays and the cursor label, an own bar
anchored to the bottom of the map frame for coordinates, map changes through
the map frame's map-changed hook, cursor position through the scroll
container's normalized cursor position. Overlays go below Sempre_Way pins
(lower frame level). Nothing of the game's own map frames is modified.

## Forever and API notes

- `GetMapInfoAtPosition` takes the map ID and normalized x and y; it returns
  a map info table or nil.
- `GetExploredMapTextures` returns an empty list for maps without overlays;
  never error.
- Textures by file data ID through the texture set call; check the texture
  coordinates for partial tiles.
- No secret values involved.

## Not in scope

Unexplored areas nobody has seen, book and rare pins, map scaling, fading,
dungeon maps, quest data.

## Acceptance checks

- `luacheck .` clean, `lua5.1 tests/run.lua` passes. New offline tests in
  `tests/map.lua` with a stubbed `C_Map`, `C_MapExplorationInfo` and map
  frame cover: level line on a zone map and its colour for players below, in
  and above the range; continent hover label from `GetMapInfoAtPosition`;
  0–0 range hidden; coordinates for player and cursor, "–" off map, no
  updates while the map is hidden; exploration stored per map and merged
  from two characters without duplicates; other character's overlays drawn
  only where this one has not explored, mouse-over overlays skipped; tile
  sizes for an overlay of 600 by 300; 400-map cap; `forget` clears; each
  option switches its part off; world map loaded later is hooked on its
  `ADDON_LOADED`.
