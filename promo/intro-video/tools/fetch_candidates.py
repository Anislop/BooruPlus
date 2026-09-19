"""Fetch general-rated Safebooru candidates and build contact sheets for review.

Usage: python -I fetch_candidates.py <media_dir>
"""
import json
import os
import sys
import time
import urllib.parse
import urllib.request

from PIL import Image, ImageDraw

UA = {"User-Agent": "BooruPlusPromo/1.0"}
# Strict filter: general rating only, plus negations for anything suggestive.
EXCLUDE = (
    "-breasts -cleavage -swimsuit -bikini -underwear -panties -pantyhose "
    "-thighhighs -thighs -bare_shoulders -navel -midriff -ass -blood -gore "
    "-nude -bath -bathing -lingerie -kiss -leotard -feet -barefoot -skirt_lift "
    "-bouncing_breasts -see-through -wet -bandages -cigarette -weapon -gun"
)
SETS = {
    "feed": "scenery sort:score",
    "sky": "sky cloud scenery sort:score",
    "cat": "cat no_humans sort:score",
    "food": "food no_humans sort:score",
    "flowers": "cherry_blossoms sort:score",
    "miku": "hatsune_miku solo sort:score",
    "anim": "animated sort:score",
}
FORBIDDEN = set(EXCLUDE.replace("-", "").split())


def query(tags, limit):
    full = f"rating:general {tags} {EXCLUDE}"
    url = ("https://safebooru.org/index.php?page=dapi&s=post&q=index&json=1"
           f"&limit={limit}&tags=" + urllib.parse.quote_plus(full))
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=30) as r:
        body = r.read()
    return json.loads(body) if body.strip() else []


def get(url, path):
    if os.path.exists(path):
        return True
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r:
            data = r.read()
        with open(path, "wb") as f:
            f.write(data)
        return True
    except Exception as e:  # noqa: BLE001
        print("fail", url, e)
        return False


def main(out):
    thumbs = os.path.join(out, "thumbs")
    os.makedirs(thumbs, exist_ok=True)
    meta = {}
    for name, tags in SETS.items():
        posts = query(tags, 40)
        kept = []
        for p in posts:
            ptags = set(p["tags"].split())
            if p["rating"] != "general" or ptags & FORBIDDEN:
                continue
            stem = p["image"].rsplit(".", 1)[0]
            turl = f"https://safebooru.org/thumbnails/{p['directory']}/thumbnail_{stem}.jpg"
            tpath = os.path.join(thumbs, f"{p['id']}.jpg")
            if get(turl, tpath):
                kept.append({k: p[k] for k in ("id", "directory", "image", "width", "height", "tags", "sample", "score")})
            time.sleep(0.15)
        meta[name] = kept
        print(name, len(kept))
        sheet(kept, thumbs, os.path.join(out, f"sheet_{name}.jpg"))
    with open(os.path.join(out, "candidates.json"), "w") as f:
        json.dump(meta, f, indent=1)


def sheet(posts, thumbs, path, cols=8, cell=180):
    rows = (len(posts) + cols - 1) // cols or 1
    img = Image.new("RGB", (cols * cell, rows * (cell + 18)), (30, 30, 30))
    d = ImageDraw.Draw(img)
    for i, p in enumerate(posts):
        t = Image.open(os.path.join(thumbs, f"{p['id']}.jpg")).convert("RGB")
        t.thumbnail((cell - 6, cell - 6))
        x, y = (i % cols) * cell, (i // cols) * (cell + 18)
        img.paste(t, (x + 3, y + 3))
        d.text((x + 4, y + cell), str(p["id"]), fill=(255, 255, 0))
    img.save(path, quality=85)


if __name__ == "__main__":
    main(sys.argv[1])
