#!/usr/bin/env python3
"""
Builds Data/QuestieNodes.lua from Questie's Forever object database.

Node data from Questie (https://github.com/Questie/Questie), used with
permission and credit. Only herb, ore and treasure chest spawn points are
taken (object ID + position), nothing else.

Usage:
    python import_questie.py <QuestieDB>/data/Forever -o ../Data/QuestieNodes.lua
"""
import argparse, hashlib, json, os, re, sys

HERBS = {  # name -> herb item ID (for the icon)
    "Peacebloom": 2447, "Silverleaf": 765, "Earthroot": 2449, "Mageroyal": 785,
    "Briarthorn": 2450, "Stranglekelp": 3820, "Bruiseweed": 2453, "Wild Steelbloom": 3355,
    "Grave Moss": 3369, "Kingsblood": 3356, "Liferoot": 3357, "Fadeleaf": 3818,
    "Goldthorn": 3821, "Khadgar's Whisker": 3358, "Wintersbite": 3819, "Firebloom": 4625,
    "Purple Lotus": 8831, "Arthas' Tears": 8836, "Sungrass": 8838, "Blindweed": 8839,
    "Ghost Mushroom": 8845, "Gromsblood": 8846, "Golden Sansam": 13464, "Dreamfoil": 13463,
    "Mountain Silversage": 13465, "Plaguebloom": 13466, "Icecap": 13467, "Black Lotus": 13468,
}
ORES = {  # name -> ore item ID
    "Copper Vein": 2770, "Tin Vein": 2771, "Silver Vein": 2775, "Iron Deposit": 2772,
    "Gold Vein": 2776, "Mithril Deposit": 3858, "Truesilver Deposit": 7911,
    "Dark Iron Deposit": 11370, "Small Thorium Vein": 10620, "Rich Thorium Vein": 10620,
    "Incendicite Mineral Vein": 3340, "Lesser Bloodstone Deposit": 4278,
    "Indurium Mineral Vein": 5833,
    "Ooze Covered Silver Vein": 2775, "Ooze Covered Gold Vein": 2776,
    "Ooze Covered Mithril Deposit": 3858, "Ooze Covered Truesilver Deposit": 7911,
    "Ooze Covered Thorium Vein": 10620, "Ooze Covered Rich Thorium Vein": 10620,
}
CHESTS = {
    "Battered Chest", "Tattered Chest", "Solid Chest", "Large Battered Chest",
    "Large Solid Chest", "Large Iron Bound Chest", "Large Mithril Bound Chest",
    "Mithril Bound Chest", "Buccaneer's Strongbox",
}
SKIP_MAPS = {1459, 1460, 1461}  # battlegrounds


def split_top(s):
    """Splits the inside of a Lua table literal at top-level commas."""
    parts, depth, cur, in_str = [], 0, [], False
    i = 0
    while i < len(s):
        c = s[i]
        if in_str:
            cur.append(c)
            if c == "\\":
                cur.append(s[i + 1]); i += 1
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True; cur.append(c)
        elif c == "{":
            depth += 1; cur.append(c)
        elif c == "}":
            depth -= 1; cur.append(c)
        elif c == "," and depth == 0:
            parts.append("".join(cur)); cur = []
        else:
            cur.append(c)
        i += 1
    if cur:
        parts.append("".join(cur))
    return parts


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("forever_dir", help="QuestieDB/data/Forever")
    ap.add_argument("-o", "--out", default="QuestieNodes.lua")
    args = ap.parse_args()

    conv = json.load(open(os.path.join(args.forever_dir, "conversion.json"), encoding="utf-8"))
    area_to_map = {t["area_id"]: t["ui_map_id"] for t in conv["geometry"]["transforms"]}

    path = os.path.join(args.forever_dir, "foreverObjectDB.lua")
    raw = open(path, encoding="utf-8").read()
    version = "questie-" + hashlib.sha1(raw.encode()).hexdigest()[:10]

    entry = re.compile(r'^\s*\[(\d+)\]\s*=\s*\{(.*)\},?\s*$')
    out, kinds, skipped_quest = {}, {}, 0
    for line in raw.splitlines():
        m = entry.match(line)
        if not m:
            continue
        oid, body = m.groups()
        if not body.startswith('"'):
            continue
        fields = split_top(body)
        name = fields[0].strip().strip('"').replace('\\"', '"')
        if name in HERBS:
            code, item = "h", HERBS[name]
        elif name in ORES:
            code, item = "o", ORES[name]
        elif name in CHESTS:
            code, item = "c", 0
        else:
            continue
        if len(fields) < 4:
            continue
        if fields[1].strip() != "nil" or fields[2].strip() != "nil":
            skipped_quest += 1  # quest objects are not gathering nodes
            continue
        spawns = fields[3].strip()
        if spawns == "nil":
            continue
        for zone in re.finditer(r'\[(\d+)\]\s*=\s*\{((?:\{[^{}]*\},?)*)\}', spawns):
            area, coords = int(zone.group(1)), zone.group(2)
            map_id = area_to_map.get(area)
            if not map_id or map_id in SKIP_MAPS:
                continue
            for x, y in re.findall(r'\{(-?[\d.]+),(-?[\d.]+)\}', coords):
                x, y = float(x), float(y)
                if not (0 <= x <= 100 and 0 <= y <= 100):
                    continue  # -1,-1 = unknown position
                out.setdefault(map_id, []).append(
                    ("o" + oid, code, round(x * 100), round(y * 100), item, name))
                kinds[code] = kinds.get(code, 0) + 1

    # Compact output: one string per zone ("id,x,y;id,x,y;..."), parsed in game
    # only for the zones a player actually visits. Names/types/items per object ID.
    kinds_by_id = {}
    for rows in out.values():
        for oid, code, x, y, item, name in rows:
            kinds_by_id[oid] = (code, item, name)
    lines = [
        "-- Generated by tools/import_questie.py, do not edit by hand.",
        "-- Node data from Questie (https://github.com/Questie/Questie), used with permission.",
        "GathercraftQuestieData = {",
        "    version = %s," % lua_str(version),
        "    -- object ID -> { type (h/o/c), itemID, name }",
        "    kinds = {",
    ]
    for oid in sorted(kinds_by_id, key=lambda k: int(k[1:])):
        code, item, name = kinds_by_id[oid]
        lines.append('        [%s] = {"%s",%d,%s},' % (lua_str(oid), code, item, lua_str(name)))
    lines += ["    },", "    -- uiMapID -> \"id,x*10000,y*10000;...\"", "    zones = {"]
    for map_id in sorted(out):
        rows = sorted(set(out[map_id]))
        packed = ";".join("%s,%d,%d" % (oid[1:], x, y) for oid, code, x, y, item, name in rows)
        lines.append('        [%d] = "%s",' % (map_id, packed))
    lines += ["    },", "}", ""]
    with open(args.out, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))
    total = sum(len(set(v)) for v in out.values())
    print("wrote %d spawn points in %d zones (herbs %d, ores %d, chests %d; skipped %d quest objects) -> %s [%s]" % (
        total, len(out), kinds.get("h", 0), kinds.get("o", 0), kinds.get("c", 0), skipped_quest, args.out, version),
        file=sys.stderr)


if __name__ == "__main__":
    main()
