# Briefing: Sempre_Way (waypoints), part 1

Status: ready to build, 2026-10-22. Pulled forward from "after launch" by the
owner. Part 1 uses the game's own user waypoint for the arrow and the minimap,
and draws its own pins only on the world map. Own minimap pins and a route
planner are later parts.

## Purpose

Type `/way 45.2 61.8 Lager` (the de-facto command many guides and videos
use), or click the map, and get a marked point: a pin on the world map, the
game's own waypoint marker in the world and on the minimap, and the distance
to it. Keep a short list of points per character, survive `/reload` and
logout, and reach the next point automatically when one is reached.

## Behaviour

1. **Command `/way`.** Forms, all case-insensitive, commas or dots as decimal
   separator, coordinates in percent (0 to 100):
   - `/way X Y [Text]`: point on the player's current best map.
   - `/way #<mapID> X Y [Text]`: point on that map.
   - `/way <zone name> X Y [Text]`: zone name in the client's language,
     resolved by searching the map tree under the player's continent and then
     all continents for a map of type zone whose name matches (exact first,
     then unique prefix). Ambiguous or unknown: print the candidates (max 5)
     and add nothing.
   - `/way` alone: list the points (number, text, zone, coordinates,
     distance when on the same map tree).
   - `/way weg <n>|alle` and `/way remove <n>|all`: remove one or all.
   - `/way naechster` / `/way next`: make the next point active.
   Register `/way` only if no other addon already owns the command (check the
   slash command tables at the module's `ADDON_LOADED` and again at login);
   otherwise print one line once and offer `/sempre way` with the same
   arguments. `/sempre way` always works.
2. **Points.** Up to 50 per character: map ID, x, y (0 to 1), text (max 60
   characters, display only), creation time. Order is the order added. One
   point is active.
3. **Active point.** The active point is set as the game's user waypoint and
   super-tracked, so the game draws its arrow marker in the world and the
   minimap edge marker. Before setting, check that a user waypoint can be set
   on that map; if not, try the parent maps up the tree (translating the
   position through world coordinates) and use the first one that allows it;
   if none does, keep the point but say once that the game cannot show it
   there (the world map pin still shows).
   If the player clears or replaces the game's user waypoint by hand, stop
   super-tracking our point without deleting it; it becomes active again only
   by `/way next` or a click on its pin.
4. **Arrival.** Every 0.5 seconds while a point is active (an own frame's
   update with a time accumulator, no work while no point is active, none in
   combat), compute the distance in yards from the player's world position to
   the point's world position when both are on the same continent. Under 10
   yards: print "Erreicht: <Text>" / "Reached: <text>", remove the point, make
   the next one active. Where the player's world position is not readable
   (instances, or restricted), skip arrival checks quietly.
5. **World map pins.** On the world map, one pin per point on the shown map
   or on a child map shown inside it: copper dot for the active point, a
   lighter dot for the others. Tooltip: text, coordinates, distance. Left
   click makes it active, right click removes it (with Shift only, so a stray
   click does not delete). Pins update when the map changes and when the list
   changes. Build the pin layer only the first time the world map opens.
6. **Click to add.** Ctrl + right click on the world map adds a point at the
   clicked position on the shown map (text: zone name and coordinates). It
   must not block the map's own right click (zoom out) without Ctrl.
7. **Persistence.** Saved per character; restored at login (the active point
   is set again as the game waypoint). Points older than 30 days are dropped
   at login.
8. **Options** via `SempreUI:RegisterOptions`: "Nächsten Punkt automatisch
   aktivieren / Activate the next point automatically" (default on),
   "Strg+Rechtsklick auf der Karte setzt einen Punkt / Ctrl + right click on
   the map adds a point" (default on).
9. **Interface for later modules** (read-only, documented in the module):
   `SempreUI.Way.GetPoints()`, `SempreUI.Way.GetActive()`; and an add call
   `SempreUI.Way.Add(mapID, x, y, text)` returning the point number, so Loot
   (`/sempre loot wo`) and later modules can offer "mark it". Message
   `WAY_CHANGED` after each change.

## Saved data

Own SavedVariables `SempreWayDB` with `version`: `chars[charKey] = { points =
{...}, active = n }`. No player names; texts come from the player.

## Loading

Must restore the waypoint and own `/way` at login: `## X-Sempre-LoadWith:
Login`, login work in its own `ADDON_LOADED` (see CLAUDE.md). Budget 60 KB.
Folder `Sempre_Way`, TOC `Sempre_Way.toc` with IconTexture and notes in both
languages like the other modules, `.pkgmeta` line, LICENSE and NAMING.md
copies.

Slash command registration needs the game's slash globals; that is the one
allowed exception to "no globals", the same one the core uses. Name them
after the module (`SLASH_SEMPREWAY1`), add them to `.luacheckrc`.

## Events

Lifecycle and low-frequency events through `SempreUI:On`: player entering
world, zone changes, user waypoint updated, super-tracking changed, regen
disabled and enabled. Feature-check optional events with
`C_EventUtils.IsEventValid`.

## Forever and API notes

- Use `C_Map` (best map for unit, player map position, map info, children,
  world position from map position and back, user waypoint functions) and
  `C_SuperTrack`. Feature-detect each; if the user waypoint functions are
  missing, the module still keeps the list and the map pins and says once that
  the game marker is not available.
- Positions come from the game as vector objects; create them with the
  game's vector constructor if it exists, else fall back to a plain table
  only where the function accepts it (feature check).
- The player's position may be unavailable in instances; never error, never
  print in a loop.
- World map pins: use the map canvas data provider mechanism the game's own
  world map offers, with a pin template defined in the module (an XML file is
  allowed for this template). If that mechanism is missing, place own frames
  on the map's canvas child at relative positions. Hook the world map only
  from the module's own `ADDON_LOADED` or the map's own load (the world map
  addon may load later; listen for its `ADDON_LOADED`).
- No secret values are involved (the player's own position); still no
  arithmetic on anything `issecretvalue` reports.
- Distance is straight-line yards in world coordinates, no height.

## Style

Copper `#C8794A` for the active pin and titles. Pin size about 14 px at the
map's normal scale, scaled with the canvas so it stays readable. German first
in `L` tables.

## Not in scope

Own minimap pins, own arrow frame, routes and route optimisation, importing
point lists, sharing points, pins on the flight map, TomTom API compatibility
beyond the `/way` text command.

## Acceptance checks

- `luacheck .` clean, `lua5.1 tests/run.lua` passes. New offline tests in
  `tests/way.lua` with a stubbed `C_Map`/`C_SuperTrack` cover: all `/way`
  forms including comma decimals, map ID and zone name (exact, prefix,
  ambiguous, unknown); out-of-range coordinates rejected; list, remove one,
  remove all, next; 50-point cap; active point set as user waypoint and
  super-tracked; parent map fallback when the zone does not allow a user
  waypoint; manual clear of the game waypoint stops tracking without deleting;
  arrival under 10 yards removes the point and activates the next (and not
  with the option off); no arrival check without a readable position or in
  combat; `/way` not registered when another addon owns it, `/sempre way`
  still works; restore at login and drop of points older than 30 days; Add
  interface and `WAY_CHANGED`; pin list for a shown map includes points on
  child maps; Ctrl + right click adds a point, plain right click does not.
