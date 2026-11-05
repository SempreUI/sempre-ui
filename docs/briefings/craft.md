# Briefing: Sempre_Craft (professions and recipe profit), part 1

Status: ready to build after Sempre_Market, 2026-11-05. New module. Other
Forever profession addons (survey in the roadmap doc of 2026-11-05) rank
recipes from a fixed recipe database; SempreUI instead works from what the
player's own characters have learned and own, priced from Sempre_Market.
Nothing of other addons' code, names or data layout is to be reproduced.
`C_` names are in `tools/api-forever.txt` (build 1.60.1) unless marked
**[probe]**; record fields were checked against the generated documentation
(`TradeSkillUITypesDocumentation`).

## Purpose

One answer across all characters: what can my account craft right now with
profit, what does it cost, what is missing, and which learned recipe levels a
profession most cheaply. Plus a reminder when a profession cooldown is ready.

## Behaviour

1. **Recipe snapshot.** When a profession window opens for the player's own
   profession (`TRADE_SKILL_SHOW`, then `TRADE_SKILL_LIST_UPDATE` and
   `TRADE_SKILL_DATA_SOURCE_CHANGED`), and it is not another player's linked
   or guild profession and not NPC crafting (`C_TradeSkillUI.IsNPCCrafting`;
   linked or guild state through the plain checks the game's own profession
   UI uses, feature-detected **[probe]**), store for this character:
   - profession: name, skill level and maximum
     (`C_TradeSkillUI.GetBaseProfessionInfo`, child info if present);
   - every **learned** recipe: recipe ID, name, output item ID
     (`outputItemID` of `C_TradeSkillUI.GetRecipeSchematic(recipeID,
     false)`), minimum and maximum output quantity (`quantityMin`,
     `quantityMax`), reagents (each required slot of `reagentSlotSchematics`:
     first reagent's `itemID` and `quantityRequired`; skip slots that are not
     `required`), difficulty for this character (`relativeDifficulty` and
     `numSkillUps` from `C_TradeSkillUI.GetRecipeInfo`), and whether it is
     an enchanting recipe without an item result (`isEnchantingRecipe` and no
     output item).
   - The recipe list itself **[probe]**: the generated documentation of
     Forever 1.60.1 lists no function that returns all recipe IDs, but the
     game's own Forever profession UI calls `C_TradeSkillUI.GetFilteredRecipeIDs`
     (see `docs/solutions/forever-api-names.md`). Feature-detect, in this
     order, a function returning all recipe IDs (`GetAllRecipeIDs`), then
     the filtered one, then **[probe]** the classic trade skill list
     (`GetNumTradeSkills` with `GetTradeSkillInfo(index)` giving name, type
     and difficulty, and `GetTradeSkillRecipeLink(index)` with the recipe
     ID in the link; only when the two `C_TradeSkillUI` functions are
     missing, and only for headers-and-recipes lists, where header rows are
     skipped). Keep only learned recipes. Never change the player's filters.
     Record which of the three ways was used in the snapshot, so the probe
     shows it. When none exists, print once that recipes cannot be read in
     this client and keep the profession level only.
   - Work in slices (about 50 recipes per frame) so opening the window never
     stutters. Re-read only recipes whose skill or difficulty changed and new
     recipes (`NEW_RECIPE_LEARNED`); `SKILL_LINES_CHANGED` updates skill
     levels.
2. **Vendor prices of reagents.** At a merchant (`MERCHANT_SHOW`), record
   the buy price per unit of every item it sells that is a reagent of any
   stored recipe (plain merchant globals, feature-checked; unlimited stock
   only). Account-wide, keep the cheapest seen with the date.
3. **Cost of a reagent** (cheapest that is known): vendor price (rule 2);
   market value from `SempreUI.Market.GetValue` (if loaded); else unknown.
   Option "Eigene Mats zum Einstandspreis" / "Own mats at cost" (default
   off): when on and `SempreUI.Ledger` reports what the account paid for
   this item in the last 30 days, use that average for the units owned.
4. **Value of a result**: market value times average output quantity, minus
   the auction cut (5 % faction, 15 % at the neutral house, depending on the
   market key in use) and minus 1 silver deposit per listing that never
   comes back. When the market has no value: the vendor sell price (item
   info, 11th value), marked "Händler" / "vendor". Enchanting recipes
   without an item result have no value (shown as cost only).
5. **Profit list.** `/sempre craft` (`beruf`) opens a small window: one row
   per learned recipe on any character, columns recipe, character, cost,
   value, profit, margin in percent, turnover estimate of the result
   (`SempreUI.Market.GetTurnover`), and "Mats da" (how many crafts the
   account's stock covers, from `SempreUI.Items.GetCount` over all
   characters). Sorted by profit; filters: only with mats in stock, only
   this character, only with a known market value. Rows with an unknown
   reagent cost show "?" and sort last. Window in the SempreUI style
   (fonts, copper accent), movable, closes with Escape, not in combat.
6. **Shopping list.** `/sempre craft plan <item or recipe> <count>`: the
   reagents for that many crafts, minus what all characters own, with the
   cost of the rest at the prices from rule 3, as chat lines and as a list
   in the window. One plan at a time, kept until cleared (`plan weg`).
7. **Cheapest skill-ups.** For each profession of the current character, the
   learned recipes that can still give skill, ranked by expected cost per
   skill point: cost of one craft divided by an expected gain per craft
   (difficulty optimal 1, medium 0.5, easy 0.15, trivial 0; multiplied by
   `numSkillUps` when above 1). Shown on a tab of the window and with
   `/sempre craft skill`. Only learned recipes; no trainer or recipe
   database (leave guides to other addons).
8. **Cooldowns.** When the player crafts a recipe that has a cooldown
   (`TRADE_SKILL_ITEM_CRAFTED_RESULT` or the recipe's cast success, and a
   cooldown read through the spell cooldown API or a recipe cooldown
   function, feature-detected **[probe]**), store the ready time per
   character and recipe. `/sempre craft cd` lists them; one chat line at
   login when one is ready on this character.
9. **Tooltip** (option, default on): on an item that is the result of a
   stored recipe, one line "Herstellbar: Name (Schneiderei) · Gewinn 12s"
   / "Craftable: ..."; on a reagent, "Gebraucht für 4 Rezepte" / "Used in 4
   recipes". No per-call table allocation on the tooltip path.

## Interface for other modules

Read-only on `SempreUI.Craft`: `GetRecipesForItem(itemID)` (who can craft
it, profit), `GetUses(itemID)` (recipes that use it as reagent, with count
per craft), `GetDemand(itemID)` (units needed by the active shopping plan).
Message `CRAFT_CHANGED` with the character key after a snapshot.

## Loading and saved data

Load on demand: on the first `TRADE_SKILL_SHOW` the core loads it (or with
`## X-Sempre-LoadWith: Login` if the tooltip lines are on; the builder picks
one and documents why). SavedVariables `SempreCraftDB` (account-wide):
characters by the core's character key, each with professions and recipes;
vendor reagent prices; plan; cooldowns. Keep it small: numbers and short
strings, reagents as a compact list. Budget 200 KB. Folder `Sempre_Craft`,
`.pkgmeta` line, luacheck globals, README rows.

## Forever notes

- Forever runs the modern profession frame in its own variant. An addon
  cannot open a profession window itself on Forever (the profession menu is
  protected); the player opens it, the module reads along. Never try to
  open, switch or refresh the profession frame from code, and never ask the
  player to open all professions at once: one snapshot per opened window.
- Recipe
  quality, concentration, specialisations and crafting orders exist in the
  API but are not part of Forever's classic professions; ignore them.
  Camping is a profession on Forever; treat it like any other.
- Character names are not secret, but never put them into shared exports.
- No protected actions: the module never crafts, buys or posts.

## Not in scope

Recipe databases, trainer and recipe source lists, levelling guides, crafting
queues that craft, auction posting, guild sharing.

## Acceptance checks

- `luacheck .` clean, `lua5.1 tests/run.lua` passes; new `tests/craft.lua`.
- Tests cover: snapshot of own profession, skipped for linked, guild and NPC
  crafting; learned-only; recipe list through each of the three ways (two
  functions, classic list with headers skipped) and the message when none
  exists; slicing; new recipe and skill change updates;
  vendor reagent prices (unlimited stock only, cheapest kept); reagent cost
  order and the "own mats at cost" option; result value with faction and
  neutral cut and the 1 silver deposit, vendor fallback, enchant without
  result; profit list sort with unknown costs last and the three filters;
  mats coverage across characters; shopping plan minus stock; skill-up
  ranking; cooldown stored and listed; tooltip lines; interface returns
  without Sempre_Market loaded (values unknown, no error).
- In the live client (Oliver): open each profession once on two characters,
  `/sempre craft`, one plan, one skill list; report which recipe list
  function the snapshot used.
