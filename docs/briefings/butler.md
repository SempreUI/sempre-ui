# Briefing: Sempre_Butler (comfort helpers), part 1

Status: ready to build, 2026-10-22. Owner's idea list (concept) plus the
comfort functions players name most for Forever (sell junk, repair, accept
resurrection, decline duels, quiet error text). Part 2 (sell / auction /
disenchant / send to alt / keep advice per item) comes after launch.
All `C_` names and events below are in `tools/api-forever.txt` (build 1.60.1)
unless marked as a plain global.

## Purpose

Small chores done for the player, each switchable, all visible in chat with
one short line so nothing happens silently.

## Behaviour

1. **Sell junk at the merchant** (option, default on). When a merchant opens,
   sell every grey-quality item in the bags that has a vendor price (item
   info, 11th value) and is not locked. Sell them one at a time through the
   container use function (`C_Container.UseContainerItem` on bag and slot),
   not through the game's "sell all junk" call, so the gold journal sees each
   item (its hook books vendor income per item). One item every 0.2 seconds
   from an own frame's update with a time accumulator, at most 60 per visit;
   stop at once when the merchant closes or combat starts. Done: one line
   "Schrott verkauft: N Gegenstände für 1g 23s 45c" / "Junk sold: N items for
   ...", computed from the vendor prices. Hold Shift while opening the
   merchant to skip selling this visit.
   Never sell: items on the player's keep list (below), non-grey items, items
   without a vendor price.
2. **Repair** (option, default on). When a merchant that can repair opens
   (plain globals: can-merchant-repair, repair-all cost, repair-all; feature
   check each), repair everything if the cost is above zero and the player
   has the money; else one line saying how much is missing. Option "Gildenbank
   für Reparaturen nutzen / Use guild funds for repairs" (default off): when
   on and the guild bank allows it (plain globals for guild repair; feature
   check), repair from guild funds first. One line with the cost and the
   source. The gold journal already books repairs (it hooks the repair call);
   make sure the order (repair before or after selling) does not confuse it:
   repair first, then start selling.
3. **Accept resurrection** (option, default off). On `RESURRECT_REQUEST`,
   if the player is not in combat, accept it after 1 second (plain global
   accept function; feature check). Not if the player is in a battleground or
   arena (instance type check). One line "Wiederbelebung angenommen" /
   "Resurrection accepted". The caster's name may be a secret value: display
   only, never compare or store.
4. **Decline duels** (option, default off). On `DUEL_REQUESTED`, decline at
   once (plain global cancel-duel function; feature check), one line per
   request at most every 10 seconds so spam does not flood the chat.
5. **Quiet error text** (option, default off). Hide the red error messages in
   the middle of the screen ("not enough energy", "out of range" and the
   like) by unregistering the error frame from `UI_ERROR_MESSAGE` while the
   option is on, and registering it again when it is switched off. Do this
   from the module's own `ADDON_LOADED` and on option change only; the error
   frame must exist (feature check). These are game messages, not Lua
   errors, so the error collector is not affected.
6. **Keep list.** `/sempre butler behalten <item link or ID>` / `keep ...`
   adds an item to a per-account keep list (never sold); `... weg <item>` /
   `remove` takes it off; `/sempre butler` alone prints the state of all
   options and the keep list.
7. **Options** through `SempreUI:RegisterOptions`, one checkbox each for 1 to
   5 and the guild repair option.
8. **Messages:** `BUTLER_SOLD` (count, copper) after a selling run,
   `BUTLER_REPAIRED` (copper, source) after a repair.

## Saved data

Own SavedVariables `SempreButlerDB` with `version` and `keep = { [itemID] =
true }`. Nothing about other players.

## Loading

Reacts to merchant and resurrection events at any time:
`## X-Sempre-LoadWith: Login`, login work in its own `ADDON_LOADED` (see
CLAUDE.md). Budget 40 KB. Folder `Sempre_Butler`, TOC `Sempre_Butler.toc`
with IconTexture and notes in both languages, `.pkgmeta` line, LICENSE and
NAMING.md copies.

## Events

Through `SempreUI:On`: `MERCHANT_SHOW` and `MERCHANT_CLOSED` (and the
interaction manager show and hide events where the merchant type is given;
use whichever the module finds valid with `C_EventUtils.IsEventValid`, never
both for the same visit), `RESURRECT_REQUEST`, `DUEL_REQUESTED`,
`PLAYER_REGEN_DISABLED`.

## Forever and API notes

- Bag contents from `C_Container` (number of slots, item info per slot with
  quality, link, locked state and item ID).
- Selling through the container use function only while the merchant is
  open; with the merchant closed the same call would use or equip the item,
  so check the merchant is still open before every single sale.
- Item quality and vendor price may be uncached: skip such an item this
  visit rather than wait.
- No secret values are used in logic.

## Not in scope

Selling non-grey items, buying reagents, auto-loot, summon accepting, group
invite handling, "delete cheapest item", the per-item advice of part 2.

## Acceptance checks

- `luacheck .` clean, `lua5.1 tests/run.lua` passes. New offline tests in
  `tests/butler.lua` with stubbed bags and merchant cover: greys with a price
  are sold one per tick, others and keep-list items are not; Shift skips;
  stop on merchant close and on combat; cap of 60; summary line with the
  right total; repair before selling, with and without guild funds, and the
  "not enough money" line; accept resurrection only out of combat and not in
  battlegrounds, after the delay; duel declined and the chat line throttled;
  error frame unregistered and registered again with the option; every
  option off means nothing happens; keep list add, remove and print;
  `BUTLER_SOLD` and `BUTLER_REPAIRED` sent; a missing API function disables
  only its feature with one line.
