"""Download the hand-reviewed Safebooru posts and website logos used by the video.

Usage: python -I fetch_media.py <media_dir>
Every post id below was reviewed on a contact sheet: rating general, no suggestive content.
"""
import json
import os
import sys
import time
import urllib.request

UA = {"User-Agent": "BooruPlusPromo/1.0"}

FEED = [4491829, 5584662, 4066256, 4049896, 4258503, 4780462, 4035225, 4209706,
        5601808, 4485697, 4438058, 4603901, 4819073, 4343202, 4030334, 4049857,
        4286658, 4064199, 5330190, 4082345, 4240899, 4045696, 6510301, 4960927,
        4226928, 4513080, 6776478, 4212568, 5457864, 4797121]
MIKU = [4912766, 4567204, 5097132, 4732480, 4736449, 4643969, 4299193, 4249376,
        4923668, 4071302, 4730886, 5131060, 4918897, 4294953, 4082161, 4099114]
# Results for the "cinnamiku" tag search and the Chiikawa stills used in booruShorts.
CINNA = [5133819, 4099466, 4086290, 4086522, 4100679, 4092702, 5190784, 5209927,
         4294958, 4626390, 5328163, 5063926, 4173011, 4128688, 4093864, 4098929]
CHIIKAWA = [6001921, 6311892, 4622032]
SHORTS = [4714371, 5219069, 6035518, 4276788, 4450254, 4387858, 6201779, 4328167]

SITES = {
    "safebooru": "https://www.google.com/s2/favicons?sz=128&domain=safebooru.org",
    "danbooru": "https://danbooru.donmai.us/packs/static/danbooru-logo-128x128-ea111b6658173e847734.png",
    "konachan": "https://www.google.com/s2/favicons?sz=128&domain=konachan.com",
    "yandere": "https://www.google.com/s2/favicons?sz=128&domain=yande.re",
    "e926": "https://www.google.com/s2/favicons?sz=128&domain=e926.net",
    "e621": "https://www.google.com/s2/favicons?sz=128&domain=e621.net",
    "gelbooru": "https://www.google.com/s2/favicons?sz=128&domain=gelbooru.com",
    "rule34": "https://www.google.com/s2/favicons?sz=128&domain=rule34.xxx",
    "sankaku": "https://www.google.com/s2/favicons?sz=128&domain=sankakucomplex.com",
    "idolcomplex": "https://www.google.com/s2/favicons?sz=128&domain=idolcomplex.com",
    "tbib": "https://www.google.com/s2/favicons?sz=128&domain=tbib.org",
    "aibooru": "https://www.google.com/s2/favicons?sz=128&domain=aibooru.online",
    "nozomi": "https://www.google.com/s2/favicons?sz=128&domain=nozomi.la",
}


def get(url, path):
    if os.path.exists(path):
        return
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=90) as r:
        data = r.read()
    with open(path, "wb") as f:
        f.write(data)
    time.sleep(0.2)


def post(pid):
    url = f"https://safebooru.org/index.php?page=dapi&s=post&q=index&json=1&id={pid}"
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=30) as r:
        p = json.loads(r.read())[0]
    if p["rating"] != "general":
        raise SystemExit(f"post {pid} is rated {p['rating']}, not general")
    return p


def main(out):
    for d in ("posts", "shorts", "sites"):
        os.makedirs(os.path.join(out, d), exist_ok=True)
    manifest = {"feed": [], "miku": [], "shorts": [], "cinna": [], "chiikawa": []}
    for group, ids in (("feed", FEED), ("miku", MIKU), ("shorts", SHORTS), ("cinna", CINNA), ("chiikawa", CHIIKAWA)):
        for pid in ids:
            p = post(pid)
            stem, ext = p["image"].rsplit(".", 1)
            if group == "shorts":
                src = f"https://safebooru.org/images/{p['directory']}/{p['image']}"
                name = f"shorts/{pid}.{ext}"
            elif p.get("sample"):
                src = f"https://safebooru.org/samples/{p['directory']}/sample_{stem}.jpg"
                name = f"posts/{pid}.jpg"
            else:
                src = f"https://safebooru.org/images/{p['directory']}/{p['image']}"
                name = f"posts/{pid}.{ext}"
            get(src, os.path.join(out, name))
            tags = p["tags"].split()
            manifest[group].append({"id": pid, "file": name, "w": int(p["width"]),
                                    "h": int(p["height"]), "tags": tags[:40]})
            print(group, pid, name)
    for key, url in SITES.items():
        get(url, os.path.join(out, "sites", f"{key}.png"))
    with open(os.path.join(out, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1)


if __name__ == "__main__":
    main(sys.argv[1])
