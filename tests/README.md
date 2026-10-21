# Tests

Plain Lua 5.1 tests for the core (including the error collector) (`run.lua`) and the item module (`items.lua`, run by `run.lua`) with a stubbed WoW API. They are not part of
the addon package (`tests` is in the `.pkgmeta` ignore list).

Run from the repo root:

    lua5.1 tests/run.lua

It prints the number of checks and exits non-zero on any failure. CI runs it
in `.github/workflows/lint.yml`.
