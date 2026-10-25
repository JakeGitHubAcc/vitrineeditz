"""The cover's people, each cut out and moved whole. The model's motion bends a body out of shape and
warps a crowd into a smear of reshaped heads and shoulders; here each person is a layer of their own that
slowly sways from where they stand and breathes, and what is behind them is painted in (LaMa) for the
little that their moving shows. People are found with Mask R-CNN (torchvision, COCO). A crowd's members
(at least CROWD_LEAST people, each small in the picture) sway freely; anyone else, such as the main
person, only breathes and sways a hair. The nearer of two people (lower in the picture) is in front.

Each person's motion is a turn about where they stand and a slight stretch from there, so their feet (or
the cover's edge, where they are cut off) stay where they are, and is made of whole cycles of the loop
starting from none: the first frame and the last are the cover as it is.
"""
import math

import cv2
import numpy as np
from scipy.ndimage import binary_dilation, gaussian_filter

import label

# A person found with at least this score; a crowd is at least this many of them, and its members are at
# most this tall, as a share of the cover's side.
PERSON_SCORE, CROWD_LEAST, CROWD_TALLEST = 0.5, 3, 0.32
# A person's outline: the mask's probability where it starts and where it is whole, and its soft edge in
# pixels.
OUTLINE_LOW, OUTLINE_HIGH, OUTLINE_SOFT = 0.25, 0.6, 0.7
# How far each sways, in degrees (the least and most, each person picked between), how much they breathe
# (a stretch up from where they stand, as a share of their height), and how many times over the loop.
SWAY_LEAST, SWAY_MOST, BREATH, CYCLES = 2.0, 3.6, 0.012, (2, 3)
# The same for anyone not in a crowd.
MAIN_SWAY_LEAST, MAIN_SWAY_MOST, MAIN_BREATH, MAIN_CYCLES = 0.25, 0.45, 0.005, (2,)
# How far past each person the cover is painted in, in pixels, for their soft edge and hair.
BEHIND_GROW = 3
# What no person who overlaps it this much moves over: a line of text.
TEXT_OVERLAP = 0.05

_model = {}


def model(path):
    if path not in _model:
        import torch
        from torchvision.models.detection import maskrcnn_resnet50_fpn_v2
        net = maskrcnn_resnet50_fpn_v2(weights=None, weights_backbone=None, box_detections_per_img=200)
        net.load_state_dict(torch.load(path, map_location="cpu"))
        # On the CPU, as ComfyUI wants all of the GPU's memory for the model.
        _model[path] = net.eval()
    return _model[path]


def found(cover, path):
    """The people in `cover` (RGB uint8, square): (probability mask, box in pixels), best first."""
    import torch
    with torch.inference_mode():
        out = model(path)([torch.from_numpy(cover).permute(2, 0, 1).float() / 255])[0]
    keep = (out["labels"] == 1) & (out["scores"] >= PERSON_SCORE)
    return list(zip(out["masks"][keep, 0].numpy(), out["boxes"][keep].numpy()))


def overlap(a, b):
    """The share of box `a` that box `b` covers."""
    w = min(a[2], b[2]) - max(a[0], b[0])
    h = min(a[3], b[3]) - max(a[1], b[1])
    return max(w, 0) * max(h, 0) / max((a[2] - a[0]) * (a[3] - a[1]), 1e-9)


class Crowd:
    """The people in `cover` (float RGB, square), or none (`self.people` empty). `text` are the boxes of its
    text, in shares of the side; `seed` picks how each person moves."""

    def __init__(self, cover, path, text, lama, seed):
        side = cover.shape[0]
        self.side = side
        self.people = []
        self.mask = np.zeros((side, side), np.float32)
        self.plate = cover
        everyone = found(np.clip(cover, 0, 255).astype(np.uint8), path) if path else []
        # Everyone found, the main person too, for what moves around them to keep off them.
        self.anyone = np.zeros((side, side), np.float32)
        for chance, _ in everyone:
            self.anyone = np.maximum(self.anyone, (chance > 0.5).astype(np.float32))
        small = [i for i, (_, box) in enumerate(everyone) if (box[3] - box[1]) / side <= CROWD_TALLEST]
        crowd = set(small) if len(small) >= CROWD_LEAST else set()
        self.crowd = 0
        if not everyone:
            return
        # Each pixel is the one person's whose mask is surest of it, the main person's included, so two
        # people never both take it.
        chances = np.stack([m for m, _ in everyone])
        owner = chances.argmax(axis=0)
        rng = np.random.default_rng(seed)
        # Back to front: the lower in the picture, the nearer.
        for i in sorted(range(len(everyone)), key=lambda i: (everyone[i][1][1] + everyone[i][1][3]) / 2):
            chance, box = everyone[i]
            if any(overlap(box / side, line) > TEXT_OVERLAP for line in text):
                continue
            outline = np.clip((chance - OUTLINE_LOW) / (OUTLINE_HIGH - OUTLINE_LOW), 0, 1) * (owner == i)
            outline = np.clip(gaussian_filter(outline, OUTLINE_SOFT), 0, 1).astype(np.float32)
            if outline.max() < 0.5:
                continue
            l, t, r, b = box
            tall = b - t
            member = i in crowd
            self.crowd += member
            least, most, breath, cycles = ((SWAY_LEAST, SWAY_MOST, BREATH, CYCLES) if member else
                                           (MAIN_SWAY_LEAST, MAIN_SWAY_MOST, MAIN_BREATH, MAIN_CYCLES))
            self.people.append({
                "outline": outline,
                "box": (l, t, r, b),
                # Where they stand: the bottom of their box, which is the cover's edge where they are cut off.
                "pivot": ((l + r) / 2, min(b, side - 1)),
                "tall": tall,
                "sway": rng.uniform(least, most) * rng.choice((-1, 1)),
                "breath": breath,
                "cycles": int(rng.choice(cycles)),
                "phases": rng.uniform(0, 2 * math.pi, 3),
            })
            self.mask = np.maximum(self.mask, outline)
        if not self.people:
            return
        # What is behind them, for what their moving shows: the cover with all of them painted out.
        behind = binary_dilation(self.mask > 0.02, iterations=BEHIND_GROW)
        if lama:
            filled = label.inpaint(cover / 255, behind.astype(np.float32), lama) * 255
        else:
            filled = cv2.inpaint(np.clip(cover, 0, 255).astype(np.uint8), behind.astype(np.uint8), 5, cv2.INPAINT_TELEA).astype(np.float32)
        soft = np.clip(gaussian_filter(behind.astype(np.float32), 1.0) + behind, 0, 1)[..., None]
        self.plate = (cover * (1 - soft) + filled * soft).astype(np.float32)
        # Each person's own picture, which stays the cover's pixels; past the cover's edge, its edge drawn out.
        # The farthest any of them moves: a wave runs up to twice its size from where it starts.
        self.reach = int(math.ceil(max(2 * math.radians(abs(p["sway"])) * (p["tall"] + (p["box"][2] - p["box"][0]) / 2)
                                       + 2 * p["breath"] * p["tall"] for p in self.people))) + 4
        pad = self.reach
        self.padded = cv2.copyMakeBorder(cover.astype(np.float32), pad, pad, pad, pad, cv2.BORDER_REPLICATE)
        for p in self.people:
            p["outline"] = cv2.copyMakeBorder(p["outline"], pad, pad, pad, pad, cv2.BORDER_REPLICATE)

    def moved(self, p, i, n):
        """Person `p`'s turn (degrees) and stretch in frame `i` of `n`: none in the first and last frames."""
        t = i / max(n - 1, 1)
        c, (a, b, s) = p["cycles"], p["phases"]
        def wave(cycles, phase):
            return math.sin(2 * math.pi * cycles * t + phase) - math.sin(phase)
        turn = p["sway"] * (0.75 * wave(c, a) + 0.25 * wave(c + 1, b))
        stretch = 1 + p["breath"] * wave(c, s)
        return turn, stretch

    def over(self, frame, i, n):
        """`frame` (the cover's animation, float RGB at the cover's side, moved over self.plate) with each
        person laid over it where they are in frame `i` of `n`."""
        if not self.people:
            return frame
        out = frame.copy()
        for p in self.people:
            turn, stretch = self.moved(p, i, n)
            placed(out, self.padded, p["outline"], self.reach, p["box"], turn, stretch, p["pivot"])
        return out


def placed(out, padded, outline, pad, box, turn, stretch, pivot, shift=(0.0, 0.0)):
    """Lays a cut-out over `out` (float RGB, square), in place: the cover's pixels inside `outline` (both
    padded by `pad`, their edges drawn out), turned by `turn` degrees and stretched up by `stretch` about
    `pivot`, then moved by `shift`, all in the cover's pixels. Only the region around `box` grown by `pad`
    is drawn, which the cut-out never moves out of."""
    side = out.shape[0]
    l, t, r, b = box
    x0, y0 = max(0, int(l) - pad), max(0, int(t) - pad)
    x1, y1 = min(side, int(math.ceil(r)) + pad), min(side, int(math.ceil(b)) + pad)
    if x1 <= x0 or y1 <= y0:
        return
    rad = math.radians(turn)
    cos, sin = math.cos(rad), math.sin(rad)
    # Forward: a point q goes to pivot + R(S(q - pivot)) + shift, S stretching up; the inverse maps the
    # frame's points to the picture's, in the padded picture's pixels with the region's corner at 0.
    forward = np.array([[cos, -sin * stretch], [sin, cos * stretch]], np.float64)
    back = np.linalg.inv(forward)
    matrix = np.zeros((2, 3), np.float64)
    matrix[:, :2] = back
    origin = np.array([x0, y0], np.float64)
    pivot = np.array(pivot, np.float64)
    matrix[:, 2] = pivot + pad - back @ (pivot + np.array(shift, np.float64) - origin)
    size = (x1 - x0, y1 - y0)
    colors = cv2.warpAffine(padded, matrix, size, flags=cv2.INTER_CUBIC | cv2.WARP_INVERSE_MAP, borderMode=cv2.BORDER_REPLICATE)
    alpha = np.clip(cv2.warpAffine(outline, matrix, size, flags=cv2.INTER_LINEAR | cv2.WARP_INVERSE_MAP, borderMode=cv2.BORDER_REPLICATE), 0, 1)[..., None]
    region = out[y0:y1, x0:x1]
    out[y0:y1, x0:x1] = region * (1 - alpha) + colors * alpha
