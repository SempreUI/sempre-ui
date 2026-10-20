# Briefing: Sempre_Items (item data engine)

Status: draft, 2026-10-20. To be checked against the probe results from the
Forever stress test on 2026-10-21 before building. Open points are marked
**[probe]**.

## Purpose

Sempre_Items remembers what every character owns and where: bags, bank, mail,
equipped gear and gold. It is the base for the alt overview, bags, mail
overview, gold journal and auction house modules. On its own it adds one
visible feature: item counts per character in the item tooltip.

## Who uses it

- The player, through the tooltip line and `/sempre items`.
- Other SempreUI modules, through a small read-only interface (below).

## Behaviour

1. **Scan on change, not on a timer.** Rescan a location only when the game
   says it changed, and only the bags that changed where the API allows it.
   Coalesce bursts: many bag events in one frame lead to one scan.
2. **Locations:**
   - Bags: backpack, the four bag slots, and the reagent bag if the client has
     one. Always readable.
   - Bank: only readable while the bank is open. Save a snapshot when it opens
     and on every bank change while open. Keep the last snapshot when closed.
   - Mail: only readable while the mailbox is open. Save every mail's items,
     attached gold and days left. Keep the snapshot with the time it was taken,
     so the alt overview can warn about mail that expires soon.
   - Equipped: all inventory slots, rescanned on equipment change.
   - Gold: on login and on every money change.
   - An account-wide bank, if Forever has one **[probe]**. Feature-detect it;
     if missing, skip silently.
3. **Characters:** key is `Name-Realm`, read once at login from the core
   (`SempreUI.charKey`). Also store class, faction, level and the time of the
   last update, for the alt overview.
4. **Tooltip:** For items that any character owns, add one line per character
   with the total and the split by location, e.g.
   `Bankie: 20 (bank 15, mail 5)`, plus a total line when more than one
   character owns it. Current character first, then by count. Class colour for
   the name. Cap at 8 characters, then "+N more". No line for soulbound
   quest items with count 0. Cache the per-item result until the data changes.
5. **Command:** `/sempre items` prints gold per character and the total, and
   the age of each bank and mail snapshot.
6. **Combat:** item data is not secret, but do no full scans in combat; queue
   them and run after `PLAYER_REGEN_ENABLED`. Tooltip lookups stay allowed.

## Saved data

Own SavedVariables `SempreItemsDB`, so the core stays small:

- `version` (number, start at 1, migrate on change)
- `chars[charKey]`: `class`, `faction`, `level`, `money`, `updated`,
  and per location (`bags`, `bank`, `mail`, `equipped`, `account` if any)
  a map of item ID to count, plus the snapshot time.
- Store an item link only when it carries more than the item ID (random
  suffix "of the Bear", enchant), as a separate map of item ID to a short
  list of such links. Plain items need no link.
- Mail additionally keeps per mail: sender type (auction house, player,
  system), gold, days left, item IDs and counts. No sender names of other
  players in shared exports later; storing them locally is fine.

Keep it small: numbers and short strings only, no tables per slot.

## Interface for other modules

Read-only functions on `SempreUI.Items`:

- `GetCount(itemID)`: total over all characters, and a table per character
  and location. Must not allocate a new table per call on the hot path
  (tooltip); reuse or cache.
- `GetChars()`: iterator over character keys with class, faction, level,
  money and snapshot ages.
- `GetMail(charKey)`: list of saved mails with days left.

Change notification: the core gets a tiny message bus, `SempreUI:Send(msg, ...)`
and `SempreUI:Listen(msg, fn)`, separate from game events. Sempre_Items sends
`ITEMS_CHANGED` with the character key and location after each scan.

## Loading

Item data must be current all the time, so Sempre_Items is not loaded on
demand like other modules: the core loads every enabled module that has
`## X-Sempre-LoadWith: Login` right after `PLAYER_LOGIN`. Add that to the core
as part of this work. Budget 150 KB with a dozen characters.

## Forever and API notes

- Use `C_Container.*` and `C_Item.*`; no removed globals.
- Bank layout: the 12.x client uses bank tabs, classic used bank bag slots.
  Which one Forever uses decides how the bank is read **[probe]**. Discover the
  bag indices at runtime from `Enum.BagIndex` and feature-detect `C_Bank`;
  do not hard-code IDs.
- Mail: `GetInboxNumItems` returns shown and total count; the server shows
  at most 50 at a time **[probe]**. Days left come from the header info.
- Item info can arrive late for items not yet cached; request it and fill in
  the name on `ITEM_DATA_LOAD_RESULT` instead of storing nil.

## Not in scope

Bag UI, sorting, search, alt overview window, gold journal, auction prices.
These are separate modules that use this engine.

## Acceptance checks

- `luacheck .` clean.
- Fresh character: log in, `/sempre items` shows the character with gold.
- Pick up an item: tooltip count changes without reload.
- Open the bank, close it, log out and in: bank counts still in the tooltip.
- Open the mailbox with an AH mail: mail counts and days left saved.
- Second character on the same account: tooltip shows both characters.
- Twenty bag events in one second cause one scan (count scans in debug mode).
- `/sempre perf`: Sempre_Items under budget with three characters.
