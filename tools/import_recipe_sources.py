#!/usr/bin/env python3
"""
Builds Data/RecipeSources.lua: where each recipe in Data/RecipeData.lua is learned.

    python tools/import_recipe_sources.py <skillup-forever> <QuestieDB>/data/Forever -o Data/RecipeSources.lua

Sources (both GPL-3.0, credited in NOTICE.md):
  * SkillUp Forever (https://github.com/cjber/skillup-forever): trainer fees,
    which pattern/recipe item teaches a spell, its likeliest named drops and
    world drops.
  * QuestieDB (https://github.com/Questie/Questie): who sells a recipe item,
    which quest rewards it, and NPC names, zones (area IDs) and factions.
Only the recipes Gathercraft ships are written.
"""
import argparse, os, re, sys

# ---------------------------------------------------------------- SkillUp
def block(text, name):
    start = text.index("ns.%s = {" % name)
    end = text.index("\n}", start)
    return text[start:end]

def skillup(root):
    def read(f):
        return open(os.path.join(root, "Data", f), encoding="utf-8").read()
    recipes, sources, trainer = read("Recipes.lua"), read("Sources.lua"), read("Trainer.lua")
    fees = {int(s): int(fee) for s, fee in re.findall(r"\[(\d+)\] = \{ (\d+), \d+ \}", block(trainer, "TrainerFees"))}
    scrolls = {int(s): int(item) for s, item in re.findall(r"\[(\d+)\] = \{ (\d+), \d+ \}", block(recipes, "RecipeScrolls"))}
    drops = {}
    for item, inner in re.findall(r"\[(\d+)\] = \{ (.*) \},", block(sources, "ScrollDrops")):
        drops[int(item)] = [(int(n), float(c)) for n, c in re.findall(r"\{ (\d+), ([\d.]+) \}", inner)]
    world = {int(i) for i in re.findall(r"\[(\d+)\] = true", block(sources, "WorldDrops"))}
    return fees, scrolls, drops, world

# ---------------------------------------------------------------- Questie
class Lit:
    """Reads one Lua table literal as QuestieDB writes it ('strings', nil, numbers, {...})."""
    def __init__(self, s):
        self.s, self.i = s, 0
    def ws(self):
        while self.i < len(self.s) and self.s[self.i] in " \t\r\n":
            self.i += 1
    def value(self):
        self.ws()
        c = self.s[self.i]
        if c == "{":
            return self.table()
        if c in "'\"":
            q, j, out = c, self.i + 1, []
            while self.s[j] != q:
                if self.s[j] == "\\":
                    j += 1
                out.append(self.s[j]); j += 1
            self.i = j + 1
            return "".join(out)
        m = re.compile(r"nil|true|false|-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?").match(self.s, self.i)
        self.i = m.end()
        w = m.group(0)
        if w == "nil": return None
        if w in ("true", "false"): return w == "true"
        return float(w) if any(ch in w for ch in ".eE") else int(w)
    def table(self):
        self.i += 1
        arr, keyed, n = [], {}, 1
        while True:
            self.ws()
            if self.s[self.i] == "}":
                self.i += 1
                break
            if self.s[self.i] == "[":
                self.i += 1
                k = self.value(); self.ws(); self.i += 1  # ]
                self.ws(); self.i += 1                     # =
                keyed[k] = self.value()
            else:
                v = self.value()
                keyed[n] = v; arr.append(v); n += 1
            self.ws()
            if self.s[self.i] in ",;":
                self.i += 1
        return keyed

def rows(path, wanted):
    """id -> list of fields for the wanted ids only (1-based like Lua)."""
    out = {}
    for m in re.finditer(r"^\[(\d+)\] = (\{.*\}),\s*$", open(path, encoding="utf-8").read(), re.M):
        i = int(m.group(1))
        if i in wanted:
            out[i] = Lit(m.group(2)).value()
    return out

def field(row, n):
    return row.get(n) if row else None

def as_list(t):
    return [t[k] for k in sorted(k for k in t if isinstance(k, int))] if isinstance(t, dict) else []

# ---------------------------------------------------------------- main
def shipped_spells(path):
    text = open(path, encoding="utf-8").read()
    body = text[text.index("    spells = {"):text.index("    guessed = {")]
    return {int(s) for s in re.findall(r"\]=(\d+)", body)}

def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("skillup")
    ap.add_argument("questie_forever", help="QuestieDB/data/Forever")
    ap.add_argument("--recipes", default=os.path.join(os.path.dirname(__file__), "..", "Data", "RecipeData.lua"))
    ap.add_argument("-o", "--out", default="RecipeSources.lua")
    args = ap.parse_args()

    spells = shipped_spells(args.recipes)
    fees, scrolls, drops, world = skillup(args.skillup)
    fees = {s: f for s, f in fees.items() if s in spells}
    scrolls = {s: i for s, i in scrolls.items() if s in spells}
    items = rows(os.path.join(args.questie_forever, "foreverItemDB.lua"), set(scrolls.values()))

    entries, npcs = {}, set()
    for item in sorted(set(scrolls.values())):
        row = items.get(item)
        vendors = [v for v in as_list(field(row, 14)) if isinstance(v, int)]
        quests = as_list(field(row, 6))
        named = drops.get(item, [])
        parts = []
        if vendors:
            parts.append("V:" + ",".join(str(v) for v in vendors[:6]))
            npcs.update(vendors[:6])
        if named:
            parts.append("D:" + ",".join("%d:%g" % (n, c) for n, c in named[:3]))
            npcs.update(n for n, _ in named[:3])
        else:
            # Questie knows who drops it, without a chance (0 = unknown)
            dropped = [d for d in as_list(field(row, 2)) if isinstance(d, int)][:3]
            if dropped and item not in world:
                parts.append("D:" + ",".join("%d:0" % d for d in dropped))
                npcs.update(dropped)
        if item in world:
            parts.append("W")
        if quests:
            parts.append("Q")
        entries[item] = "|".join(parts)

    npc_rows = rows(os.path.join(args.questie_forever, "foreverNpcDB.lua"), npcs)
    npc_out = {}
    for n in sorted(npcs):
        r = npc_rows.get(n)
        if not r or not isinstance(field(r, 1), str):
            continue
        area = field(r, 9) or 0
        spawns = field(r, 7) or {}
        x = y = 0
        pts = spawns.get(area) if isinstance(spawns, dict) else None
        if not pts and isinstance(spawns, dict) and spawns:
            area = sorted(spawns)[0]
            pts = spawns[area]
        first = as_list(pts)[0] if pts else None
        if isinstance(first, dict):
            x, y = first.get(1) or 0, first.get(2) or 0
        faction = field(r, 13) or ""
        npc_out[n] = "%s|%d|%s|%d|%d" % (field(r, 1), area or 0, faction, round(x * 100), round(y * 100))

    lines = [
        "-- Generated by tools/import_recipe_sources.py, do not edit by hand.",
        "-- Where recipes are learned. Trainer fees, recipe items and their likeliest drops from",
        "-- SkillUp Forever (https://github.com/cjber/skillup-forever, GPL-3.0-or-later); vendors,",
        "-- quest rewards and NPC names/zones from Questie (https://github.com/Questie/Questie, GPLv3).",
        "-- trainer: [recipe spell] = fee in copper (taught by a trainer)",
        "-- scroll:  [recipe spell] = the recipe item that teaches it",
        "-- items:   [recipe item] = \"V:vendor,...|D:npc:chance%,...|W (world drop)|Q (quest reward)\"",
        "-- npcs:    [npc] = \"name|areaID|friendly to (A/H)|x*100|y*100\"",
        "GathercraftRecipeSources = {",
        "    trainer = {",
    ]
    lines += ["        [%d] = %d," % (s, f) for s, f in sorted(fees.items())]
    lines += ["    },", "    scroll = {"]
    lines += ["        [%d] = %d," % (s, i) for s, i in sorted(scrolls.items())]
    lines += ["    },", "    items = {"]
    lines += ["        [%d] = %s," % (i, lua_str(e)) for i, e in sorted(entries.items()) if e]
    lines += ["    },", "    npcs = {"]
    lines += ["        [%d] = %s," % (n, lua_str(e)) for n, e in sorted(npc_out.items())]
    lines += ["    },", "}", ""]
    with open(args.out, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))
    known = sum(1 for e in entries.values() if e)
    print("recipes: %d by trainer, %d by recipe item (%d items, %d with a known source), %d npcs"
          % (len(fees), len(scrolls), len(entries), known, len(npc_out)), file=sys.stderr)

if __name__ == "__main__":
    main()
