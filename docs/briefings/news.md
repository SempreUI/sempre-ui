# Briefing: "Was ist neu / What's new" window (core)

Status: ready to build, 2026-10-22. Part of the agreed user channel: an
in-game "what's new" window, website release notes later.

## Purpose

After an update the player should see in a few lines what changed, in their
language, once, without links or advertising, and be able to open it again.

## Behaviour

1. **Data.** A Lua data file in the core, `Sempre/News.lua`, holds a list of
   releases, newest first: version string (same as the CHANGELOG heading,
   e.g. `0.1.0-alpha2`), date, and up to 8 short points, each with a German
   and an English text. No links, no player names, no monetisation hints
   (Blizzard policy and CLAUDE.md). Start with two entries: `0.1.0-alpha1`
   (items, gold journal, loot memory, error collector) and `0.1.0-alpha2`
   (settings window, mail overview, gold journal part 2, waypoints, minimap
   button collector, fonts). Write the texts from the merged PRs and the
   README; keep each point under 90 characters.
2. **When it opens.** At login work, compare the newest version in the data
   with the version the player last saw (`SempreDB.global.newsSeen`). If the
   data has a newer entry, open the window once after login (a short delay
   after entering the world, not in combat; if in combat, at combat end).
   A first install (no saved version at all) does not open it; it only stores
   the newest version, so new players are not greeted with a changelog.
   Closing the window stores the newest version as seen.
3. **Option** "Neuigkeiten nach Updates zeigen / Show what's new after
   updates" (core, default on). Off: never opens on its own; the newest
   version is still stored when the player opens it by command.
4. **Command** `/sempre neu` (alias `news`) opens the window at any time.
5. **Window.** A small movable frame in the centre: title "SempreUI – Was ist
   neu" in the title font role, then per release (newest first, all entries
   in the data, scrolling if needed) a heading with version and date and the
   points as a bulleted list in the text role. A close button, Escape closes
   it (register it in the game's special-frames list only if that list
   exists; feature-check). Copper `#C8794A` for headings, dark background with
   a 1 px copper border, like the minimap button panel. Built only the first
   time it opens.
6. **Feedback line.** Below the list one grey line: "Fehler oder Wünsche?
   GitHub-Issues: github.com/SempreUI/sempre-ui/issues" / "Bugs or wishes?
   GitHub issues: ...". This is the only link allowed in the game (CLAUDE.md);
   plain text, not clickable, no other URL anywhere.

## Release process note

When a new CHANGELOG entry is added for a release, a matching entry is added
to `Sempre/News.lua` in the same PR. Add one line saying so to
CONTRIBUTING.md (release section, or a new short one if none exists).

## Loading and budget

Core. Data file small (a few KB). Window built lazily. No new SavedVariables:
`newsSeen` lives in `SempreDB.global` through the existing defaults.

## Not in scope

Fetching news from the internet (impossible in the game), per-module news
pages, images.

## Acceptance checks

- `luacheck .` clean, `lua5.1 tests/run.lua` passes. New offline tests in
  `tests/news.lua` cover: opens once after an update; not on first install
  but stores the version; not again after closing; not with the option off;
  waits for combat end; `/sempre neu` opens it and stores the version; German
  and English texts by client language; entries newest first; a test that
  scans `News.lua` and every module's `L` tables for `http`, `www.` and
  `.com` and allows only the GitHub issues text (enforces the link rule).
