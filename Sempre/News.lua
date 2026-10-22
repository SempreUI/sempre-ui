-- Copyright (C) 2026 SempreUI
-- SPDX-License-Identifier: GPL-3.0-only, with additional terms in NAMING.md

-- Release notes shown by the "what's new" window (SempreUI.News), newest first.
-- version: same as the CHANGELOG heading. date: dd.mm.yyyy. points: up to 8
-- short lines (under 90 characters), each with a German and an English text.
-- No links, no player names. A new CHANGELOG entry gets a matching entry here
-- in the same pull request.

local S = SempreUI

S.News = {
	{
		version = "0.1.0-alpha2",
		date = "22.10.2026",
		points = {
			{ de = "Einstellungsfenster mit allen Optionen und Modulschaltern", en = "Settings window with all options and module switches" },
			{ de = "Postübersicht: alle Mails pro Charakter, alles nehmen am Briefkasten", en = "Mail overview: all mail per character, take all at the mailbox" },
			{ de = "Goldjournal Teil 2: Auktionshaus, Einkäufe und Händlerprüfung", en = "Gold journal part 2: auction house, purchases and vendor check" },
			{ de = "Wegpunkte mit /way: Pfeil in der Welt, Marker auf Minimap und Weltkarte", en = "Waypoints with /way: arrow in the world, markers on minimap and world map" },
			{ de = "Minimap-Knöpfe anderer Addons hinter einem SempreUI-Knopf gesammelt", en = "Minimap buttons of other addons collected behind one SempreUI button" },
			{ de = "Eigene Schriften für SempreUI-Fenster, auf Wunsch auch für das Spiel", en = "Own fonts for SempreUI windows, optionally for the game as well" },
		},
	},
	{
		version = "0.1.0-alpha1",
		date = "22.10.2026",
		points = {
			{ de = "Gegenstände: Taschen, Bank, Post und Gold aller Charaktere im Tooltip", en = "Items: bags, bank, mail and gold of all characters in the tooltip" },
			{ de = "Goldjournal: jede Geldänderung nach Quelle, pro Sitzung, Tag und Woche", en = "Gold journal: every money change by source, per session, day and week" },
			{ de = "Beutegedächtnis: Droprate, Wert pro Kill und Farmziele aus eigenem Looten", en = "Loot memory: drop rates, value per kill and farm goals from your own looting" },
			{ de = "Fehlersammler: /sempre fehler listet Lua-Fehler und blockierte Aktionen", en = "Error collector: /sempre errors lists Lua errors and blocked actions" },
		},
	},
}
