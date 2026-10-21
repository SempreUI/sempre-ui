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
| `/sempre perf` | Memory per SempreUI module |
| `/sempre errors` (`fehler`) | Recorded Lua errors and blocked addon actions, SempreUI first; `all` (`alle`) lists every record, `clear` (`leeren`) empties the list |
| `/sempre version` | Addon version and client build |
| `/sempre items` | Gold per character, age of bank and mail snapshots (`debug`: scan count) |
| `/sempre gold` (`ledger`) | Gold journal of this character: session, today and last 7 days by source; `all` (`alle`) shows the last 7 days per character, `items` the top 10 vendor sales of the last 30 days |
| `/sempre loot` | Loot memory: this session (kills, gathers, money, item value, gold per hour) and farm goals. `goal <item> <count>` (`ziel`) sets a goal, `goal remove <item>` (`ziel weg`) removes it, `where <item>` (`wo`) lists the best mobs and nodes for an item, `mob` shows the drop table of the target or the last looted mob, `top` ranks mobs by value per kill. Everything is learned from your own looting |

## License

GPLv3 with one additional term about the name, see [LICENSE](LICENSE) and
[NAMING.md](NAMING.md).

