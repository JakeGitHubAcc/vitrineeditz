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
# In a loose box, a part filling more than this share of its own bounds, and bigger than this share of the box, is a
# block (a window in a wall) rather than a letter.
LETTER_SOLID, LETTER_BLOCK = 0.8, 0.01
# A part this many times longer than it is wide, and sparse, is a streak or the wall's grain rather than a letter.
LETTER_LONG = 6
# However solid, a part this drawn out is a seam or a rule, not a letter.
LETTER_SEAM = 10
# The least a letter's part is, as a share of its box's height squared, below which it is a speck of grain.
LETTER_SPECK = 0.035
# How far apart a letter's pieces may be and still be joined, in pixels.
LETTER_JOIN = 7
# A drop shadow or dark outline: as far from the letters as it is looked for, as a share of the line's
# height, and how much darker than what is behind it a pixel must be to be one, out of 255.
SHADOW_REACH, SHADOW_DARKER = 0.2, 8
# The farthest a shadow is looked for whatever the box's height, as a share of the cover's side: a loose box many
# lines tall reached far past its letters and took in the dark seam where To the Stars' wall meets the water.
SHADOW_MOST = 0.012
# The fade: the text shows for this share of the loop at its start, fades out over FADE seconds, stays
# away, and fades back in to show again for this share at the end. The first frame, the poster, has it.
SHOWN_FIRST, SHOWN_LAST, FADE = 0.3, 0.12, 1.2
# Sprayed text: how wide the edge between shown and not is (a share of the way along the text), how much the
# edge wavers and how much it is speckled (shares of the order the text goes in), the waver's size as a share of
# the side and the speckle's dots in pixels.
SPRAY_EDGE, SPRAY_ROUGH, SPRAY_SPECKLE, SPRAY_WAVER, SPRAY_DOT = 0.14, 0.12, 0.16, 0.03, 0.7
# Line boil: how many redrawn copies, how many frames each is held (on threes at 24 fps), how far a line wavers
# broadly and trembles finely (pixels, a deviation), and the waver's size (a share of the side) and tremble's (pixels).
BOIL_COPIES, BOIL_HOLD, BOIL_SHIFT, BOIL_TREMBLE, BOIL_BROAD, BOIL_FINE = 3, 3, 0.6, 0.3, 0.015, 1.6
# Which lines boil: the edges' thresholds, how near a figure they must be (a share of the side), and the band around
# a line that moves with it (pixels).
BOIL_EDGE_LOW, BOIL_EDGE_HIGH, BOIL_NEAR, BOIL_BAND = 60, 160, 0.006, 2
# The sway: the drift sideways and up and down and the push in, as shares of the frame's width, and the
# tilt in degrees. The frame is always enlarged by at least ZOOM_LEAST, so its edges never show.
DRIFT_X, DRIFT_Y, PUSH, TILT, ZOOM_LEAST = 0.005, 0.003, 0.012, 0.25, 1.025


def split(patch):
    """A box (one channel, uint8) split into its two shades: (the letters, how well they stand apart, 0 to 1), the
    letters being the shade that touches the box's edge less, as the background runs out past it; None when the
    two are too alike to tell apart. How well they stand apart weighs the shades' difference by how little of the
    box's edge the letters touch, so a grain or a pattern running through the box scores low."""
    _, light = cv2.threshold(patch, 0, 1, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    light = light.astype(bool)
    if not light.any() or light.all():
        return None
    difference = abs(float(patch[light].mean()) - float(patch[~light].mean()))
    if difference < LETTER_CONTRAST:
        return None
    edge = np.concatenate([light[0], light[-1], light[:, 0], light[:, -1]])
    found = ~light if edge.mean() > 0.5 else light
    border = np.concatenate([found[0], found[-1], found[:, 0], found[:, -1]]).mean()
    return found, difference / 255 * (1 - border)


def letters(patch, color=None):
    """Which pixels of a line's box are its letters, by brightness (`patch`, gray uint8) or, where it tells them
    apart better, by how strong their color is (`color`, the box in RGB): rust letters on gray wood are as dark
    as the wood's grain, which the brightness alone took for letters too (To the Stars). None when neither tells
    them from their background."""
    best = split(patch)
    if color is not None:
        strength = cv2.cvtColor(color, cv2.COLOR_RGB2HSV)[..., 1]
        by_color = split(strength)
        if by_color and (not best or by_color[1] > best[1]):
            best = by_color
    return best[0] if best else None


def lettered(found, loose_box=False):
    """Of what letters() found in a box, only what looks like letters: no long thin streak (the wall's grain), no
    part that fills its own bounds nearly whole (a window set in the wall), and in a loose box (`loose_box`, the
    finder's rather than a line the reader read) nothing touching the box's edge (an arm reaching in, To the Stars)."""
    # Painted letters on a grained wall come apart along the grain: their pieces are joined first, so a letter is
    # judged whole and the specks between them stay small.
    found = cv2.morphologyEx(found.astype(np.uint8), cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (LETTER_JOIN, LETTER_JOIN)))
    count, parts, stats, _ = cv2.connectedComponentsWithStats(found)
    h, w = found.shape
    keep = np.zeros(count, bool)
    # A speck of grain is far smaller than a letter of the line: a part must be some of the line's height across.
    least = max(4.0, (LETTER_SPECK * h) ** 2)
    for k in range(1, count):
        x, y, bw, bh, area = stats[k]
        touches = (x == 0 or y == 0 or x + bw >= w or y + bh >= h) and loose_box
        solid = area / max(bw * bh, 1) > LETTER_SOLID and bw * bh > LETTER_BLOCK * w * h
        # A grain line or a streak is long and thin; a letter, even an I, is not this drawn out and this sparse.
        # A solid one this drawn out is a seam (where To the Stars' wall meets the water), not a letter either.
        drawn_out = max(bw, bh) / max(min(bw, bh), 1)
        streak = drawn_out > LETTER_LONG and (area / max(bw * bh, 1) < 0.5 or drawn_out > LETTER_SEAM)
        keep[k] = not touches and not solid and not streak and area >= least
    return keep[parts]


def hole(cover, boxes, loose=()):
    """1 over the letters of each line of text in `cover` (RGB array, square), not the box around them,
    grown by GLYPH_GROW for their soft edges, so a design next to the text, or inside its box, stays. A line
    whose letters cannot be told from their background is painted out whole; a box in `loose` (the finder's)
    only where letters are told from it (lettered()). Boxes are shares of the side."""
    size = cover.shape[0]
    gray = cv2.cvtColor(cover, cv2.COLOR_RGB2GRAY)
    mask = np.zeros((size, size), bool)
    for box in list(boxes) + list(loose):
        l, t, r, b = box
        grow = ERASE_PAD * (b - t)
        x0, y0 = max(0, int((l - grow) * size)), max(0, int((t - grow) * size))
        x1, y1 = min(size, int(math.ceil((r + grow) * size))), min(size, int(math.ceil((b + grow) * size)))
        if x1 - x0 < 2 or y1 - y0 < 2:
            continue
        found = letters(gray[y0:y1, x0:x1], cover[y0:y1, x0:x1])
        if found is not None:
            mask[y0:y1, x0:x1] |= lettered(found, box in loose)
        elif box not in loose:
            mask[y0:y1, x0:x1] = True
    return binary_dilation(mask, iterations=GLYPH_GROW)


def shadow(cover, behind, letters, boxes):
    """1 where the letters darken what is around them, a drop shadow or an outline: near them, and darker
    in `cover` (RGB array) than in `behind`, the cover with the letters and all around them painted out."""
    size = cover.shape[0]
    luma = np.array([0.299, 0.587, 0.114], dtype=np.float32)
    darker = (behind.astype(np.float32) @ luma) - (cover.astype(np.float32) @ luma) > SHADOW_DARKER
    found = np.zeros((size, size), bool)
    for l, t, r, b in boxes:
        reach = max(2, int(round(min(SHADOW_REACH * (b - t), SHADOW_MOST) * size)))
        grow = reach + int(ERASE_PAD * (b - t) * size)
        x0, y0 = max(0, int(l * size) - grow), max(0, int(t * size) - grow)
        x1, y1 = min(size, int(math.ceil(r * size)) + grow), min(size, int(math.ceil(b * size)) + grow)
        mine = letters[y0:y1, x0:x1]
        near = binary_dilation(mine, iterations=reach) & ~mine
        dark = near & darker[y0:y1, x0:x1]
        # Only the dark that reaches the letters, not a dark design that happens to be near.
        count, parts = cv2.connectedComponents(dark.astype(np.uint8))
        touching = np.unique(parts[binary_dilation(mine, iterations=2) & dark])
        found[y0:y1, x0:x1] |= np.isin(parts, touching[touching > 0])
    return binary_dilation(found, iterations=1)


def plate(cover, boxes, lama, loose=()):
    """`cover` (PIL, square) with its text and its shadow painted out by LaMa, and the mask of where they
    were, soft at its edge. `loose` are the finder's text boxes, whose letters are told more strictly (hole())."""
    image = np.asarray(cover)
    where = hole(image, boxes, loose)
    boxes = list(boxes) + list(loose)
    # What is behind the letters and around them, to tell their shadow from it.
    reach = max([int(round(min(SHADOW_REACH * (b - t), SHADOW_MOST) * image.shape[0])) for _, t, _, b in boxes] + [2])
    behind = label.inpaint(image.astype(np.float32) / 255, binary_dilation(where, iterations=reach).astype(np.float32), lama) * 255
    where |= shadow(image, behind, where, boxes)
    filled = label.inpaint(image.astype(np.float32) / 255, where.astype(np.float32), lama)
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
    """The frame's cover with the still text over it at `amount` (a number, or one per pixel), inside `mask`."""
    a = (mask * amount)[..., None]
    return cover * (1 - a) + text * a


def boil_lines(cover, subjects):
    """Where line boil goes, 0 to 1: the drawn lines (the cover's edges) of `subjects` (0 to 1, the people and things
    cut out), in a thin soft band, so the outlines of the figures boil and the rest of the picture holds still. The
    whole picture boiling was too harsh (The Re-Up). With no subjects, the cover's strongest lines."""
    gray = cv2.cvtColor(np.clip(cover, 0, 255).astype(np.uint8), cv2.COLOR_RGB2GRAY)
    side = gray.shape[0]
    near = binary_dilation(subjects > 0.5, iterations=max(1, int(round(BOIL_NEAR * side))))
    if near.any():
        lines = cv2.Canny(gray, BOIL_EDGE_LOW, BOIL_EDGE_HIGH) > 0
        lines &= near
    else:
        lines = cv2.Canny(gray, BOIL_EDGE_LOW * 2, BOIL_EDGE_HIGH * 2) > 0
    band = gaussian_filter(binary_dilation(lines, iterations=BOIL_BAND).astype(np.float32), 1.0)
    return np.clip(band * 1.5, 0, 1).astype(np.float32)


class Boil:
    """Line boil, for a drawn cover: its lines as if redrawn a few times by hand and the copies cycled, each held
    for a few frames as animation is drawn on twos, so the outlines shimmer and jump a little while the picture
    stays. Each copy moves the lines in `region` (boil_lines()) along a field of its own, broad wavers and a fine
    tremble, under a pixel mostly. The last frame takes the first frame's copy, so the loop closes."""

    def __init__(self, side, seed, region):
        self.region = region[..., None]
        rng = np.random.default_rng(seed)
        y, x = np.mgrid[0:side, 0:side].astype(np.float32)
        self.maps = []
        for _ in range(BOIL_COPIES):
            field = []
            for _ in range(2):
                broad = gaussian_filter(rng.standard_normal((side, side)).astype(np.float32), BOIL_BROAD * side)
                fine = gaussian_filter(rng.standard_normal((side, side)).astype(np.float32), BOIL_FINE)
                broad *= BOIL_SHIFT / max(float(broad.std()), 1e-6)
                fine *= BOIL_TREMBLE / max(float(fine.std()), 1e-6)
                field.append(broad + fine)
            self.maps.append((x + field[0], y + field[1]))

    def over(self, frame, i, n):
        copy = 0 if i == n - 1 else (i // BOIL_HOLD) % BOIL_COPIES
        map_x, map_y = self.maps[copy]
        boiled = cv2.remap(frame, map_x, map_y, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT)
        return frame * (1 - self.region) + boiled * self.region


class Spray:
    """The text sprayed on and off rather than faded, as some animated covers do: it goes from the end of its
    diagonal back to the start and comes again from the start, the edge between what shows and what does not the
    speckle of spray paint. `mask` is where the text is (plate()'s), `seed` picks the speckle."""

    def __init__(self, mask, seed):
        side = mask.shape[0]
        rng = np.random.default_rng(seed)
        y, x = np.mgrid[0:side, 0:side].astype(np.float32)
        ys, xs = np.nonzero(mask > 0.05)
        if not len(xs):
            ys, xs = np.array([0, side - 1]), np.array([0, side - 1])
        x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
        # Along the text's own diagonal, top left first, wavering a little and speckled at the finest scale.
        diagonal = np.clip(((x - x0) / max(x1 - x0, 1) + (y - y0) / max(y1 - y0, 1)) / 2, 0, 1)
        waver = gaussian_filter(rng.standard_normal((side, side)).astype(np.float32), SPRAY_WAVER * side)
        speckle = gaussian_filter(rng.random((side, side)).astype(np.float32), SPRAY_DOT)
        def spread(field):
            return (field - field.min()) / max(float(field.max() - field.min()), 1e-6)
        order = (1 - SPRAY_ROUGH - SPRAY_SPECKLE) * diagonal + SPRAY_ROUGH * spread(waver) + SPRAY_SPECKLE * spread(speckle)
        self.order = spread(order).astype(np.float32)

    def amount(self, shown):
        """How much of the text shows at each pixel when `shown` (shown_text()'s) of it does."""
        return np.clip((shown * (1 + SPRAY_EDGE) - self.order) / SPRAY_EDGE, 0, 1)


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
# Jewelry's glints: at most this many, this far apart as a share of the side, on a highlight at least this
# bright out of 255.
JEWEL_GLINTS, JEWEL_APART, JEWEL_BRIGHT = 3, 0.035, 150
# The light: this many soft patches, each this wide as a share of the frame's width, brightening and
# dimming by up to this much, once round the loop each. Around the text it fades out over this share of the
# side, so no edge of where it stops shows.
LIGHTS, LIGHT_WIDTH, LIGHT_AMOUNT = 3, 0.45, 0.07
LIGHT_EASE = 0.08


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


def jewel_glints(cover, pieces, keep):
    """Where jewelry (`pieces`, props.jewelry's outlines) catches the light: its brightest highlights, at most
    JEWEL_GLINTS of them, JEWEL_APART of the side apart, none where `keep` (text, faces) is. Metal on a person
    is rarely the lone bright speck on a dark ground that glints() looks for, so these are its own."""
    if not pieces:
        return []
    side = cover.shape[0]
    gray = cv2.cvtColor(np.clip(cover, 0, 255).astype(np.uint8), cv2.COLOR_RGB2GRAY).astype(np.float32)
    lift = gray - cv2.blur(gray, (9, 9))
    found = []
    for piece in pieces:
        inside = piece & (keep < 0.5)
        if inside.sum() < GLINT_LEAST:
            continue
        # The piece's highlights: its brightest pixels that stand out from what is next to them.
        score = np.where(inside, gray + 2 * lift, -1e9)
        least = max(np.percentile(gray[inside], 97), JEWEL_BRIGHT)
        for _ in range(JEWEL_GLINTS):
            y, x = np.unravel_index(int(np.argmax(score)), score.shape)
            if gray[y, x] < least:
                break
            if all(math.hypot(x - a, y - b) >= JEWEL_APART * side for a, b in found):
                found.append((float(x), float(y)))
            cv2.circle(score, (int(x), int(y)), int(JEWEL_APART * side), -1e9, -1)
        if len(found) >= JEWEL_GLINTS:
            break
    return found[:JEWEL_GLINTS]


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


def unlit(inside, side):
    """What the light leaves alone, 0 to 1: `inside` (a hard mask) whole, and from its edge out a fall to
    nothing over LIGHT_EASE of `side` that starts flat, so neither its edge nor the fall's shows."""
    if not inside.any():
        return np.zeros(inside.shape, np.float32)
    away = cv2.distanceTransform((inside <= 0).astype(np.uint8), cv2.DIST_L2, 5)
    return np.exp(-(away / (LIGHT_EASE * side / 2)) ** 2).astype(np.float32)


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
