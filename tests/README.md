# Tests

Plain Lua 5.1 tests for the core (including the error collector) (`run.lua`) the item module (`items.lua`) the gold journal (`ledger.lua`, `ledger2.lua` for auction house sales, purchases, deposits and the vendor check, which reuses the stubbed boot of `ledger.lua`) the loot memory (`loot.lua`) the mail overview (`mail.lua`) the waypoints (`way.lua`) the minimap button collector (`buttons.lua`) the butler (`butler.lua`: selling junk one item per tick with keep list, Shift, cap, stop on close and combat, repair order and guild funds, resurrection, duel throttle, error frame, missing functions and the keep command) the SempreUI fonts (`fonts.lua`: roles, option, language guard, fallback, game font replacement and `/sempre schrift`; the mail panel roles are checked in `mail.lua`, the greyed option in `settings.lua`) the "what's new" window (`news.lua`: when it opens, first install, option, combat, command, language, entries newest first and the scan that allows only the GitHub issues link in the game texts) and the settings window with the option interface (`settings.lua`, all run by `run.lua`) with a stubbed WoW API. They are not part of
the addon package (`tests` is in the `.pkgmeta` ignore list).

Run from the repo root:

    lua5.1 tests/run.lua

It prints the number of checks and exits non-zero on any failure. CI runs it
in `.github/workflows/lint.yml`.
