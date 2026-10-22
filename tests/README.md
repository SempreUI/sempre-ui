# Tests

Plain Lua 5.1 tests for the core (including the error collector) (`run.lua`) the item module (`items.lua`) the gold journal (`ledger.lua`, `ledger2.lua` for auction house sales, purchases, deposits and the vendor check, which reuses the stubbed boot of `ledger.lua`) the loot memory (`loot.lua`) the mail overview (`mail.lua`) the waypoints (`way.lua`) and the settings window with the option interface (`settings.lua`, all run by `run.lua`) with a stubbed WoW API. They are not part of
the addon package (`tests` is in the `.pkgmeta` ignore list).

Run from the repo root:

    lua5.1 tests/run.lua

It prints the number of checks and exits non-zero on any failure. CI runs it
in `.github/workflows/lint.yml`.
