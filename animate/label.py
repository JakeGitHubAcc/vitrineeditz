"""Takes the Parental Advisory label off a cover: OCR finds its words, the label's box is reckoned from
them and snapped to its straight black edges, and LaMa (big-lama.pt) paints in what is behind it from the
cover around it.

    python label.py cover.png cleaned.png [--model big-lama.pt]   # a test on one cover
"""
import difflib
import os

import numpy as np
from PIL import Image, ImageFilter

WORDS = ("PARENTAL", "ADVISORY", "EXPLICIT", "CONTENT")
# The usual label: PARENTAL, ADVISORY and EXPLICIT CONTENT in three bands of about a third each, the two
# big words about 0.9 of its width, and 0.6 as tall as it is wide.
WORD_SHARE, ASPECT = 0.9, 0.6
# How far a side of the reckoned box may move out and in to the label's edge, as shares of the label's
# side, and how much stronger than the lines around it an edge must be to be taken for the label's.
SNAP, INWARD, EDGE = 0.2, 0.08, 2.0
# The margin painted past the label's edge for its antialiasing and JPEG fringe, as a share of the cover.
MARGIN = 0.006
# The cover around the label that LaMa sees, as a multiple of the label's longer side.
CONTEXT = 1.25
# The size a cover is read at, in pixels.
READ_SIDE = 1280

_ocr = None
_lama = {}


def ocr():
    global _ocr
    if _ocr is None:
        from rapidocr_onnxruntime import RapidOCR
        _ocr = RapidOCR()
    return _ocr


def lama(path):
    if path not in _lama:
        import torch
        model = torch.jit.load(path, map_location="cpu")
        model.eval()
        _lama[path] = model
    return _lama[path]


def label_word(text):
    """The label word the OCR text is, or None. Close enough counts: the label's words are small."""
    for part in text.upper().replace("/", " ").split():
        letters = "".join(c for c in part if c.isalpha())
        for word in WORDS:
            if len(letters) >= 4 and difflib.SequenceMatcher(None, letters, word).ratio() >= 0.75:
                return word
    return None


def text_box(gray, box):
    """The letters' tight box inside an OCR box, whose own is padded: pixels far from the box's usual shade."""
    l, t, r, b = (int(round(v)) for v in box)
    patch = gray[t:b, l:r]
    if patch.size == 0:
        return l, t, r, b
    letters = np.abs(patch - np.median(patch)) > 60
    rows, cols = np.flatnonzero(letters.any(axis=1)), np.flatnonzero(letters.any(axis=0))
    if not rows.size:
        return l, t, r, b
    return l + cols[0], t + rows[0], l + cols[-1] + 1, t + rows[-1] + 1


def snapped(gray, box):
    """`box` with each side moved out to the label's edge: the outermost strong straight edge near it, since
    the edges between the label's own black and white bands are as strong but lie inside it. A side with no
    edge standing out near it stays where it was reckoned."""
    h, w = gray.shape
    across = np.abs(np.diff(gray, axis=1))   # [y, x - 1]: the step between columns x - 1 and x
    down = np.abs(np.diff(gray, axis=0))     # [y - 1, x]: the step between rows y - 1 and y

    def edge(profile, at, reach, limit, outward):
        # Far outward, but only a little inward: the bands' edges are a third of the label in.
        out, back = reach, INWARD / SNAP * reach
        lo, hi = (at - out, at + back) if outward < 0 else (at - back, at + out)
        lo, hi = max(1, int(lo)), min(limit - 1, int(hi))
        if hi <= lo:
            return at
        window = profile[lo - 1:hi]
        strong = np.flatnonzero(window >= max(EDGE * np.median(window), 0.5 * window.max(), 8.0))
        if not strong.size:
            return at
        return lo + int(strong[-1] if outward > 0 else strong[0])

    l, t, r, b = box
    y0, y1 = int(t + 0.1 * (b - t)), int(b - 0.1 * (b - t))
    if y1 > y0:
        columns = across[y0:y1].mean(axis=0)
        reach = SNAP * (r - l)
        l, r = edge(columns, l, reach, w, -1), edge(columns, r, reach, w, 1)
    x0, x1 = int(l + 0.1 * (r - l)), int(r - 0.1 * (r - l))
    if x1 > x0:
        rows = down[:, x0:x1].mean(axis=1)
        reach = SNAP * (b - t)
        t, b = edge(rows, t, reach, h, -1), edge(rows, b, reach, h, 1)
    return l, t, r, b


def read(cover):
    """The text on `cover`: (text, score, (left, top, right, bottom)) in its pixels, for each line read."""
    # Read at READ_SIDE whatever the cover's size: a label is often a tenth of the cover, its smallest line
    # a few pixels tall, and the reader shrinks much larger pictures until it misses even big titles.
    scale = READ_SIDE / max(cover.width, cover.height)
    big = np.asarray(cover.convert("RGB").resize((round(cover.width * scale), round(cover.height * scale)), Image.LANCZOS))
    found, _ = ocr()(big[:, :, ::-1])
    lines = []
    for points, text, score in found or []:
        xs, ys = [p[0] / scale for p in points], [p[1] / scale for p in points]
        lines.append((text, float(score), (min(xs), min(ys), max(xs), max(ys))))
    return lines


def find(cover, lines=None):
    """The label's box (left, top, right, bottom) in `cover`'s pixels, or None. `lines` is read(cover)'s,
    when it has been read already."""
    pixels = np.asarray(cover.convert("RGB"))
    gray = pixels.astype(np.float32) @ np.array([0.299, 0.587, 0.114], dtype=np.float32)
    hits = {}
    for text, score, box in read(cover) if lines is None else lines:
        word = label_word(text)
        if word in ("PARENTAL", "ADVISORY") and score > 0.5:
            if word not in hits or box[2] - box[0] > hits[word][2] - hits[word][0]:
                hits[word] = box
    if not hits:
        return None
    # Reckoned from ADVISORY, the middle band, or else from PARENTAL, the top one.
    word = "ADVISORY" if "ADVISORY" in hits else "PARENTAL"
    l, t, r, b = text_box(gray, hits[word])
    width = (r - l) / WORD_SHARE
    height = ASPECT * width
    cx = (l + r) / 2
    cy = (t + b) / 2 + (0 if word == "ADVISORY" else height / 3)
    box = snapped(gray, (int(cx - width / 2), int(cy - height / 2), int(cx + width / 2), int(cy + height / 2)))
    h, w = gray.shape
    margin = max(2, int(round(MARGIN * max(w, h))))
    l, t, r, b = (int(v) for v in box)
    return max(0, l - margin), max(0, t - margin), min(w, r + margin), min(h, b + margin)


def inpaint(image, hole, model):
    """LaMa's fill of `hole` (1 where it fills) in `image` (RGB, 0 to 1), the whole image back."""
    import torch
    # LaMa takes sides in multiples of 8; the image is padded by reflection and the padding cut off after.
    ph, pw = (-image.shape[0]) % 8, (-image.shape[1]) % 8
    padded = np.pad(image, ((0, ph), (0, pw), (0, 0)), mode="reflect").astype(np.float32)
    mask = np.pad(hole, ((0, ph), (0, pw)), mode="reflect").astype(np.float32)
    with torch.inference_mode():
        out = lama(model)(torch.from_numpy(padded).permute(2, 0, 1)[None], torch.from_numpy(mask)[None, None])
    return np.clip(out[0].permute(1, 2, 0).numpy()[:image.shape[0], :image.shape[1]], 0, 1)


def paint(cover, box, model):
    """`cover` with `box` painted in by LaMa from the cover around it, at the cover's own resolution."""
    cover = cover.convert("RGB")
    l, t, r, b = box
    pad = int(CONTEXT * max(r - l, b - t))
    cl, ct = max(0, l - pad), max(0, t - pad)
    cr, cb = min(cover.width, r + pad), min(cover.height, b + pad)
    crop = np.asarray(cover.crop((cl, ct, cr, cb)), dtype=np.float32) / 255
    hole = np.zeros(crop.shape[:2], dtype=np.float32)
    hole[t - ct:b - ct, l - cl:r - cl] = 1
    out = inpaint(crop, hole, model)
    # Only the hole takes LaMa's pixels, its edge softened a little into the cover's own.
    soft = np.asarray(Image.fromarray((hole * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(1.5)), dtype=np.float32) / 255
    soft = np.maximum(soft, hole)[..., None]
    mixed = crop * (1 - soft) + out * soft
    cleaned = cover.copy()
    cleaned.paste(Image.fromarray((mixed * 255 + 0.5).astype(np.uint8)), (cl, ct))
    return cleaned


def clean(cover, model, lines=None):
    """`cover` without its label, and the label's box, or the cover as it was and None."""
    box = find(cover, lines)
    return (paint(cover, box, model), box) if box else (cover, None)


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("cover")
    parser.add_argument("out")
    parser.add_argument("--model", default=os.path.join(os.environ.get("VITRINE_ANIMATE", r"D:\VitrineAnimate"), "models", "big-lama.pt"))
    args = parser.parse_args()
    cleaned, box = clean(Image.open(args.cover), args.model)
    print("label at", box if box else "none found")
    cleaned.save(args.out)
