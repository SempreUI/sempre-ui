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
| `/sempre version` | Addon version and client build |
| `/sempre items` | Gold per character, age of bank and mail snapshots (`debug`: scan count) |

## License

GPLv3 with one additional term about the name, see [LICENSE](LICENSE) and
[NAMING.md](NAMING.md).

