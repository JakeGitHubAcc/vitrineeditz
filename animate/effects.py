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
# How far past a line of text it is painted out, as a share of the line's height, and the soft edge of
# the fade's mask, in pixels.
ERASE_PAD, FADE_EDGE = 0.3, 4
# The fade: the text shows for this share of the loop at its start, fades out over FADE seconds, stays
# away, and fades back in to show again for this share at the end. The first frame, the poster, has it.
SHOWN_FIRST, SHOWN_LAST, FADE = 0.3, 0.12, 1.2
# The sway: the drift sideways and up and down and the push in, as shares of the frame's width, and the
# tilt in degrees. The frame is always enlarged by at least ZOOM_LEAST, so its edges never show.
DRIFT_X, DRIFT_Y, PUSH, TILT, ZOOM_LEAST = 0.005, 0.003, 0.012, 0.25, 1.025


def hole(size, boxes):
    """1 over the lines of text, grown by ERASE_PAD of their height. Boxes are shares of the side."""
    mask = np.zeros((size, size), bool)
    for l, t, r, b in boxes:
        grow = ERASE_PAD * (b - t)
        x0, y0 = max(0, int((l - grow) * size)), max(0, int((t - grow) * size))
        x1, y1 = min(size, int(math.ceil((r + grow) * size))), min(size, int(math.ceil((b + grow) * size)))
        mask[y0:y1, x0:x1] = True
    return mask


def plate(cover, boxes, lama):
    """`cover` (PIL, square) with its text painted out by LaMa, and the mask of where it was, soft at its edge."""
    size = cover.width
    where = hole(size, boxes)
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
