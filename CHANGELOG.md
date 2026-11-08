## v0.1.18 – 2026-11-08

### Fixed
- **Skill plan, material amounts:** what the plan crafts along the way (Light Leather, bolts of cloth, bars, stones, powder, oils) was made a second time for the whole need. Now it is counted once, for every profession: one stock per item for the whole plan – what you have plus what the plan's own steps make – and only what is still missing after that is crafted extra. Example, Leatherworking to ~75 with 35 Light Leather in your bags: 249 Ruined Leather Scraps instead of 324.
- **Skill plan, what you have:** the open plan counts again when your bags or the bank change (it counted only when it opened). The reagent bag is always counted, also if the game leaves it out of its own count. With /gcr debug the plan says per material where its count comes from (bags, reagent bag, bank).
- **Sharing status:** Options, Sharing now says how many players a spot waits for (3 different players; guild and friends count at once), not "a second player".
- **Crafting:** WoW: Forever has only the modern profession window; the events of the old window are no longer asked for there, so /gcr crafttest says "none".

### New
- **Craft log:** what each finished craft did to your skill (skill before and after, the recipe's colour, how many it made), to make the skill plan better later. On your computer only, never shared; failed casts, hidden values, crafts at the rank's maximum and crafts that overlap the one before are kept apart; only clear single crafts count. Other spells never land in it. /gcr craftlog sums it up per colour, /gcr craftlog clear empties it; switch it off in Options, General.
- **Sharing:** counts over all sessions what other players sent you – spots in all, new ones (guild and friends, others after confirmation) and confirmations of spots you know. /gcr sync shows all of it, Options, Sharing one line.

### Changed
- **Minimap guesses:** a spot learned from the minimap that you never gather and nobody confirms is dropped after 30 days without a new look. Every new look starts the 30 days again; gathered, Questie, starter and shared spots stay, and so do guesses another player confirmed – also when close guesses are merged into one at login.
