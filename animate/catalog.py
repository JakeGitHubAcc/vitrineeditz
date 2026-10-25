"""Looks up a clean copy of an album's cover: Apple's catalog (the iTunes Search API) keeps covers without
Parental Advisory labels and at up to 1500 pixels. A copy is taken only when it is the same picture as the
cover the phone sent, compared small, and of the same edition by its name (a Deluxe Edition's cover is
often the regular one's with a word added), so another edition's or another album's cover never stands in.

    python catalog.py cover.png "Album" "Artist" out.png   # a test
"""
import io
import json
import re
import urllib.parse
import urllib.request

import numpy as np
from PIL import Image

SEARCH = "https://itunes.apple.com/search"
# The size asked for, and how alike the two covers must be, as the correlation of their small grays (1 is
# the same picture; a label over a corner costs a few hundredths).
SIZE, ALIKE = 1500, 0.9
# The covers' colors may differ this much on average, out of 255, as two masterings of one picture do.
COLOR = 18.0
# Words that name an edition: a catalog album named with one the album asked for is not, is another edition.
# ("Edition" and "Version" alone say nothing: "Deluxe" and "Deluxe Edition" are one.)
EDITION = re.compile(r"\b(deluxe|expanded|remaster(?:ed)?|anniversary|bonus|special|collector'?s|"
                     r"platinum|complete|tour|reloaded|extended|international)\b", re.I)


def editions(name):
    return {word.lower() for word in EDITION.findall(name or "")}


def fetch(url, timeout=15):
    request = urllib.request.Request(url, headers={"User-Agent": "VitrineAnimate/1"})
    with urllib.request.urlopen(request, timeout=timeout) as r:
        return r.read()


def small(image):
    return np.asarray(image.convert("RGB").resize((48, 48), Image.BILINEAR), dtype=np.float32)


def likeness(a, b):
    """How alike two covers are: the correlation of their grays, and how far apart their colors are."""
    ga, gb = a.mean(axis=2).ravel(), b.mean(axis=2).ravel()
    ga, gb = ga - ga.mean(), gb - gb.mean()
    correlation = float(ga @ gb / max(np.linalg.norm(ga) * np.linalg.norm(gb), 1e-6))
    return correlation, float(np.abs(a - b).mean())


def clean_copy(cover, album, artist):
    """The catalog's copy of `cover` at SIZE, or None when it has none that is the same picture."""
    if not album:
        return None
    # By artist and album, then by the album alone, which finds what an artist's name written another way
    # ("Tyler, The Creator") hides.
    results = []
    for term in ([f"{artist} {album}"] if artist else []) + [album]:
        query = urllib.parse.urlencode({"term": term, "entity": "album", "limit": 15})
        results += json.loads(fetch(f"{SEARCH}?{query}")).get("results", [])
    mine = small(cover)
    best = None
    wanted = editions(album)
    for result in results:
        if editions(result.get("collectionName")) - wanted:
            continue
        thumb = result.get("artworkUrl100")
        if not thumb:
            continue
        try:
            theirs = small(Image.open(io.BytesIO(fetch(thumb))))
        except OSError:
            continue
        correlation, color = likeness(mine, theirs)
        if correlation >= ALIKE and color <= COLOR and (not best or correlation > best[0]):
            best = (correlation, thumb)
    if not best:
        return None
    # Asked for as PNG, so it comes without JPEG's blocks; JPEG at the best quality if that fails.
    for name in (f"{SIZE}x{SIZE}bb.png", f"{SIZE}x{SIZE}-999bb.jpg"):
        try:
            image = Image.open(io.BytesIO(fetch(best[1].rsplit("/", 1)[0] + "/" + name))).convert("RGB")
        except OSError:
            continue
        if abs(image.width - image.height) <= 2:
            return image
    return None


if __name__ == "__main__":
    import sys
    found = clean_copy(Image.open(sys.argv[1]), sys.argv[2], sys.argv[3])
    print("found", found.size if found else None)
    if found:
        found.save(sys.argv[4])
