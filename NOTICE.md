# Licenses in Gathercraft

Gathercraft - Gather. Route. Profit.
Copyright (C) 2026 pheenixlawl

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. It is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See LICENSE for the full text.

Source code: https://github.com/pheenixlawl-ui/Gathercraft

## Name and logo (additional term under GPLv3 section 7(e))

The GPLv3 lets you copy, change and share the code. It does not give you the
right to use the name "Gathercraft", the slogan "Gather. Route. Profit." or the
Gathercraft emblem, logo and banner (Media/Icon.tga, Media/IconRound.tga,
docs/icon.png, docs/banner.png) as the name or branding of your own version.

- Sharing an unchanged copy of Gathercraft: fine, name and logo included.
- Sharing a changed version (a fork): give it a different name and its own
  icon, and do not present it as the official Gathercraft or as made by
  pheenixlawl. Saying "based on Gathercraft" with a link is welcome.

## Third-party content

- **Data/QuestieNodes.lua** - herb, ore and chest spawn coordinates from the
  Questie database (QuestieDB, https://github.com/Questie/Questie), licensed
  under the GPLv3. Converted (filtered to gathering objects, reformatted) by
  tools/import_questie.py. The name "Questie" and its logo belong to the
  Questie team and are not covered by this license.
- **Data/ItemNames.lua** - item names and IDs from the same Questie database
  (GPLv3), converted by tools/import_item_names.py.
- **Data/NodeNames.lua** - herb, ore and chest names in other languages from
  Questie's object lookups (GPLv3), converted by tools/import_node_names.py.
- **Data/RecipeData.lua** - recipes (product, amount, required skill, reagents)
  from SkillUp Forever by Cillian Berragan (https://github.com/cjber/skillup-forever),
  GPL-3.0-or-later, which reads them from the WoW: Forever client tables
  (via wago.tools) and CMaNGOS classic-db (GPL-3.0). Converted by
  tools/import_skillup.lua.
- **Data/AreaMaps.lua** - zone area IDs and their map IDs from the Questie
  database (GPLv3), converted by tools/import_area_maps.py (for waypoints to
  recipe vendors).
- **Data/RecipeSources.lua** - where recipes are learned: trainer fees, recipe
  items and their likeliest drops from SkillUp Forever (GPL-3.0-or-later, see
  above); vendors, quest rewards and NPC names and zones from the Questie
  database (GPLv3). Converted by tools/import_recipe_sources.py.
- **Libs/HereBeDragons** - HereBeDragons by Nevcairiel, BSD license, bundled
  with CallbackHandler-1.0 (BSD) and LibStub (public domain).
- **Libs/LibDataBroker-1.1** - LibDataBroker by tekkub, under its own license.
- **Libs/LibDBIcon-1.0** - LibDBIcon, under its own license.

World of Warcraft is a trademark of Blizzard Entertainment. Gathercraft is a
fan-made addon and is not affiliated with or endorsed by Blizzard.
