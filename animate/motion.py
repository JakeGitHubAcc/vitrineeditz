"""The cover's own pixels moved the way the model's clip moves. The model's frames are only measured: the
optical flow from each back to its first says where every point went, and the sharp cover is warped along
it. So the clip has the cover's exact colors and detail, and nothing in it is drawn anew. The motion is
softened, capped and shaped: a person (a face found, and the body under it) moves only a little, the rest
(a crowd, trees, water) as freely as the model moved it; text does not move, faces move only as a whole
(never reshaped), anything held still stays (a starfield, effects.py), and the cover's edges stay put, where
the still frame around it meets them. The end turns back to the start along
the motion itself, so the last frame is the cover as it is, the first frame.
"""
import cv2
import numpy as np
from PIL import Image
from scipy.ndimage import gaussian_filter, gaussian_filter1d

# The flow is measured and shaped at this size: the motion is smooth, and smaller is steadier and quicker.
FLOW_SIZE = 320
# How much of the model's motion is kept, and the farthest any point moves, as a share of the cover's side:
# for a person, and for everything else. A crowd's or a tree's motion reads as natural only when it is
# free; small and far, their detail does not give the warp away.
MOTION_PERSON, MAX_PERSON = 0.5, 0.006
MOTION_FREE, MAX_FREE = 1.0, 0.02
# A person's reach from a face found: the face's widths sideways, its heights up and down, the body below.
BODY_WIDE, BODY_UP, BODY_DOWN = 1.8, 1.2, 5.0
# The flow's smoothing over the picture (a share of its side) and over time (frames), which takes out the
# model's wobble and the flow's noise.
SPACE_SMOOTH, TIME_SMOOTH = 0.012, 1.2
# The still border at the cover's edges, as a share of its side.
EDGE_STILL = 0.04
# How far past a line of text, and past a face, the stillness reaches, as shares of the box's height, and
# the soft edge around both, as a share of the cover's side.
TEXT_PAD, FACE_PAD, FEATHER = 0.3, 0.45, 0.02
# Where the clip may turn back to its start, as a share of it, and the fewest and most frames it takes.
LATE, RETURN_MIN, RETURN_MAX = 0.6, 6, 16
# The face finder's least score, and the sizes the cover is looked at in.
FACE_SCORE, FACE_SCALES = 0.5, (1, 2, 3)
# The film grain: its strength in levels out of 255 and its grain size in pixels.
GRAIN, GRAIN_SIZE = 3.5, 0.7

_faces = {}


def faces(cover, model):
    """The faces in `cover` (RGB uint8), as boxes (left, top, right, bottom). OpenCV's YuNet, at the cover's
    size and enlarged, since faces on covers are often small or turned. One taken for a face that is not
    only moves whole, which costs little."""
    if not model:
        return []
    h, w = cover.shape[:2]
    if model not in _faces:
        _faces[model] = cv2.FaceDetectorYN.create(model, "", (w, h), FACE_SCORE, 0.3, 50)
    detector = _faces[model]
    boxes = []
    for scale in FACE_SCALES:
        image = cv2.resize(cover, (w * scale, h * scale), interpolation=cv2.INTER_LANCZOS4) if scale > 1 else cover
        detector.setInputSize((w * scale, h * scale))
        _, found = detector.detect(cv2.cvtColor(image, cv2.COLOR_RGB2BGR))
        for x, y, fw, fh in (found[:, :4] / scale if found is not None else []):
            box = (x, y, x + fw, y + fh)
            if not any(overlap(box, other) > 0.3 for other in boxes):
                boxes.append(box)
    return boxes


def overlap(a, b):
    """The share of the smaller of two boxes that the other covers."""
    w = min(a[2], b[2]) - max(a[0], b[0])
    h = min(a[3], b[3]) - max(a[1], b[1])
    if w <= 0 or h <= 0:
        return 0.0
    return w * h / min((a[2] - a[0]) * (a[3] - a[1]), (b[2] - b[0]) * (b[3] - b[1]))


def soft_box(size, box, pad, feather, ellipse=False):
    """A mask at `size` (square), 1 inside `box` (in a cover of side 1) grown by `pad` of its height."""
    l, t, r, b = box
    grow = pad * (b - t)
    l, t, r, b = l - grow, t - grow, r + grow, b + grow
    y, x = np.mgrid[0:size, 0:size].astype(np.float32) / size
    if ellipse:
        cx, cy, rx, ry = (l + r) / 2, (t + b) / 2, (r - l) / 2, (b - t) / 2
        inside = ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 <= 1
    else:
        inside = (x >= l) & (x <= r) & (y >= t) & (y <= b)
    return np.clip(gaussian_filter(inside.astype(np.float32), feather * size), 0, 1) if feather else inside.astype(np.float32)


def flows(frames):
    """For each of the model's frames, where each of its points was in the first frame, at FLOW_SIZE, in
    shares of the side: flow[t][y, x] is the step from (x, y) in frame t to the same point in frame 0."""
    dis = cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_MEDIUM)
    gray = [cv2.cvtColor(cv2.resize(np.clip(f, 0, 255).astype(np.uint8), (FLOW_SIZE, FLOW_SIZE), interpolation=cv2.INTER_AREA), cv2.COLOR_RGB2GRAY) for f in frames]
    out = [np.zeros((FLOW_SIZE, FLOW_SIZE, 2), np.float32)]
    for g in gray[1:]:
        out.append(dis.calc(g, gray[0], None) / FLOW_SIZE)
    return np.stack(out)


def without_camera(flow):
    """The flow less what a camera would do: each frame's shift, zoom, turn and tilt of the whole picture,
    fitted over it, is taken out, leaving what moves in it."""
    size = flow.shape[1]
    y, x = np.mgrid[0:size, 0:size].astype(np.float32) / size - 0.5
    basis = np.stack([np.ones_like(x), x, y], axis=-1).reshape(-1, 3)
    fit = np.linalg.lstsq(basis, flow.reshape(len(flow), -1, 2).transpose(1, 0, 2).reshape(size * size, -1), rcond=None)[0]
    camera = (basis @ fit).reshape(size, size, len(flow), 2).transpose(2, 0, 1, 3)
    return (flow - camera).astype(np.float32)


def person(size, box):
    """A soft mask at `size` over the person a face belongs to: the face and the body below it."""
    l, t, r, b = box
    w, h = r - l, b - t
    cx = (l + r) / 2
    top, bottom = t - BODY_UP * h, b + BODY_DOWN * h
    y, x = np.mgrid[0:size, 0:size].astype(np.float32) / size
    cy, ry, rx = (top + bottom) / 2, (bottom - top) / 2, BODY_WIDE * w
    inside = ((x - cx) / max(rx, 1e-6)) ** 2 + ((y - cy) / max(ry, 1e-6)) ** 2 <= 1
    return np.clip(gaussian_filter(inside.astype(np.float32), 2 * FEATHER * size), 0, 1)


def shaped(flow, text_boxes, face_boxes, still=None):
    """The flow without the camera's part, softened and smoothed: people moving a little and the rest more,
    text still, faces moving whole, `still` (1 where nothing moves, at FLOW_SIZE) and the edges still. Boxes
    are in shares of the cover's side."""
    size = FLOW_SIZE
    calm = np.zeros((size, size), np.float32)
    for box in face_boxes:
        calm = np.maximum(calm, person(size, box))
    amount = MOTION_FREE + (MOTION_PERSON - MOTION_FREE) * calm
    most = (MAX_FREE + (MAX_PERSON - MAX_FREE) * calm)[None, ..., None]
    flow = without_camera(flow) * amount[None, ..., None]
    flow = gaussian_filter(flow, (0, SPACE_SMOOTH * size, SPACE_SMOOTH * size, 0))
    smoothed = gaussian_filter1d(flow, TIME_SMOOTH, axis=0, mode="nearest")
    # The first frames keep to the measured flow, so the clip starts from the cover itself.
    lead = np.clip(np.arange(len(flow), dtype=np.float32) / 3, 0, 1)[:, None, None, None]
    flow = flow * (1 - lead) + smoothed * lead
    flow[0] = 0
    for box in face_boxes:
        mask = soft_box(size, box, FACE_PAD, FEATHER, ellipse=True)[None, ..., None]
        core = soft_box(size, box, 0, 0) > 0.5
        whole = flow[:, core].mean(axis=1)[:, None, None, :] if core.any() else 0
        flow = flow * (1 - mask) + whole * mask
    free = np.ones((size, size), np.float32)
    for box in text_boxes:
        free = np.minimum(free, 1 - soft_box(size, box, TEXT_PAD, FEATHER))
    ramp = np.clip(np.minimum(np.arange(size), size - 1 - np.arange(size)) / (EDGE_STILL * size), 0, 1).astype(np.float32)
    free = free * ramp[:, None] * ramp[None, :]
    if still is not None:
        free = free * (1 - still)
    flow = flow * free[None, ..., None]
    reach = np.linalg.norm(flow, axis=-1, keepdims=True)
    return (flow * np.minimum(1, most / np.maximum(reach, 1e-9))).astype(np.float32)


def looped(flow):
    """The flow running to its frame in its last part nearest the cover as it is, then back to none at the
    pace it moves at, so the last frame is the cover, the first."""
    late = range(int(LATE * len(flow)), len(flow))
    turn = min(late, key=lambda i: float(np.abs(flow[i]).mean()))
    pace = float(np.abs(np.diff(flow[:turn + 1], axis=0)).mean()) if turn else 1.0
    steps = int(np.clip(round(float(np.abs(flow[turn]).mean()) / max(pace, 1e-9)), RETURN_MIN, RETURN_MAX))
    back = [flow[turn] * (1 - k / steps) for k in range(1, steps + 1)]
    return list(flow[:turn + 1]) + back


def warped(cover, flow):
    """`cover` (float RGB, square) moved along `flow` (at any size, in shares of the side)."""
    side = cover.shape[0]
    step = cv2.resize(flow.astype(np.float32), (side, side), interpolation=cv2.INTER_CUBIC) * side
    x, y = np.meshgrid(np.arange(side, dtype=np.float32), np.arange(side, dtype=np.float32))
    return cv2.remap(cover, x + step[..., 0], y + step[..., 1], cv2.INTER_CUBIC, borderMode=cv2.BORDER_REFLECT)


def grained(frame, seed):
    """`frame` with film grain, strongest in the midtones, the same for the same seed."""
    noise = gaussian_filter(np.random.default_rng(seed).standard_normal(frame.shape[:2]).astype(np.float32), GRAIN_SIZE)
    noise /= max(float(noise.std()), 1e-6)
    luma = np.clip(frame.mean(axis=2) / 255, 0, 1)
    return frame + (GRAIN * noise * (0.35 + 2.6 * luma * (1 - luma)))[..., None]


def loop(frames, text_boxes, face_boxes, still=None):
    """The looped flow of the model's `frames`, shaped, one per frame of the clip: warped() moves the cover
    by each."""
    return looped(shaped(flows(frames), text_boxes, face_boxes, still))
