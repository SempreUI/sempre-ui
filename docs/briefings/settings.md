# Briefing: settings window (core)

Status: ready to build, 2026-10-22. Decided with the owner: one switch per
module plus only the options that are really needed, no pages of sliders.

## Purpose

SempreUI is "modules of your choice". The player needs one place in the game's
own settings menu to see every SempreUI module, switch it on or off, and set
the few options a module offers. Everything stays usable by slash command too.

## Behaviour

1. **Where.** One category "SempreUI" in the game's settings menu (Esc,
   Options, AddOns tab), registered through the `Settings` API from the core's
   login work. Feature-detect the API; if it is missing, `/sempre optionen`
   prints the module list with on/off state and the commands to change it.
2. **Opening.** `/sempre optionen`, `/sempre options` and `/sempre config` open
   the category. If the player is in combat, print a short note and open it
   once combat ends (the settings frame may be protected in combat).
3. **Main page: modules.** One row per SempreUI module (every addon folder
   whose TOC carries `X-Sempre-Module: 1`; the core's existing module list),
   sorted by title. Each row shows: title (TOC title without colour codes),
   the TOC notes in the client's language as a tooltip or second line, a
   checkbox "an/on", and a state word: "geladen/loaded", "aus/off", or
   "nach /reload/after /reload" when the checkbox differs from what is
   actually running.
   - Switching **on** an off module enables it for all characters and loads it
     right away if it is load-on-demand and not loaded (through the core's
     existing load path, which also records the load cost). No reload needed.
   - Switching **off** a loaded module disables it for all characters; it keeps
     running until the next reload. The page then shows a "Neu laden/Reload"
     button that calls the game's reload. Never reload without the click.
   - The core itself has no checkbox.
   - Enable state is account-wide (all characters) for now. Per-character
     choices are out of scope.
4. **Module option pages.** A module may register options through a small
   documented core interface (see "Interface"). Each module with options gets
   a subcategory page under SempreUI, titled with the module title. Options of
   a module that is not loaded are not shown (its code is not there); its row
   on the main page says so in the tooltip.
5. **Option kinds:** checkbox (true/false) only in this version. Each option
   has a key, a default, a German and an English label and an optional
   tooltip. Values are stored in the core's saved variables (account-wide,
   `SempreDB.global.options[moduleName][key]`), only when they differ from
   the default.
6. **First options** (the modules register these themselves; tests cover each):
   - Core: "Begrüßung im Chat beim Login / Login message in chat" (default on)
     controls the existing "loaded" line.
   - Sempre_Items: "Besitz im Item-Tooltip / Owners in the item tooltip"
     (default on).
   - Sempre_Loot: "Wert pro Kill im Gegner-Tooltip / Value per kill in the unit
     tooltip" (default on).
   - Sempre_Ledger: no options yet, so no subpage.
7. **Changes apply at once.** Reading an option is a table lookup each time
   (cheap; tooltips call it often), and the core sends message
   `OPTION_CHANGED` with module name, key and new value.
8. **Slash fallback.** `/sempre modul <name> an|aus` and `/sempre module <name>
   on|off` do the same as the checkbox (name without the `Sempre_` prefix,
   case-insensitive). `/sempre modul` alone lists modules and state.
9. **Help text.** Add the new commands to the core's help line in both
   languages.

## Interface (read-only for other modules, documented in Core.lua)

- `SempreUI:RegisterOptions(moduleName, list)`: list of `{ key, default,
  label = { de, en }, tooltip = { de, en }? }`. Call from the module's own
  `ADDON_LOADED`. Calling it twice for the same module replaces the list.
- `SempreUI:GetOption(moduleName, key)`: stored value or the default.
- `SempreUI:SetOption(moduleName, key, value)`: stores, sends
  `OPTION_CHANGED`.

## Data

`SempreDB.global.options` added through the existing defaults mechanism; no
version bump needed if missing tables are created on load.

## Budget and style

Core stays under its 300 KB budget; the settings page is built only the first
time it is opened or on login after `PLAYER_LOGIN`, not before. All strings
in the core's `L` tables, German first. Copper accent for the category title.
No new globals beyond `SempreUI` and the slash globals that already exist.

## Forever and API notes

- Use the vertical-layout settings category and its checkbox controls where
  they exist; a canvas page is acceptable if those are missing. Detect both.
- `C_AddOns.EnableAddOn` / `C_AddOns.DisableAddOn` with no character means
  all characters on this client; feature-detect.
- Do not touch Blizzard frames outside the core's own `ADDON_LOADED` or login
  work.

## Not in scope

Profiles, per-character module choices, sliders, colour pickers, frame
movers, import/export.

## Acceptance checks

- `luacheck .` clean, `lua5.1 tests/run.lua` passes. New offline tests in
  `tests/settings.lua` with a stubbed `Settings` and `C_AddOns` API cover:
  category registered once; one checkbox per module, none for the core;
  switching on loads a load-on-demand module without reload; switching off
  disables it and marks "after /reload"; the reload button only after a
  change; options stored only when different from default; `GetOption`
  default; `OPTION_CHANGED` sent; the three first options act (login line
  hidden, item tooltip lines hidden, loot tooltip line hidden); slash
  fallback `modul` on/off/list; missing Settings API falls back to chat;
  opening in combat waits for combat end.
