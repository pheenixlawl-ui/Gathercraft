## v0.1.17 – 2026-11-08

### New
- **Run window:** the "-" button folds it into one slim line (title, time, next node, Skip, Stop); "+" brings it back. "Hide the run window" (Options, Farm runs) hides it completely: arrow, target ring and minimap keep guiding you, Stop with a right-click on the minimap button or /gcr stop. The same for the fishing window (Options, General).
- **Minimap:** new style "Ring only", now the default on the minimap: a coloured ring without an icon, so the yellow dot of the game's tracking shows in the middle; the run target there is a broad gold ring without an icon. "Normal" stays if you chose it. "Subtle" was the old default and saved the same way, so if you had picked it on purpose, pick it again once in the options. The world map is unchanged.
- **Route line:** on the minimap it lies below the pins and stops just before each one. It has its own switch ("Route line on the minimap"), and "Route line shows" picks the whole route, the next 10 points or nothing (Smart: next 10, Loop: whole round until you choose). /gcr line says where colour and style are set.
- **Fishing:** "Mark my bobber" (on by default) puts the game's icon over your bobber while the line is out. Stop ends the session with a summary like a farm run, ready to share. "Louder bobber splash while fishing" (off by default) turns effects up and music and ambience down while the line is out. Your settings come back when the line comes in or you press Stop; a value you change meanwhile stays as you set it.
- **Crafting:** click a column title to sort (Item, Skill, Profit, Sells for, Costs, Can make), click again for the other direction. By default the required skill, lowest first; it has its own column. Recipes whose skill isn't known show "?" and come last.

### Changed
- **Smart route:** the shown route is untangled once more after points were left out, so the line crosses itself less often.
- **Tanning Rack (Leatherworking):** needs skill 125 instead of 140, its skill-up colours are 15 lower (Blizzard hotfix of 06.11.).
- **Debug output:** "SCAN REPLICATE_ITEM_LIST_UPDATE left out" comes once per scan; further updates are counted in one line.

### Fixed
- **Cities:** pointing at the minimap from a capital city (Thunder Bluff) put the herbs below on the small city map. They go to the zone around the city now; old guesses move there once.
- **Continent map:** nodes found where the game reported only the continent (Kalimdor) go to their zone, when the map knows it at that spot.
- **Crafting:** events this client doesn't know are no longer dropped silently: /gcr crafttest names them, and /gcr debug once at login.
