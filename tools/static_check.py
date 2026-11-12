#!/usr/bin/env python3
"""Static check of the addon: LuaLS with Ketho's WoW API annotations, and the
WoW functions the addon uses that Classic Era does not have.

    python -I -B static_check.py <addon folder or git worktree> [--rev COMMIT] [--out FILE.md]

An extra stage before a release, next to the syntax check and the smoke test.
It reads only: the addon is copied (or exported from git with --rev) into a
temporary folder, the check runs there, the copy is removed.

The tools are not part of the repository. They are looked for in
    --tools DIR   or   %GC_STATIC_TOOLS%   or   D:\\Sven\\Gathercraftentwicklung\\06-Werkzeuge
        luals-*\\bin\\lua-language-server.exe
        ketho-wow-api-*\\Annotations\\Core, ...\\FrameXML, ...\\src\\data\\flavor.ts

What the result is worth: the annotations describe Blizzard's clients (Retail,
Mists, Classic Era). WoW: Forever (interface 16001) is a client of its own: a
finding is a hint, not proof. Where a live probe in the game says otherwise,
the live probe counts.
"""
import argparse, glob, json, os, re, shutil, subprocess, sys, tempfile

CLASSIC_ERA = 0x8  # the bit of "classic_era" in Ketho's flavor data (src/providers/flavor.ts)
SKIP_DIRS = ("Libs", "tools", ".github", "docs")


def find_tools(base):
    luals = sorted(glob.glob(os.path.join(base, "luals-*", "bin", "lua-language-server.exe")))
    ketho = sorted(glob.glob(os.path.join(base, "ketho-wow-api-*")))
    if not luals or not ketho:
        sys.exit("tools not found under %s (see QUELLEN.md there)" % base)
    return luals[-1], ketho[-1]


def export(root, rev, dest):
    """the tracked files of the worktree (or of a commit) into dest"""
    if rev:
        data = subprocess.run(["git", "-C", root, "archive", rev], capture_output=True, check=True).stdout
        subprocess.run(["tar", "-x", "-C", dest], input=data, check=True)
        return subprocess.run(["git", "-C", root, "rev-parse", "--short=7", rev], capture_output=True, text=True).stdout.strip()
    files = subprocess.run(["git", "-C", root, "ls-files"], capture_output=True, text=True)
    names = files.stdout.splitlines() if files.returncode == 0 else None
    if names is None:  # no repository: every file
        names = [os.path.relpath(os.path.join(d, f), root).replace("\\", "/") for d, _, fs in os.walk(root) for f in fs]
    for n in names:
        src = os.path.join(root, n)
        if os.path.isfile(src):
            os.makedirs(os.path.dirname(os.path.join(dest, n)) or dest, exist_ok=True)
            shutil.copyfile(src, os.path.join(dest, n))
    head = subprocess.run(["git", "-C", root, "rev-parse", "--short=7", "HEAD"], capture_output=True, text=True)
    dirty = subprocess.run(["git", "-C", root, "status", "--porcelain"], capture_output=True, text=True).stdout.strip()
    return (head.stdout.strip() or "?") + (" + uncommitted changes" if dirty else "")


def luals_check(exe, ketho, work, logs):
    cfg_path = os.path.join(work, ".luarc.json")
    cfg = json.load(open(cfg_path, encoding="utf-8")) if os.path.exists(cfg_path) else {}
    cfg["runtime.version"] = "Lua 5.1"
    cfg["workspace.library"] = [os.path.join(ketho, "Annotations", "Core").replace("\\", "/"), os.path.join(ketho, "Annotations", "FrameXML").replace("\\", "/")]
    cfg["workspace.checkThirdParty"] = False
    cfg["workspace.ignoreDir"] = sorted(set(cfg.get("workspace.ignoreDir", [])) | set(SKIP_DIRS))
    json.dump(cfg, open(cfg_path, "w", encoding="utf-8"), indent=2)
    run = subprocess.run([exe, "--check=" + work, "--checklevel=Warning", "--logpath=" + logs, "--check_format=json"],
                         capture_output=True, text=True, encoding="utf-8", errors="replace")
    result = os.path.join(logs, "check.json")
    found = []
    if os.path.exists(result):
        data = json.load(open(result, encoding="utf-8"))
        for uri, items in data.items():
            name = uri.replace("\\", "/")
            name = name[name.lower().rfind(os.path.basename(work).lower()) + len(os.path.basename(work)) + 1:]
            for d in items:
                found.append({"file": name, "line": d["range"]["start"]["line"] + 1, "code": str(d.get("code")), "severity": d.get("severity"),
                              "message": " ".join(str(d.get("message", "")).split())})
    elif "no problems found" not in (run.stdout + run.stderr).lower():
        sys.exit("LuaLS gave no result file:\n" + (run.stdout + run.stderr)[-800:])
    found.sort(key=lambda d: (d["file"], d["line"], d["code"]))
    return found, (run.stdout + run.stderr).strip().splitlines()[-1:] or [""]


def flavor_data(ketho):
    text = open(os.path.join(ketho, "src", "data", "flavor.ts"), encoding="utf-8").read()
    return {m.group(1): int(m.group(2), 16) for m in re.finditer(r'\["([^"]+)"\]:\s*(0x[0-9A-Fa-f]+)', text)}


def strip_lua(text):
    """comments and strings out (rough, good enough to find names)"""
    text = re.sub(r"--\[(=*)\[.*?\]\1\]", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    text = re.sub(r"\[(=*)\[.*?\]\1\]", lambda m: '""' + "\n" * m.group(0).count("\n"), text, flags=re.S)
    out = []
    for line in text.split("\n"):
        line = re.sub(r'"(?:\\.|[^"\\])*"', '""', line)
        line = re.sub(r"'(?:\\.|[^'\\])*'", "''", line)
        out.append(line.split("--", 1)[0])
    return out


def flavor_check(work, flavors):
    """WoW functions named in the addon that Ketho's data knows, but not for Classic Era"""
    uses = {}
    for d, dirs, files in os.walk(work):
        dirs[:] = [x for x in dirs if x not in SKIP_DIRS and not x.startswith(".")]
        for f in files:
            if not f.endswith(".lua") or os.path.relpath(d, work).split(os.sep)[0] == "Data":
                continue
            rel = os.path.relpath(os.path.join(d, f), work).replace("\\", "/")
            for no, line in enumerate(strip_lua(open(os.path.join(d, f), encoding="utf-8", errors="replace").read()), 1):
                for m in re.finditer(r"(?<![\w.:])((?:C_\w+\.)?[A-Za-z_]\w*)", line):
                    name = m.group(1)
                    if name in flavors and not flavors[name] & CLASSIC_ERA:
                        # asked for before it is called ("if X then", "X and X(...)") on this line?
                        guarded = bool(re.search(r"(?:\bif\b|\band\b|\bor\b|=)\s*(?:not\s+)?\(?\s*" + re.escape(name) + r"\b(?!\s*\()", line)) or \
                            bool(re.search(r"\b" + re.escape(name.split(".")[0]) + r"\s+and\s+" + re.escape(name), line))
                        uses.setdefault(name, []).append((rel, no, guarded))
    return uses


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("root")
    ap.add_argument("--rev")
    ap.add_argument("--out")
    ap.add_argument("--tools", default=os.environ.get("GC_STATIC_TOOLS", r"D:\Sven\Gathercraftentwicklung\06-Werkzeuge"))
    a = ap.parse_args()
    exe, ketho = find_tools(a.tools)
    tmp = tempfile.mkdtemp(prefix="gc-static-")
    work, logs = os.path.join(tmp, "Gathercraft"), os.path.join(tmp, "log")
    os.makedirs(work)
    os.makedirs(logs)
    try:
        state = export(os.path.abspath(a.root), a.rev, work)
        found, last = luals_check(exe, ketho, work, logs)
        flavors = flavor_data(ketho)
        uses = flavor_check(work, flavors)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    lines = ["# Static check: %s" % state, "",
             "- LuaLS `%s`, annotations `%s`, level Warning, Lua 5.1; `Libs`, `tools`, `docs`, `.github` left out." % (os.path.basename(os.path.dirname(os.path.dirname(exe))), os.path.basename(ketho)),
             "- LuaLS: **%d findings**. Functions not in Classic Era (Ketho's data): **%d names**." % (len(found), len(uses)), ""]
    by_code = {}
    for d in found:
        by_code.setdefault(d["code"], []).append(d)
    lines += ["## LuaLS, by kind", "", "| kind | findings | files |", "|---|---|---|"]
    for code, items in sorted(by_code.items(), key=lambda kv: -len(kv[1])):
        lines.append("| `%s` | %d | %s |" % (code, len(items), ", ".join(sorted({d["file"] for d in items}))))
    lines += ["", "## LuaLS, every finding", ""]
    for d in found:
        lines.append("- `%s:%d` `%s` %s" % (d["file"], d["line"], d["code"], d["message"][:300]))
    lines += ["", "## WoW functions the addon names that Classic Era does not have (Ketho's flavor data)", "",
              "\"asked first\": on that line the name is tested before it is called (`if X then`, `X and X(...)`).", ""]
    for name, where in sorted(uses.items()):
        mask = flavors[name]
        has = [n for bit, n in ((1, "mainline"), (2, "mists"), (4, "bcc")) if mask & bit]
        lines.append("- `%s` (in: %s): %s" % (name, ", ".join(has) or "-", "; ".join("%s:%d%s" % (f, n, " (asked first)" if g else "") for f, n, g in where)))
    text = "\n".join(lines) + "\n"
    if a.out:
        open(a.out, "w", encoding="utf-8", newline="\n").write(text)
    print("static check %s: LuaLS %d findings (%s), %d names not in Classic Era%s" % (
        state, len(found), ", ".join("%s %d" % (c, len(i)) for c, i in sorted(by_code.items(), key=lambda kv: -len(kv[1]))) or "none", len(uses),
        (" -> " + a.out) if a.out else ""))
    if not a.out:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
