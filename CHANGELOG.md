## v0.1.11 – Learn nodes from the minimap, smarter runs, minimap your way

**Sorry for the wait!** This update comes about 20 hours later than planned. We used the WoW Forever stress test to collect node spots (Zephras Isle alone grew from 24 to 70 known nodes – they will ship with the next starter data update) and to test every new feature on the real launch client. A few things we found there are already fixed in this version. Thank you for your patience – and for all the feedback on Discord!

### Highlights
- **Learn nodes from the minimap:** point your mouse at a herb or vein that your tracking shows on the minimap, and Gathercraft remembers it – no need to ride there first.
- **Subtle minimap style (new default):** our pins get a thin silver ring and a see-through icon, so what the game's tracking shows *right now* stands out from "a node usually spawns here". Works great next to addons like Node Sight.
- **Gold target ring:** the next node of a farm run is marked with a pulsing gold ring on the map and minimap.
- **Gear and buffs count:** gloves, enchants and Goldthorn Tea now let you gather above your own skill – routes and Farm Spots know it.
- **Runs that understand questing and cliffs:** walk off for a quest and the run picks a new target near you; can't reach a node (cliff, waterfall)? The run notices and moves on.

### Minimap and map
- **Learn nodes from the minimap:** a known spawn point you point at is marked as *up right now*, and farm runs go there first. A new spot is added with a rough position: every hover makes it more exact (the mouse positions of one hover are averaged, and hovers with the minimap zoomed in count more), and harvesting it puts it exactly on the spot. Only what you point at yourself is read – nothing is scanned. Rough spots aren't shared with other players until you harvest them. Turn it off in the options if you like.
- **Subtle style** is on by default. Prefer the old look? Options → Minimap style → Normal.
- **Minimap opacity:** choose how visible Gathercraft's minimap pins are (20–100 %). The run target always stays fully visible.
- **World map and minimap apart:** two switches – for example Gathercraft on the big map for planning, and another addon on the minimap. `/gcr pins` still switches both.
- **Pins on the same spot** are always drawn in the same order: your own finds on top, known spawn points below.

### Farm runs
- **Next node marked:** a bigger pin with a pulsing gold ring, sticks to the minimap edge while far away, and shows even when node pins are off.
- **Your waypoint stays yours:** runs only use the game's waypoint when the Gathercraft arrow is off – and never replace or clear a waypoint you set yourself.
- **Questing during a run:** walk about 150 yards away from the target and the run picks a new one instead of pointing back all the time.
- **Can't get there?** If you keep moving for 25 seconds without getting closer (a cliff, a waterfall – routes only know straight lines), the run leaves that node out for a while and picks another. `/gcr unreachable` does the same by hand. Not while fighting, dead or on a flight.
- **"Empty" only when you could check:** only the run's target counts as found empty – not nodes you just pass, not while fighting, not when you skip. Routes learn fewer wrong things while you quest.
- **Waiting for respawns:** the farm panel counts down to the next expected respawn; a run with nothing to farm for 10 minutes stops by itself.
- **Route line:** the *Line* style is solid all around you, also where the route comes back past you.

### Skills
- **Gear and buffs count:** herbalism/mining bonuses let routes and Farm Spots include nodes above your own skill; skill-ups still go by your own skill. The bonus shows as "+N" in the Overview and tooltips, and a run notices it within seconds.

### Sharing (sync)
- **Self-healing shared nodes:** a node that only came from other players, that you found empty again and again (5 times over at least 12 hours) and never harvested, is left out of routes and shown faded – not deleted. It comes back as soon as a new player reports it or you harvest it. Nodes known to more than the first three players are never parked.
- **Two-part names:** your own sync messages are recognized with Forever's first + last names, so they are no longer treated as another player's.

### Other
- **Tidier options:** the options are now split into sections – Map & minimap, Farm runs, Sharing, Rares & prices, General – with a short line on what each one is about. Gathercraft remembers the section you had open.
- **Debug tab:** turning debug output on opens the "Gathercraft" chat tab right away, also when an old closed one was left over. `/gcr mmtest` shows what Gathercraft sees on the minimap, for bug reports.
