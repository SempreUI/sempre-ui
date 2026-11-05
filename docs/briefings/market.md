# Briefing: Sempre_Market (market memory)

Status: ready to build, 2026-11-05. New module. Every later gold module
(Ledger part 3, Sempre_Craft, Butler part 2, Loot values) reads its prices
from here, so it comes first. The study of other Forever auction addons
(survey in the roadmap doc of 2026-11-05) only shaped the behaviour below;
nothing of their code, names or data layout is to be reproduced.
All `C_` names and events are in `tools/api-forever.txt` (build 1.60.1)
unless marked otherwise; record and field names were checked against the
generated documentation in the same mirror.

## Purpose

Remember what the auction house asked for every item over weeks, with as
little effort from the player as possible, and answer three questions
everywhere in SempreUI: what is this item worth right now, is the price
rising or falling, and how fast does it sell. No posting, buying or
cancelling: that stays with Auctionator and the game's own frames.

## Where the prices come from

1. **Full scan.** At an open auction house the module offers a "Scan"
   button. A click asks the game for the full listing
   (`C_AuctionHouse.ReplicateItems`). The game answers with
   `REPLICATE_ITEM_LIST_UPDATE`; then `C_AuctionHouse.GetNumReplicateItems`
   gives the count and `C_AuctionHouse.GetReplicateItemInfo(index)` one
   listing (index starts at **0**). Values used: count, buyout price (whole
   listing, so price per unit = buyout divided by count, rounded up), item
   ID (17th return). The item link (`GetReplicateItemLink`) is only needed
   for gear with a random suffix. The owner is not given on Forever; never
   rely on it. Listings with no buyout (bid only) are counted but give no
   price. The 18th return says whether the item's data is loaded; when it is
   false, the name and some fields may still be missing. Price, count and
   item ID are present anyway, which is all the summary needs; never wait for
   item data inside the read, and never request it for every listing (the
   tooltip and the commands load an item's data on demand through
   `C_Item.RequestLoadItemDataByID` and `ITEM_DATA_LOAD_RESULT`).
2. **Scans started by other addons.** `REPLICATE_ITEM_LIST_UPDATE` also
   fires when Auctionator or another addon asked for the full listing. Read
   it the same way, so the player's normal Auctionator scans fill SempreUI's
   memory without a second scan. Ignore a second arrival within 60 seconds of
   a finished read (same data).
3. **Server wait.** The game sends a full listing only once every 15 minutes
   (measured on Forever by other authors; keep it a constant). Remember when
   the last listing arrived (account-wide per market, see below) and show the
   remaining wait on the button ("12:40"). If no answer arrives within 60
   seconds of a click, reset and print one line that the server's wait is
   probably not over. The timeout is not optional: a request sent while the
   server's wait is still running is ignored silently (no event, no error),
   as other authors report.
4. **Reading without freezing.** Never read the whole listing in one frame.
   Read in slices from an own frame's update with a time budget of about
   8 ms per frame (measure with `debugprofilestop`), collect per item the
   list of (unit price, quantity), then summarise item by item, again in
   slices. The button shows the progress in percent. Closing the auction
   house does not stop a read that has started (the data is already in the
   client); it stops only a scan still waiting for the answer.
5. **Normal searches.** Whatever the player or another addon searches is free
   data:
   - Browse results (`AUCTION_HOUSE_BROWSE_RESULTS_UPDATED` with
     `C_AuctionHouse.GetBrowseResults()`, `AUCTION_HOUSE_BROWSE_RESULTS_ADDED`
     with the added list): per item key the lowest unit price (`minPrice`)
     and the listed quantity (`totalQuantity`). Lowest price and quantity
     only, no market value.
   - Commodity results (`COMMODITY_SEARCH_RESULTS_UPDATED` with the item ID;
     `GetNumCommoditySearchResults`, `GetCommoditySearchResultInfo` with
     `unitPrice` and `quantity` per price step): the full depth of a stack
     good. When `HasFullCommoditySearchResults` is true it counts like a
     full scan of that one item (market value too). Keep the price steps of
     the last search per item for 30 minutes in memory only (for the depth
     question below).
   - Item results (`ITEM_SEARCH_RESULTS_UPDATED` with the item key;
     `GetItemSearchResultInfo` with `buyoutAmount` and `quantity`): same as
     commodities; skip results without buyout.
   A search within 10 minutes of the last data for the same item refines the
   day's values but does not count as a new observation.
6. **Watch list check** (quick prices between full scans). The player keeps
   a watch list (command below; also every item the account sold or bought
   at the auction house in the last 30 days, from `SempreUI.Ledger` if
   loaded). At the auction house a second button "Merkliste" / "Watch list"
   searches these items by item key, at most 100 keys per request
   (`C_AuctionHouse.SearchForItemKeys(keys, {})`, keys built with
   `C_AuctionHouse.MakeItemKey`). Answers arrive as browse results (rule 5).
   Send the next batch only after the answer arrived and the throttle system
   is ready (`C_AuctionHouse.IsThrottledMessageSystemReady`, else wait for
   `AUCTION_HOUSE_THROTTLED_SYSTEM_READY`). Stop on
   `AUCTION_HOUSE_BROWSE_FAILURE` or when the auction house closes. One click
   = one pass through the list, never a loop.
7. **Fallback: Auctionator.** When the memory has no value for an item that
   is younger than 7 days and Auctionator is loaded, ask Auctionator's public
   read interface, version 1: `Auctionator.API.v1.GetAuctionPriceByItemID`
   with the caller name `"SempreUI"` and the item ID gives the last known
   price in copper (nil when unknown), `GetAuctionAgeByItemID` the age in
   days; `GetAuctionPriceByItemLink` exists for links. Feature-detect the
   table and each function (`Auctionator.API.v1` may be missing or renamed
   in a later version) and call them inside a protected call, never on the
   tooltip path without a cached answer (cache per item for 60 seconds).
   Mark such a value as "Auctionator" in every display. Option, default on.
   Never store Auctionator's values in the memory.

## Which market

Forever has no realm auction houses: one auction house per region, ruleset
(Normal, PvP, RP) and faction, plus a neutral one that both factions share
(15 % cut). Prices therefore belong to a **market key**, never to a realm:

- region from `GetCurrentRegion`;
- ruleset: **[probe]** no API is known. Take it from the realm name when it
  ends in a ruleset word (the beta realm was named "... PvE"), else use the
  realm name as it is. Keep the raw realm name and the result of
  `C_GameRules.GetForeverExperiencePreset` (feature-detect, record only) in
  the market's info so a later version can merge keys;
- side: at `AUCTION_HOUSE_SHOW` read the faction of the interaction unit
  (`UnitFactionGroup("npc")`); an auctioneer without Alliance or Horde means
  the neutral house, else the player's faction.

Remember the market key of the last opened auction house per character.
Tooltips and the interface use the character's own faction market, or the
neutral one when the character is standing in it.

## Values per item

Item identity: the item ID; for gear with a random suffix, item ID plus
suffix. Item level is ignored (Forever items have fixed levels).

From one full observation of an item (all its listings):

- **lowest**: lowest unit price;
- **listed**: total quantity;
- **market value**: a quantity-weighted median of the cheaper part of the
  offer, robust against bait and silly listings. Own rule: compute the
  weighted median price of all units; drop units priced below a quarter of
  it or above four times it; of the rest take the cheapest 25 % of units (at
  least 1) and return their weighted median. Fixtures in the tests must show
  that one stack of 1 unit at 1 copper and one stack at 1000 gold do not move
  the value.

History per item and market:

- one record per day for the last 14 days: lowest of the day, market value
  as the mean of the day's full observations, listed quantity of the last
  observation, number of observations;
- older days fold into one record per calendar week (Monday start), weeks
  older than 365 days are dropped. Folding runs once per login in slices.
- Store each item's history as one compact string in the saved data and
  decode on demand; keep a small cache of decoded items (about 200, least
  recently used out). The builder chooses the encoding; it must survive a
  damaged record by skipping it. Positional lists (a value's meaning given by
  its position) are preferred over named fields everywhere in the saved
  data; they are about half the size on disk.
- Every saved table has a hard cap (items per market, watch list 500,
  commodity price steps in memory only). Very large SavedVariables files are
  known to be written incompletely by the client, which loses the whole
  file; the budget and the caps are the protection against that.

Derived values (computed on demand, not stored):

- **trend**: market value now against the mean of the 7 days before, in
  percent; only with at least 3 days of data;
- **usual offer**: median listed quantity over the last 7 days;
- **turnover estimate**: for stack goods with at least two observations a
  day apart, the sum of drops in listed quantity per day, as a rough "sold
  per day" estimate. Always labelled "ca." / "approx."; never presented as
  exact (cancellations look like sales);
- **depth**: cost to buy the next N units now, only from the price steps of
  a commodity search younger than 30 minutes; else unknown.

## Size limits

Budget `## X-Sempre-Budget-KB: 1500` (the one large module; update the
README budget table and the total line). Keep full history only for stack
goods and for items the account owned, sold, bought or watches; other gear
keeps the daily records of 14 days and no weeks. Hard cap of 8000 items per
market: when exceeded, drop the items whose newest data is oldest, never a
watched or owned item. `/sempre perf` must stay inside the budget with a
full listing of about 30,000 auctions.

## Display

- **Tooltip** (option, default on), one line under the existing SempreUI
  lines: "Markt: 1g 20s · Tief 1g 05s · 7 T +8 %" / "Market: ...". Shift
  adds a second line "Angebot 340 (üblich 500) · ca. 120 / Tag · vor 3 Std"
  and, for stack goods, the price of 20 units from depth when known. Values
  from Auctionator carry "(Auctionator)". No line when nothing is known.
  Hook through `TooltipDataProcessor.AddTooltipPostCall` like Sempre_Items.
- **Buttons** at the auction house: "Scan" and "Merkliste", placed next to
  the game's search bar after `Blizzard_AuctionHouseUI` loaded (hook from the
  module's own `ADDON_LOADED`, check frames exist). Option "Knöpfe im
  Auktionshaus" (default on).
- One chat line after a full read: "Markt: 28.410 Angebote, 3.212 Artikel,
  Preise gespeichert (4,1 s)." Option to silence it.

## Commands

`/sempre markt` (`market`):

- no argument: market key, items known, age of the last full listing, time
  until the next is possible, watch list size;
- `<item link or ID>`: the last 14 days (one line per day with data) and the
  last 8 weeks, then trend, usual offer and turnover estimate;
- `merke <item>` / `watch`, `vergiss <item>` / `unwatch`, `liste` / `list`;
- `scan`: same as the button (only at the auction house).

## Interface for other modules

Read-only, on `SempreUI.Market`, documented in the module:

- `GetValue(item)` (item ID or link): market value, lowest, listed, age in
  seconds, source (`scan`, `search` or `auctionator`); nil when unknown.
- `GetTrend(item)`, `GetTurnover(item)`, `GetUsualOffer(item)`.
- `GetDepth(item, count)`: copper for `count` units, or nil.
- `GetHistory(item, days)`: iterator over (day, lowest, market, listed).
- `GetMarketKey()`.

Must not allocate per call on the tooltip path. Message `MARKET_UPDATED`
(market key, number of items) after a full read, a watch list pass or a
search that changed values (at most once per second).

## Loading and saved data

`## X-Sempre-LoadWith: Login` (tooltips need it always). Own SavedVariables
`SempreMarketDB` (account-wide): version, markets by key (info, last full
listing time, items, watch list). Per-account options through
`SempreUI:RegisterOptions`. Folder `Sempre_Market`, `.pkgmeta` line,
luacheck globals, README rows (command, budget), compatibility rules: none.

## Forever notes

- No secret values are involved (prices and quantities are plain), but never
  read or store player names (owners, bidders).
- Every buy, post and cancel needs a real click on Forever; this module never
  calls any of them.
- `BigUInteger` prices arrive as plain Lua numbers; keep them as numbers.
- The minimum deposit of 1 silver per auction is never refunded (reported by
  other authors); that is for Ledger part 3, not here.

## Not in scope

Posting, buying, sniping, cancelling, sharing prices with other players or
any network traffic, charts (a later part may draw a small history graph),
disenchant values (Butler part 2).

## Acceptance checks

- `luacheck .` clean, `lua5.1 tests/run.lua` passes; new `tests/market.lua`
  run by `run.lua`.
- Tests cover: market value rule with bait and outliers, and with gear that
  has only one or two listings; day records, folding
  into weeks across a year boundary and dropping after 365 days; encode,
  decode and a damaged record; full read in slices with a stubbed listing
  (0-based), bid-only listings, suffix gear; a listing started by another
  addon is read; second arrival within 60 seconds ignored; 15-minute wait and
  60-second timeout; browse, commodity and item search results, including the
  10-minute refine rule and "full results" only for market value; watch list
  in batches of 100 waiting for the throttle; market key with neutral and
  faction auctioneers and with a ruleset word in the realm name; Auctionator
  fallback marked and not stored; trend needs 3 days; turnover estimate;
  depth only within 30 minutes; item cap keeps watched and owned items;
  tooltip lines with and without Shift; interface returns; no owner or
  player name stored anywhere.
- In the live client (Oliver, after the first evening): one full scan, one
  Auctionator scan read, tooltip line on a herb, `/sempre markt <herb>`,
  `/sempre perf` within budget.
