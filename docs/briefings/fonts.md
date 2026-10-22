# Briefing: SempreUI fonts (core), part 1

Status: ready to build, 2026-10-22. The fonts were chosen in the concept and
are in the repo as static TrueType files under `Sempre/Media/Fonts/`, made
from the official variable fonts (all SIL Open Font License 1.1, licence texts
next to them, no reserved font names):

- `Grenze-SemiBold.ttf`: headings and titles.
- `AtkinsonHyperlegibleNext-Regular.ttf` and `-Bold.ttf`: body text.
- `AtkinsonHyperlegibleMono-Regular.ttf`: numbers in lists (money, counts,
  coordinates), so columns line up.

All four cover German umlauts, ß, € and typographic quotes. They have no
Cyrillic, Korean or Chinese glyphs.

## Purpose

SempreUI should look like itself: one recognisable heading font and a very
readable text font in every SempreUI window, and, if the player wants, in the
game's own interface too.

## Behaviour

1. **Font interface in the core** (read-only for modules, documented in
   Core.lua): `SempreUI.Fonts` with a path per role (`title`, `text`,
   `bold`, `mono`) and a call `SempreUI:SetFont(fontString, role, size,
   flags)` that applies the role's file, the size (default per role: title
   14, text 12, bold 12, mono 12) and flags (default none; title gets a thin
   shadow through the font string's shadow, not an outline). If the role is
   unknown, or SempreUI fonts are switched off, or the client language has no
   glyphs in these fonts, it applies the game's standard font file at the
   same size instead. Modules never hard-code font paths.
2. **Language guard.** For the client languages `ruRU`, `koKR`, `zhCN` and
   `zhTW` the SempreUI fonts are never used (they would show empty boxes);
   the option below is shown but greyed out with a tooltip saying why.
3. **Use in SempreUI windows.** Switch the existing own windows to the
   interface: the settings page title (title role), the mail panel (title,
   text for rows, mono for money and days), and the waypoint and button
   panels where they show text. No layout changes beyond what the new sizes
   need.
4. **Option "SempreUI-Schriften / SempreUI fonts"** (core, default on): off
   uses the game's fonts everywhere through the same call. Applies at once to
   windows that are open or built later (listen for `OPTION_CHANGED` and
   re-apply to the font strings the core knows about; a module may register
   its font strings with the core for this, or re-apply on its own listen).
5. **Option "Auch Spielschriften ersetzen / Replace game fonts too"** (core,
   default off): replaces the font file of the game's common font objects
   (normal, highlight, small, large, headers, tooltip header and text, chat
   frame font objects, quest text) with the text or title role, keeping each
   object's size, flags and colour. Names of the objects are read from the
   game and feature-checked; a missing object is skipped silently. Done once
   at login work and when the option changes; switching it off restores the
   original font files remembered before the first change. Damage numbers and
   nameplates are not touched in this part. A note in the option tooltip
   says some frames update only after `/reload`.
6. **`/sempre schrift`** (alias `font`): prints which fonts are active, the
   client language and whether game fonts are replaced,
   as plain text in chat.

## Data

Two options in `SempreDB.global.options.Sempre` through the existing options
interface. No new SavedVariables.

## Files and packaging

The font files and their three licence texts (`OFL-Grenze.txt`,
`OFL-AtkinsonHyperlegibleNext.txt`, `OFL-AtkinsonHyperlegibleMono.txt`) are
already in `Sempre/Media/Fonts/`. Make sure `.pkgmeta` does not ignore them.
Mention the fonts and their licence in README.md (one short section: the
font files are OFL 1.1, the code is GPL 3.0). Core budget stays under 300 KB
of memory; font files are on disk and do not count.

## Forever and API notes

- Font strings take a file path, a size and flags; check the return of the
  set call (it reports failure when a file cannot be loaded) and fall back to
  the game font on failure, printing one line once.
- The game's standard font path comes from its standard font global; feature
  check it, and use a known game font path only as a last fallback.
- Font object changes are allowed out of combat and in combat (they are not
  protected), but do them at login work and on option change only, never per
  frame.
- No globals: no named font objects are created; use the set call on font
  strings and on the game's existing font objects.

## Not in scope

Font size sliders, a font picker, other fonts, damage text, nameplates,
unit frames, chat bubbles.

## Acceptance checks

- `luacheck .` clean, `lua5.1 tests/run.lua` passes. New offline tests in
  `tests/fonts.lua` with stubbed font strings and font objects cover: each
  role's path and default size; flags; option off gives the game font; each
  guarded language gives the game font and the greyed option; failed load
  falls back once with one line; game font replacement keeps size and flags,
  skips missing objects and restores the originals when switched off;
  `OPTION_CHANGED` re-applies to registered font strings; mail panel uses
  title, text and mono roles; `/sempre schrift` output.
