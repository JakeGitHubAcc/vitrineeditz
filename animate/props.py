"""Things on a cover that move on their own, each cut out and moved whole, as crowd.py does with people:
bees, butterflies and birds hover, clouds drift, flowers nod on their stems, and trees, bushes and grass
bend from where they stand (scene.py's sway, anchored below). They are found by name with Grounding DINO
and outlined with SAM, which read paintings and photos alike, where a scene model trained on photos does
not. What is behind them is painted in (LaMa) for the little their moving shows.

Each motion is made of whole cycles of the loop starting from none: the first and last frames are the
cover as it is.
"""
import math

import cv2
import numpy as np
from scipy.ndimage import binary_dilation, gaussian_filter

import crowd
import label

# What is looked for, and how each moves: "fly" hovers and turns a little, "drift" slides to and fro,
# "nod" turns on its stem, "bend" sways from where it stands.
KINDS = {
    "bee": "fly", "butterfly": "fly", "bird": "fly", "insect": "fly", "dragonfly": "fly", "moth": "fly",
    "balloon": "fly", "feather": "fly",
    "cloud": "drift",
    "flower": "nod", "sunflower": "nod", "rose": "nod", "tulip": "nod", "daisy": "nod",
    "tree": "bend", "palm tree": "bend", "bush": "bend", "grass": "bend",
}
# Back to front: what drifts is far, what flies is near. People go between "bend" and "nod".
DEPTH = {"drift": 0, "bend": 1, "nod": 2, "fly": 3}
# The finder's least scores, and when two finds are one (the share of the smaller box the other covers).
SCORE, WORD_SCORE, SAME = 0.3, 0.25, 0.7
# A find that holds this many others is a group of them (a field of flowers), not one thing; and the most
# of the cover one thing may be, and one that bends.
GROUP, LARGEST, LARGEST_BEND = 3, 0.3, 0.6
# What a thing over a person (a bee over a face) or text, this much of it, is left where it is.
OVER_PERSON, OVER_TEXT = 0.25, 0.05
# How far each moves, as shares of the cover's side or in degrees, and how many times over the loop.
FLY_SHIFT, FLY_LIFT, FLY_TURN, FLY_CYCLES = 0.012, 0.009, 5.0, (2, 3)
DRIFT_SHIFT, DRIFT_CYCLES = 0.015, (1,)
NOD_TURN, NOD_STEM, NOD_CYCLES = 4.0, 0.6, (2, 3)
# How far past each thing the cover is painted in, in pixels, and its outline's soft edge.
BEHIND_GROW, OUTLINE_SOFT = 3, 0.8

_models = {}


def models(path):
    """Grounding DINO and SAM, from the folder holding grounding-dino-base and sam-vit-base."""
    if path not in _models:
        import os
        from transformers import (AutoModelForZeroShotObjectDetection, AutoProcessor, SamModel,
                                  SamProcessor)
        # On the CPU, as ComfyUI wants all of the GPU's memory for the video model.
        _models[path] = (
            AutoProcessor.from_pretrained(os.path.join(path, "grounding-dino-base")),
            AutoModelForZeroShotObjectDetection.from_pretrained(os.path.join(path, "grounding-dino-base")).eval(),
            SamProcessor.from_pretrained(os.path.join(path, "sam-vit-base")),
            SamModel.from_pretrained(os.path.join(path, "sam-vit-base")).eval(),
        )
    return _models[path]


def kind_of(words):
    """How a find named `words` (the finder may give several, as "flower sunflower") moves, or None."""
    for word in sorted(KINDS, key=len, reverse=True):
        if word in words:
            return KINDS[word]
    return None


def named(cover, path, words, score=SCORE):
    """What the finder sees of `words` in `cover` (RGB uint8, square), at least `score` sure: (box in pixels,
    its words, score), the surest first."""
    import torch
    from PIL import Image
    finder_words, finder, _, _ = models(path)
    side = cover.shape[0]
    inputs = finder_words(images=Image.fromarray(cover), text=". ".join(words) + ".", return_tensors="pt")
    with torch.inference_mode():
        out = finder(**inputs)
    result = finder_words.post_process_grounded_object_detection(
        out, inputs.input_ids, threshold=score, text_threshold=min(WORD_SCORE, score), target_sizes=[(side, side)])[0]
    names = result.get("text_labels", result["labels"])
    return sorted(((b, str(n), float(s)) for b, n, s in zip(result["boxes"].numpy(), names, result["scores"].numpy())),
                  key=lambda f: -f[2])


def outlines(cover, path, boxes):
    """SAM's outline (bool, square) of what is in each of `boxes` (pixels) in `cover` (RGB uint8)."""
    import torch
    from PIL import Image
    _, _, outliner_words, outliner = models(path)
    inputs = outliner_words(Image.fromarray(cover), input_boxes=[[list(map(float, b)) for b in boxes]], return_tensors="pt")
    with torch.inference_mode():
        out = outliner(**inputs, multimask_output=False)
    masks = outliner_words.image_processor.post_process_masks(
        out.pred_masks, inputs["original_sizes"], inputs["reshaped_input_sizes"])[0][:, 0].numpy()
    return [m.astype(bool) for m in masks]


# Jewelry, for effects.py's glints: what is looked for, the finder's least score for it (small and thin, the
# finder is less sure of it than of a bee), and the most of the cover one piece may be.
JEWELRY = ("chain", "necklace", "ring", "bracelet", "watch", "earring", "pendant", "jewelry", "grill")
JEWEL_SCORE, JEWEL_LARGEST = 0.2, 0.08


def jewelry(cover, path):
    """The outlines (bool, square) of the jewelry in `cover` (RGB uint8, square)."""
    side = cover.shape[0]
    boxes = []
    for box, name, _ in named(cover, path, JEWELRY, JEWEL_SCORE):
        if (box[2] - box[0]) * (box[3] - box[1]) / side ** 2 > JEWEL_LARGEST:
            continue
        if any(crowd.overlap(box, other) > SAME for other in boxes):
            continue
        boxes.append(box)
    return outlines(cover, path, boxes) if boxes else []


def found(cover, path):
    """The things in `cover` (RGB uint8, square) that move: (kind, mask, box in pixels)."""
    side = cover.shape[0]
    finds = []
    for box, name, score in named(cover, path, KINDS):
        kind = kind_of(str(name))
        if not kind:
            continue
        area = (box[2] - box[0]) * (box[3] - box[1]) / side ** 2
        if area > (LARGEST_BEND if kind == "bend" else LARGEST):
            continue
        if any(crowd.overlap(box, other) > SAME or crowd.overlap(other, box) > SAME for _, other in finds):
            continue
        finds.append((kind, box))
    # A box around a group of others is the group, not a thing of its own.
    def holds(a, b):
        cx, cy = (b[0] + b[2]) / 2, (b[1] + b[3]) / 2
        return a[0] <= cx <= a[2] and a[1] <= cy <= a[3]
    finds = [(k, b) for k, b in finds if sum(holds(b, o) for _, o in finds if o is not b) < GROUP]
    if not finds:
        return []
    return [(k, m, b) for (k, b), m in zip(finds, outlines(cover, path, [b for _, b in finds]))]


class Props:
    """The things that move on their own in `cover` (float RGB, square), from the models in `path`. `people`
    is 1 over everyone (crowd.Crowd.anyone), who are in front of what bends and behind what nods and flies;
    `text` the text's boxes, in shares of the side; `seed` picks how each moves. `self.bend` is the mask of
    what bends, for scene.Curtains to sway."""

    def __init__(self, cover, path, people, text, lama, seed):
        side = cover.shape[0]
        self.side = side
        self.things = []
        self.mask = np.zeros((side, side), np.float32)
        self.bend = np.zeros((side, side), bool)
        self.plate = cover
        self.count = {}
        if not path:
            return
        people = people > 0.5
        finds = []
        for kind, mask, box in found(np.clip(cover, 0, 255).astype(np.uint8), path):
            if any(crowd.overlap(box / side, line) > OVER_TEXT for line in text):
                continue
            if kind != "bend" and (mask & people).sum() > OVER_PERSON * max(mask.sum(), 1):
                continue
            finds.append((kind, mask & ~people if kind != "bend" else mask, box))
        # Back to front, and within a depth the lower the nearer; each pixel is the nearest thing's.
        finds.sort(key=lambda f: (DEPTH[f[0]], f[2][3]))
        nearer = np.zeros((side, side), bool)
        owned = []
        for kind, mask, box in reversed(finds):
            mine = mask & ~nearer
            if kind == "bend":
                mine &= ~people
            nearer |= mask
            owned.append((kind, mine, box))
        rng = np.random.default_rng(seed)
        for kind, mine, box in reversed(owned):
            if mine.sum() < 30:
                continue
            self.count[kind] = self.count.get(kind, 0) + 1
            if kind == "bend":
                self.bend |= mine
                continue
            outline = np.clip(gaussian_filter(mine.astype(np.float32), OUTLINE_SOFT), 0, 1)
            l, t, r, b = box
            w, h = r - l, b - t
            pivot = ((l + r) / 2, (t + b) / 2) if kind != "nod" else ((l + r) / 2, b + NOD_STEM * h)
            cycles = {"fly": FLY_CYCLES, "drift": DRIFT_CYCLES, "nod": NOD_CYCLES}[kind]
            self.things.append({
                "kind": kind, "outline": outline, "box": (l, t, r, b), "pivot": pivot,
                "cycles": int(rng.choice(cycles)), "phases": rng.uniform(0, 2 * math.pi, 4),
                "sign": rng.choice((-1, 1), 3), "size": (w, h),
            })
            self.mask = np.maximum(self.mask, outline)
        if not self.things:
            return
        behind = binary_dilation(self.mask > 0.02, iterations=BEHIND_GROW)
        if lama:
            filled = label.inpaint(cover / 255, behind.astype(np.float32), lama) * 255
        else:
            filled = cv2.inpaint(np.clip(cover, 0, 255).astype(np.uint8), behind.astype(np.uint8), 5, cv2.INPAINT_TELEA).astype(np.float32)
        soft = np.clip(gaussian_filter(behind.astype(np.float32), 1.0) + behind, 0, 1)[..., None]
        self.plate = (cover * (1 - soft) + filled * soft).astype(np.float32)
        # The farthest any moves, for the room each is drawn in.
        def reach(p):
            w, h = p["size"]
            if p["kind"] == "fly":
                return 2 * (FLY_SHIFT + FLY_LIFT) * side + 2 * math.radians(FLY_TURN) * max(w, h)
            if p["kind"] == "drift":
                return 2 * DRIFT_SHIFT * side
            return 2 * math.radians(NOD_TURN) * (1 + NOD_STEM) * max(w, h) * 1.5
        self.reach = int(math.ceil(max(reach(p) for p in self.things))) + 4
        pad = self.reach
        self.padded = cv2.copyMakeBorder(cover.astype(np.float32), pad, pad, pad, pad, cv2.BORDER_REPLICATE)
        for p in self.things:
            p["outline"] = cv2.copyMakeBorder(p["outline"], pad, pad, pad, pad, cv2.BORDER_REPLICATE)

    def moved(self, p, i, n):
        """Thing `p`'s turn (degrees) and shift (pixels) in frame `i` of `n`: none in the first and last."""
        t = i / max(n - 1, 1)
        c, (a, b, d, e), (sa, sb, sc) = p["cycles"], p["phases"], p["sign"]
        def wave(cycles, phase):
            return math.sin(2 * math.pi * cycles * t + phase) - math.sin(phase)
        side = self.side
        if p["kind"] == "fly":
            return (sc * FLY_TURN * wave(c, d) / 2,
                    (sa * FLY_SHIFT * side * wave(c, a) / 2, sb * FLY_LIFT * side * wave(c + 1, b) / 2))
        if p["kind"] == "drift":
            return 0.0, (sa * DRIFT_SHIFT * side * wave(c, a) / 2, 0.0)
        return sa * NOD_TURN * (0.75 * wave(c, a) + 0.25 * wave(c + 1, b)) / 2, (0.0, 0.0)

    def over(self, frame, i, n, front):
        """`frame` with the things laid over it as they are in frame `i` of `n`: those behind people
        (`front` False) or in front of them."""
        out = frame
        for p in self.things:
            if (DEPTH[p["kind"]] >= DEPTH["nod"]) != front:
                continue
            turn, shift = self.moved(p, i, n)
            if out is frame:
                out = frame.copy()
            crowd.placed(out, self.padded, p["outline"], self.reach, p["box"], turn, 1.0, p["pivot"], shift)
        return out
