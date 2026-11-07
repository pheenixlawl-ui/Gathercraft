## v0.1.16 – 2026-11-06

### New
- **Map and minimap:** pins show only what your professions can gather: herbs with Herbalism, ores with Mining. On by default, switch it off under Options, Map & minimap. Chests and fishing spots are not affected. Without a gathering profession one chat line tells you how to show the pins again.

### Changed
- **Right-click on the emblem:** without a gathering profession it no longer starts a run, but tells you to learn one from a trainer.
- **Sharing:** unconfirmed finds wait 7 days instead of 3 in zones with known spawn points.

### Fixed
- **Dungeons and combat:** fixed a flood of Lua errors when casting spells there. The client hides some values in those places; Gathercraft now skips them.
- **Gathering:** a buff or an attack can no longer be learned as a gathering spell. Spells learned by older versions are dropped once; real ones come back with their next gather.
