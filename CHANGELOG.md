## v0.1.20 – 2026-11-09

### Fixed
- **Herbs/minerals button:** on a square minimap (UI addons that tell their shape via GetMinimapShape) the button now sits on the edge of the rectangle instead of a circle around the centre, and above the minimap's frame. Round minimaps: as before. Shift-drag and the saved angle work the same.

### Changed
- **Craft log, Create All:** crafts of one recipe cast back to back (Create All) are counted as one block – how many casts, your skill before the first and after the last – when the block is clear: one recipe, no failure or hidden value in it, not at the rank's maximum, no more points than casts, the same colour throughout and, for yellow/green, the same distance group to grey. The points of a block count as that many successful crafts because a craft gives at most one skill point; should a craft of a profession ever be measured with more than one, that profession's series are no longer counted, and /gcr craftlog says so. Switching the recording off or on, or clearing the log, ends everything still open. Anything else stays "overlapping" as before. /gcr craftlog shows a line "from series (Create All)", and its first line counts crafts, a block and its casts once.
- **Craft log, colours:** the game ships only the yellow and the grey threshold of a recipe, so the log no longer makes up a green one: everything between the two is one line, "yellow/green". The distance to grey stays the real statistic; nothing stored changes.
