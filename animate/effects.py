"""What goes over a clip's motion: the phone's Text and Camera sway settings (the cover's text painted out,
or faded out and back in over the loop as some animated covers do, and a slow camera sway over the whole
frame), and what a still photo's light does: a starfield drifting and twinkling on its own while the rest
stays, a glint passing over small shiny things (a ring, a chain), and the light slowly shifting. All of
them want a longer loop than the motion's few seconds, so the clip is played over itself first (it ends on
its first frame, so it repeats without a seam), and each runs once over the whole, ending where it starts.
"""
import math

import cv2
import numpy as np
from PIL import Image
from scipy.ndimage import binary_dilation, gaussian_filter

import label

FPS = 24
# The shortest loop, in seconds.
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


# A starfield: points this much brighter than what is around them, on ground this dark, out of 255; at
# least this many of them, on at least this share of the cover.
STAR_LIFT, STAR_GROUND, STARS_LEAST, STARFIELD_LEAST = 35, 40, 40, 0.25
# The ground's most color, out of 255, and the least share of it that is stars.
STAR_CHROMA, STAR_DENSITY = 22, 0.004
# How far the stars drift over the loop, as a share of the side, which way, in degrees, and how much each
# twinkles.
STAR_DRIFT, STAR_HEADING, TWINKLE = 0.07, 200, 0.45
# How long a star takes to fade over to where it will be, as a share of the loop, and how far in from the
# starfield's edge stars are taken, in pixels.
STAR_SWAP, STAR_MARGIN = 0.04, 6
# The biggest a star is, in pixels.
STAR_SIZE = 25
# A glint: a highlight at least this bright, out of 255, this much brighter than the ground around it,
# whose ground is at most this bright, at least and at most this many pixels big (a speck is a light far
# off, not metal catching it); at most GLINTS of them, the biggest, at least GLINT_APART of the side apart. Its flare's reach as a share of the side, how long it lasts, in seconds,
# and how strong it is at its height.
GLINT_BRIGHT, GLINT_LIFT, GLINT_GROUND, GLINT_LEAST, GLINT_SIZE = 235, 110, 100, 10, 60
GLINTS, GLINT_APART = 2, 0.12
GLINT_REACH, GLINT_SECONDS, GLINT_STRENGTH = 0.045, 0.9, 0.9
# The light: this many soft patches, each this wide as a share of the frame's width, brightening and
# dimming by up to this much, once round the loop each.
LIGHTS, LIGHT_WIDTH, LIGHT_AMOUNT = 3, 0.45, 0.07


def starfield(cover, keep):
    """The cover's starfield, if it has one: (the cover without its stars, the stars' light alone, where the
    starfield is (soft, 0 to 1), each star's label). None for a cover without one. `keep` (0 to 1, at the
    cover's size) marks what is not starfield whatever it looks like: text and faces."""
    pixels = cover.astype(np.uint8)
    gray = cv2.cvtColor(pixels, cv2.COLOR_RGB2GRAY)
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7))
    opened = cv2.morphologyEx(gray, cv2.MORPH_OPEN, kernel)
    # The ground between the stars: near black and without color (a dark blue curtain is not space).
    under = cv2.morphologyEx(pixels, cv2.MORPH_OPEN, kernel).astype(np.int16)
    chroma = cv2.blur((under.max(axis=2) - under.min(axis=2)).astype(np.float32), (25, 25))
    points = ((gray.astype(np.int16) - opened) > STAR_LIFT) & (cv2.blur(opened, (31, 31)) < STAR_GROUND)
    # Space is where that ground has stars strewn over it, not a dark shadow with one or two in it.
    strewn = cv2.blur(points.astype(np.float32), (41, 41)) > STAR_DENSITY
    dark = (cv2.blur(opened, (25, 25)) < STAR_GROUND) & (chroma < STAR_CHROMA) & strewn
    dark = cv2.morphologyEx(dark.astype(np.uint8), cv2.MORPH_CLOSE, np.ones((15, 15), np.uint8))
    dark = cv2.morphologyEx(dark, cv2.MORPH_OPEN, np.ones((21, 21), np.uint8)).astype(bool)
    dark &= keep < 0.5
    # Stars are taken a little in from the starfield's edge, so a bright rim of what is in front of it is
    # not taken for stars and drifted off it.
    inner = cv2.erode(dark.astype(np.uint8), np.ones((2 * STAR_MARGIN + 1, 2 * STAR_MARGIN + 1), np.uint8)).astype(bool)
    count, labels, stats, _ = cv2.connectedComponentsWithStats((points & inner).astype(np.uint8))
    # A star is a point: anything bigger is the rim or a glint of something else, which must not drift off.
    big = np.flatnonzero(stats[:, cv2.CC_STAT_AREA] > STAR_SIZE)
    labels[np.isin(labels, big[big > 0])] = 0
    if count - len(big[big > 0]) - 1 < STARS_LEAST or dark.mean() < STARFIELD_LEAST:
        return None
    stars = binary_dilation(labels > 0, iterations=2)
    plain = cv2.inpaint(cover.astype(np.uint8), stars.astype(np.uint8), 3, cv2.INPAINT_TELEA).astype(np.float32)
    light = np.maximum(cover - plain, 0) * stars[..., None]
    # Each star's label reaches over its glow, so it twinkles whole.
    grown = cv2.dilate(labels.astype(np.float32), np.ones((5, 5), np.uint8)).astype(np.int32)
    where = gaussian_filter(dark.astype(np.float32), 1.5)
    return plain, light, where, grown


def stars_at(field, i, n):
    """The starfield's light in frame `i` of `n`, drifted STAR_DRIFT over the loop and back to where it was:
    the whole field drifts on, and each star, at a moment of its own, fades over from where the drift has
    taken it to where it will be at the loop's end, one drift behind, so the loop closes with every star at
    full strength the whole time (a field faded over all at once went dim halfway). Each star twinkles."""
    plain, light, where, labels = field
    size = light.shape[0]
    rng = np.random.default_rng(7)
    count = labels.max() + 1
    phase = rng.uniform(0, 2 * math.pi, count)
    turns = rng.integers(1, 4, count)
    moment = rng.uniform(STAR_SWAP, 1 - STAR_SWAP, count)
    t = i / max(n - 1, 1)
    twinkle = 1 - TWINKLE * 0.5 * (1 + np.sin(2 * math.pi * turns * t + phase))
    twinkle[0] = 1
    over = np.clip((t - moment) / STAR_SWAP + 0.5, 0, 1)
    over = over * over * (3 - 2 * over)
    lit_stars = light * twinkle[labels][..., None]
    later = over[labels][..., None]
    heading = math.radians(STAR_HEADING)
    far = STAR_DRIFT * size

    def shifted(image, distance):
        matrix = np.float32([[1, 0, distance * math.cos(heading)], [0, 1, distance * math.sin(heading)]])
        return cv2.warpAffine(image, matrix, (size, size), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_WRAP)

    return shifted(lit_stars * (1 - later), far * t) + shifted(lit_stars * later, far * (t - 1))


def with_stars(cover, field, i, n):
    """The cover's frame with its starfield's own stars swapped for the drifting ones."""
    plain, _, where, _ = field
    w = where[..., None]
    return cover * (1 - w) + (plain + stars_at(field, i, n)) * w


def glints(cover, keep):
    """Where small shiny things catch the light: (x, y) in the cover's pixels, the biggest first. `keep`
    (0 to 1) marks where none may be: text, faces, and a starfield."""
    gray = cv2.cvtColor(cover.astype(np.uint8), cv2.COLOR_RGB2GRAY).astype(np.float32)
    ground = cv2.blur(gray, (21, 21))
    lift = gray - ground
    hot = (gray >= GLINT_BRIGHT) & (lift >= GLINT_LIFT) & (ground <= GLINT_GROUND) & (keep < 0.5)
    count, labels, stats, centers = cv2.connectedComponentsWithStats(hot.astype(np.uint8))
    found = []
    order = np.argsort(-stats[1:, cv2.CC_STAT_AREA]) + 1 if count > 1 else []
    for k in order:
        if not GLINT_LEAST <= stats[k, cv2.CC_STAT_AREA] <= GLINT_SIZE:
            continue
        x, y = centers[k]
        if all(math.hypot(x - a, y - b) >= GLINT_APART * cover.shape[0] for a, b in found):
            found.append((float(x), float(y)))
        if len(found) == GLINTS:
            break
    return found


def flare(size, reach):
    """A four-pointed glint with four short rays between, 0 to 1, `size` square, centered."""
    c = (size - 1) / 2
    y, x = np.mgrid[0:size, 0:size].astype(np.float32) - c
    r = np.hypot(x, y) + 1e-6
    core = np.exp(-(r / (0.06 * reach)) ** 2)
    long = np.exp(-(np.minimum(np.abs(x), np.abs(y)) / 0.9) ** 2) * np.clip(1 - r / reach, 0, 1) ** 1.5
    d1, d2 = np.abs(x - y) / math.sqrt(2), np.abs(x + y) / math.sqrt(2)
    short = np.exp(-(np.minimum(d1, d2) / 0.8) ** 2) * np.clip(1 - r / (0.45 * reach), 0, 1) ** 1.5
    return np.clip(core + long + 0.6 * short, 0, 1)


def with_glints(frame, places, i, n, offset=(0, 0)):
    """`frame` with each glint's flare at its moment of the loop: the glints take turns, each rising and
    falling over GLINT_SECONDS. `places` is (x, y) in the cover; `offset` where the cover is in the frame."""
    if not places:
        return frame
    reach = GLINT_REACH * frame.shape[1]
    size = int(2 * reach) | 1
    shape = flare(size, reach)
    total = (n - 1) / FPS
    t = i / FPS
    out = frame
    for k, (x, y) in enumerate(places):
        at = total * (k + 0.5) / len(places)
        apart = min(abs(t - at), total - abs(t - at))
        height = GLINT_STRENGTH * math.exp(-(apart / (GLINT_SECONDS / 3)) ** 2)
        if height < 0.01:
            continue
        x0, y0 = int(round(x + offset[0])) - size // 2, int(round(y + offset[1])) - size // 2
        fx0, fy0 = max(0, -x0), max(0, -y0)
        fx1, fy1 = size - max(0, x0 + size - frame.shape[1]), size - max(0, y0 + size - frame.shape[0])
        if fx1 <= fx0 or fy1 <= fy0:
            continue
        if out is frame:
            out = frame.copy()
        patch = out[y0 + fy0:y0 + fy1, x0 + fx0:x0 + fx1]
        glow = (shape[fy0:fy1, fx0:fx1] * height)[..., None] * np.float32([1.0, 0.97, 0.9])
        # Screened over, as light adds: never past white.
        out[y0 + fy0:y0 + fy1, x0 + fx0:x0 + fx1] = 255 - (255 - patch) * (1 - glow)
    return out


def lights(shape, seed=11):
    """The light's soft patches over a frame of `shape`: (patch, phase) each."""
    h, w = shape[:2]
    rng = np.random.default_rng(seed)
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    out = []
    for _ in range(LIGHTS):
        cx, cy = rng.uniform(0.15, 0.85) * w, rng.uniform(0.15, 0.85) * h
        patch = np.exp(-(((x - cx) ** 2 + (y - cy) ** 2) / (2 * (LIGHT_WIDTH * w / 2) ** 2)))
        out.append((patch.astype(np.float32), rng.uniform(0, 2 * math.pi)))
    return out


def lit(frame, patches, i, n, keep=None):
    """`frame` under the light's patches as they are in frame `i` of `n`: each brightening and dimming once
    round the loop and back to where it began, never on `keep` (0 to 1, the frame's size: text)."""
    t = 2 * math.pi * i / max(n - 1, 1)
    gain = np.zeros(frame.shape[:2], np.float32)
    for patch, phase in patches:
        gain += patch * (math.sin(t + phase) - math.sin(phase))
    gain = LIGHT_AMOUNT * gain / max(len(patches) ** 0.5, 1)
    if keep is not None:
        gain *= 1 - keep
    return frame * (1 + gain)[..., None]
