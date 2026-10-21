# Briefing: Sempre_Ledger (gold journal), part 1

Status: ready to build, 2026-10-21. Part 2 (auction house sales per item from
mail invoices, purchases) follows after the beta probe.

## Purpose

Show where each character's gold comes from and where it goes, per day and per
session, and how much gold each item earned when sold to a vendor. Base for
the later profit-per-item view (vendor versus auction house).

## Behaviour

1. **Every money change is booked.** On each money change, the difference to
   the last known amount is one booking with a source. The first reading after
   login only sets the baseline (no booking). A difference while the module did
   not run (other addon, deleted data) must not appear as income.
2. **Source by context**, decided at the moment of the change, first match
   wins:
   - `vendor`: a merchant window is open. Split into `repair` when the change
     follows a repair (the game's repair functions, hooked after the call)
     and `vendor` otherwise.
   - `mail`: the mailbox is open (money taken from mail, postage paid).
   - `auction`: the auction house is open (deposits, buyouts).
   - `trainer`: a trainer window is open.
   - `flight`: a flight master window is open, or the change happens within
     a few seconds after taking a flight.
   - `quest`: a quest was turned in within the last second.
   - `loot`: the loot window is open, or within a second after it closed.
   - `trade`: the trade window is open.
   - `guildbank`: the guild bank is open.
   - `other`: everything else.
   Open and close states come from the interaction-manager show/hide events
   where they exist, with the classic window events as fallback. Check event
   validity with `C_EventUtils.IsEventValid` before registering optional
   events (see Sempre_Items for the pattern).
3. **Transfers between own characters are not profit.** Money sent by mail to
   a character of the same account (known from `SempreItemsDB.chars`, if
   Sempre_Items is loaded; otherwise from Sempre_Ledger's own character list)
   is booked as `transfer`, both on the sending side and when the receiving
   character takes it from the mail. The receiving side recognises it when the
   mail sender is one of the own characters. Store no names of other players.
4. **Vendor sales per item.** While a merchant is open, selling an item from
   the bags (the container use function, hooked after the call) records item
   ID, count and the vendor price from item info (sell price times count).
   Book it per character per day as `vendorItems[itemID] = {count, copper}`.
   Buyback within the same merchant visit reverses it. If item info is not
   cached yet, request it and fill in the price when it arrives.
5. **Storage:** own SavedVariables `SempreLedgerDB`, `version` field with
   migrations. Per character and per day (`YYYY-MM-DD`, local date) a table of
   `income[source]` and `expense[source]` in copper, plus `vendorItems`. Keep
   90 days, drop older days at login.
6. **Session:** starts at login, survives `/reload` (keep start time and start
   money if the last session ended less than 15 minutes ago). Session income,
   expense and gold per hour.
7. **Command `/sempre gold`** (alias `/sempre ledger`), through the core's
   commands table:
   - default: this session (net, gold per hour), today and last 7 days for
     this character, by source, largest first;
   - `alle` / `all`: last 7 days net per character and total;
   - `items`: top 10 items by vendor income in the last 30 days.
   Money formatted as `12g 34s 56c`, in copper colour for the totals.
8. **Interface for later modules:** `SempreUI.Ledger.GetDay(charKey, date)`,
   `GetRange(charKey, days)`, `GetSession()`; message `LEDGER_CHANGED` with
   char key and source after each booking.
9. **Combat:** money changes in combat (loot) are booked normally; no extra
   work is queued.

## Loading

Must see every money change, so `## X-Sempre-LoadWith: Login`, login work in
its own `ADDON_LOADED` (see CLAUDE.md). Optional dependency on Sempre_Items
only through `SempreItemsDB` being present; never require it. Budget 100 KB.
Folder `Sempre_Ledger`, TOC `Sempre_Ledger.toc`, `.pkgmeta` line, LICENSE and
NAMING.md copies like Sempre_Items.

## Forever and API notes

- Money is not a secret value; still guard with `issecretvalue` where a value
  could be (names in mail headers). Never compare a secret sender name.
- Hooks with `hooksecurefunc` only, from the module's own `ADDON_LOADED`.
  Feature-detect every hooked function; a missing one turns off that part.
- Mail functions are plain globals without a `C_` replacement; allowed.

## Not in scope

UI windows, charts, auction house invoices per item, purchase prices,
exports. Those come in part 2 or separate modules.

## Acceptance checks

- `luacheck .` clean, `lua5.1 tests/run.lua` passes. New offline tests with a
  stubbed API cover: baseline without booking at login; each source by
  context; repair split; flight and quest windows; transfer both ways; vendor
  item sale and buyback; late item price; day roll-over and 90-day pruning;
  session surviving a reload and a new session after 15 minutes; `/sempre
  gold` output for all three forms.
