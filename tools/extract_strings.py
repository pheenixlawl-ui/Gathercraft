#!/usr/bin/env python3
"""
Lists every English text Gathercraft shows, for the translation files.

    python tools/extract_strings.py            -> keys, one per line (Lua-escaped)
    python tools/extract_strings.py --check X  -> keys missing in Locales/X.lua

A text counts when the code passes it through L["..."], ns.LText(obj, "...")
or one of the label helpers (Header, Button, AddTab, AddCheck, ...).
"""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILES = [f for f in os.listdir(ROOT) if f.endswith(".lua") and f != "Locales.lua"]
STR = r'"((?:[^"\\]|\\.)*)"'
PATTERNS = [
    r'\bL\[' + STR + r'\]',
    r'ns\.LText\([^,]+,\s*' + STR,
    r'\b(?:Header|AddHeader|AddCheck|RunButton|ModeButton|style\.header)\((?:[\w.]+,\s*)?' + STR,
    r'\bAddTab\("\w+",\s*' + STR,
    r'\bCreateBar\("\w+",\s*' + STR,
    r'\bButton\(overview,\s*' + STR,
    r'\bCol\((?:"\w+",\s*)?' + STR,
    r'\bSubTab\(\d+,\s*"\w+",\s*' + STR,
    r'\bshort = ' + STR,
]
TABLES = [r'local (?:TIERS|TYPE_LABELS|PROFESSION_LABEL|FILTER_LABELS|MODE_LABELS) = \{(.*)\}',
          r'for i, label in ipairs\(\{(.*)\}\)']


def keys():
    found = []
    for f in sorted(FILES):
        src = open(os.path.join(ROOT, f), encoding="utf-8").read()
        for p in PATTERNS:
            found += re.findall(p, src)
        for t in TABLES:
            for body in re.findall(t, src):
                found += re.findall(STR, body)
    loc = open(os.path.join(ROOT, "Locales.lua"), encoding="utf-8").read()
    found += re.findall(r'name = "(Auto \(game language\))"', loc)
    out, seen = [], set()
    for k in found:
        if k not in seen and re.search(r"[A-Za-z]", k):
            seen.add(k)
            out.append(k)
    return out


if __name__ == "__main__":
    ks = keys()
    if len(sys.argv) > 2 and sys.argv[1] == "--check":
        have = set(re.findall(r'^\s*\["((?:[^"\\]|\\.)*)"\]\s*=', open(os.path.join(ROOT, "Locales", sys.argv[2] + ".lua"), encoding="utf-8").read(), re.M))
        missing = [k for k in ks if k not in have]
        # the same %s / %d in the same order, or string.format breaks
        pairs = re.findall(r'^\s*\["((?:[^"\\]|\\.)*)"\]\s*=\s*"((?:[^"\\]|\\.)*)"', open(os.path.join(ROOT, "Locales", sys.argv[2] + ".lua"), encoding="utf-8").read(), re.M)
        spec = re.compile(r"%[-\d.]*[sdfx%]")
        for k, v in pairs:
            if spec.findall(k) != spec.findall(v):
                print("FORMAT MISMATCH:", k, "->", v, file=sys.stderr)
        extra = [k for k in have if k not in set(ks)]
        print("\n".join(missing))
        print(f"{len(missing)} missing, {len(extra)} unused", file=sys.stderr)
    else:
        print("\n".join(ks))
        print(f"{len(ks)} texts", file=sys.stderr)
