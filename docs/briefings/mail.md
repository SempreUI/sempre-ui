# Briefing: Sempre_Mail (mail overview), part 1

Status: ready to build, 2026-10-22. The stress test confirmed the mail events
and inbox functions exist; auction house invoices were not seen yet (empty
auction house), so everything about invoices must be feature-checked and is
verified after launch.

## Purpose

See every mail at a glance instead of opening letters one by one, take money
and items quickly, and never lose mail because it expired on a character the
player has not logged in for a while.

## Data source

Sempre_Items already snapshots each character's inbox while the mailbox is
open and keeps per mail: kind (auction house sale, other auction house mail,
player, system), money, days left at snapshot time, items with counts, and
the snapshot time. Sempre_Mail reads it only through the documented read-only
interface `SempreUI.Items` (`GetMail`, `GetChars`, `GetName`) and listens for
`ITEMS_CHANGED`. It never reads `SempreItemsDB` directly. If Sempre_Items is
not loaded, the module prints one line at login and stays off.

For the open mailbox the module reads the inbox functions itself (headers,
items, invoice info), because it needs live indexes to take mail.

## Behaviour

1. **Inbox list.** While the mailbox is open, show a panel docked to the
   right of the game's mail frame (moves and hides with it). One row per mail
   in the inbox, sorted by days left (soonest first):
   - a small type marker: auction sale, auction other (outbid, expired,
     cancelled), player, system or cash-on-delivery (COD);
   - the first item's icon and count, "+N" when the mail has more items;
   - money in copper colour (`12g 34s 56c`), or the COD amount in red with
     "COD";
   - days left: whole days, or hours when under one day; red when under 3
     days;
   - the sender as the game shows it (display only, never compared).
   A total row at the bottom: total money, total item count, "shown / total"
   mails. If the server holds more mails than the inbox shows, say how many
   are waiting and that they appear after taking some (the game refreshes the
   inbox about once a minute; do not spam the refresh call).
2. **Taking.** Clicking a row takes that mail's money and then its items.
   A button "Alles nehmen / Take all" takes all mails in list order:
   - one take action at a time, and the next only after the inbox has updated
     (or after a short timeout), so the server is never flooded;
   - money before items for each mail;
   - never pays cash on delivery: COD mails are skipped and counted in the
     summary;
   - stops when the bags are full and says so;
   - a second button state "Stopp / Stop" while running; closing the mailbox
     stops it;
   - a summary line in chat when done: money taken, items taken, mails
     skipped.
   A checkbox "nur Gold / gold only" next to the button limits "Take all" to
   money. Taking is player-initiated (a click starts it); nothing runs on its
   own when the mailbox opens.
3. **Expiry warning across characters.** At login, and after each inbox
   snapshot, check every character's mail snapshot from Sempre_Items: days
   left minus the days passed since the snapshot. If any mail on any
   character will expire within 3 days, print one chat line per character:
   name, number of mails and the earliest expiry ("Bankie: 4 Briefe, erster
   läuft in 2 Tagen ab"). Do not warn about the current character while its
   mailbox is open. At most once per character per login.
4. **Command `/sempre post`** (alias `/sempre mail`): per character with mail:
   count, money in mail, items in mail, earliest expiry, snapshot age; then a
   total line. Characters without a snapshot are listed as "nie geöffnet /
   never opened".
5. **Options** through the core's `SempreUI:RegisterOptions`: "Postliste am
   Briefkasten / Mail list at the mailbox" (default on) and "Warnung vor
   ablaufender Post / Warning about expiring mail" (default on).
6. **Interface for later modules:** none needed yet. Send message
   `MAIL_TAKEN` with item ID (or nil for money), count and copper after each
   successful take, so the gold journal and others can listen.

## Loading

The expiry warning must run at login, so `## X-Sempre-LoadWith: Login`, with
the login work in the module's own `ADDON_LOADED` (see CLAUDE.md). Budget 80
KB. Folder `Sempre_Mail`, TOC `Sempre_Mail.toc` with IconTexture like the
others, `.pkgmeta` line, LICENSE and NAMING.md copies. Build the panel only
the first time the mailbox opens.

## Events

Mailbox open and close through the interaction-manager show and hide events,
with the classic mail show and close events as fallback (check validity with
`C_EventUtils.IsEventValid`, as Sempre_Items does). Inbox updates, bag
updates (to detect full bags) and money changes. All through `SempreUI:On`.

## Forever and API notes

- The inbox functions are plain globals without a `C_` replacement; allowed.
  Feature-detect each one; a missing take function disables that button with
  a tooltip saying why.
- Sender names may be secret values: display only, guard with
  `issecretvalue` before any string work, never compare.
- Item info may not be cached: request it and fill the icon in when it
  arrives.
- Free bag space comes from `C_Container` functions.
- No frame of the game is modified; the panel is the module's own frame
  anchored to the mail frame, created after the mail frame exists.

## Style

Copper accent `#C8794A` for titles and money; the game's standard fonts until
the font module exists. Panel height follows the mail frame; rows scroll when
there are more than fit. German first in the `L` tables.

## Not in scope

Sending mail, mail templates, deleting mail, opening letters with text,
auction house invoice details per item (that is gold journal part 2), mail
history.

## Acceptance checks

- `luacheck .` clean, `lua5.1 tests/run.lua` passes. New offline tests in
  `tests/mail.lua` with a stubbed API cover: list sorted by days left with the
  right markers; total row and "more waiting" count; click takes money then
  items; "Take all" one action per inbox update, skips COD, stops on full
  bags, stops on close, prints the summary; "gold only"; expiry warning from
  another character's snapshot with elapsed days, once per login, not for the
  open mailbox; `/sempre post` output with "never opened"; both options act;
  missing Sempre_Items keeps the module off with one line; a secret sender
  name is shown without error; `MAIL_TAKEN` sent.
