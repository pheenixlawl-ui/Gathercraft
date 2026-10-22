## v0.1.11 – Minimap your way, gear bonuses count

- **Minimap style:** new option *Subtle* – a silver ring around a smaller, see-through icon. What the game's herb and mineral tracking (or addons like Node Sight) shows right now stands out from "a node usually spawns here".
- **World map and minimap apart:** two switches – keep Gathercraft on the big map for planning and let something else handle the minimap. `/gcr pins` still switches both.
- **Minimap opacity:** set how visible Gathercraft's minimap pins are (20–100 %) – the lower, the more the game's live tracking stands out. The next node of a run always stays fully visible.
- **Learn nodes from the minimap:** point at a herb or vein your tracking shows on the minimap, and Gathercraft learns it – no need to ride there. A known spawn point is marked as *up right now* (farm runs go there first), a new one is added with a rough position – every further look makes it more exact, and harvesting it puts it on the spot. Only what you point at yourself is read; nodes only seen this way aren't shared. Can be turned off in the options.
- **Next node marked:** the next node of a farm run gets a bigger pin with a gold ring on the map and minimap, sticks to the minimap edge while it's far away, and shows even with node pins off.
- **Your waypoint stays yours:** farm runs only use the game's waypoint when the Gathercraft arrow is off – and never replace or clear a waypoint you set yourself.
- **Gear and buffs count:** herbalism/mining bonuses (gloves, enchants, Goldthorn Tea …) now let routes and Farm Spots include nodes above your own skill. Skill-ups still go by your own skill. The bonus shows as "+N" in the Overview and tooltips, and a run notices it within seconds.
- **Route line:** the *Line* style is now solid everywhere around you – also where the route comes back past you later.
- **Waiting for respawns:** the farm panel counts down to the next expected respawn, and a run with nothing to farm for 10 minutes stops by itself.
- **Debug tab:** turning debug output on opens the "Gathercraft" chat tab right away, also when an old closed one was left over.
- **Self-healing shared nodes:** a node that only came from other players, that you found empty again and again (5 times, spread over at least 12 hours) and never harvested, is left out of routes and shown faded. It is not deleted: it comes back as soon as a player who didn't report it before reports it, or when you harvest it. Nodes known to more players than the first three are never parked.
- **Questing during a run:** walk far away from the run's target (about 150 yards) and the run picks a new target instead of pointing back all the time.
- **"Empty" only when you could check:** only the run's target counts as found empty – not nodes you just pass on the way, not while you are fighting, not when you skip one. Routes learn less wrong things while you quest or fight.
- **Two-part names:** your own sync messages are recognized with Forever's first + last names too, so they are no longer handled as another player's.

