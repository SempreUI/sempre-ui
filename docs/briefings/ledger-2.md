# Briefing: Sempre_Ledger part 2 (auction house and purchases)

Status: ready to build, 2026-10-22. Extends part 1 (`docs/briefings/ledger.md`),
which stays valid. Auction house invoices were not seen in the beta (the
auction house was empty); every invoice field below is an assumption, built
behind feature checks and verified after launch.

## Purpose

Know what each item really earned: vendor sales (part 1), auction house sales
after cut and deposit, minus what the player paid for it at vendors and the
auction house. Base for "is this worth farming / crafting" answers later.

## Behaviour

1. **Auction sales from mail.** When money is taken from a mail that carries
   an auction house sale invoice (the invoice function returns a type meaning
   "seller"), book it with source `auction` (not `mail`), and record per item:
   count sold, gross price (bid or buyout as the invoice reports), auction cut,
   deposit returned or kept, and net copper received. The invoice names the
   item by name: resolve the item ID through item info for that name or
   through the items the player owns (`SempreUI.Items` if loaded); if it cannot
   be resolved, store under the name. Never store the buyer's name.
   Read the invoice when the mailbox shows the mail (before taking), because
   the mail may be gone after the money is taken.
2. **Other auction mail.** Money from auction mail without a sale invoice
   (outbid refunds, cancelled or expired auctions) is source `auction` too,
   but not a sale: outbid refunds cancel the matching bid expense, and they
   are not profit.
3. **Deposits.** Money paid while posting at the auction house is booked as
   source `auction` expense with sub-kind `deposit`, per item when the posted
   item is known (hook the post functions after the call and remember item and
   count for the next money change).
4. **Purchases per item.**
   - Vendor: buying from a merchant (the buy function, hooked after the call)
     records item, count and copper for the next money decrease while the
     merchant is open. Buyback stays as in part 1 (it reverses a sale, it is
     not a purchase).
   - Auction house: a commodity purchase confirmation and an item bid or
     buyout record item, count and copper for the next money decrease while
     the auction house is open. For a bid, the money leaves at bid time; if
     an outbid refund arrives later (rule 2), the purchase is cancelled.
   Store per character per day: `purchases[itemID] = {count, copper, source}`
   where source is `vendor` or `auction`.
5. **Profit per item.** `/sempre gold items` (part 1: top vendor income) now
   shows the top 10 items of the last 30 days by net result: vendor income +
   auction net income − purchases, with each part listed. `/sempre gold items
   ah` limits it to auction house sales.
6. **Vendor check (from the stress test).** For each merchant visit, compare
   the sum of the recorded item sales (at vendor price) with the vendor income
   booked during that visit. If they differ, keep a record (time, difference,
   items sold) in a list of the last 20 differences in the ledger's saved data
   and do not print anything during play. `/sempre gold pruefen` (alias
   `check`) prints that list. This exists to find the cause of small
   differences such as the 2 copper seen in the test.
7. **Interface additions** (read-only): `SempreUI.Ledger.GetItem(charKey,
   itemID, days)` returns vendor income, auction net, auction count,
   purchases (copper and count) for that range; `SempreUI.Ledger.GetItemAll(
   itemID, days)` the same summed over all characters. Message
   `LEDGER_ITEM_CHANGED` with char key and item ID after each item booking.
8. **Migration.** Bump the saved data version; existing days keep their data
   and get the new tables on demand.

## Forever and API notes

- Mail and invoice functions are plain globals; feature-check each. Assumed
  invoice return order: type, item name, buyer name, bid, buyout, deposit,
  cut, delay. If the count of returned values or their types do not fit,
  book the money as `auction` without item details and record nothing per
  item (no guessing).
- Auction house purchase and post functions live in `C_AuctionHouse`; hook
  only those that exist, from the module's own `ADDON_LOADED`, after the call.
  Note that the auction house UI is load-on-demand: hooks on `C_AuctionHouse`
  functions do not need its frames.
- Player names (buyers, senders) can be secret values; never compare or store
  them.
- Faction auction house cut 5 %, neutral 15 % (for test fixtures only; always
  use the numbers the invoice reports).

## Not in scope

Market prices, price history, posting help, crafting costs, windows or charts.

## Acceptance checks

- `luacheck .` clean, `lua5.1 tests/run.lua` passes, existing ledger tests
  still pass. New tests (extend `tests/ledger.lua` or add `tests/ledger2.lua`)
  cover: invoice read at mailbox show and booked as auction sale with cut and
  deposit when the money is taken; unresolved item name stored by name;
  outbid refund cancels the bid purchase; cancelled or expired auction mail
  is not a sale; deposit booked per posted item; vendor purchase and auction
  commodity purchase per item; profit list order and the `ah` filter; vendor
  check records a difference and `pruefen` prints it; malformed invoice falls
  back to plain `auction` booking; migration from version 1 data; no buyer
  name stored anywhere.
