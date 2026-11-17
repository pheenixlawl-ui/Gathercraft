#!/usr/bin/env python3
"""
Builds Data/Trainers.lua: the profession trainers of the skill plan's professions,
with the rank their English title names, their faction and their places.

    python tools/import_trainers.py <QuestieDB>/data/Forever -o Data/Trainers.lua

Source: QuestieDB (https://github.com/Questie/QuestieDB), used under the terms of the
GPLv3 with the permission of the Questie team - credited in NOTICE.md.

What is taken:
  * NPCs with the trainer flag (npcFlags 16) whose English title (subName) names a
    profession of the skill plan: "Alchemy Trainer", "Expert Alchemist", "Miner" ...
  * the rank the title names: Apprentice 1, Journeyman 2, Expert 3, Artisan 4,
    Master 5; 0 where the title names none ("Alchemy Trainer", "Superior Cook").
    Worked out here, from the English data, so the game needs no text of the
    client's language for it.
  * specialisation trainers ("Master Goblin Engineer", "Armorsmith", ...) and titles
    that name no profession ("Physician") are left out: they are listed when the
    file is made.
  * friendly to Alliance and/or Horde (Questie's "A", "H"); trainers hostile to both
    are left out.
  * every spawn in a zone Data/AreaMaps.lua knows (one without a map gets no waypoint).

The vendors of Data/RecipeSources.lua are checked here too: each one has exactly one
place in this source, and RecipeSources already ships it. Should a vendor have more
places in a later source, the file is not made (extend this tool for it then).
"""
import argparse, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from import_recipe_sources import Lit, as_list  # noqa: E402  (the same Lua reader)

PROFESSIONS = {
    "Alchemy": ["Alchemy", "Alchemist"],
    "Blacksmithing": ["Blacksmithing", "Blacksmith"],
    "Enchanting": ["Enchanting", "Enchanter"],
    "Engineering": ["Engineering", "Engineer"],
    "Leatherworking": ["Leatherworking", "Leatherworker", "Leathercrafter"],
    "Tailoring": ["Tailoring", "Tailor"],
    "Cooking": ["Cooking", "Cook", "Chef"],
    "First Aid": ["First Aid"],
    "Mining": ["Mining", "Miner"],
}
RANKS = {"Apprentice": 1, "Journeyman": 2, "Expert": 3, "Artisan": 4, "Master": 5}
WORD = {w: prof for prof, words in PROFESSIONS.items() for w in words}
TITLE = re.compile(r"^(?:(Apprentice|Journeyman|Expert|Artisan|Master|Superior) )?(%s)(?: Trainer)?(?: & Supplies)?$"
                   % "|".join(sorted((re.escape(w) for w in WORD), key=len, reverse=True)))


def title(sub):
    """(profession, rank) of a trainer's English title, or None"""
    m = TITLE.match(sub or "")
    if not m:
        return None
    return WORD[m.group(2)], RANKS.get(m.group(1), 0)


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("forever_dir", help="QuestieDB/data/Forever")
    here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Data")
    ap.add_argument("--maps", default=os.path.join(here, "AreaMaps.lua"))
    ap.add_argument("--sources", default=os.path.join(here, "RecipeSources.lua"))
    ap.add_argument("-o", "--out", default="Trainers.lua")
    args = ap.parse_args()

    maps = {int(a) for a, _ in re.findall(r"\[(\d+)\] = (\d+)", open(args.maps, encoding="utf-8").read())}
    sources = open(args.sources, encoding="utf-8").read()
    vendors = set()
    for v in re.findall(r'"V:([\d,]+)', sources):
        vendors.update(int(x) for x in v.split(","))

    out = {prof: {} for prof in PROFESSIONS}
    left_out, vendor_places = {}, {}
    text = open(os.path.join(args.forever_dir, "foreverNpcDB.lua"), encoding="utf-8").read()
    for m in re.finditer(r"^\[(\d+)\] = (\{.*\}),\s*$", text, re.M):
        npc = int(m.group(1))
        is_vendor = npc in vendors
        row = Lit(m.group(2)).value()
        spawns = row.get(7) if isinstance(row.get(7), dict) else {}
        if is_vendor:
            vendor_places[npc] = sum(len(as_list(p)) for p in spawns.values())
        if not ((row.get(15) or 0) & 16) or not isinstance(row.get(14), str):
            continue
        got = title(row.get(14))
        if not got:
            left_out[row.get(14)] = left_out.get(row.get(14), 0) + 1
            continue
        prof, rank = got
        friendly = row.get(13) or ""
        if not re.fullmatch(r"A?H?", friendly) or friendly == "":
            left_out["(hostile to both) " + row.get(14)] = left_out.get("(hostile to both) " + row.get(14), 0) + 1
            continue
        places = []
        for area in sorted(spawns):
            if area not in maps:
                continue
            for pt in as_list(spawns[area]):
                if isinstance(pt, dict) and pt.get(1) is not None and pt.get(2) is not None:
                    places.append("%d:%d:%d" % (area, round(pt[1] * 100), round(pt[2] * 100)))
        if not places:
            left_out["(no known map) " + row.get(14)] = left_out.get("(no known map) " + row.get(14), 0) + 1
            continue
        out[prof][npc] = "%s|%d|%s|%s" % (row.get(1), rank, friendly, ";".join(places))

    several = {n: c for n, c in vendor_places.items() if c > 1}
    missing = vendors - set(vendor_places)
    if several or missing:
        sys.exit("RecipeSources vendors with more than one place %r or not in the source %r: extend this tool"
                 % (sorted(several), sorted(missing)))

    lines = [
        "-- Generated by tools/import_trainers.py, do not edit by hand.",
        "-- Profession trainers: names, places and factions from the Questie database",
        "-- (QuestieDB, https://github.com/Questie/QuestieDB; Questie: https://github.com/Questie/Questie),",
        "-- used under the terms of the GPLv3 with the permission of the Questie team. See their LICENSE.md.",
        "-- The rank is read from the trainer's English title when this file is made:",
        "-- 1 Apprentice, 2 Journeyman, 3 Expert, 4 Artisan, 5 Master, 0 = the title names no rank.",
        "-- [profession] = { [npc] = \"name|rank|friendly to (A/H)|areaID:x*100:y*100;...\" }",
        "GathercraftTrainers = {",
    ]
    for prof in sorted(out):
        lines.append("    [%s] = {" % lua_str(prof))
        lines += ["        [%d] = %s," % (n, lua_str(e)) for n, e in sorted(out[prof].items())]
        lines.append("    },")
    lines += ["}", ""]
    with open(args.out, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))
    total = sum(len(v) for v in out.values())
    print("%d trainers (%s); %d recipe vendors, each with one place (shipped in RecipeSources)"
          % (total, ", ".join("%s %d" % (p, len(out[p])) for p in sorted(out)), len(vendor_places)), file=sys.stderr)
    for sub, n in sorted(left_out.items()):
        print("  left out: %dx %s" % (n, sub), file=sys.stderr)


if __name__ == "__main__":
    main()
