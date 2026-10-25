"""Liquid on a cover, moving the way liquid moves rather than bent along the model's motion, which made it look
strange (+44's When Your Heart Stops Beating, the sea on Tom DeLonge's To the Stars).

Drips (paint, blood, anything dripping, found by name with Grounding DINO and outlined with SAM) run: each one
stretches slowly down from where it hangs and draws back, the most at its tip, and now and then a drop falls
from the longest. The cover is only resampled downward, so nothing behind a drip needs painting in.

Water (the scene model's sea, water, river and lake, or water the finder names) has its own detail smoothed away
and a simulated sea laid in its place in perspective (Waves).

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
# What the finder looks for as water too, its least score for it, and the most of the cover its box may be: the
# finder's scores for water move with the words asked, and a box over the whole cover was a background it took for
# water (+44's, 0.79), where the flood on To the Stars is its lower part (0.52).
WATER_WORDS, WATER_SCORE, WATER_BOX = ("water",), 0.3, 0.85
# How sure the scene model must be, the least share of the cover water must be, and its soft edge in pixels.
WATER_SURE, WATER_LEAST, WATER_SOFT = 0.5, 0.02, 3
# The sea's surface: its tile's cells and size in metres, the wind's speed (m/s) and direction (radians, 0 across),
# the smallest wave kept (m), how many times the tile repeats across the cover's width at the bottom, how much the
# plane is stretched away from the eye, and how fast the waves go against deep water's own speed.
SEA_N, SEA_SIZE, SEA_SPEED, SEA_WIND, SEA_SMALLEST, SEA_TILES, SEA_STRETCH, SEA_PACE = 256, 40.0, 6.0, 1.2, 0.05, 3.0, 0.45, 0.35
# How far the water's own detail is smoothed (a share of the side), how high the eye is over the plane (how flat the
# view is), how much a slope turns the light, the water's reflectance head on (Schlick's F0), how strongly the
# reflection and a ripple's own light and shade change the water, where a glint starts (in the ripples' spreads)
# and how strong it is, and how far in from the horizon the waves fade in (a share of the water's depth).
SEA_SMOOTH, SEA_EYE, SEA_TILT, SEA_F0 = 0.02, 0.35, 2.5, 0.02
SEA_AMOUNT, SEA_RIPPLE, SEA_SHINE, SEA_GLINT, WAVE_HORIZON = 0.5, 0.16, 2.4, 0.04, 0.12
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
             if any(word in name for word in WATER_WORDS) and (box[2] - box[0]) * (box[3] - box[1]) <= WATER_BOX * side ** 2]
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
    """The water in a cover (`cover`, float RGB, square) made a moving sea: its own detail smoothed away and a
    simulated surface laid in its place in perspective; none (`self.mask` empty) where there is too little water.
    `water` is the 0 to 1 map of it, `keep` 1 where nothing may change (faces, text, people).

    The surface is Tessendorf's (the FFT ocean of film work): a field of waves from the Phillips spectrum, each moving
    at its own speed, every speed rounded to whole turns over the loop so the last frame is the first. It is seen on
    the water's plane from the cover's eye: its slopes give each point's normal, which reflects more of the sky the
    flatter the view, with a glint where a crest faces the light. That light is laid over the water's own smoothed
    colors, so the cover keeps its grade (a black and white cover stays one)."""

    def __init__(self, cover, water, keep, seed, fps):
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
        self.mask = mask.astype(np.float32)
        # The water's own colors without its detail: blurred within the water only, so nothing around it bleeds in.
        inside = (water > 0.5).astype(np.float32)
        spread = SEA_SMOOTH * side
        weight = gaussian_filter(inside, spread)
        smooth = np.stack([gaussian_filter(cover[..., c] * inside, spread) for c in range(3)], -1) / np.maximum(weight, 1e-4)[..., None]
        self.smooth = np.where(weight[..., None] > 1e-3, smooth, cover).astype(np.float32)
        # The plane: the horizon is the top of the water, and a pixel's distance on the plane grows toward it.
        horizon = float(ys.min())
        y, x = np.mgrid[0:side, 0:side].astype(np.float32)
        depth = np.clip((y - horizon) / max(side - horizon, 1), 0.015, 1)
        distance = 1 / depth
        # Where each pixel looks on the tile, in its cells.
        scale = SEA_TILES * SEA_N
        self.map_x = np.mod((x - side / 2) / side * distance * scale, SEA_N).astype(np.float32)
        self.map_y = np.mod(distance * scale * SEA_STRETCH, SEA_N).astype(np.float32)
        # Far off the waves are smaller than a pixel and would shimmer: they fade toward the smooth water.
        self.detail = smooth_ramp(depth / WAVE_HORIZON).astype(np.float32)
        # The view: flatter toward the horizon, so more of the sky is reflected there.
        self.view_y = (1 / np.sqrt(1 + (distance * SEA_EYE) ** 2)).astype(np.float32)
        self.seed = seed
        self.loop = None

    def surface(self, n):
        """The spectrum, once the loop's length is known: each wave's start and its whole turns over the loop."""
        rng = np.random.default_rng(self.seed)
        k = np.fft.fftfreq(SEA_N, d=1.0 / SEA_N) * 2 * math.pi / SEA_SIZE
        kx, kz = np.meshgrid(k, k)
        length = np.sqrt(kx ** 2 + kz ** 2)
        length[0, 0] = 1
        biggest = SEA_SPEED ** 2 / 9.81
        along = (kx * math.cos(SEA_WIND) + kz * math.sin(SEA_WIND)) / length
        phillips = np.exp(-1 / (length * biggest) ** 2) / length ** 4 * along ** 2 * np.exp(-(length * SEA_SMALLEST) ** 2)
        phillips[0, 0] = 0
        self.h0 = (rng.standard_normal((SEA_N, SEA_N)) + 1j * rng.standard_normal((SEA_N, SEA_N))) * np.sqrt(phillips / 2)
        # h0 at -k, conjugated: the other half of each wave, so the field is real.
        self.h0_minus = np.conj(np.roll(np.flip(self.h0), 1, axis=(0, 1)))
        # Deep water's speed for each wave over the loop, rounded to whole turns, at least one.
        seconds = (n - 1) / self.fps
        self.turns = np.maximum(np.round(np.sqrt(9.81 * length) * seconds / (2 * math.pi) * SEA_PACE), 1)
        self.kx, self.kz = kx, kz
        self.loop = n

    def over(self, frame, i, n):
        """`frame` with the sea as it is in frame `i` of `n`."""
        if not self.mask.any():
            return frame
        if self.loop != n:
            self.surface(n)
        t = i / max(n - 1, 1)
        turn = np.exp(1j * 2 * math.pi * self.turns * t)
        h = self.h0 * turn + self.h0_minus * np.conj(turn)
        slope_x = np.fft.ifft2(1j * self.kx * h).real.astype(np.float32)
        slope_z = np.fft.ifft2(1j * self.kz * h).real.astype(np.float32)
        # The slopes seen from the cover, each pixel sampling the tile where it looks on the plane.
        sx = cv2.remap(slope_x, self.map_x, self.map_y, cv2.INTER_LINEAR, borderMode=cv2.BORDER_WRAP) * self.detail
        sz = cv2.remap(slope_z, self.map_x, self.map_y, cv2.INTER_LINEAR, borderMode=cv2.BORDER_WRAP) * self.detail
        sx, sz = sx * SEA_TILT, sz * SEA_TILT
        # The normal against the eye: flatter views reflect more (Schlick's Fresnel), crests facing the light glint.
        norm = np.sqrt(sx * sx + 1 + sz * sz)
        facing = np.clip((self.view_y - sz) / norm, 0, 1)
        fresnel = SEA_F0 + (1 - SEA_F0) * (1 - facing) ** 5
        inside = self.mask > 0.5
        mean = float(fresnel[inside].mean()) if inside.any() else 0.5
        # Seen nearly from above, the reflection hardly changes over a ripple (the near water was a plain blur), so
        # each ripple is also lit on the side facing the light and shaded on the other, measured in its own spread.
        spread = float(np.sqrt((slope_x ** 2 + slope_z ** 2).mean())) * SEA_TILT + 1e-6
        ripple = (sz * 0.8 + sx * 0.6) / spread
        light = 1 + SEA_AMOUNT * (fresnel / max(mean, 1e-3) - 1) + SEA_RIPPLE * ripple
        glint = np.clip(ripple - SEA_SHINE, 0, None) ** 2 * self.detail
        sea = self.smooth * light[..., None] + 255 * SEA_GLINT * glint[..., None]
        m = self.mask[..., None]
        return frame * (1 - m) + sea * m
