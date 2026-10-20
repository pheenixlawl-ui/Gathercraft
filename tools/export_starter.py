#!/usr/bin/env python3
"""
Builds Data/StarterData.lua from one or more Gathercraft (or old WoWFFarm) SavedVariables files.

Usage:
    python export_starter.py Gathercraft.lua [more.lua ...] -o ../Data/StarterData.lua
                             [--version beta-2026-10-19] [--min-reporters 1]

Only own, real nodes are exported (game object id "o123", known type, no
"source" field), so imports from sync or older starter data never come back.
With --include-sync, nodes other players shared that were confirmed (guild,
friends or 3 reporters) count too: the way to ship new Forever zones nobody
of us has farmed yet. Shipped starter nodes still only show once confirmed.
Nodes of the same kind closer than --radius (map fraction) are merged; the
number of files that had a node is stored as "reporters".
"""
import argparse, datetime, os, re, sys

# --- tiny parser for the Lua subset WoW writes into SavedVariables ---------
TOKEN = re.compile(r'''\s*(?:(--[^\n]*)|(\[)|(\])|(\{)|(\})|(=)|(,)|(;)|
    ("(?:\\.|[^"\\])*")|(-?\d+\.?\d*(?:[eE][-+]?\d+)?)|([A-Za-z_][A-Za-z0-9_]*))''', re.X)

def tokens(text):
    pos = 0
    while pos < len(text):
        m = TOKEN.match(text, pos)
        if not m or m.end() == pos:
            if text[pos:].strip() == "":
                return
            raise ValueError("cannot parse at %d: %r" % (pos, text[pos:pos + 30]))
        pos = m.end()
        if m.group(1):
            continue
        for i, kind in enumerate("[]{}=,;", start=2):
            if m.group(i):
                yield kind, None
                break
        else:
            if m.group(9):
                yield "str", bytes(m.group(9)[1:-1], "utf-8").decode("unicode_escape").encode("latin-1").decode("utf-8")
            elif m.group(10):
                v = m.group(10)
                yield "num", float(v) if any(c in v for c in ".eE") else int(v)
            elif m.group(11):
                w = m.group(11)
                yield ("val", {"true": True, "false": False, "nil": None}[w]) if w in ("true", "false", "nil") else ("name", w)

class Parser:
    def __init__(self, text):
        self.t = list(tokens(text)); self.i = 0
    def peek(self): return self.t[self.i] if self.i < len(self.t) else (None, None)
    def take(self, kind=None):
        tok = self.t[self.i]; self.i += 1
        if kind and tok[0] != kind: raise ValueError("expected %s, got %s" % (kind, tok))
        return tok
    def value(self):
        kind, v = self.take()
        if kind == "{": return self.table()
        if kind in ("str", "num", "val"): return v
        raise ValueError("unexpected %s" % kind)
    def table(self):
        result, n = {}, 1
        while self.peek()[0] != "}":
            if self.peek()[0] == "[":
                self.take(); key = self.value(); self.take("]"); self.take("=")
                result[key] = self.value()
            elif self.peek()[0] == "name" and self.t[self.i + 1][0] == "=":
                key = self.take()[1]; self.take("=")
                result[key] = self.value()
            else:
                result[n] = self.value(); n += 1
            if self.peek()[0] in (",", ";"): self.take()
        self.take("}")
        return result
    def assignments(self):
        out = {}
        while self.peek()[0]:
            name = self.take("name")[1]; self.take("=")
            out[name] = self.value()
        return out

def as_list(t):
    return [t[k] for k in sorted(k for k in t if isinstance(k, int))] if isinstance(t, dict) else []

# --- export -----------------------------------------------------------------
TYPE_CODE = {"herb": "h", "ore": "o", "chest": "c"}

def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

HERE = os.path.dirname(os.path.abspath(__file__))

def known_zones():
    """Map IDs we ship Questie spawn points for (new Forever zones are not among them)."""
    text = open(os.path.join(HERE, "..", "Data", "QuestieNodes.lua"), encoding="utf-8").read()
    return {int(m) for m in re.findall(r"\[(\d+)\]\s*=\s*\"", text)}

def item_names():
    text = open(os.path.join(HERE, "..", "Data", "ItemNames.lua"), encoding="utf-8").read()
    return {int(i): n for i, n in re.findall(r"^(\d+)\t(.+)$", text, re.M)}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("-o", "--out", default="StarterData.lua")
    ap.add_argument("--version", default="beta-" + datetime.date.today().isoformat())
    ap.add_argument("--radius", type=float, default=0.003, help="merge distance as map fraction")
    ap.add_argument("--min-reporters", type=int, default=1)
    ap.add_argument("--include-sync", action="store_true", help="also export confirmed nodes from sync")
    ap.add_argument("--include-pending", type=int, default=0, metavar="N",
                    help="zones without known spawn points only: also export unconfirmed sync reports "
                         "that N or more different players sent (0 = off)")
    args = ap.parse_args()
    if args.include_pending == 1:
        ap.error("--include-pending needs 2 or more: starter nodes join routes, one stranger's report must not")

    merged = {}  # mapID -> list of entries
    for path in args.files:
        with open(path, encoding="utf-8") as f:
            saved = Parser(f.read()).assignments()
            db = saved.get("GathercraftDB") or saved.get("WoWFFarmDB") or {}
        seen_here = set()
        count = 0
        for mapID, nodes in (db.get("nodes") or {}).items():
            for n in as_list(nodes):
                nid, ntype = n.get("id"), n.get("type")
                if not (isinstance(nid, str) and re.fullmatch(r"o\d+", nid)) or ntype not in TYPE_CODE or (n.get("source") and not (args.include_sync and n.get("source") == "sync")):
                    continue
                entries = merged.setdefault(int(mapID), [])
                hit = None
                for e in entries:
                    # never merge two nodes from the same file (close neighbors are real)
                    if id(e) not in seen_here and e["id"] == nid and abs(e["x"] - n["x"]) <= args.radius and abs(e["y"] - n["y"]) <= args.radius:
                        hit = e; break
                if hit:
                    if id(hit) not in seen_here:
                        hit["reporters"] += 1
                        k = hit["reporters"]  # running average of the position
                        hit["x"] += (n["x"] - hit["x"]) / k
                        hit["y"] += (n["y"] - hit["y"]) / k
                    hit["item"] = hit["item"] or n.get("item") or 0
                else:
                    hit = {"id": nid, "type": ntype, "x": n["x"], "y": n["y"],
                           "item": n.get("item") or 0, "name": n.get("name") or nid, "reporters": 1}
                    entries.append(hit)
                seen_here.add(id(hit))
                count += 1
        if args.include_pending > 0:
            known = known_zones()
            names = item_names()
            for mapID, lst in ((db.get("sync") or {}).get("pending") or {}).items():
                if int(mapID) in known:
                    continue
                for p in as_list(lst):
                    nid, ntype = p.get("id"), p.get("type")
                    if not (isinstance(nid, str) and re.fullmatch(r"o\d+", nid)) or ntype not in TYPE_CODE:
                        continue
                    if (p.get("rc") or 0) < args.include_pending:
                        continue
                    entries = merged.setdefault(int(mapID), [])
                    if any(e["id"] == nid and abs(e["x"] - p["x"]) <= args.radius and abs(e["y"] - p["y"]) <= args.radius for e in entries):
                        continue
                    item = p.get("item") or 0
                    entries.append({"id": nid, "type": ntype, "x": p["x"], "y": p["y"], "item": item,
                                    "name": names.get(item) or ("Unknown Herb" if ntype == "herb" else "Unknown Ore"),
                                    "reporters": int(p.get("rc") or 1)})
                    count += 1
        print("%s: %d nodes read" % (path, count), file=sys.stderr)

    lines = ["-- Generated by tools/export_starter.py, do not edit by hand.",
             "-- {id, type (h/o), x*10000, y*10000, itemID, reporters, name}",
             "GathercraftStarterData = {",
             "    version = %s," % lua_str(args.version),
             "    nodes = {"]
    total = 0
    for mapID in sorted(merged):
        rows = [e for e in merged[mapID] if e["reporters"] >= args.min_reporters]
        if not rows: continue
        rows.sort(key=lambda e: (e["id"], e["x"], e["y"]))
        lines.append("        [%d] = {" % mapID)
        for e in rows:
            lines.append('            {%s,"%s",%d,%d,%d,%d,%s},' % (
                lua_str(e["id"]), TYPE_CODE[e["type"]], round(e["x"] * 10000), round(e["y"] * 10000),
                int(e["item"]), e["reporters"], lua_str(e["name"])))
        lines.append("        },")
        total += len(rows)
    lines += ["    },", "}", ""]
    with open(args.out, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))
    print("wrote %d nodes in %d zones to %s (version %s)" % (total, len(merged), args.out, args.version), file=sys.stderr)

if __name__ == "__main__":
    main()
