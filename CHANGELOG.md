## v0.2.4 – 2026-11-28

### Added
- **The route line follows your ridden ways:** during a farm run, the head of the route line and the arrow follow the ways you have ridden yourself instead of a straight line; gaps between your ways are guessed. The run window says what the line follows right now: "Path: your ridden ways" (with the guessed share, without the first and last yards) or "Path: straight line". On unless you turn it off: "Route line and arrow follow your ridden paths" (Options › Sharing › Paths). Without height, a way may cross under a bridge or into a cave.
- **A smooth line along your ways:** the line is pulled tight through the ways you rode, with rounded corners, instead of following every 25-yard step. Until it is ready, the line stays straight, as with the switch off.
- **More starter spots:** 185 new gathering spots in the new zones Mount Hyjal, Zephras Isle and Riverglades.

### Changed
- **No hitch after a harvest:** a farm run gathers its points again only in the zones that changed, and the Smart plan improves the route in small bites, a little each frame.
- **Sharing your ways:** the window now tells you to paste each part into its own field of the form (Part 1, Part 2, …) and to submit once at the end.

### Fixed
- **Auction prices for gear:** weapons and armour now get their cheapest buyout, shown as "lowest offer" in the tooltip. With a few single offers, the price was the dearest of them. Trade goods keep their market price.
- **GathercraftSync no longer grabs /1 on a slow login:** after login, the sharing channel waits until General or another zone channel is there – up to 30 seconds (for example in an instance). If your sync channel is still on /1 from an older version, Gathercraft tells you once per session how to fix it (type /leave GathercraftSync and log out once).
- **Jumping is no fall:** jumping several times in a row no longer marks your recorded path as a fall. Real falls are still noted.
- **The fishing key no longer gets stuck on a lure you can't use yet:** it picks one you can use, or casts without a lure.
