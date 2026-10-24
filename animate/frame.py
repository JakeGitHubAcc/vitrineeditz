"""The lock screen's 3:4 frame around a cover: the cover across the frame's width, centered and sharp; above
and below it, the cover painted on past its edges (LaMa), blurred more the farther from it, so it fades
smoothly into a soft wash of itself; and the bottom shaded for the lock screen's controls. The cover's own
pixels are never blurred, so its text stays sharp.
"""
import numpy as np
from PIL import Image
from scipy.ndimage import gaussian_filter

import label

# The clip the phone gets: 3:4 at three quarters of an iPhone's width, the size SGMotionPixels downloads.
OUT_W, OUT_H = 768, 1024
# The share of the cover cut off each edge first: many covers have a thin border or a JPEG fringe there.
EDGE_TRIM = 0.006
# The blur at the frame's top and bottom edges, as a share of the cover's side, and how it grows from the
# cover's edge: as the distance to this power, so the first rows painted on stay nearly sharp.
BLUR_MAX, BLUR_CURVE = 0.06, 1.6
# The blurs mixed between, as shares of the most.
LEVELS = (0, 0.03, 0.07, 0.15, 0.3, 0.55, 1.0)
# How much richer and darker the wash is at the frame's edges, as SGExtendedClip.m's far wash is.
SATURATION, BRIGHTNESS = 1.15, -0.05
# The shade over the bottom, where the lock screen's controls are: from this share of the frame's height
# from the bottom, to this darkness at the bottom.
SHADE_FROM, SHADE_ALPHA = 0.6, 0.4


def to_linear(c):
    c = c / 255
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4).astype(np.float32)


def to_srgb(c):
    c = np.clip(c, 0, 1)
    return (255 * np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)).astype(np.float32)


class Extended:
    """The frame around `cover`. `lama` is big-lama.pt's path; without it the edges are drawn out instead
    of painted on."""

    def __init__(self, cover, lama=None):
        w, h = cover.size
        trim = (round(w * EDGE_TRIM), round(h * EDGE_TRIM), w - round(w * EDGE_TRIM), h - round(h * EDGE_TRIM))
        self.cover = cover.convert("RGB").crop(trim).resize((OUT_W, OUT_W), Image.LANCZOS)
        side = OUT_W
        self.top = top = (OUT_H - side) // 2
        sharp = np.asarray(self.cover, dtype=np.float32)
        if lama:
            # LaMa paints at half size, as the band is blurred anyway; the cover is laid back over it whole.
            canvas = np.zeros((OUT_H, OUT_W, 3), dtype=np.uint8)
            canvas[top:top + side] = sharp.astype(np.uint8)
            half = np.asarray(Image.fromarray(canvas).resize((OUT_W // 2, OUT_H // 2), Image.LANCZOS), dtype=np.float32) / 255
            # The hole takes two rows of the cover too, where shrinking mixed the black into it.
            hole = np.ones(half.shape[:2], dtype=np.float32)
            hole[top // 2 + 2:(top + side) // 2 - 2] = 0
            painted = label.inpaint(half, hole, lama)
            filled = np.asarray(Image.fromarray((painted * 255 + 0.5).astype(np.uint8)).resize((OUT_W, OUT_H), Image.LANCZOS), dtype=np.float32)
        else:
            filled = np.pad(sharp, ((top, OUT_H - top - side), (0, 0), (0, 0)), mode="edge")
        filled[top:top + side] = sharp
        light = to_linear(filled)
        # Each row's blur, from its distance to the cover, mixed between the two nearest of LEVELS.
        y = np.arange(OUT_H, dtype=np.float32)
        away = np.maximum(np.maximum(top - y, y - (top + side - 1)), 0) / top
        want = away ** BLUR_CURVE
        sigmas = [level * BLUR_MAX * side for level in LEVELS]
        blurred = [light if s == 0 else gaussian_filter(light, (s, s, 0), mode="nearest") for s in sigmas]
        position = np.interp(want, LEVELS, np.arange(len(LEVELS)))
        low = np.floor(position).astype(int)
        high = np.minimum(low + 1, len(LEVELS) - 1)
        mix = (position - low)[:, None, None]
        stack = np.stack(blurred)
        rows = np.arange(OUT_H)
        wash = stack[low, rows] * (1 - mix) + stack[high, rows] * mix
        luma = (wash @ np.array([0.2125, 0.7154, 0.0721], dtype=np.float32))[..., None]
        reach = want[:, None, None]
        wash = luma + (wash - luma) * (1 + (SATURATION - 1) * reach) + BRIGHTNESS * reach
        self.edges = to_srgb(wash)
        shade = SHADE_ALPHA * np.clip((y + 0.5 - OUT_H * (1 - SHADE_FROM)) / (OUT_H * SHADE_FROM), 0, 1)
        self.unshaded = (1 - shade)[:, None, None]

    def frame(self, cover):
        """The frame with `cover`, a frame of the cover's animation at OUT_W, in its place."""
        frame = self.edges.copy()
        frame[self.top:self.top + OUT_W] = cover
        return frame * self.unshaded
