# Briefing: compatibility check with EllesmereUI and Naowh Forever (core)

Status: ready to build, 2026-10-26. Owner's pick. Many Forever players will
run SempreUI next to EllesmereUI (whole interface) and Naowh Forever
(Forever helpers). Several SempreUI parts then do the same job twice: two junk
sellers, two waypoint systems, two minimap button collectors. SempreUI should
notice that and offer to switch its own duplicates off, never the other
addon's, and never on its own. All `C_` names below are in
`tools/api-forever.txt` (build 1.60.1).

## Detection

- Go through the addon list once (`C_AddOns.GetNumAddOns`,
  `C_AddOns.GetAddOnInfo` for folder name and title). Strip colour codes
  from titles and compare in lower case.
- **EllesmereUI** counts as present when a folder name or title starts with
  `ellesmereui` and that addon is loaded at `PLAYER_LOGIN`. Its extra parts
  are separate folders with the same start, and the main part is enough.
- **Naowh Forever** counts as present when a folder name or title, with
  spaces removed, starts with `naowhforever` or `naowforever` and is loaded at
  `PLAYER_LOGIN`.
- The folder names of both are not verified from here. The match has to work
  for any spelling above, and the rule table holds the patterns in one place
  so they can be fixed in one line.
- Never treat a `Sempre` folder as foreign.

## Rule table

One table in the new core file, one entry per overlap. Each entry has:

- the other addon it applies to;
- the target: a whole module, or one option of a module;
- a short reason in German and English, under 70 characters;
- whether switching the module off needs a reload.

| Target | Applies when | Reason, roughly |
|---|---|---|
| module `Sempre_Way` | NF | NF has waypoint pins and routes |
| module `Sempre_Buttons` | EUI | EUI collects minimap buttons |
| module `Sempre_Rares` | NF | NF Discovery finds rares |
| option `Sempre_Butler.sell` | EUI or NF | junk is already sold by the other addon |
| option `Sempre_Butler.repair` | EUI or NF | repairs are already done by the other addon |
| option `Sempre_Butler.quiet` | EUI | EUI hides the error text |
| option `Sempre_Map.show_coords` | EUI | EUI shows map coordinates |
| option `Sempre_Map.show_explored` | NF | NF shows unexplored areas |
| info only: `Sempre_Items` tooltip | NF | Two owner lines in the tooltip. Keep one: SempreUI's tooltip option or NF's alt items. |

- Butler's resurrection and duel options stay: neither addon has them.
- Map's level ranges stay too: a gap in both addons.
- The info-only row offers no switch, only the line.

A suggestion counts as **open** only when its target is still on:

- module rows: the module is enabled (`S.IsModuleEnabled`);
- option rows: the module is enabled and the option is true. The module
  does not need to be loaded, because the option value lives in the core's
  saved options.

Rows whose target is already off are not shown.

## When it asks

- At login work, after `PLAYER_LOGIN`, a few seconds after entering the
  world, and not in combat (if in combat, at combat end).
- After the "what's new" window if that one opens in the same login: wait
  until it is closed, or open 2 seconds after it.
- Opens only if there is at least one open suggestion and the set of detected
  addons differs from the one stored as answered
  (`SempreDB.global.compatAnswered`, for example `"eui,nf"`). This way a
  player who said "no" is not asked again until they install the other addon
  too.
- Option of the core: "Auf doppelte Funktionen mit anderen Addons hinweisen /
  Point out functions doubled by other addons" (default on). Off means it
  never opens by itself.

## Window

Built only the first time it is shown. No global name, same look as the
news window: dark panel, 1 px copper border, title role for the heading.

- **Title:** "SempreUI – Doppelte Funktionen" / "SempreUI – Doubled
  functions".
- **One line under the title:** "Erkannt: EllesmereUI, Naowh Forever. Diese
  SempreUI-Teile machen dasselbe:" / "Found: ... These SempreUI parts do the
  same:".
- **One row per open suggestion**, holding a checkbox (checked), the target
  in plain words ("Modul Wegpunkte" / "Waypoints module", "Butler: Schrott
  verkaufen" / "Butler: sell junk") and the reason in grey. Info rows have
  no checkbox, only the text.
- **Buttons:**
  - "Ausgewählte ausschalten / Switch off selected": switches modules off
    for all characters, the same way as the module checkbox in the
    settings, and sets options to false with `SempreUI:SetOption`. Then
    stores the answer and closes. If a module was switched off, it prints
    one chat line saying a `/reload` is needed and offers a "Neu laden /
    Reload" button in the window instead of closing. That button reloads
    only on click.
  - "Nicht jetzt / Not now": closes without storing, so the window asks
    again at the next login.
  - "Nicht mehr fragen / Don't ask again": stores the answer and closes.
- Nothing is switched without a click. A module that is running stays
  running until the reload.

The settings code holds the module switch locally. Expose it to the core as
a documented internal function rather than copying it.

## Command

`/sempre vertraeglich` (aliases `compat`, `kompatibel`):

- prints the detected addons and each open suggestion in one line each,
  then opens the window even if it was answered;
- with nothing detected: "Weder EllesmereUI noch Naowh Forever gefunden." /
  "Neither EllesmereUI nor Naowh Forever found.";
- with nothing open: "Keine doppelten Funktionen." / "No doubled functions."

Add the command to the README table and to `/sempre` help.

## Data

`SempreDB.global.compatAnswered` (string), through the existing defaults.
No new SavedVariables, nothing about other players.

## Not in scope

- Switching anything in the other addons, or reading their saved data.
- Detecting other addons (Auctionator, Baganator, Questie, TomTom, Leatrix
  and so on). Add them later as table rows if needed.
- Automatic switching.

## Acceptance checks

- `luacheck .` clean, `lua5.1 tests/run.lua` passes.
- New offline tests in `tests/compat.lua` with a stubbed addon list cover:
  - **Detection:**
    - EUI by folder name and by a colour-coded title;
    - NF in the spellings "NaowhForever", "Naowh Forever" and "NaowForever";
    - an unloaded EUI does not count;
    - Sempre folders are never matched.
  - **Rules:**
    - each rule appears only with its addon;
    - Butler sell and repair appear with either addon;
    - rows whose target is already off are hidden;
    - an option row of a module that is enabled but not loaded still
      shows;
    - option rows of a switched-off module are hidden.
  - **When it opens:**
    - opens once after login;
    - not in combat, but at combat end;
    - waits for the news window;
    - not again after "Don't ask again" with the same addon set;
    - again when NF is added to an answered "eui" set;
    - again after "Not now";
    - not with the option off.
  - **Switching:**
    - switches only the checked rows;
    - modules through the shared module switch, options through
      `SetOption`;
    - reload line and button only when a module was switched off;
    - info rows have no checkbox.
  - **Command:** `/sempre vertraeglich` output for nothing found, nothing
    open, and open rows.
  - **Strings:** German and English by client language.
