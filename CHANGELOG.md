## v0.2.2 – 2026-11-23

### Added
- **Tooltip options for the map pins:** Options › Map & minimap has two new rows. "World map tooltip": Always or With Shift – with Shift, the world map pins let the mouse through to what lies below them, such as quest symbols; hold Shift to point at a pin. "Minimap tooltip": Always, With Shift or Never. Learning the nodes you point at works with every setting.
- **`/gcr visitlog`:** a log of your route visits and gathers, for looking into how nodes come back – off unless you turn it on (`/gcr visitlog on`, `off`, `status`, `clear`). It is kept in your saved data only on this computer; nothing is sent.

### Changed
- **World map and minimap pins do less work:** the check every 3 seconds looks only at the pins that are shown, and at none while the map is closed; a login builds the world map pins once; a zone you see for the first time on the world map adds only its own pins instead of rebuilding them all. On the minimap, the 3-second pass looks only at the pins near you, and a pin that comes near gets its look right away. Very dense zones can still cost performance on the world map – if the map stutters, turn off "Show nodes on the world map" (Options › Map & minimap).
- **Questing options on Leveling:** the questing switch, its radius and the arrow moved from Map & minimap to Options › Leveling, to make room for the tooltip rows.
- **Sharing:** `/gcr sync` shows which Gathercraft versions the players around you run, what the game refused to send, and what was received but not counted (the same player again, spots already confirmed). A shared spot keeps at most 4 reporter names instead of 8, so the messages get shorter.
- **Starter data refreshed:** new herb and ore spots for Mount Hyjal, Riverglades and Zephras Isle, from what Gathercraft players gathered and shared up to 21 November; every spot shipped before stays.
- **Professions on German and other clients:** a profession is now told by its skill line, not by its name in your language. Recipes saved under a German name such as "Kräuterkunde" move to the profession they belong to at your next login; two lists of one profession are put together, nothing is lost. Where the game hides a profession's name, nothing is stored under it.
- **A profession you gave up:** leaves the Crafting tab's profit list ("Mine") and your own professions at the next login or reload; its recipes stay saved, in case you learn it again.

### Fixed
- **The route line no longer piles up world map pins:** with a farm run's route line on, every move put the line's head onto the world map again – once you had opened the world map, the addon's memory kept growing while you rode. The line's world map dots are now drawn only while the world map is open.
