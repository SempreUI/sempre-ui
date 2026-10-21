# Briefing: Sempre_Loot (loot memory), part 1

Status: ready to build, 2026-10-21. Based on the beta stress test the same
day (probe 0.2.5): the loot source of every loot slot is readable after combat
and equals the looted corpse's GUID; item info returns the vendor sell price
as its 11th value; nameplate and target name, GUID and level are readable out
of combat; health is secret even out of combat.

## Purpose

Learn from the player's own looting what each mob and each gathering node
drops, how often, and what a kill is worth. Answer "where do I farm X?",
rank mobs by value per kill, and show the session's loot value and gold per
hour. No preloaded databases: everything comes from the player's own play.

## Behaviour

1. **A kill counts when the corpse is opened.** When the loot window opens,
   read every loot slot: item ID (from the slot's link), count, slot type
   (item or money) and the slot's sources (GUID and amount per source; one
   slot can have several sources with area loot). Each creature GUID that
   appears as a source is one looted kill, counted once per GUID for its
   lifetime. Keep a short-lived set of seen GUIDs (session only, capped,
   oldest dropped first) to deduplicate re-opening the same corpse.
2. **Kill loot versus gathering.** The first loot of a creature GUID is kill
   loot. A later loot of the same GUID (skinning, and anything else opened on
   an already looted corpse) is gathering loot of that creature, stored apart
   and counted as one "gather" of that creature. Sources that are not
   creatures (game objects: herbs, ore, chests, fishing) are gathering nodes,
   keyed by their object ID from the GUID, with the node's name taken from the
   loot target or tooltip when readable, else "node <id>".
3. **Mob identity.** The NPC ID is a field of the creature GUID; split it from
   the GUID string, never compare GUID parts as numbers before checking with
   `issecretvalue`. Remember the mob's name, level range and classification
   (normal, elite, rare) when they are readable: from the target or mouseover
   when its GUID matches, or from a nameplate. Names are only read out of
   combat, or after checking `issecretvalue`. Mob names are game data, not
   player names, and may be stored.
4. **Where.** Store kills per map ID (best map for the player at loot time)
   for each mob and node. "Where" answers list the maps with the most kills.
5. **Money.** Money slots carry no reliable number in their text. Book the
   money change that happens while the loot window is open (or within one
   second after it closes) to the money slot's source, split evenly when a
   slot has several sources. This must agree with Sempre_Ledger, which books
   the same change as `loot`; Sempre_Loot never books it a second time into
   the ledger.
6. **Roll items.** Items won or lost through a group roll count toward the
   drop rate of the mob but not toward the player's loot value. With no
   reliable roll result, count every item that was in the loot window for the
   drop rate, and only items that reached the bags (count change seen right
   after) for the value.
7. **Rates and reliability.** Drop rate per item = times dropped / looted
   kills. Show a rate as reliable from 20 kills (or 20 gathers) on; below,
   show the count only ("3 of 7 kills") in grey. Rates below 1 % with fewer
   than 100 kills are shown under "rare" and left out of the value per kill
   (outlier rule), so one lucky drop does not dominate the ranking.
8. **Value.** Value of an item = vendor sell price from item info (11th value)
   for now. If `SempreUI.Market` exists later, use its price instead (feature
   check, no hard dependency). Value per kill = money per kill + sum of item
   value times average count per kill, without rare outliers. Items whose
   info is not cached yet: request the data, show "?" until it arrives.
9. **Session.** Session starts at login and survives `/reload` under the same
   15-minute rule as Sempre_Ledger. Track kills, gathers, items and their
   value, money from loot. Gold per hour only after 5 minutes of session.
10. **Farm goals.** Up to 6 goals per character: item ID and target count.
    Progress uses the count the character owns (through the read-only
    `SempreUI.Items.GetCount` if Sempre_Items is loaded, else bag count from
    `C_Item.GetItemCount`). Estimate the time left from the item's drop rate
    and this session's kills per hour when both are known. A chat line when a
    goal is reached. Goals are per character; the knowledge tables are
    account-wide.
11. **Tooltip on mobs.** When the tooltip shows a unit whose GUID is readable
    and not secret, and the mob has at least one looted kill, add one line:
    value per kill and kill count, e.g. "Loot: 12s 40c per kill (34 kills)".
    Top 3 items by rate below it while Shift is held. Nothing in combat.
12. **Commands** through the core's commands table, `/sempre loot`:
    - no argument: this session (time, kills, gathers, money, item value, gold
      per hour) and progress of the farm goals;
    - `ziel <item link or ID> <count>` / `goal ...`: add or change a goal;
      `ziel weg <item>` / `goal remove <item>` removes it;
    - `wo <item link or name>` / `where ...`: mobs and nodes that dropped it,
      best rate first, with map name and kill count (top 5);
    - `mob` (current target, else the last looted mob): drop table, rate,
      value per kill, maps;
    - `top`: top 10 mobs by value per kill with at least 20 kills.
    All user-facing text through `L` tables, German first, then English.
13. **Interface for later modules** (read-only, documented in the module):
    `SempreUI.Loot.GetMob(npcID)`, `GetNode(objectID)`, `GetSession()`,
    `WhereDrops(itemID)`; message `LOOT_RECORDED` with the source key after
    each loot window.

## Saved data

Own SavedVariables `SempreLootDB` with `version` and migrations:

- `mobs[npcID]`: name, level min/max, classification, `kills`, `money`,
  `items[itemID] = {drops, count, kept}` (drops = times seen, count = total
  amount, kept = amount that reached the bags), `gather` with the same shape
  plus `gathers`, `maps[mapID] = kills`, `last` (time of last kill).
- `nodes[objectID]`: name, `gathers`, `items` like above, `maps`, `last`.
- `chars[charKey]`: `goals` (list of item ID and target), `session`.
- Pruning at login: drop mobs and nodes with fewer than 5 kills or gathers
  whose `last` is older than 90 days. Warn in `/sempre perf` terms by staying
  under the budget; if the table grows past 2000 mobs, prune the least
  recently seen first.

No player names, no GUIDs of players, no gold amounts of other players.

## Loading

Must see every loot window, so `## X-Sempre-LoadWith: Login`; login work in
its own `ADDON_LOADED` (see CLAUDE.md). Budget 150 KB. Folder `Sempre_Loot`,
TOC `Sempre_Loot.toc` with `## IconTexture` like the other modules, `.pkgmeta`
line, LICENSE and NAMING.md copies like Sempre_Ledger. Optional use of
Sempre_Items and Sempre_Ledger only through their documented interfaces.

## Events

Lifecycle and loot window events through `SempreUI:On`: loot opened, loot
closed, money change, bag update (delayed variant), regen enabled. Cursor and
tooltip work through `TooltipDataProcessor`. No combat log (it does not exist
on Forever). Check optional events with `C_EventUtils.IsEventValid` before
registering.

## Forever and API notes

- Loot source per slot is readable after combat (probe 0.2.5). If the
  function is missing or returns nothing, fall back to the target's GUID when
  the target is dead and the loot window opened; if neither is readable, book
  the loot as "unknown source" for the session value only.
- Health and power are secret; do not use them to detect kills.
- Guard every GUID and name with `issecretvalue` before string work.
- Use `C_Item` functions; the global item info function does not exist.

## Not in scope

Windows, map pins, arrows, respawn timers, level-band grind lists, auction
prices, exports. Those come later or in other modules.

## Acceptance checks

- `luacheck .` clean, `lua5.1 tests/run.lua` passes. New offline tests in
  `tests/loot.lua` with a stubbed API cover: one kill counted once when the
  corpse is reopened; area loot with two sources in one slot; skinning after
  looting counted as gather of the same mob; herb node keyed by object ID;
  money split to the money slot's sources; item value from sell price and the
  late price after item data arrives; reliability threshold at 20 kills and
  the rare-outlier rule; `wo` ranking; farm goal progress and the reached
  message; session over `/reload` and new session after 15 minutes; secret
  GUID or name ignored without error; pruning at login.
