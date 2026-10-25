"""Fog, smoke and mist on a cover, drifting. Warping the cover along the model's motion to move a haze bent
whatever stood in it (a gravestone, a speaker), so the haze is not moved at all: a smoke of its own is laid
over it instead, billows of soft noise in the haze's own color drifting slowly across where the haze is.

Where: Grounding DINO (props.py's models) finds fog, smoke, mist and haze by name, and within what it found
the haze is what is pale, unsaturated and smooth. Faces and text are kept clear of it.

The billows are noise that tiles, so it slides with no edge; and so the clip loops, each layer is the noise
slid along its drift crossfaded, over the loop, into the same noise slid as far again from where the loop ends:
the last frame is the first.
"""
import math

import cv2
import numpy as np
from scipy.ndimage import gaussian_filter

import props

WORDS = ("fog", "smoke", "mist", "haze")
# What is haze inside a find: at most this saturation, at least this brightness (0 to 1), and smoother than
# this (the gray's local deviation, levels out of 255, over SMOOTH_SIZE of the side).
HAZE_SATURATION, HAZE_LEAST, HAZE_SMOOTH, SMOOTH_SIZE = 0.3, 0.1, 18.0, 0.006
# Nor what is near white, where the smoke's gray only showed as blotches (+44's, Make Yourself's glow); and the
# finder's least score, which a white ground or a glow could pass at the props' 0.3.
HAZE_MOST, FOG_SCORE = 0.88, 0.4
# The haze's soft edge as a share of the side, and the least share of the cover it must be.
HAZE_SOFT, HAZE_LEAST_SHARE = 0.02, 0.01
# The most the smoke thickens toward the haze's color, how far the billows reach from their mean, and how much
# it darkens between them, as a share of AMOUNT.
AMOUNT, BILLOW, THIN = 0.3, 0.9, 0.5
# The billows' size (a share of the side) and each layer's drift, in shares of the side a second.
SIZE = 0.16
DRIFTS = ((0.022, -0.004), (-0.014, 0.005))
# How far around faces and text it eases off, and in from the cover's top and bottom, as shares of the side.
KEEP_EASE, EDGE_FADE = 0.03, 0.1


def tiling_noise(side, size, rng):
    """Smooth noise at `side` that tiles, its billows about `size` of the side across: zero mean, unit
    deviation."""
    fy = np.fft.fftfreq(side)[:, None]
    fx = np.fft.fftfreq(side)[None, :]
    f = np.sqrt(fx ** 2 + fy ** 2) * side * size
    spectrum = (rng.standard_normal((side, side)) + 1j * rng.standard_normal((side, side))) / (1 + f ** 2.2)
    spectrum[0, 0] = 0
    noise = np.fft.ifft2(spectrum).real.astype(np.float32)
    return (noise - noise.mean()) / max(float(noise.std()), 1e-6)


def slid(noise, dx, dy):
    """`noise` slid by (dx, dy) pixels, wrapping round."""
    m = np.float32([[1, 0, dx], [0, 1, dy]])
    return cv2.warpAffine(noise, m, noise.shape[::-1], flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_WRAP)


def found(cover, path):
    """The finder's boxes, in pixels, for haze in `cover` (RGB uint8, square)."""
    return [box for box, name, _ in props.named(cover, path, WORDS, FOG_SCORE) if any(w in name for w in WORDS)]


class Fog:
    """The drifting smoke over the haze in `cover` (float RGB, square), from the models in `path`; none where
    there is no haze (`self.mask` empty). `keep` is 1 where it may not go (faces, text)."""

    def __init__(self, cover, path, keep, seed, fps):
        side = cover.shape[0]
        self.side, self.fps = side, fps
        self.mask = np.zeros((side, side), np.float32)
        if not path:
            return
        pixels = np.clip(cover, 0, 255).astype(np.uint8)
        boxes = found(pixels, path)
        if not boxes:
            return
        where = np.zeros((side, side), np.float32)
        for l, t, r, b in boxes:
            where[max(0, int(t)):int(math.ceil(b)), max(0, int(l)):int(math.ceil(r))] = 1
        hsv = cv2.cvtColor(pixels, cv2.COLOR_RGB2HSV).astype(np.float32) / 255
        gray = cv2.cvtColor(pixels, cv2.COLOR_RGB2GRAY).astype(np.float32)
        spread = SMOOTH_SIZE * side
        deviation = np.sqrt(np.maximum(gaussian_filter(gray ** 2, spread) - gaussian_filter(gray, spread) ** 2, 0))
        haze = ((hsv[..., 1] <= HAZE_SATURATION) & (hsv[..., 2] >= HAZE_LEAST) & (hsv[..., 2] <= HAZE_MOST) & (deviation <= HAZE_SMOOTH)).astype(np.float32)
        haze = np.clip(gaussian_filter(haze * where, HAZE_SOFT * side) * 1.5, 0, 1)
        haze *= 1 - np.clip(gaussian_filter(keep.astype(np.float32), KEEP_EASE * side) * 2, 0, 1)
        # None at the cover's top and bottom, where the still blur drawn out from them meets it: smoke up to the
        # edge made a line there.
        y = np.arange(side, dtype=np.float32)
        ramp = np.clip(np.minimum(y, side - 1 - y) / (EDGE_FADE * side), 0, 1)
        haze *= (ramp * ramp * (3 - 2 * ramp))[:, None]
        if haze.mean() < HAZE_LEAST_SHARE:
            return
        self.mask = haze
        # The haze's own color: its lighter part, which is the haze rather than what shows through it.
        inside = cover[haze > 0.5] if (haze > 0.5).any() else cover.reshape(-1, 3)
        light = inside[inside.mean(axis=1) >= np.percentile(inside.mean(axis=1), 70)]
        self.color = light.mean(axis=0).astype(np.float32)
        rng = np.random.default_rng(seed)
        self.layers = [(tiling_noise(side, SIZE * scale, rng), drift) for scale, drift in zip((1.0, 0.6), DRIFTS)]

    def density(self, i, n):
        """The billows in frame `i` of `n`, about 0 to 1."""
        seconds = (n - 1) / self.fps
        t = i / self.fps
        w = t / max(seconds, 1e-6)
        total = np.zeros((self.side, self.side), np.float32)
        for noise, (vx, vy) in self.layers:
            now = slid(noise, vx * t * self.side, vy * t * self.side)
            back = slid(noise, vx * (t - seconds) * self.side, vy * (t - seconds) * self.side)
            # Two unrelated fields crossfaded lose contrast midway; this keeps their spread.
            total += ((1 - w) * now + w * back) / math.sqrt((1 - w) ** 2 + w ** 2)
        total /= math.sqrt(len(self.layers))
        return np.clip(0.5 + 0.5 * BILLOW * total, 0, 1)

    def over(self, frame, i, n):
        """`frame` with the smoke over it as it is in frame `i` of `n`: thicker toward the haze's color where
        the billows are dense, a little thinner (darker) between them, so on the whole the cover keeps its
        look."""
        if not self.mask.any():
            return frame
        d = self.density(i, n) * 2 - 1
        thick = (AMOUNT * self.mask * np.clip(d, 0, 1))[..., None]
        thin = (THIN * AMOUNT * self.mask * np.clip(-d, 0, 1))[..., None]
        return (frame * (1 - thick) + self.color * thick) * (1 - thin)
