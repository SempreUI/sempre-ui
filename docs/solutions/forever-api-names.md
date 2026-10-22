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
