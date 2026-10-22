# SempreUI

A lightweight, modular UI suite for **World of Warcraft: Forever**.

SempreUI starts with everything outside of combat: world, levelling,
professions and gold. Every feature is its own module that loads only when
you switch it on and when it is needed, so you pay in memory only for what
you use.

> Status: early development. The first public release is planned for the
> Forever launch on 5 November 2026.

## Principles

- **Light first.** A tiny core is always loaded; every module is
  LoadOnDemand. `/sempre perf` shows what each module costs.
- **Written from scratch.** No code is copied from other addons.
- **Works within Forever's rules.** In combat, addons may display but not
  decide. SempreUI never tries to work around that.
- **One look.** Copper accent (`#C8794A`), calm dark surfaces, readable fonts.

## Slash commands

| Command | What it does |
| --- | --- |
| `/sempre` | Lists the commands |
| `/sempre options` (`optionen`, `config`) | Opens the SempreUI category in the game's settings: a switch per module and the options of loaded modules. In combat it opens after combat |
| `/sempre module` (`modul`) | Lists the modules and their state. `/sempre module <name> on\|off` (`an\|aus`) switches a module for all characters, same as the checkbox; switching on loads it at once, switching off takes effect after `/reload` |
| `/sempre font` (`schrift`) | Which fonts are active, the client language and whether game fonts are replaced |
| `/sempre perf` | Memory per SempreUI module |
| `/sempre errors` (`fehler`) | Recorded Lua errors and blocked addon actions, SempreUI first; `all` (`alle`) lists every record, `clear` (`leeren`) empties the list |
| `/sempre version` | Addon version and client build |
| `/sempre items` | Gold per character, age of bank and mail snapshots (`debug`: scan count) |
| `/sempre gold` (`ledger`) | Gold journal of this character: session, today and last 7 days by source; `all` (`alle`) shows the last 7 days per character, `items` the top 10 items of the last 30 days by net result (vendor income plus auction net minus purchases, each part listed), `items ah` only items sold at the auction house, `pruefen` (`check`) the last 20 differences between recorded vendor sales and vendor income |
| `/sempre loot` | Loot memory: this session (kills, gathers, money, item value, gold per hour) and farm goals. `goal <item> <count>` (`ziel`) sets a goal, `goal remove <item>` (`ziel weg`) removes it, `where <item>` (`wo`) lists the best mobs and nodes for an item, `mob` shows the drop table of the target or the last looted mob, `top` ranks mobs by value per kill. Everything is learned from your own looting |
| `/sempre post` (`mail`) | Mail per character from the snapshots of the mailbox: mails, money, items, earliest expiry and snapshot age, or "never opened". At the mailbox a panel lists every mail with "Take all" (never pays cash on delivery) and a warning names characters whose mail expires within 3 days |
| `/way X Y [text]` (`/sempre way`) | Waypoints. `/way 45.2 61.8 Camp` on this map, `/way #<mapID> X Y` or `/way <zone> X Y` on another. The active point is the game's own waypoint (arrow in the world, marker on the minimap) and a pin on the world map. `/way` lists the points, `/way remove <n>\|all` (`weg <n>\|alle`) removes, `/way next` (`naechster`) switches. Ctrl + right click on the world map adds a point, reaching a point (under 10 yards) activates the next. `/way` is left to another addon that owns it, `/sempre way` always works |
| `/sempre knoepfe` (`buttons`) | Minimap buttons of other addons are collected behind one SempreUI button with a fold-out panel (up to 6 columns, sorted by name). Left click opens the panel, right click opens the settings, dragging moves the button around the minimap. `/sempre knoepfe` lists collected and kept-outside buttons with numbers, `raus <n\|name>` (`out`) puts one back on the minimap and keeps it there, `rein <n\|name>` (`in`) takes it back, `neu` (`rescan`) scans again, `zeigen` (`show`) toggles the panel when the SempreUI button is switched off. Nothing of the other addons is changed, they are only moved |

## Fonts

SempreUI windows use Grenze SemiBold for titles, Atkinson Hyperlegible Next
(regular and bold) for text and Atkinson Hyperlegible Mono for numbers. The
font files are under `Sempre/Media/Fonts/` and are licensed under the SIL Open
Font License 1.1 (licence texts next to them); the addon code is GPL 3.0.

Two options in the general SempreUI settings: "SempreUI fonts" (default on;
off uses the game fonts everywhere) and "Replace game fonts too" (default off;
replaces the font files of the game's common font objects, keeping size, flags
and colour, and restores the originals when switched off; some frames update
only after `/reload`). The fonts have no Cyrillic, Korean or Chinese glyphs, so
on `ruRU`, `koKR`, `zhCN` and `zhTW` clients they are never used and both
options are greyed out. Modules set fonts through `SempreUI:SetFont(fontString,
role, size, flags)` with the roles `title`, `text`, `bold` and `mono`.

## License

GPLv3 with one additional term about the name, see [LICENSE](LICENSE) and
[NAMING.md](NAMING.md).

