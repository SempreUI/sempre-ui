# Briefing: Sempre_Whisper (whisper windows), part 1

Status: ready to build, 2026-10-22. Owner's pick; players ask for it
("WIM", "Whisper Messenger": never miss a whisper). All `C_` names and
events below are in `tools/api-forever.txt` (build 1.60.1), and the secret
rules are taken from the generated documentation.

## Purpose

Every whisper conversation gets its own small window, like a messenger:
incoming whispers are not lost in busy chat, answers go back from the same
window, and recent conversations are still there after `/reload`.

## Secret values (most important)

The whisper events (`CHAT_MSG_WHISPER`, `CHAT_MSG_WHISPER_INFORM`,
`CHAT_MSG_BN_WHISPER`, `CHAT_MSG_BN_WHISPER_INFORM`) are documented as
"secret in chat messaging lockdown": while
`C_ChatInfo.InChatMessagingLockdown()` returns true (encounters and similar),
text, player name, GUID and Battle.net sender ID are secret values. The
`lineID` argument is never secret.

- Never compare, key, store, concatenate or measure a value for which
  `issecretvalue` is true.
- During lockdown, keep only the `lineID`, the event kind (in or out, game or
  Battle.net) and the time in a pending list (cap 50). The game's own chat
  frame still shows the whisper as usual.
- When lockdown ends (check on `PLAYER_REGEN_ENABLED`, on zone change and
  every 5 seconds while the pending list is not empty, using an own frame's
  update with a time accumulator; stop the timer when the list is empty),
  resolve each pending line with `C_ChatInfo.GetChatLineSenderName(lineID)`
  and `C_ChatInfo.GetChatLineText(lineID)`. If both are readable, file the
  line into its conversation with its original time; if not (line gone),
  drop it silently.
- Outside lockdown the event values are plain; still check each with
  `issecretvalue` before use.

## Behaviour

1. **Conversations.** One conversation per partner: for game whispers the
   player name with realm as the event gives it, for Battle.net whispers the
   Battle.net account ID (`bnSenderID`), with the display name from
   `C_BattleNet.GetAccountInfoByID` (feature check).
2. **Window.** A small movable, resizable window per conversation (min
   260×160): title with the partner's name in the title font role, the
   messages as a scrolling list (time `HH:MM`, "Ich"/"Me" or the partner's
   name, text; links in the text stay clickable through the game's hyperlink
   handling on the message frame), an input line at the bottom. Enter sends,
   Escape clears focus. Only one window shows at a time by default; the
   others are tabs along the top of the shown window (partner names,
   unread marker in copper). Window position and size are saved.
3. **Opening.** An incoming whisper opens the window if none is shown and the
   player is not in combat; in combat it only marks the tab unread and opens
   at combat end. Option "Fenster bei neuem Flüstern öffnen / Open the
   window on a new whisper" (default on); off means only the unread marker
   and a minimap-button count (below). An outgoing whisper typed in the
   normal chat also files into its conversation (from the inform event).
4. **Sending.** The input line sends through `C_ChatInfo.SendChatMessage(
   text, "WHISPER", nil, target)` for game partners and
   `C_BattleNet.SendWhisper(accountID, text)` for Battle.net partners. Only
   from the input line's Enter (a key press, so the game allows it). The
   sent text appears when the inform event arrives, not before, so failed
   sends do not show as sent. Messages longer than 255 bytes are split at
   word boundaries into several sends.
5. **Sound.** A short sound on an incoming whisper when the window was not
   focused (`C_Sound.PlaySound` or the game's sound kit call, feature check).
   Option "Ton bei neuem Flüstern / Sound on a new whisper" (default on).
6. **Unread count.** The number of unread conversations shows in the
   window's title area and in `/sempre fluestern` / `whisper`, which also
   opens the last conversation.
7. **History.** Keep the last 50 lines per conversation and at most 30
   conversations per character, for 7 days, in saved variables, so they
   survive `/reload` and logout. Option "Verlauf speichern / Keep history"
   (default on); off keeps it only for the session and deletes saved lines.
   This is the player's own chat stored on their own computer; it is never
   exported or sent anywhere.
8. **Do not hide** whispers from the normal chat in this part (no chat
   filters), so nothing can get lost if the module fails.
9. **Messages** `WHISPER_RECEIVED` (conversation key only, never text) for
   later modules.

## Saved data

Own SavedVariables `SempreWhisperDB` with `version`; per character:
`conversations[key] = { name, bnet = true|nil, lines = { {t, out, text} },
unread }`, window position and size. Only non-secret values ever go in.

## Loading

Must catch every whisper: `## X-Sempre-LoadWith: Login`, login work in its
own `ADDON_LOADED` (see CLAUDE.md). Budget 80 KB. Build windows only on the
first whisper or command. Folder `Sempre_Whisper`, TOC `Sempre_Whisper.toc`
with IconTexture and notes in both languages, `.pkgmeta` line, LICENSE and
NAMING.md copies.

## Events

Through `SempreUI:On`: the four whisper events, `PLAYER_REGEN_DISABLED`,
`PLAYER_REGEN_ENABLED`, `ZONE_CHANGED_NEW_AREA`.

## Style

Dark panel with a 1 px copper border like the button panel; text role for
messages, mono role for times; incoming partner name in the game's whisper
colour (`C_ChatInfo.GetColorForChatType("WHISPER")`, feature check), own
name in copper. German first in `L` tables.

## Not in scope

Group, guild or channel chat, chat filters that hide whispers from the main
chat, auto replies, typing indicators, emoji, a minimap button.

## Acceptance checks

- `luacheck .` clean, `lua5.1 tests/run.lua` passes. New offline tests in
  `tests/whisper.lua` with a stubbed `C_ChatInfo`, `C_BattleNet` and a
  secret-value stub (`issecretvalue` true for marked values) cover: incoming
  and outgoing game whispers filed by partner; Battle.net whisper keyed by
  account ID with display name; during lockdown secret values are never
  compared, stored or concatenated (the stub errors if they are), only the
  line ID is queued; after lockdown the queued lines are resolved and filed
  with their original time, unreadable ones dropped; window opens out of
  combat, waits in combat; option off only marks unread; Enter sends through
  the right call, long text split at word boundaries, text shown only on the
  inform event; history caps (50 lines, 30 conversations, 7 days) and the
  history option off deletes saved lines; sound only when not focused and
  with the option; `/sempre fluestern` opens the last conversation;
  `WHISPER_RECEIVED` carries no text.
