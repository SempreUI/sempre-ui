# Briefing: core message bus and login modules

Status: ready to build, 2026-10-20. Needed by Sempre_Items (see `items.md`);
independent of the beta probe.

## Purpose

Two small additions to the core `Sempre`:

1. A message bus, so modules can tell each other about changes without
   knowing about each other (e.g. Sempre_Items says "bags changed", a later
   bag window redraws).
2. Modules that load right after login instead of on demand, for engines whose
   data must always be current (Sempre_Items).

## 1. Message bus

- `SempreUI:Send(msg, ...)` calls every listener of `msg` right away
  (synchronously), in the order they were added, with `(msg, ...)`.
- `SempreUI:Listen(msg, fn)` adds a listener. `SempreUI:Unlisten(msg, fn)`
  removes it.
- Messages are plain strings, upper case by convention (`ITEMS_CHANGED`).
  They are not game events and never reach the event frame; a message with
  the same name as a game event must not register that event.
- Sending a message nobody listens to is cheap and silent.
- An error in one listener must not stop the others: report it through the
  game's error handler and carry on, the same way the event dispatcher does.
- Removing a listener while a message is being sent (also the listener
  removing itself) must not skip or call twice any other listener.
- A listener added while a message is being sent is not called for that send,
  only for later ones.
- A listener may send another message from inside its handler (nesting).
  Make sure removal during a nested send is still safe.
- The event bus already solves the same list problems (`On`, `Off`, the
  dispatcher, `compact`). Share that logic between events and messages
  instead of writing it twice; the event-specific part (registering and
  unregistering on the frame) stays separate. Behaviour of `On`/`Off` must not
  change.
- Hot path: `Send` must not allocate tables or closures per call.

## 2. Modules that load at login

- A module opts in with the TOC line `## X-Sempre-LoadWith: Login`. It still
  has `## LoadOnDemand: 1`; the core loads it.
- On `PLAYER_LOGIN`, after the character key is set, the core loads every
  SempreUI module that has this line and is enabled for the current character,
  in alphabetical order, through the existing module loader, so the load cost
  shows in `/sempre perf`.
- "Enabled" means the player has not switched it off in the addon list. Use
  `C_AddOns.GetAddOnEnableState` with the character name; check what it returns
  in the 12.x API (a number or an `Enum.AddOnEnableState` value) and treat
  anything above "none" as enabled. If the function is missing, treat the
  module as enabled.
- Important: the existing `LoadModule` switches a module on before loading.
  That is right when the player asks for a module, but the login loader must
  never switch on a module the player has switched off. Split or parameterise
  this so the login path only loads.
- A failing module prints the existing "could not be loaded" message and the
  others still load.
- The login print ("SempreUI ... loaded") stays one line; do not print a line
  per module.

## Rules that apply

Read `CLAUDE.md` in the repo root and follow it: copyright header, tabs,
`local` everything, upvalue globals at the top, no new globals, German and
English strings if any new user-facing text is needed (try to need none),
`luacheck .` clean. Add any newly used WoW API name to `read_globals` in
`.luacheckrc`.

Update `CLAUDE.md`: in the module rule, mention the optional
`## X-Sempre-LoadWith: Login` line and that it is only for engines that must
always be current. Add one line under Style: modules talk to each other with
`SempreUI:Send` / `SempreUI:Listen`, never by calling each other's functions
directly, except through a documented read-only interface such as
`SempreUI.Items`.

## Not in scope

Settings UI, enabling or disabling modules from SempreUI, Sempre_Items itself.

## Acceptance checks

- `luacheck .` clean.
- A plain Lua 5.1 script with stubbed `CreateFrame`, `C_AddOns` etc. (kept out
  of the addon folder, e.g. under `tests/`, and listed in `.pkgmeta` ignore)
  shows:
  - listeners run in order with the right arguments;
  - an erroring listener does not stop the next one;
  - a listener that removes itself, or the next one, during a send: every
    other listener runs exactly once;
  - a listener added during a send runs only on the next send;
  - nested send with removal works;
  - a message named like a game event does not register it on the frame;
  - `On`/`Off` still behave as before;
  - at login, only modules with `X-Sempre-LoadWith: Login` that are enabled
    are loaded, a disabled one is not switched on, and a failing one does not
    stop the rest.
- If CI can run that script cheaply (e.g. a Lua 5.1 setup step in `lint.yml`),
  add it; otherwise document how to run it in `tests/README.md`.
