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

## Third-party content

- **Data/QuestieNodes.lua** - herb, ore and chest spawn coordinates from the
  Questie database (QuestieDB, https://github.com/Questie/Questie), licensed
  under the GPLv3. Converted (filtered to gathering objects, reformatted) by
  tools/import_questie.py. The name "Questie" and its logo belong to the
  Questie team and are not covered by this license.
- **Data/ItemNames.lua** - item names and IDs from the same Questie database
  (GPLv3), converted by tools/import_item_names.py.
- **Data/RecipeData.lua** - recipes (product, amount, required skill, reagents)
  from SkillUp Forever by Cillian Berragan (https://github.com/cjber/skillup-forever),
  GPL-3.0-or-later, which reads them from the WoW: Forever client tables
  (via wago.tools) and CMaNGOS classic-db (GPL-3.0). Converted by
  tools/import_skillup.lua.
- **Libs/HereBeDragons** - HereBeDragons by Nevcairiel, BSD license, bundled
  with CallbackHandler-1.0 (BSD) and LibStub (public domain).
- **Libs/LibDataBroker-1.1** - LibDataBroker by tekkub, under its own license.
- **Libs/LibDBIcon-1.0** - LibDBIcon, under its own license.

World of Warcraft is a trademark of Blizzard Entertainment. Gathercraft is a
fan-made addon and is not affiliated with or endorsed by Blizzard.
