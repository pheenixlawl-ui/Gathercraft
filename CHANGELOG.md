## v0.1.12 – Loop routes, sharing you can see, and fixes from a full review

### New
- **Loop routes:** Options → Farm runs → Route type → *Loop*. One fixed round through all spawn points you can gather, ridden in the same direction again and again – like the routes in farming guides, but worked out by Gathercraft from its own spawn points. Empty or hard to reach points are left out until they can have a node again, new spots go in where they are on the way, and after a quest you join the round again ahead of where you left it. `/gcr route` shows the whole round before you start. *Smart* (planning live) stays the default – in our simulator both bring about the same nodes per hour, so pick what you like riding.
- **Herbs / minerals switch:** a small button next to the minimap switches your tracking between Find Herbs and Find Minerals with one click (shown when you know both; Shift-drag moves it along the minimap's edge). Prefer your action bar? Options → Map & minimap → *Put it on an action bar* creates the macro "GC Tracking" and puts it on your cursor. There is a key binding too. Every switch is your own click – nothing switches by itself.
- **See what sharing does:** Options → Sharing shows how many Gathercraft players were around in the last hour, how many spots you received and how many wait for a second confirmation – and now and then one line in chat tells you when spots of other players arrived (can be turned off).
- **Chests on or off:** Options → Map & minimap → *Show chests*.
- **World map pins in a ring:** the world map now uses the same silver rings as the minimap. Prefer the old look? Options → World map style → Normal.

A thorough review of v0.1.11 also found a few things that could get in your way. All fixed:

### Farm runs
- **The line follows you:** the dotted part from you to the next node is drawn again as you move (10 times a second) – it no longer starts where you stood when the route was planned.
- **Questing with a run on no longer blocks nodes:** walking crosswise to the target (a quest, a mailbox, a building in the way) was sometimes taken as "can't get there", and the node was left out for 15 minutes or more. Now only walking around without getting any closer counts – standing still doesn't, and walking away is handled as a detour.
- **"Hard to reach" is remembered properly:** for known spawn points it now survives a /reload or logout, and the count starts over after a day without problems.
- **A target that moves stays marked:** when a few more looks at the minimap move a rough spot, the gold ring and the arrival check move with it.

### Learning nodes from the minimap
- **Works on our own pins too:** Gathercraft's minimap pins now let the mouse through to the game's tracking blip, so Gathercraft learns that a known node is there right now. What Gathercraft knows about it shows in a small tooltip of its own – right below the game's tooltip (also below a quest area's), or next to the pin where the game shows nothing.
- **Several blips at once:** when the game lists several things in one tooltip (a quest and a vein), each name is read on its own.
- **No more double pins after harvesting:** a herb or vein learned from the minimap now always merges with your harvest, even when the game uses another object for the same herb (Peacebloom, Silverleaf, Earthroot, Copper and others have several).
- **The right node lights up:** pointing at a herb next to one you just picked now marks the herb you point at, not the one you just harvested.
- **Seen = real:** a shared node that was left out for being always empty comes back as soon as you see it on the minimap.

### Sharing (sync)
- **Made for megaservers:** when many players log in at once, one of them asks for the zone and everyone else listens to the answers – about 40 % less traffic on the sharing channel in our 800-player test, with the same spots reaching everyone.
- **Calmer channel:** a zone is answered at most every 5 minutes, answers are capped to what other players accept anyway, and repeated questions from one player are cut off. Your own finds are never stuck behind a long queue.
- **Harder to flood:** one player can only keep a limited number of unconfirmed reports with you, and the oldest reports make room instead of blocking new ones. Broken zone or item numbers are ignored.
- **Self-healing counts fresh:** an empty visit from long ago no longer counts towards leaving a shared node out.
