"""Bundle the media manifests into media/data.js so the page works from file://.

Usage: python -I build_data.py <intro-video dir>
"""
import json
import os
import sys

root = sys.argv[1]
media = os.path.join(root, "media")
manifest = json.load(open(os.path.join(media, "manifest.json")))
frames = json.load(open(os.path.join(media, "shorts", "frames.json")))
data = {
    "feed": [{"id": p["id"], "src": f"media/posts_sm/{p['id']}.jpg", "lg": f"media/posts_md/{p['id']}.jpg", "w": p["w"], "h": p["h"]} for p in manifest["feed"]],
    "miku": [{"id": p["id"], "src": f"media/posts_sm/{p['id']}.jpg", "lg": f"media/posts_md/{p['id']}.jpg", "w": p["w"], "h": p["h"]} for p in manifest["miku"]],
    **{g: [{"id": p["id"], "src": f"media/posts_sm/{p['id']}.jpg", "lg": f"media/posts_md/{p['id']}.jpg", "w": p["w"], "h": p["h"]} for p in manifest[g]]
       for g in ("cinna", "chiikawa")},
    "shorts": {pid: {"w": v["w"], "h": v["h"], "durations": v["durations"],
                     "frames": [f"media/shorts/{pid}/{i:03d}.jpg" for i in range(len(v["durations"]))]}
               for pid, v in frames.items()},
}
with open(os.path.join(media, "data.js"), "w") as f:
    f.write("window.DATA = " + json.dumps(data) + ";\n")
print("feed", len(data["feed"]), "miku", len(data["miku"]), "shorts", list(data["shorts"]))
