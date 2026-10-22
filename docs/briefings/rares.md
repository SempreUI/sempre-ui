# Briefing: Sempre_Rares (rare detection), part 1

Status: ready to build, 2026-10-22. Forever has no vignettes, so the game
shows rares nowhere. Readable instead (probe 0.2.5 and the generated API
documentation, build 1.60.1): nameplate units appear with
`NAME_PLATE_UNIT_ADDED`; `UnitClassification(unit)` is not secret;
`UnitGUID`, `UnitName` and `UnitCreatureType` can be secret when unit
identity is restricted, so every value is checked with `issecretvalue`
before use. Health stays secret: never used.

## Purpose

When a rare mob comes into nameplate range, notice it at once: a sound, a
banner with its name, one click to target it, and a list of where rares were
seen, so later parts can draw them on the map.

## Behaviour

1. **Detection.** On `NAME_PLATE_UNIT_ADDED`, `PLAYER_TARGET_CHANGED` (unit
   `target`) and `UPDATE_MOUSEOVER_UNIT` (unit `mouseover`): if
   `UnitClassification(unit)` is `rare` or `rareelite`, the unit is not dead
   (`UnitIsDead`), and its GUID is readable (not secret), it is a sighting.
   NPC ID from the GUID (creature GUID field, same split as Sempre_Loot; check
   `issecretvalue` first). Ignore sightings of the same GUID for 5 minutes, and
   of the same NPC ID for 60 seconds.
2. **Alert.** For a new sighting:
   - one chat line: "Rare: <name> (Stufe <level>) bei 45.2, 61.8" / "Rare:
     <name> (level <level>) at ..." with the player's map coordinates;
   - a sound (`C_Sound.PlaySound` or the game's sound kit call, feature
     check), option "Ton bei Rares / Sound for rares" (default on);
   - a banner at the top centre of the screen for 15 seconds: name in the
     title font role, level, "Klicken zum Anvisieren / Click to target",
     copper border. Hover pauses the fade.
3. **Click to target.** The banner is a secure action button using the
   game's secure action button template with a macro action whose text
   targets the rare by its name (exact-name targeting, so a similarly named
   mob is not picked). Attributes may only be set out of combat: when a rare
   is seen in combat the banner shows without the click action and with the
   hint "Im Kampf: /tar <Name>" / "In combat: ...", and the action is set at
   combat end if the banner is still shown. Names are game data of NPCs and
   may be used in the macro text only when not secret. Right click on the
   banner closes it; Shift + right click adds a waypoint at the player's
   position through `SempreUI.Way.Add` if Sempre_Way is loaded (feature
   check, documented interface).
4. **Seen list.** Account-wide, per NPC ID: name, level, classification, and
   up to 10 sighting places `{ mapID, x, y, time }` (the player's position at
   sighting, rounded to 0.1 %), newest first; places within 2 % of an existing
   one on the same map update that one instead. Cap 500 NPCs, least recently
   seen dropped first.
5. **Command** `/sempre rares`: last 10 rares seen (name, level, zone, when);
   `/sempre rares hier` / `here`: rares seen on the current map with their
   places; `/sempre rares vergessen` / `forget` clears the list.
6. **Options** via `SempreUI:RegisterOptions`: "Rares melden / Announce
   rares" (default on), the sound option, "Banner zeigen / Show the banner"
   (default on).
7. **Interface** (read-only, documented in the module):
   `SempreUI.Rares.GetSeen(npcID)` and `SempreUI.Rares.GetSeenOnMap(mapID)`
   for later map pins; message `RARE_SEEN` with the NPC ID.

## Saved data

Own SavedVariables `SempreRaresDB` with `version` and `seen[npcID]`. Only NPC
data, never players: a unit that is a player (`UnitIsPlayer`) is ignored.

## Loading

Must watch nameplates from login: `## X-Sempre-LoadWith: Login`, login work
in its own `ADDON_LOADED` (see CLAUDE.md). The nameplate event is
high-frequency: register it on the module's own frame, not through
`SempreUI:On` (CLAUDE.md style rule); target and mouseover events through
`SempreUI:On`. Budget 40 KB. Folder `Sempre_Rares`, TOC `Sempre_Rares.toc`
with IconTexture and notes in both languages, `.pkgmeta` line, LICENSE and
NAMING.md copies. Build the banner on the first sighting, out of combat if
possible (creating a secure button in combat is not allowed: if the first
sighting is in combat, show a plain, non-secure banner and create the secure
one at combat end).

## Forever and API notes

- Enemy nameplates must be enabled in the game's settings for nameplate
  detection; if no nameplate unit was ever seen 5 minutes after login, say
  once in chat that turning on enemy nameplates helps (no automatic change of
  game settings).
- All unit functions take unit tokens; check every returned value with
  `issecretvalue` before comparing or storing.
- Player position from `C_Map.GetBestMapForUnit` and
  `C_Map.GetPlayerMapPosition`; skip the place when unreadable (instances).

## Not in scope

Map pins for rares (part 2, reading this list), rare loot, respawn timers,
sharing sightings with other players, scanning without nameplates.

## Acceptance checks

- `luacheck .` clean, `lua5.1 tests/run.lua` passes. New offline tests in
  `tests/rares.lua` cover: rare and rare elite detected from a nameplate,
  target and mouseover; normal, elite, dead and player units ignored; secret
  GUID or name ignored without error; 5-minute GUID and 60-second NPC
  throttles; chat line, sound and banner with their options; banner click
  action set out of combat, plain banner with the hint in combat and the
  action added at combat end; Shift + right click adds a waypoint when Way is
  loaded and does nothing otherwise; seen list merges near places, keeps 10
  places and caps 500 NPCs; `rares`, `hier` and `vergessen` output; the
  nameplate hint after 5 minutes without nameplates, once.
