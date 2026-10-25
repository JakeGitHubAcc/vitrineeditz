"""Liquid on a cover, moving the way liquid moves rather than bent along the model's motion, which made it look
strange (+44's When Your Heart Stops Beating, the sea on Tom DeLonge's To the Stars).

Drips (paint, blood, anything dripping, found by name with Grounding DINO and outlined with SAM) run: each one
stretches slowly down from where it hangs and draws back, the most at its tip, and now and then a drop falls
from the longest. The cover is only resampled downward, so nothing behind a drip needs painting in.

Water (the scene model's sea, water, river and lake) is left still and a light pattern of waves is laid over
it in perspective: the waves are worked out on the water's own plane and seen from the cover's eye, small and
close together toward the horizon and larger toward the bottom, crests a little lighter and troughs a little
darker, rolling toward the viewer.

Every motion is made of whole cycles of the loop starting from none, so the last frame is the first.
"""
import math

import cv2
import numpy as np
from scipy.ndimage import gaussian_filter
from scipy.ndimage import label as components

import props

DRIP_WORDS = ("drip", "dripping paint", "paint drip", "blood drip", "dripping", "paint splatter", "splatter")
# The finder's least score for a drip: it is less sure of a splatter (0.15 to 0.17 on +44's) than of a bee.
DRIP_SCORE = 0.15
# What a drip may be at most, as a share of the cover (a splatter can fill most of it), the least a drip's part must
# be, in pixels, and the least it must hang, as a share of the side: thin lines taken for drips (Make Yourself's
# interface lines) only shifted a pixel.
DRIP_LARGEST, DRIP_LEAST, DRIP_SHORTEST = 0.9, 60, 0.03
# How far a drip's tip runs down at its longest, as a share of the drip's height and at most a share of the side, so
# a splatter the size of the cover runs at its streaks' ends rather than sliding whole; and how many times over the loop.
DRIP_RUN, DRIP_MOST, DRIP_CYCLES = 0.08, 0.02, (1, 2)
# Falling drops: at most this many, how far one falls (a share of the side), how long it takes (seconds), its
# size (a share of the side), and the least height a drip must be (a share of the side) to let one fall.
DROPS, DROP_FALL, DROP_SECONDS, DROP_SIZE, DROP_FROM = 2, 0.08, 0.7, 0.006, 0.05

WATER = {"sea", "water", "river", "lake", "swimming pool"}
# What the finder looks for as water too, and its least score for it.
WATER_WORDS, WATER_SCORE = ("water", "sea", "ocean", "lake", "river", "flood"), 0.4
# How sure the scene model must be, the least share of the cover water must be, and its soft edge in pixels.
WATER_SURE, WATER_LEAST, WATER_SOFT = 0.5, 0.02, 3
# The waves: how many, their length on the water's plane (shares of the cover's width at the bottom), how much a
# crest lightens and a trough darkens, how far in from the horizon they fade in (a share of the water's depth),
# and how many times each rolls over the loop.
WAVES, WAVE_LONGEST, WAVE_SHORTEST, WAVE_AMOUNT, WAVE_HORIZON, WAVE_CYCLES = 7, 0.22, 0.05, 0.07, 0.25, (1, 2, 3)
# How far around faces and text, and in from the cover's top and bottom, the waves ease off, as shares of the side.
KEEP_EASE, EDGE_EASE = 0.03, 0.06


def water_found(cover, path, keep):
    """Water the finder sees in `cover` (RGB float, square), outlined by SAM: 0 to 1. The scene model took the
    flood on To the Stars for a floor, sure of it; the finder named it water."""
    side = cover.shape[0]
    found = np.zeros((side, side), np.float32)
    if not path:
        return found
    pixels = np.clip(cover, 0, 255).astype(np.uint8)
    boxes = [box for box, name, _ in props.named(pixels, path, WATER_WORDS, WATER_SCORE)
             if any(word in name for word in WATER_WORDS)]
    if not boxes:
        return found
    for outline in props.outlines(pixels, path, boxes):
        found = np.maximum(found, outline.astype(np.float32))
    return found * (keep < 0.5)


def smooth_ramp(x):
    x = np.clip(x, 0, 1)
    return x * x * (3 - 2 * x)


def edge_ease(side):
    """1 inside, falling to 0 at the cover's top and bottom, where the still blur drawn out from them meets it."""
    y = np.arange(side, dtype=np.float32)
    return smooth_ramp(np.minimum(y, side - 1 - y) / (EDGE_EASE * side))[:, None]


class Drips:
    """The drips in `cover` (float RGB, square) running, from the models in `path`; none (`self.mask` empty) where
    there are none. `keep` is 1 where nothing may move (faces, text)."""

    def __init__(self, cover, path, keep, seed, fps):
        side = cover.shape[0]
        self.side, self.fps = side, fps
        self.mask = np.zeros((side, side), np.float32)
        self.count = 0
        if not path:
            return
        pixels = np.clip(cover, 0, 255).astype(np.uint8)
        boxes = []
        for box, name, _ in props.named(pixels, path, DRIP_WORDS, DRIP_SCORE):
            if (box[2] - box[0]) * (box[3] - box[1]) / side ** 2 <= DRIP_LARGEST:
                boxes.append(box)
        if not boxes:
            return
        found = np.zeros((side, side), bool)
        for outline in props.outlines(pixels, path, boxes):
            found |= outline
        found &= keep < 0.5
        parts, count = components(found)
        rng = np.random.default_rng(seed)
        # How far down each pixel is resampled at the drips' longest: down each column of a part, growing from where
        # the part hangs to its tip, then held for the run's length below the tip, which is what draws it out.
        self.reach = np.zeros((side, side), np.float32)
        self.drops = []
        tips = []
        for k in range(1, count + 1):
            part = parts == k
            if part.sum() < DRIP_LEAST:
                continue
            ys, xs = np.nonzero(part)
            top, bottom = ys.min(), ys.max()
            height = bottom - top + 1
            if height < DRIP_SHORTEST * side:
                continue
            run = min(DRIP_RUN * height, DRIP_MOST * side) * rng.uniform(0.6, 1.0)
            for x in np.unique(xs):
                column = ys[xs == x]
                tip = column.max()
                length = (tip - top + 1) / height
                most = run * length * length
                if most < 0.5:
                    continue
                down = np.arange(top, min(side, int(tip + 2 * most) + 1))
                grow = np.clip((down - top) / max(tip - top, 1), 0, 1) ** 2
                below = smooth_ramp(1 - (down - tip) / max(2 * most, 1))
                self.reach[down, x] = np.maximum(self.reach[down, x], most * np.where(down <= tip, grow, below))
            self.mask = np.maximum(self.mask, part.astype(np.float32))
            if height >= DROP_FROM * side:
                x = int(np.median(xs[ys >= bottom - 2]))
                tips.append((height, x, bottom))
            self.count += 1
        if not self.count:
            return
        self.reach = gaussian_filter(self.reach, 1.0)
        self.cycles = int(rng.choice(DRIP_CYCLES))
        # The longest drips let a drop fall, each at its own moment well inside the loop.
        for height, x, bottom in sorted(tips, reverse=True)[:DROPS]:
            color = cover[min(bottom, side - 1), x].astype(np.float32)
            self.drops.append({"x": float(x), "y": float(bottom), "color": color, "at": rng.uniform(0.15, 0.7)})
        rows = np.nonzero(self.reach.max(axis=1) > 0.05)[0]
        self.rows = (int(rows.min()), int(rows.max()) + 1) if len(rows) else (0, 0)

    def over(self, frame, i, n):
        """`frame` with the drips as they are in frame `i` of `n`."""
        if not self.count:
            return frame
        t = i / max(n - 1, 1)
        out = frame
        # Down and back up, from none.
        run = (1 - math.cos(2 * math.pi * self.cycles * t)) / 2
        y0, y1 = self.rows
        if run > 0.001 and y1 > y0:
            out = frame.copy()
            region = self.reach[y0:y1] * run
            x, y = np.meshgrid(np.arange(self.side, dtype=np.float32), np.arange(y0, y1, dtype=np.float32))
            out[y0:y1] = cv2.remap(frame, x, y - region, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
        seconds = (n - 1) / self.fps
        for drop in self.drops:
            into = (t * seconds - drop["at"] * seconds) / DROP_SECONDS
            if not 0 < into < 1:
                continue
            if out is frame:
                out = frame.copy()
            # Falling faster as it goes, and gone by the end.
            y = drop["y"] + DROP_FALL * self.side * into * into
            r = max(1.5, DROP_SIZE * self.side * (1 - 0.3 * into))
            alpha = (1 - into) ** 0.5
            layer = np.zeros(out.shape[:2], np.float32)
            cv2.ellipse(layer, (int(round(drop["x"])), int(round(y))), (int(round(r)), int(round(r * 1.5))), 0, 0, 360, 1.0, -1, cv2.LINE_AA)
            layer = (gaussian_filter(layer, 0.6) * alpha)[..., None]
            out = out * (1 - layer) + drop["color"] * layer
        return out


class Waves:
    """Waves laid over the water in a cover, in perspective; none (`self.mask` empty) where there is too little.
    `water` is the scene model's 0 to 1 map of it, `keep` 1 where nothing may change (faces, text)."""

    def __init__(self, water, keep, seed, fps):
        side = water.shape[0]
        self.side, self.fps = side, fps
        self.mask = np.zeros((side, side), np.float32)
        if water.mean() < WATER_LEAST:
            return
        mask = np.clip(gaussian_filter(water.astype(np.float32), WATER_SOFT), 0, 1)
        mask *= 1 - np.clip(gaussian_filter(keep.astype(np.float32), KEEP_EASE * side) * 2, 0, 1)
        mask *= edge_ease(side)
        ys = np.nonzero(water.max(axis=1) > 0.5)[0]
        if not len(ys):
            return
        # The horizon is the top of the water; the water's plane is seen from above it, nearer toward the bottom.
        horizon = float(ys.min())
        y, x = np.mgrid[0:side, 0:side].astype(np.float32)
        depth = np.clip((y - horizon) / max(side - horizon, 1), 0.02, 1)
        distance = 1 / depth
        self.u = (x - side / 2) / side * distance
        self.v = distance
        # Far waves crowd together and would shimmer: they fade in from the horizon.
        mask *= smooth_ramp(depth / WAVE_HORIZON)
        self.mask = mask.astype(np.float32)
        rng = np.random.default_rng(seed)
        self.waves = []
        for _ in range(WAVES):
            angle = math.radians(rng.uniform(-50, 50))
            length = rng.uniform(WAVE_SHORTEST, WAVE_LONGEST)
            self.waves.append((math.sin(angle) / length, math.cos(angle) / length, int(rng.choice(WAVE_CYCLES)),
                               rng.uniform(0, 2 * math.pi), rng.uniform(0.5, 1.0)))
        total = sum(w[4] for w in self.waves)
        self.waves = [(a, b, c, p, w / total) for a, b, c, p, w in self.waves]

    def over(self, frame, i, n):
        """`frame` with the waves as they are in frame `i` of `n`: rolling toward the viewer, the same at both ends."""
        if not self.mask.any():
            return frame
        t = i / max(n - 1, 1)
        height = np.zeros((self.side, self.side), np.float32)
        for a, b, cycles, phase, weight in self.waves:
            # The crests move toward the viewer (down the plane), a whole number of wavelengths over the loop.
            height += weight * np.sin(2 * math.pi * (a * self.u + b * self.v + cycles * t) + phase).astype(np.float32)
        light = 1 + WAVE_AMOUNT * 2.2 * height * self.mask
        return frame * light[..., None]
