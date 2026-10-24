"""What the phone's Text and Camera sway settings add to a clip: the cover's text painted out, or faded out
and back in over the loop as some animated covers do, and a slow camera sway over the whole frame. Both
want a longer loop than the motion's few seconds, so the clip is played over itself first (it ends on its
first frame, so it repeats without a seam), and both run once over the whole, ending where they start.
"""
import math

import cv2
import numpy as np
from PIL import Image
from scipy.ndimage import binary_dilation, gaussian_filter

import label

FPS = 24
# The shortest loop for a fade or a sway, in seconds.
LONG = 8.0
# How far past a line's box its letters are looked for, as a share of its height (the reader's boxes can
# clip them); how far a letter's shade must be from the box's usual one, out of 255; how far the letters
# are grown for their soft edges, and the soft edge of the fade's mask, in pixels.
ERASE_PAD, LETTER_CONTRAST, GLYPH_GROW, FADE_EDGE = 0.08, 60, 3, 2
# The fade: the text shows for this share of the loop at its start, fades out over FADE seconds, stays
# away, and fades back in to show again for this share at the end. The first frame, the poster, has it.
SHOWN_FIRST, SHOWN_LAST, FADE = 0.3, 0.12, 1.2
# The sway: the drift sideways and up and down and the push in, as shares of the frame's width, and the
# tilt in degrees. The frame is always enlarged by at least ZOOM_LEAST, so its edges never show.
DRIFT_X, DRIFT_Y, PUSH, TILT, ZOOM_LEAST = 0.005, 0.003, 0.012, 0.25, 1.025


def letters(patch):
    """Which pixels of a line's box (gray, uint8) are its letters: the box split into its light and dark
    shades, the letters being the shade that touches the box's edge less, as the background runs out past
    it. None when the two shades are too alike to tell apart."""
    split, light = cv2.threshold(patch, 0, 1, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    light = light.astype(bool)
    if not light.any() or light.all():
        return None
    if abs(float(patch[light].mean()) - float(patch[~light].mean())) < LETTER_CONTRAST:
        return None
    edge = np.concatenate([light[0], light[-1], light[:, 0], light[:, -1]])
    return ~light if edge.mean() > 0.5 else light


def hole(cover, boxes):
    """1 over the letters of each line of text in `cover` (RGB array, square), not the box around them,
    grown by GLYPH_GROW for their soft edges, so a design next to the text, or inside its box, stays. A line
    whose letters cannot be told from their background is painted out whole. Boxes are shares of the side."""
    size = cover.shape[0]
    gray = cv2.cvtColor(cover, cv2.COLOR_RGB2GRAY)
    mask = np.zeros((size, size), bool)
    for l, t, r, b in boxes:
        grow = ERASE_PAD * (b - t)
        x0, y0 = max(0, int((l - grow) * size)), max(0, int((t - grow) * size))
        x1, y1 = min(size, int(math.ceil((r + grow) * size))), min(size, int(math.ceil((b + grow) * size)))
        if x1 - x0 < 2 or y1 - y0 < 2:
            continue
        found = letters(gray[y0:y1, x0:x1])
        mask[y0:y1, x0:x1] |= True if found is None else found
    return binary_dilation(mask, iterations=GLYPH_GROW)


def plate(cover, boxes, lama):
    """`cover` (PIL, square) with its text painted out by LaMa, and the mask of where it was, soft at its edge."""
    where = hole(np.asarray(cover), boxes)
    filled = label.inpaint(np.asarray(cover, dtype=np.float32) / 255, where.astype(np.float32), lama)
    soft = gaussian_filter(binary_dilation(where, iterations=FADE_EDGE).astype(np.float32), FADE_EDGE / 2)
    soft = np.maximum(soft, where)
    return Image.fromarray((filled * 255 + 0.5).astype(np.uint8)), soft


def lengthened(items):
    """`items`, whose last is its first, played over itself until the whole is at least LONG seconds."""
    times = max(1, math.ceil(LONG * FPS / max(len(items) - 1, 1)))
    return list(items[:-1]) * times + [items[0]]


def shown_text(i, n):
    """How much of the text shows in frame `i` of `n`: all at the start and end, none in between."""
    seconds = (n - 1) / FPS
    t = i / FPS
    out_from, in_to = SHOWN_FIRST * seconds, (1 - SHOWN_LAST) * seconds
    def ease(x):
        x = min(max(x, 0.0), 1.0)
        return x * x * (3 - 2 * x)
    return max(1 - ease((t - out_from) / FADE), ease((t - (in_to - FADE)) / FADE))


def faded(cover, text, mask, amount):
    """The frame's cover with the still text over it at `amount`, inside `mask`."""
    a = (mask * amount)[..., None]
    return cover * (1 - a) + text * a


def swayed(frame, i, n):
    """`frame` (float RGB) as a camera swaying slowly sees it, frame `i` of `n`: once round over the loop."""
    h, w = frame.shape[:2]
    turn = 2 * math.pi * i / max(n - 1, 1)
    dx = DRIFT_X * w * math.sin(turn)
    dy = DRIFT_Y * w * math.sin(2 * turn + 0.7)
    zoom = ZOOM_LEAST + PUSH * (1 - math.cos(turn)) / 2
    angle = TILT * math.sin(turn + 1.1)
    matrix = cv2.getRotationMatrix2D((w / 2, h / 2), angle, zoom)
    matrix[:, 2] += (dx, dy)
    return cv2.warpAffine(frame, matrix, (w, h), flags=cv2.INTER_CUBIC, borderMode=cv2.BORDER_REFLECT)
