## v0.1.13 – Skill plan with material list, run summary, and routes that ask ahead

### New
- **Skill plan:** Crafting tab → *Skill plan* (or `/gcr plan`). Pick a profession and a target skill, and Gathercraft works out the cheapest way there: which recipe to make from which skill, how many, and where to learn it (trainer or vendor). Below: every material you need, what you already have in bags and bank, what's missing and what it costs. Bars and bolts you can make yourself are broken down into ore and cloth – and herbs and ore get a *Farm* button that starts a farm run for them. Prices come from your auction house scan; without one they are rough.
- **Skill bars to 300 and a trainer reminder:** the profession bars in the overview now show the whole way to 300 – the part your trainer has unlocked is lighter. 5 points before the end of a rank, one line in chat reminds you to visit your trainer, and once more when you're there (Options → General).
- **Run summary:** when you stop a farm run, a small window shows what it brought – time, nodes, nodes per hour, worth, gold per hour and skill-ups. *Share in guild* or *Share in group* posts one line in chat, only when you click it. Don't want it? Options → Farm runs → *Show a summary when a run ends*.
- **Routes ask ahead:** a farm run through other zones asks other Gathercraft players about those zones right away (a few zones, one after another) – new spots they found there are in your route before you arrive.
- **Waypoints to recipe vendors:** in the Crafting tab, click a recipe you don't know yet and Gathercraft sets a waypoint to the nearest vendor of your faction who sells it.
- **Welcome:** new players get a short welcome on their first start – three steps to get going. `/gcr welcome` shows it again.
- **What's new:** after an update, one line in chat says what's new. `/gcr whatsnew` repeats it.

### Changed
- **Right-click farms where you are:** right-click on the minimap button, the run buttons in the overview and the key binding now always farm the zone you're in, for the gathering professions you have – whatever is picked in the Zones tab. In a capital city that's its zone (Thunder Bluff → Mulgore, Orgrimmar → Durotar, ...). Too few known spots here: the nearest zone that has some. Before, a run could stretch across the whole continent.
- **Clearer route line:** on the world map the line keeps the same spacing all the way to the end – long rounds no longer fall apart into scattered dots far from you. The default style is now a solid line (Options → Farm runs → Route line).
- **The map shows everything:** unticking a zone or material in the Zones tab now only decides what *Start run* farms – the pins stay on the map. Want the old way? Options → Map & minimap → *Hide zones and materials unticked in the Zones tab*.
- **Loop adapts to busy zones:** the Loop route type now watches how fast spots come back while you ride. Where many players farm, a spot is soon back to what it can be – so the round gets shorter and runs through the dense part of the zone more often, like the small loops in farming guides. Where you farm alone, it stays the whole round (or grows back). One line in chat says when it changes, and the next run in that zone starts the same way for a few hours. In our simulations (two-hour runs in Durotar, Mulgore and Dun Morogh) with eight other gatherers in the zone, Loop now brings 6–27% more nodes per hour than before and 3–16% more than Smart; farming alone it is as good as Smart or a little better.
- **Runs over several zones stay together:** a run from the Zones tab plans the picked zones that border each other near you. Zones far away are left out for this run, and one line in chat names them – start a run there once you're there.

### Fixed
- Nodes were sometimes saved as "Find Herbs" or "Find Minerals" (the name of the tracking button under the mouse). Such entries are repaired on login.

### Under the hood
- Newer WoW functions are used where the game has them (the old ones stay as a fallback), and a `.luarc.json` lets the Lua language server and Ketho's WoW API extension check the code cleanly.
