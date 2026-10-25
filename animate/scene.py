"""What the cover shows, by kind, and curtains, trees and bushes swaying. A scene model (SegFormer, ADE20K's
150 kinds) says what each pixel is. Built and solid things (a stage, a floor, walls, a lamp) keep their
shape: the model's motion, which bends them, is held off them (motion.py's `still`) where the scene model
is sure of them, which it is not of a painting. Curtains do not take the model's motion either, which drags
the stage along with them, but sway on their own: each is a layer moved by a slow wave that grows from
where it hangs to its hem, over the cover with its edges painted in behind it for what the moving shows.
Trees, bushes and grass (found by props.py) sway the same way from where they stand, their tops most.

The wave is made of whole cycles of the loop starting from none, so the first and last frames are the
cover as it is.
"""
import math

import cv2
import numpy as np
from scipy.ndimage import binary_erosion, gaussian_filter, gaussian_filter1d
from scipy.ndimage import label as components

import label

# The kinds that keep their shape: built, solid and fixed things.
SOLID = {
    "wall", "building", "floor", "ceiling", "road", "sidewalk", "door", "house", "skyscraper", "windowpane",
    "fence", "railing", "column", "stairs", "stairway", "step", "stage", "bridge", "tower", "car", "bus",
    "truck", "van", "boat", "ship", "airplane", "table", "chair", "cabinet", "desk", "lamp", "streetlight",
    "pole", "signboard", "stool", "bannister", "base", "box", "counter", "shelf", "bookcase", "seat", "bench",
    "rock", "grandstand", "trade name", "light", "sconce", "chandelier", "bed", "sofa", "armchair",
}
CURTAIN = "curtain"
# The only kinds the model's motion may move: what flows. Moving the rest bent whatever stood in it (a gravestone,
# a speaker behind fog); what moves there moves as layers of its own (crowd.py, props.py, curtains, fog.py).
# Standing water is not among them: bent, a sea's waves looked strange (Tom DeLonge's To the Stars), so it takes
# liquid.py's waves laid over it instead.
FLUID = {"sky", "waterfall", "fountain"}
# The fluid's soft edge in pixels, and the least share of the cover it must be for the model to run at all. The
# motion is smoothed, so it reached a little past the sky's edge into the roofs and trees against it: it is kept
# this share of the side inside the fluid, and only where the scene model is at least this sure of it.
FLUID_SOFT, FLUID_LEAST = 4, 0.03
FLUID_INSET, FLUID_SURE = 0.035, 0.6
# How much of the model's motion is held off solid things, and the soft edge of where they are, in pixels.
SOLID_HOLD, SOLID_SOFT = 0.9, 3
# How sure the scene model must be of a pixel's kind for it to be held.
SOLID_SURE = 0.7
# The least share of the cover that is curtains for them to sway.
CURTAIN_LEAST = 0.02
# The sway at a curtain's hem, as a share of the cover's side (a wave runs up to twice this from where it
# starts); how it grows from where the curtain hangs (a power of the way down); the folds' width, as a share
# of the side; and how many times it sways over the loop.
SWAY, HANG_CURVE, FOLD, CYCLES = 0.008, 1.3, 0.3, 2
# The same for what stands: a tree's or a bush's top sways this share of its height, the least share of
# the cover a thing that stands must be, and the folds and cycles.
STAND_SWAY, STAND_CURVE, STAND_LEAST, STAND_FOLD, STAND_CYCLES = 0.02, 1.6, 0.002, 0.25, 2
# How far in from a curtain's edge it is painted in behind, beyond its sway, in pixels, and its soft edge.
BEHIND_EXTRA, CURTAIN_SOFT = 3, 0.8
# How far around what never moves (text, people) the sway eases off, and in from the cover's top and bottom, where
# the still blur drawn out from them meets it (a treetop swaying at the edge made a line there), as shares of the side.
KEEP_EASE, EDGE_EASE = 0.025, 0.08

_model = {}


def model(path):
    if path not in _model:
        from transformers import SegformerForSemanticSegmentation
        # On the CPU, as ComfyUI wants all of the GPU's memory for the video model.
        _model[path] = SegformerForSemanticSegmentation.from_pretrained(path).eval()
    return _model[path]


class Scene:
    """What each pixel of `cover` (float RGB, square) is, from the scene model at `path`; nothing without one."""

    def __init__(self, cover, path):
        side = cover.shape[0]
        self.side = side
        self.kinds = None
        if not path:
            return
        import torch
        net = model(path)
        x = (cover / 255 - np.array([0.485, 0.456, 0.406])) / np.array([0.229, 0.224, 0.225])
        x = torch.from_numpy(x.astype(np.float32)).permute(2, 0, 1)[None]
        x = torch.nn.functional.interpolate(x, size=(640, 640), mode="bilinear", align_corners=False)
        with torch.inference_mode():
            logits = net(pixel_values=x).logits
            logits = torch.nn.functional.interpolate(logits, size=(side, side), mode="bilinear", align_corners=False)
        chances = logits[0].softmax(0)
        self.sure = chances.max(0).values.numpy()
        self.kinds = chances.argmax(0).numpy()
        self.names = {int(k): v.strip() for k, v in net.config.id2label.items()}

    def of(self, names):
        """1 where the cover shows any of `names`."""
        if self.kinds is None:
            return np.zeros((self.side, self.side), np.float32)
        ids = [k for k, v in self.names.items() if v in names]
        return np.isin(self.kinds, ids).astype(np.float32)

    def fluid(self):
        """Where the model's motion may move the cover, 0 to 1; None without a scene model, when it may move
        anything that is not held."""
        if self.kinds is None:
            return None
        sure = (self.of(FLUID) > 0) & (self.sure >= FLUID_SURE)
        inside = binary_erosion(sure, iterations=max(1, int(round(FLUID_INSET * self.side))))
        return np.clip(gaussian_filter(inside.astype(np.float32), FLUID_SOFT), 0, 1)

    def solid(self):
        """How much of the model's motion to hold off each pixel."""
        held = self.of(SOLID) * (self.sure >= SOLID_SURE) if self.kinds is not None else self.of(SOLID)
        return np.clip(gaussian_filter(held, SOLID_SOFT), 0, 1) * SOLID_HOLD


class Curtains:
    """What hangs (curtains) or stands (trees, bushes: `stand`) in `cover` (float RGB, square) swaying,
    where `found` (bool, square) is; none (`self.mask` empty) where it is too little. `keep` is 1 where
    nothing may move (text, people)."""

    def __init__(self, cover, found, keep, lama, seed, stand=False):
        side = cover.shape[0]
        self.side = side
        self.mask = np.zeros((side, side), np.float32)
        self.plate = cover
        if found.mean() < (STAND_LEAST if stand else CURTAIN_LEAST):
            return
        self.cover = cover.astype(np.float32)
        self.mask = np.clip(gaussian_filter(found.astype(np.float32), CURTAIN_SOFT), 0, 1)
        y, x = np.mgrid[0:side, 0:side].astype(np.float32)
        if stand:
            size, fold, self.cycles = standing(found, y) * STAND_SWAY, STAND_FOLD, STAND_CYCLES
        else:
            size, fold, self.cycles = hanging(found, y) * SWAY * side, FOLD, CYCLES
        calm = np.clip(gaussian_filter(np.clip(keep, 0, 1).astype(np.float32), KEEP_EASE * side) * 3, 0, 1)
        calm = np.maximum(calm, keep)
        edge = np.clip(np.minimum(y, side - 1 - y) / (EDGE_EASE * side), 0, 1)
        self.size = (size * (1 - calm) * edge * edge * (3 - 2 * edge)).astype(np.float32)
        rng = np.random.default_rng(seed)
        self.folds = [(2 * math.pi * (x / (fold * side) + 0.25 * y / (fold * side)) + rng.uniform(0, 2 * math.pi)).astype(np.float32),
                      (2 * math.pi * (x / (0.6 * fold * side) - 0.15 * y / (fold * side)) + rng.uniform(0, 2 * math.pi)).astype(np.float32)]
        self.grid = (x, y)
        # Behind the edges, for what the sway shows: painted in from what is past them.
        reach = int(math.ceil(2 * float(self.size.max()))) + BEHIND_EXTRA
        band = found & ~binary_erosion(found, iterations=reach)
        if lama and band.any():
            filled = label.inpaint(self.cover / 255, band.astype(np.float32), lama) * 255
            soft = np.clip(gaussian_filter(band.astype(np.float32), 1.0) + band, 0, 1)[..., None]
            self.plate = (self.cover * (1 - soft) + filled * soft).astype(np.float32)

    def over(self, frame, i, n):
        """`frame` (the cover's animation over self.plate) with the curtains laid over it as they sway in
        frame `i` of `n`."""
        if not self.mask.any():
            return frame
        t = i / max(n - 1, 1)
        wave = np.zeros_like(self.size)
        for weight, cycles, phase in ((0.7, self.cycles, self.folds[0]), (0.3, self.cycles + 1, self.folds[1])):
            wave += weight * (np.sin(2 * math.pi * cycles * t + phase) - np.sin(phase))
        step = self.size * wave
        x, y = self.grid
        map_x = x - step
        colors = cv2.remap(self.cover, map_x, y, cv2.INTER_CUBIC, borderMode=cv2.BORDER_REFLECT)
        alpha = np.clip(cv2.remap(self.mask, map_x, y, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT), 0, 1)[..., None]
        return frame * (1 - alpha) + colors * alpha


def hanging(found, y):
    """How far down each pixel is from where its column of curtain hangs to its hem, 0 to 1, to the
    HANG_CURVE power, the columns' tops and hems smoothed across."""
    side = found.shape[0]
    has = found.any(axis=0)
    cols = np.arange(side)
    top = np.where(has, found.argmax(axis=0), 0).astype(np.float32)
    hem = np.where(has, side - 1 - found[::-1].argmax(axis=0), side - 1).astype(np.float32)
    if (~has).any():
        top = np.interp(cols, cols[has], top[has]).astype(np.float32)
        hem = np.interp(cols, cols[has], hem[has]).astype(np.float32)
    top = gaussian_filter1d(top, 0.02 * side, mode="nearest")
    hem = gaussian_filter1d(hem, 0.02 * side, mode="nearest")
    return np.clip((y - top[None]) / np.maximum(hem - top, 1)[None], 0, 1) ** HANG_CURVE


def standing(found, y):
    """How far up each pixel is in the thing it is part of, 0 at its foot and 1 at its top, to the
    STAND_CURVE power, times its height in pixels: a tall tree's top sways farther than a bush's."""
    side = found.shape[0]
    parts, count = components(found)
    up = np.zeros((side, side), np.float32)
    for k in range(1, count + 1):
        rows, cols = np.nonzero(parts == k)
        if len(rows) < 30:
            continue
        top, foot = rows.min(), rows.max()
        l, r = max(0, cols.min() - 8), min(side, cols.max() + 9)
        tall = max(foot - top, 1)
        share = np.clip((foot - y[:, l:r]) / tall, 0, 1) ** STAND_CURVE * tall
        up[:, l:r] = np.maximum(up[:, l:r], share)
    return gaussian_filter(up, 4)
