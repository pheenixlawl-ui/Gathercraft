## v0.2.3 – 2026-11-26

### Added
- **Share your ridden ways:** `/gcr shareways` (or "Share my ways..." in Options › Sharing) turns the ways you have recorded into text. Copy each part with Ctrl+C and send it through a short form; the window shows the form's link for you to copy. Nothing is sent by itself, and no browser opens. The text holds only the ways – rough 25-yard steps, how hard each was to ride and where you fell – and a random code for this submission: no names, no times, no prices.
- **A hint, once:** when you have recorded 2,000 path steps, a chat line points you to `/gcr shareways` – once per character, a minute after login and not in combat. Turn it off with "Donation hint in chat" (Options › Sharing).
- **Your best runs per zone:** the run summary shows your best of the last 20 runs in a zone – nodes per hour and gold per hour, each on its own – and tells you when a run is a new personal best. A run counts from 10 minutes of riding; best runs are kept per character, filter and route goal, on this computer only.
- **Search range:** during a farm run, once the node the run heads for is within the range of Find Herbs / Find Minerals (150 yards unless you change "Search range" in Options › Rares & prices), its gold pin gets a light-blue ring and the run window says "In search range - no yellow dot? Press Skip." A ring of dots on the minimap can show the range ("Show the search range on the minimap during farm runs", off by default). Nothing is skipped by itself.
- **`/gcr mapdiag`:** switches for testing map performance.

### Changed
- **Smoother farm runs:** less work and less memory while you ride. The route line's head no longer makes garbage around the minimap pins, a run keeps its points from plan to plan, and gathering a run's points again after a harvest skips the zones on other continents and the kind checks where nothing is unticked.
- **The skill plan counts your stock:** materials you already have count at their market value, and of two steps that cost the same, the one that uses your stock comes first.
- **`/gcr perf on`** also shows how much garbage each part of the addon makes, next to its time, and the addon's memory at the start and at the end.
