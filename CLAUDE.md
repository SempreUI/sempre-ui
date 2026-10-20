# Rules for AI contributors

SempreUI is a WoW addon suite for World of Warcraft: Forever (client based on
Mainline 12.x, TOC `## Interface: 16001`, TOC suffix `_Camelot.toc`).

## Hard rules

- Never copy code from other addons, whatever their license. You may read
  them to understand a problem; write the solution from scratch.
- Forever applies the Midnight addon restrictions: secret values (health,
  names, GUIDs, threat in combat), no `COMBAT_LOG_EVENT_UNFILTERED`. Display is
  allowed; logic, comparisons or arithmetic on secret values are not. Check
  with `issecretvalue` where a value may be secret.
- Use `C_` namespaces (`C_Item.GetItemInfo`, `C_Container`, `C_AddOns`), not
  removed legacy globals. Feature-detect APIs that may be missing and disable
  the feature with a clear message instead of erroring.
- One module = one addon folder `Sempre_<Name>` with `## LoadOnDemand: 1`
  and `## X-Sempre-Budget-KB: <n>`. The core `Sempre` stays under 300 KB.
- No globals except the addon table `SempreUI` and SavedVariables.
- Small commits, one topic each, English commit messages.
- Commit as `SempreUI <SempreUI@users.noreply.github.com>`. No `Co-Authored-By` or `Claude-Session` trailers, no mention of the AI in commits.

## Style

- Tabs for indentation, `local` everything, upvalue hot globals at the top.
- One event frame in the core; modules register through `SempreUI:On(event, fn)`.
- User-facing strings in German and English (`L` tables), German first.
- Copper accent `0.78, 0.47, 0.29` (`#C8794A`).

## Checks

- `luacheck .` must be clean.
