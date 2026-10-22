# Briefing: Sempre_Buttons (minimap button collector), part 1

Status: ready to build, 2026-10-22. Pulled forward from "after launch" by the
owner. Part 1 collects the buttons other addons put around the minimap into
one SempreUI button with a fold-out panel. Restyling the minimap itself is a
later module.

## Purpose

Every addon adds its own round button to the minimap edge; after ten addons
the minimap is buried. Collect them behind one button, keep them clickable
exactly as before, and let the player choose which stay outside.

## Behaviour

1. **The SempreUI button.** One round button on the minimap edge with the
   SempreUI icon (`Interface\AddOns\Sempre\Media\Icon`). Drag (left button
   held) moves it around the minimap edge; the angle is saved. Left click
   opens or closes the panel. Right click opens the SempreUI settings
   (through the core's existing open path). Tooltip: "SempreUI", the number of
   collected buttons and the two click hints.
2. **Collecting.** Candidates are the direct children of the minimap and of
   the minimap's known holder frames (the cluster frame around it if it
   exists) that:
   - are buttons (or frames with a click or mouse-up script) about 20 to 40
     px in size,
   - have a global name,
   - are not owned by the game: skip names that start with `Minimap`,
     `MiniMap`, `GameTime`, `TimeManager`, `Queue`, `Expansion`, `Garrison`,
     `Tracking`, `Mail` and frames whose `IsProtected` reports true, plus a
     short list of game frames the builder finds in the current client's
     minimap (document the list in the code),
   - are not on the player's "keep outside" list,
   - and are not our own button.
   Scan after login (once the player entering world event has fired, then a
   second time 5 seconds later for slow addons), and when the player asks
   (`/sempre knoepfe neu`). Never scan in combat; queue for combat end.
3. **The panel.** A small frame next to the SempreUI button, in a grid of up
   to 6 columns, buttons sorted by name. Collected buttons are moved into the
   panel (reparented and re-anchored); their own size, scripts, tooltips and
   textures stay untouched. A button that tries to move itself back (its own
   drag or a position call from its addon) is put back into its grid cell on
   the next panel open; do not fight it every frame. The panel closes on a
   second click, on a click on the minimap outside it, and when combat
   starts.
4. **Releasing.** A button on the "keep outside" list, or every button when
   the module is switched off and the player reloads, keeps its original
   parent and anchor. Remember each collected button's original parent,
   points and frame strata before moving it, so `/sempre knoepfe raus <Name>`
   can put it back at once.
5. **Command `/sempre knoepfe`** (alias `buttons`): list collected and kept
   outside buttons with their numbers; `raus <n|Name>` / `out ...` moves one
   to the keep outside list and back to the minimap; `rein <n|Name>` / `in
   ...` takes it back into the panel; `neu` / `rescan` scans again.
6. **Options** via `SempreUI:RegisterOptions`: "Panel schließt nach einem
   Klick auf einen Knopf / Close the panel after clicking a button" (default
   on), "SempreUI-Knopf an der Minimap / SempreUI button on the minimap"
   (default on; off hides the button, the panel is then reached with
   `/sempre knoepfe zeigen` / `show`).
7. **Message** `BUTTONS_CHANGED` after each scan with the collected count.

## Saved data

Account-wide in own SavedVariables `SempreButtonsDB` with `version`: `angle`,
`outside = { [frameName] = true }`. Frame names are addon frames, never
player data.

## Loading

The buttons exist only after other addons load, and the scan runs after
login: `## X-Sempre-LoadWith: Login`, login work in its own `ADDON_LOADED`
(see CLAUDE.md). Budget 40 KB. Folder `Sempre_Buttons`, TOC
`Sempre_Buttons.toc` with IconTexture and notes in both languages, `.pkgmeta`
line, LICENSE and NAMING.md copies.

## Forever and API notes

- Other addons' buttons are only moved, never modified; no hooks on other
  addons' functions. Reading their global name is allowed.
- Never touch protected frames, never reparent in combat (check
  `InCombatLockdown`).
- The minimap's shape may be round or square (a later minimap module may make
  it square); place the SempreUI button on a circle of the minimap's radius
  plus a few pixels, and feature-check the shape function if the game has
  one.
- Minimap child frames come from `Minimap:GetChildren()`; feature-check the
  holder frames by name before use.

## Style

Panel background dark with a 1 px copper (`#C8794A`) border, 4 px gaps, the
game's standard tooltip. German first in `L` tables.

## Not in scope

Minimap shape, zoom, clock, coordinates, hiding the game's own minimap
buttons, a data broker bar, button sorting by drag.

## Acceptance checks

- `luacheck .` clean, `lua5.1 tests/run.lua` passes. New offline tests in
  `tests/buttons.lua` with a stubbed minimap and frames cover: addon buttons
  collected; game frames, protected frames, nameless and wrong-sized frames
  skipped; keep outside list respected and saved; `raus` restores the
  original parent and points at once, `rein` collects it again; scan queued in
  combat and run at combat end; grid order and column count; panel closes on
  combat start and (with the option) after a click on a collected button; drag
  angle saved and restored; button hidden with the option off and the panel
  reachable through `zeigen`; second scan picks up a late button;
  `BUTTONS_CHANGED` sent.
