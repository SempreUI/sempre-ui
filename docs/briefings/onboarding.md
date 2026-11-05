# Briefing: onboarding (core)

Status: ready to build, 2026-11-05. Part of the core, no new module. Decided
with the owner: SempreUI must be understood by anyone within two minutes of
the first login, without reading the README. The study of other addons'
setup flows (survey in the roadmap doc of 2026-11-05) only shaped the
behaviour below; nothing of their code, names, texts or layout is to be
reproduced. It can be built before Sempre_Market, because it touches only
the core.

## Purpose

A new player installs SempreUI and today sees one chat line. The onboarding
gives three things: a short assistant that picks modules for the player's
role, one hint at the place where a module first matters, and a help command
that lists what exists. It stays small: no option pages, no links, nothing
that must be clicked away before playing.

## Behaviour

1. **Assistant** (`/sempre start`, alias `setup`, `einrichten`). Opens once
   by itself on the first login of the account (`SempreDB.global.setupSeen`
   is nil), a short delay after entering the world, never in combat (then at
   combat end), and only after the "what's new" window would have closed
   (first install never shows "what's new", so in practice the assistant is
   the only window). Closing the window at any step stores the current addon
   version as seen; the assistant never opens by itself again, unless a later
   version adds modules that did not exist when it was last seen (compare the
   stored list of module names with the current one; then it opens once more
   and shows only step 2). The command opens it at any time.
   Four steps, each skippable with "Weiter" / "Next", and "Zurück" / "Back":
   - **Step 1, welcome.** One sentence what SempreUI is (gold, professions,
     all your characters), one sentence that everything is a module you can
     switch off, and the note that `/sempre start` reopens this window. The
     language follows the client (German or English, like all strings).
   - **Step 2, role.** Four buttons: "Main" (plays and farms: Items, Ledger,
     Loot, Mail, Market, Craft, Butler, Rares, Way), "Bank-Twink" / "Bank
     alt" (sells and mails: Items, Ledger, Mail, Market, Butler, Whisper),
     "Farmer" (Items, Loot, Market, Way, Map, Rares), "Alles" / "Everything".
     A click fills a checkbox list of all modules (every addon folder whose
     TOC carries `X-Sempre-Module: 1`, sorted by title, with the TOC notes
     as a second line) with the role's set; the player can change any box.
     Modules that are not installed (folder missing) are not listed. "Weiter"
     applies the boxes through the core's existing enable path (loads
     switched-on modules at once, switched-off ones stop after `/reload`,
     and the window says so). Nothing changes before "Weiter".
   - **Step 3, tooltip lines.** Three checkboxes that map to existing or
     planned options: owners in the item tooltip (Sempre_Items), market line
     (Sempre_Market), craftable line (Sempre_Craft). Boxes of modules that
     are not switched on are shown greyed with "(Modul aus)". Values go
     through `SempreUI:RegisterOptions` keys, nothing else.
   - **Step 4, done.** The three most useful commands for the chosen role
     (for example `/sempre gold`, `/sempre markt`, `/sempre post`), one tip
     for the first evening ("Öffne das Auktionshaus einmal, dann kennt
     SempreUI die Preise" / "Open the auction house once ..."), and
     `/sempre hilfe`. Button "Fertig" / "Done".
   Window in the SempreUI style: centred, movable, dark background, 1 px
   copper border, title font role for the title, text role for the rest,
   Escape closes (special-frames list, feature-checked). Built only the
   first time it opens; about 60 lines of strings in `L`.
2. **Hints at the place.** The first time an account opens the auction house
   (`AUCTION_HOUSE_SHOW`), a profession window (`TRADE_SKILL_SHOW`), the
   mailbox (`MAIL_SHOW`) and loots a mob (`LOOT_OPENED` with a creature
   source), the core prints one chat line in the copper colour: what SempreUI
   does here and the command that belongs to it (for example "SempreUI: Der
   Scan-Knopf merkt sich die Preise, /sempre markt zeigt sie"). The text
   names only modules that are switched on; when the module for this place
   is off, the line says which module would help and how to switch it on.
   Each hint exactly once per account (`SempreDB.global.hints[key] = true`),
   never in combat (skip, do not queue), never more than one hint per
   minute. Option "Hinweise beim ersten Besuch" / "First-visit hints"
   (core, default on). The hint texts live in the core, not in the modules,
   so an unloaded module can still be named.
3. **Help.** `/sempre hilfe` (`help`) prints the commands grouped by module,
   one line per module in the form "/sempre gold – Gold-Journal, Verkäufe,
   Käufe", loaded modules first, then switched-off modules marked "(aus)".
   `/sempre hilfe <modul>` prints that module's sub-commands with one line
   each. The texts come from a small per-module registration
   (`SempreUI:RegisterHelp(moduleName, lines)` from the module's own
   `ADDON_LOADED`; the core keeps a fallback line per known module for the
   "(aus)" case). `/sempre` without an argument prints the role-independent
   five lines and points to `/sempre hilfe`.
4. **Readable results.** A rule for every module, written into
   `docs/briefings/README.md`: every value that is estimated or old carries
   its source and age in the same line ("Markt vor 3 Std", "ca.", "Händler",
   "Auctionator"). The onboarding build adds the sentence; the modules follow
   it as they are built or touched.
5. **README.** A section "Erste Schritte / First steps" with the four steps
   of the assistant and the three commands per role, above the module
   table. The "what's new" data gets a line for the assistant in the next
   release entry.

## Loading and saved data

Core only (`Sempre/Onboarding.lua`, listed in `Sempre.toc` after
`Settings.lua`). Saved in `SempreDB.global`: `setupSeen` (version string),
`setupModules` (list of module names seen by the assistant), `hints`
(table of keys). The core stays under 300 KB; the window is built lazily.

## Forever notes

No secret values are touched. The assistant never reloads the UI by itself
and never calls protected functions; module changes go through the existing
enable path of the settings window.

## Not in scope

Per-character module choices, profiles, import or export of settings, a
tutorial that moves frames, any window that opens again on every login.

## Acceptance checks

- `luacheck .` clean, `lua5.1 tests/run.lua` passes; new `tests/onboarding.lua`.
- Tests cover: assistant opens once on first login and not again; reopens
  once when a new module name appears; not in combat, then at combat end;
  role buttons fill the boxes and "Weiter" applies them through the enable
  path (nothing applied before); step 3 maps to option keys and greys
  unloaded modules; step 4 texts per role; each hint once per account, one
  per minute, skipped in combat, option off silences them, hint for a
  switched-off module names it; `/sempre hilfe` grouping, loaded first,
  "(aus)" marking, sub-command listing, unknown module message; strings
  exist in both languages.
- In the live client (Oliver): delete `setupSeen` once, log in, run through
  the assistant as "Bank-Twink", open the auction house and the mailbox for
  the hints, `/sempre hilfe`.
