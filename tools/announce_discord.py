"""Posts a release announcement to Discord.

Reads the notes from CHANGELOG.md (first heading = title) and sends them as an
embed to the webhook in the DISCORD_WEBHOOK secret. Used by release.yml after
every release and by announce.yml to post one by hand.
"""
import json
import os
import sys
import urllib.error
import urllib.request

hook = os.environ.get("DISCORD_WEBHOOK", "").strip()
if hook.endswith("/github"):
    hook = hook[: -len("/github")]
if not hook:
    print("DISCORD_WEBHOOK is not set, nothing to announce")
    sys.exit(0)

repo = os.environ.get("GITHUB_REPOSITORY", "pheenixlawl-ui/Gathercraft")
version = os.environ.get("VERSION") or os.environ.get("GITHUB_REF_NAME", "")

lines = open("CHANGELOG.md", encoding="utf-8").read().strip().splitlines()
title = "Gathercraft %s is out!" % version
if lines and lines[0].startswith("#"):
    title = "Gathercraft " + lines[0].lstrip("#").strip()
    lines = lines[1:]
notes = "\n".join(lines).strip()
if len(notes) > 3500:
    notes = notes[:3500].rsplit("\n", 1)[0] + "\n…"

release = "https://github.com/%s/releases/tag/%s" % (repo, version)
icon = "https://raw.githubusercontent.com/%s/main/docs/icon.png" % repo
links = ("[CurseForge](https://www.curseforge.com/wow/addons/gathercraft) · "
         "[Wago](https://addons.wago.io/addons/gathercraft) · [GitHub](%s)" % release)

payload = {
    "username": "Gathercraft",
    "avatar_url": icon,
    "embeds": [{
        "title": title[:256],
        "url": release,
        "description": notes,
        "color": 0xE6B85C,
        "thumbnail": {"url": icon},
        "fields": [{"name": "Download", "value": links}],
        "footer": {"text": "Gather · Route · Profit"},
    }],
}
request = urllib.request.Request(
    hook,
    data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json",
             "User-Agent": "DiscordBot (https://github.com/%s, 1.0)" % repo},
)
try:
    urllib.request.urlopen(request, timeout=20)
except urllib.error.HTTPError as e:
    print("Discord said %d: %s" % (e.code, e.read().decode("utf-8", "replace")))
    sys.exit(1)
print("Announced %s on Discord" % version)
