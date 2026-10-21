# Briefing: error collector in the core

Status: ready to build, 2026-10-21.

## Purpose

Forever reportedly hides Lua errors from players (the default error display is
off). Testers then see nothing when SempreUI breaks. The core gets a small
error collector so `/sempre fehler` shows what went wrong, and so the
SavedVariables file carries the errors to us.

## Behaviour

1. At load, the core wraps the game's current error handler: every Lua error
   is recorded first, then passed on to the previous handler unchanged, so the
   game and other addons behave as before. Get and set the handler through
   the game's error-handler functions; if setting fails or the functions are
   missing, the feature is off without a message.
2. Also record the game events that report blocked or forbidden addon actions
   (`ADDON_ACTION_BLOCKED`, `ADDON_ACTION_FORBIDDEN`, with the addon name and
   the function), when the client knows them. Check validity first so the
   core's unknown-event warning is not printed.
3. A record holds: the message, a short stack (the game's stack-trace
   function, limited to a few lines, when available), the time, the SempreUI
   version, and a count. Identical message plus first stack line counts up
   instead of adding a record.
4. Mark each record as SempreUI or other: SempreUI when the message or stack
   mentions an `Sempre` or `Sempre_` addon folder. Others are kept too (useful
   for the beta), but listed after ours.
5. Keep at most 50 records in `SempreDB.global.errors`, dropping the oldest.
   Errors that happen before the saved data is loaded are kept in memory and
   moved in once it is.
6. The first new SempreUI error of a session prints one chat line pointing to
   `/sempre fehler`. No further chat lines that session; never a popup.
7. `/sempre fehler` (alias `/sempre errors`) lists the newest 10 records,
   ours first: time, count, message (cut to one line), first stack line.
   `/sempre fehler alle` lists all, `/sempre fehler leeren` (alias `clear`)
   empties the list. Mention the slash command in the core's help line.
8. The collector must never raise an error itself: guard all its work, and a
   failure inside it must still pass the original error on.
9. Error text can, in theory, contain secret values: never compare or
   concatenate a value for which `issecretvalue` is true; store a placeholder
   instead.

## Rules that apply

`CLAUDE.md`. German and English strings, German first. No new globals. Update
README's command table. Keep the core small.

## Acceptance checks

- `luacheck .` clean, `lua5.1 tests/run.lua` passes with new tests (stubbed
  error-handler functions): an error is recorded and still reaches the previous
  handler; duplicates count up; cap at 50; SempreUI records list first; early
  errors move into saved data; one chat line per session; a failure inside the
  collector still passes the error on; blocked-action event recorded;
  missing functions leave the feature off silently.
