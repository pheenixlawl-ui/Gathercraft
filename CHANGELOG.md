## v0.1.14 – Leveling: pins in the trainer colour

### New
- **Pins in the trainer colour:** while you level a gathering profession, the ring around every herb and ore pin shows what it does for your skill – orange: a skill-up every time, yellow: likely, green: sometimes, grey: never, red: your skill is too low. You see at a glance which node is worth the little detour. Grey nodes step back a bit. Where Copper or Tin can spawn on the same spot, the ring shows the better of the two. At 300, or for nodes whose requirement isn't known yet, the ring stays silver.
- **Hide nodes that give no more skill-ups:** one tick and grey nodes leave map and minimap – handy while you level, off again when you farm for gold. At 300 nothing is hidden.
- **New options page "Leveling"** for both, and the trainer reminder moved there too.
- **Built in: new Forever nodes found during the beta** – Poor Copper Vein, Wilted Peacebloom, Stunted Silverleaf and more, in Durotar, Mulgore and a new Forever zone. They show as "From the beta database (not confirmed yet)" until you or someone else finds them. Minimap guesses and spots already known from Questie are no longer part of this data.

### Changed
- **Smoother zone borders:** crossing from one zone into the next (Thunder Bluff and Mulgore, for example) no longer rebuilds every map pin – only the minimap pins move.
- **Only your own loot counts:** a gather is recorded only when its own loot arrives. A gather whose loot can't be told apart from another one is left out instead of guessed, so it no longer becomes an "Unknown Herb" entry and the same spawn isn't counted twice. (A new object nobody has a name for yet can still show up as "Unknown Herb".)
- **Better "was it there?" check after you arrive:** a gather you started is waited for, a different herb or vein next to the spot doesn't count as a find, and a late second try takes back an "empty".
- **Standing still counts once:** waiting at one spot no longer teaches a node "empty" again and again, and it counts as a single visit for the self-healing of shared nodes.
- **Shared finds during a run are bundled:** reports from other players that your run can use are taken over together, at most every 10 seconds; others no longer redraw your route. Parking or reactivating a shared node updates just that node.
- **Skip leaves a node out without learning it was empty:** you can skip a node because of a cliff or a mob in the way – it stays out of the run for 5 minutes, but it no longer counts as an empty visit: the hit statistics it has learned stay as they are.
- **Skill plan is more honest:** the total no longer shows "0c" when prices are missing but says how many have no price; trainer fees and recipes from vendors are listed on their own; a training step appears where your rank ends; you only make intermediate items yourself when you have the profession, the recipe and the skill; estimated prices are marked with "~".

### Fixed
- **Fishing gives your interact settings back:** the wider interact range used for the bobber is now remembered across /reload and logout and put back on the next login. A setting you change yourself while the line is out stays as you set it. If you set exactly the same value Gathercraft uses, it can't tell the difference. (After a game crash this can't always be done.)
- **Skill-up statistics at the end of a rank:** gathers at 75/75, 150/150 or 225/225 – where no point is possible until you train – no longer count in the skill-up statistics for that node kind.
- **The same node counts once in your run:** opening a node's loot again (or mining the same vein again) no longer adds to gathered, per hour and gold of the farm run, its summary and the line you share, or to the session totals.
- **Crafting costs without a price:** when reagents have no price yet, "Costs" shows "?" (or "~" when only some have one, the tooltip says how many have none) instead of "0c", and such recipes are no longer ranked by a profit nobody knows.
- **A run no longer gets stuck waiting:** checks for nodes you reached now also finish while the run has no target, so one empty node can't block the run until it stops by itself.
