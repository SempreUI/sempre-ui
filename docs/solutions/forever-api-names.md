# Checking API names against the Forever client

Applies when a briefing or a build assumes that a `C_` function or an event
exists in WoW: Forever.

- The generated API documentation of the Forever client is mirrored in
  Gethe/wow-ui-source, branch `forever`
  (`Interface/AddOns/Blizzard_APIDocumentationGenerated`). Build 1.60.1
  (70450) is the snapshot in `tools/api-forever.txt`, one line per name
  (`fn C_Map.GetUserWaypoint`, `event USER_WAYPOINT_UPDATED`).
- Before relying on a name, `grep -x "fn C_Foo.Bar" tools/api-forever.txt`.
  The documentation files also list arguments, returns and table fields;
  check return shapes there instead of guessing. Example: the auction table
  from `C_AuctionHouse.GetAuctionInfoByID` has no `quantity` field.
- Plain globals such as the mail inbox and merchant functions are not in the
  generated documentation; they still need a feature check.
- A name that is called only behind a feature check, for a later client, goes
  into `tools/api-optional.txt` so the weekly API watch does not report it.
- Names and fields are not enough for geometry: units, tile sizes and layer
  indexes of map art come from the art layer info, not fixed constants. When
  a briefing depends on such details, check how the game's own UI in the same
  mirror uses the call (Blizzard code is reference, not addon code) and write
  the facts into the briefing.
- The generated documentation is not complete. Blizzard's own Forever
  profession UI (`Blizzard_ProfessionsTemplates/Blizzard_Professions.lua` in
  the same mirror) calls `C_TradeSkillUI.GetFilteredRecipeIDs`,
  `GetRecipeLink`, `GetTradeSkillListLink`, `IsTradeSkillLinked`,
  `IsTradeSkillGuild` and `GetRecipeCooldown`, none of which is in
  `tools/api-forever.txt` (checked 2026-11-05). A name missing from the
  snapshot is therefore not proof that it is missing from the client: search
  the game's own UI code in the mirror as well, and when only the UI code
  shows it, mark it **[probe]** in the briefing, feature-detect it and add it
  to `tools/api-optional.txt`.
- Auction house facts for Forever reported by other authors (not yet seen by
  our own probe): the full listing (`C_AuctionHouse.ReplicateItems`) is sent
  at most every 15 minutes, its index starts at 0, the owner field is empty,
  and `REPLICATE_ITEM_LIST_UPDATE` also fires when another addon started the
  scan. Treat them as assumptions with tests until a live check confirms them.
- Known behaviour of the Forever auction house that a briefing must plan
  for (reported by several addon authors, 2026-11-05): a full-listing
  request sent while the server's 15-minute wait is running is ignored
  silently, so every scan needs a timeout; item data inside a full listing
  can arrive lazily (the per-listing "has all info" flag is false, name
  missing) while price, count and item ID are present. Profession windows
  cannot be opened by addons on Forever (protected menu); read them when the
  player opens them. Recipe lists: feature-detect a function for all recipe
  IDs, then the filtered list, then the classic `GetNumTradeSkills` list.
- SavedVariables size: the client writes very large SavedVariables files
  incompletely and loses them; keep every saved table under a hard cap and
  prefer positional lists to named fields (about half the size).
