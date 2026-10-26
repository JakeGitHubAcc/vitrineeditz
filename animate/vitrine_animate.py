"""Vitrine Animate: turns album covers into subtle looping animations on this computer's GPU.

The iPhone (Shared/AnimatedArtwork/SGCoverAnimator.x) sends an album's cover as PNG with the album's name
and artist; this server queues it and makes its loop:

1. the cover without its Parental Advisory label: Apple's catalog's copy when it has the same picture
   (catalog.py), else the label painted out (label.py);
2. what moves: Wan 2.2 TI2V-5B in ComfyUI (workflow.json) animates the cover, and the optical flow of its
   frames, softened, with text and faces held, moves the cover's own pixels (motion.py), so its colors,
   detail and faces stay its own; the end turns back along the motion to the first frame; people are
   each cut out and move whole, a crowd swaying and anyone else only breathing (crowd.py), and so do
   things that move on their own: bees and birds hover, clouds drift, flowers nod, trees bend (props.py), curtains sway as fabric and solid things (a stage, a
   floor, walls) keep their shape (scene.py);
3. the lock screen's 3:4 frame around it (frame.py); what the phone's Text and Camera sway settings ask
   for, a starfield's drift, glints on shiny things and a slow shift of the light (effects.py); and a
   light film grain;

and keeps the MP4 in the clips folder, where the phone downloads it. One job runs at a time. Run it with
ComfyUI's own Python (start.bat), which has everything it imports.

    POST /animate?key=K&album=A&artist=R&text=keep|fade|hide|spray&sway=0|1&boil=0|1&off=people,things,...
                                             (off: any of EFFECTS, each left out of the clip)
                                       body: PNG -> {"state": "queued"|"running"|"done", "position": n}
                                                        (a cover sent again is animated again)
    GET  /status?key=K                    -> {"state": ..., "progress": 0..1, "position": n, "error": ...}
    GET  /clip?key=K                      -> the MP4
    GET  /clips                           -> {"clips": [{"key", "album", "artist", "bytes"}]}: every MP4 kept,
                                             for a phone that lost its own (Spotify deleted and installed again)
    GET  /health                          -> {"ok": true, ...}
"""
import argparse
import copy
import io
import ipaddress
import json
import os
import random
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import av
import cv2
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import catalog  # noqa: E402
import crowd  # noqa: E402
import effects  # noqa: E402
import fog  # noqa: E402
import liquid  # noqa: E402
import label  # noqa: E402
import motion  # noqa: E402
import props  # noqa: E402
import scene  # noqa: E402
from frame import OUT_H, OUT_W, Extended, shown as shown_cover  # noqa: E402

KEY = re.compile(r"^[0-9a-f]{16,64}$")

# Wan 2.2 TI2V-5B works in multiples of 32 and 4n+1 frames at 24 fps; a 640 square fits an 8 GB card, and
# 73 frames is three seconds. Its frames are only measured for their motion (motion.py).
SIDE, FRAMES, FPS = 640, 73, 24
# The addresses Tailscale gives the user's own devices, let in with the home network's.
TAILSCALE = ipaddress.ip_network("100.64.0.0/10")
# What the phone may switch off, each by its name in `off`: people moving, things moving (bees, clouds, flowers,
# bubbles), curtains and trees swaying, fog, drips, water's waves, glints and jewelry, the light's shift, the video
# model's motion of the sky, and the film grain.
EFFECTS = {"people", "things", "sway", "fog", "drips", "water", "glints", "light", "model", "grain"}
# How long the video model takes before a run has been timed, in seconds (an RTX 4060 8 GB).
MODEL_SECONDS = 240
# How far motion eases to still toward a starfield, in pixels of the flow (motion.FLOW_SIZE).
SKY_EASE = 4
WIDTH, HEIGHT = SIDE, SIDE

POSITIVE = (
    "A nearly still cinemagraph of this picture with only slight, slow, natural movement. The main person "
    "stays in place and only breathes gently. A crowd or people in the background shift, sway and move "
    "naturally, as a live audience does. A soft breeze "
    "stirs leaves, grass, hair and fabric a little. Clouds drift, water ripples, rain and snow fall, smoke "
    "curls, lights shimmer. Fixed static camera: no zoom, no pan, no tilt. Text, logos and lettering stay "
    "unchanged, and everything keeps its shape, colors and composition."
)
NEGATIVE = (
    "frozen, static image, no motion, still frame, "
    "camera movement, zoom, pan, dolly, shaking, walking, fast motion, sudden motion, morphing, warping, melting, "
    "distortion, changing text, moving letters, new objects appearing, objects disappearing, scene change, "
    "cut, transition, flicker, strobing, blur, low quality, jpeg artifacts, deformed face, extra limbs, "
    "extra fingers, color shift, oversaturated"
)


class Jobs:
    """The queue and what the phone is told about each key. Finished clips are read off the disk, so a
    restart forgets only jobs that had not finished, which the phone then sends again."""

    def __init__(self, clips):
        self.clips = clips
        self.lock = threading.Condition()
        self.queue = []          # keys waiting, oldest first
        self.images = {}         # key -> (PNG bytes, {"album", "artist"}), until its job runs
        self.state = {}          # key -> {"state", "started", "error"}
        self.durations = []      # seconds the last few jobs took, for the progress estimate

    def clip(self, key):
        return os.path.join(self.clips, key + ".mp4")

    def remember(self, key, names):
        """The album and artist a clip was made for, kept beside it for GET /clips."""
        about = {name: names[name] for name in ("album", "artist") if names.get(name)}
        with open(os.path.join(self.clips, key + ".json"), "w", encoding="utf-8") as f:
            json.dump(about, f, ensure_ascii=False)

    def kept(self):
        """Every clip in the folder: its key, its size, and its album and artist where they were kept."""
        out = []
        for name in sorted(os.listdir(self.clips)):
            key, ext = os.path.splitext(name)
            if ext != ".mp4" or not re.fullmatch(r"[0-9a-f]{32}", key):
                continue
            item = {"key": key, "bytes": os.path.getsize(os.path.join(self.clips, name))}
            try:
                with open(os.path.join(self.clips, key + ".json"), encoding="utf-8") as f:
                    item.update({k: v for k, v in json.load(f).items() if k in ("album", "artist")})
            except (OSError, ValueError):
                pass
            out.append(item)
        return out

    def add(self, key, png, names):
        with self.lock:
            current = self.state.get(key, {}).get("state")
            if current in ("queued", "running"):
                return self.status_locked(key)
            # Sent again (Animate Again on the phone): a new loop is made, which takes the old one's place
            # when it is done. The old one is not touched here: another program reading it (Explorer making
            # its thumbnail) can hold it, and the phone must have its answer meanwhile.
            self.images[key] = (png, names)
            self.queue.append(key)
            self.state[key] = {"state": "queued"}
            self.lock.notify()
            return self.status_locked(key)

    def status(self, key):
        with self.lock:
            return self.status_locked(key)

    def status_locked(self, key):
        job = self.state.get(key)
        # A loop being made again is not done until the new one is, though the old one is still there.
        if not job and os.path.exists(self.clip(key)):
            return {"state": "done"}
        if not job:
            return {"state": "unknown"}
        answer = {"state": job["state"]}
        if job["state"] == "queued":
            answer["position"] = self.queue.index(key) if key in self.queue else 0
        elif job["state"] == "running":
            if "progress" in job:
                answer["progress"] = round(min(0.99, job["progress"]), 3)
            else:
                expected = sum(self.durations[-5:]) / len(self.durations[-5:]) if self.durations else 420.0
                answer["progress"] = round(min(0.97, (time.time() - job["started"]) / expected), 3)
        elif job["state"] == "failed":
            answer["error"] = job.get("error", "")
        return answer

    def next(self):
        with self.lock:
            while not self.queue:
                self.lock.wait()
            key = self.queue.pop(0)
            self.state[key] = {"state": "running", "started": time.time()}
            return (key,) + self.images.pop(key)

    def report(self, key, fraction, stage):
        """How far the running job is, 0 to 1, and what it is doing: for the phone and the console's bar."""
        with self.lock:
            job = self.state.get(key)
            if job and job["state"] == "running":
                job["progress"] = fraction
        bar(fraction, stage)

    def finish(self, key, seconds=None, error=None):
        with self.lock:
            if error:
                self.state[key] = {"state": "failed", "error": error}
            else:
                self.state.pop(key, None)
                self.durations.append(seconds)


class Comfy:
    """ComfyUI, started by this server unless one already answers on its port."""

    def __init__(self, root, port):
        self.root = root
        self.url = f"http://127.0.0.1:{port}"
        self.port = port
        self.process = None
        self.took = []   # seconds the model took on the last runs, for the progress estimate
        with open(os.path.join(HERE, "workflow.json"), encoding="utf-8") as f:
            self.workflow = json.load(f)

    def up(self):
        try:
            with urllib.request.urlopen(self.url + "/system_stats", timeout=3) as r:
                return r.status == 200
        except OSError:
            return False

    def start(self, stop=sys.exit):
        """ComfyUI up, started if it is not; `stop` with why, if it does not start."""
        if self.up():
            print(f"Using the ComfyUI already running at {self.url}")
            return
        python = os.path.join(self.root, "python_embeded", "python.exe")
        main = os.path.join(self.root, "ComfyUI", "main.py")
        log = open(os.path.join(HERE, "comfyui.log"), "a", encoding="utf-8")
        print("Starting ComfyUI (its log is animate/comfyui.log)...")
        self.process = subprocess.Popen(
            [python, "-s", main, "--windows-standalone-build", "--listen", "127.0.0.1", "--port", str(self.port),
             "--disable-auto-launch"],
            cwd=self.root, stdout=log, stderr=subprocess.STDOUT)
        for _ in range(300):
            if self.up():
                print("ComfyUI is ready.")
                return
            if self.process.poll() is not None:
                stop("ComfyUI stopped while starting; see animate/comfyui.log")
                return
            time.sleep(1)
        stop("ComfyUI did not start within five minutes; see animate/comfyui.log")

    def run(self, image_name, seed, progress=None):
        """The model's frames for the cover in ComfyUI's input folder. `progress`, when given, is told how far
        along the model is, 0 to 1, as it waits: an estimate from how long the last runs took."""
        # ComfyUI can be gone since this server started (closed, or gone with the window that started it):
        # started again rather than the job failing.
        if not self.up():
            def stop(why):
                raise RuntimeError(why)
            self.start(stop)
        graph = copy.deepcopy(self.workflow)
        for node in graph.values():
            inputs = node["inputs"]
            for name, value in list(inputs.items()):
                if value == "$IMAGE":
                    inputs[name] = image_name
                elif value == "$POSITIVE":
                    inputs[name] = POSITIVE
                elif value == "$NEGATIVE":
                    inputs[name] = NEGATIVE
                elif value == "$SEED":
                    inputs[name] = seed
                elif value == "$WIDTH":
                    inputs[name] = WIDTH
                elif value == "$HEIGHT":
                    inputs[name] = HEIGHT
                elif value == "$FRAMES":
                    inputs[name] = FRAMES
        body = json.dumps({"prompt": graph, "client_id": str(uuid.uuid4())}).encode()
        request = urllib.request.Request(self.url + "/prompt", body, {"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=30) as r:
            prompt_id = json.load(r)["prompt_id"]
        started = time.time()
        expected = sum(self.took[-5:]) / len(self.took[-5:]) if self.took else MODEL_SECONDS
        while True:
            time.sleep(3)
            if progress:
                progress(min(0.98, (time.time() - started) / expected), time.time() - started)
            with urllib.request.urlopen(f"{self.url}/history/{prompt_id}", timeout=30) as r:
                history = json.load(r).get(prompt_id)
            if not history:
                continue
            status = history.get("status", {})
            if status.get("status_str") == "error":
                messages = [m for m in status.get("messages", []) if m[0] == "execution_error"]
                raise RuntimeError(messages[0][1].get("exception_message", "ComfyUI failed") if messages else "ComfyUI failed")
            if status.get("completed"):
                frames = []
                for output in history["outputs"].values():
                    for image in output.get("images", []):
                        frames.append(os.path.join(self.root, "ComfyUI", "output", image.get("subfolder", ""), image["filename"]))
                if not frames:
                    raise RuntimeError("ComfyUI finished without frames")
                self.took.append(time.time() - started)
                return sorted(frames)


def cover_of(png):
    """The cover the phone sent. Builds before the phone sent its cover sent the whole 3:4 frame, whose
    middle square is the cover."""
    image = Image.open(io.BytesIO(png)).convert("RGB")
    if image.height > image.width * 1.15:
        top = (image.height - image.width) // 2
        image = image.crop((0, top, image.width, top + image.width))
    return image


def encode(frames, path):
    partial = path + ".partial"
    with av.open(partial, mode="w", format="mp4") as container:
        stream = container.add_stream("libx264", rate=FPS)
        stream.width, stream.height = frames[0].shape[1], frames[0].shape[0]
        stream.pix_fmt = "yuv420p"
        stream.options = {"crf": "20", "preset": "slow", "movflags": "+faststart"}
        for frame in frames:
            for packet in stream.encode(av.VideoFrame.from_ndarray(frame, format="rgb24")):
                container.mux(packet)
        for packet in stream.encode():
            container.mux(packet)
    os.replace(partial, path)


# The console's progress bar: one line written over as the job goes, its width in characters.
BAR_WIDTH = 30
_bar = {"shown": "", "length": 0}


def bar(fraction, stage):
    """The running job's progress as a bar on one line, written over in place; only when what it shows changes."""
    fraction = min(max(fraction, 0.0), 1.0)
    filled = int(round(fraction * BAR_WIDTH))
    line = f"[{time.strftime('%H:%M:%S')}] [{'#' * filled}{'-' * (BAR_WIDTH - filled)}] {fraction * 100:3.0f}%  {stage}"
    shown = line[11:]
    if shown == _bar["shown"]:
        return
    _bar["shown"] = shown
    sys.stdout.write("\r" + line + " " * max(0, _bar["length"] - len(line)))
    sys.stdout.flush()
    _bar["length"] = len(line)


def say(text):
    # A bar on the line is left as it was and the line goes on under it.
    if _bar["length"]:
        sys.stdout.write("\n")
        _bar["length"], _bar["shown"] = 0, ""
    print(f"[{time.strftime('%H:%M:%S')}] {text}", flush=True)


def clean_cover(cover, names, lama, keep_labels):
    """The cover without its Parental Advisory label, and its text as read, for holding it still."""
    if not keep_labels:
        try:
            found = catalog.clean_copy(cover, names.get("album"), names.get("artist"))
        except (OSError, ValueError) as error:
            found = None
            say(f"the catalog did not answer ({error})")
        if found:
            say(f"using Apple's catalog copy of {names.get('album')} ({found.width} px)")
            cover = found
    lines = label.read(cover)
    if lama and not keep_labels:
        cover, box = label.clean(cover, lama, lines)
        if box:
            say(f"took the Parental Advisory label off at {box}")
            lines = label.read(cover)
    return cover, lines


def work(jobs, comfy, lama, faces, keep_labels, persons=None, scenes=None, finders=None):
    inputs = os.path.join(comfy.root, "ComfyUI", "input")
    while True:
        key, png, names = jobs.next()
        started = time.time()
        say(f"animating {key} ({names.get('album') or 'no album name'})")
        image_name = f"vitrine_{key}.png"
        frames = []

        def progress(fraction, stage, key=key):
            jobs.report(key, fraction, stage)

        try:
            progress(0.01, "reading the cover and its text")
            cover, lines = clean_cover(cover_of(png), names, lama, keep_labels)
            shown = shown_cover(cover)
            # Text and faces as boxes in shares of the cover's side; the trim it is shown with is a hair's.
            text = [tuple(v / cover.width for v in box) for _, score, box in lines if score > 0.5]
            people = [tuple(v / shown.width for v in box) for box in motion.faces(np.asarray(shown), faces)]
            # Text the reader misses (in perspective on To the Stars' wall), as the finder names it.
            loose = props.text_boxes(np.asarray(shown), finders, text, people) if finders else []
            wording = names.get("text", "keep") if (text or loose) and lama else "keep"
            if wording not in ("keep", "fade", "hide", "spray"):
                wording = "keep"
            sway = names.get("sway") == "1"
            # What the phone's Animated Covers page switched off (EFFECTS), and line boil for a drawn cover.
            off = {name for name in names.get("off", "").split(",") if name in EFFECTS}
            boil = names.get("boil") == "1"
            say(f"{len(text)} lines of text ({wording}), {len(people)} faces, {'a' if sway else 'no'} camera sway"
                f"{', line boil' if boil else ''}{', off: ' + ', '.join(sorted(off)) if off else ''}")
            # Hidden text is painted out of what moves; faded text is painted out under the text laid over it.
            # The finder's boxes are loose, so only what looks like letters in them is painted out (effects.hole()).
            erased, where = effects.plate(shown, text, lama, loose) if wording != "keep" else (None, None)
            text = text + loose
            moving = erased if wording == "hide" else shown
            extended = Extended(erased if erased is not None else shown, lama)
            moving.resize((SIDE, SIDE), Image.LANCZOS).save(os.path.join(inputs, image_name))
            # Faded or sprayed text is laid over a cover without it.
            base = np.asarray(erased if wording in ("fade", "spray") else moving, dtype=np.float32)
            # What no effect may land on: text, its whole box, and faces.
            side = shown.width
            covered = np.zeros((side, side), np.float32)
            for box in ([] if wording == "hide" else text):
                covered = np.maximum(covered, motion.soft_box(side, box, motion.TEXT_PAD, 0))
            for box in people:
                covered = np.maximum(covered, motion.soft_box(side, box, motion.FACE_PAD, 0))
            progress(0.06, "finding stars and people")
            stars = effects.starfield(base, covered)
            sky = stars[2] if stars else np.zeros((side, side), np.float32)
            # People move as layers of their own over what is painted in behind them.
            words = [] if wording == "hide" else text
            audience = crowd.Crowd(base, persons if "people" not in off else None, words, lama, int(key[:8], 16))
            # Things that move on their own, each cut out; what bends sways in place, as curtains do.
            progress(0.11, "finding things that move (bees, clouds, flowers, trees)")
            things = props.Props(audience.plate, finders if "things" not in off else None, audience.anyone, words, lama, int(key[16:24] or "5", 16))
            cut_out = np.maximum(audience.mask, things.mask)
            shiny = effects.glints(base, np.maximum(np.maximum(covered, sky), cut_out)) if "glints" not in off else []
            # Jewelry shines wherever it is, on a person too (its glint moves with them); never on a face or text.
            bare = np.zeros((side, side), np.float32)
            for box in words:
                bare = np.maximum(bare, motion.soft_box(side, box, motion.TEXT_PAD, 0))
            for box in people:
                bare = np.maximum(bare, motion.soft_box(side, box, 0, 0))
            progress(0.16, "finding jewelry")
            pieces = props.jewelry(np.clip(base, 0, 255).astype(np.uint8), finders) if finders and "glints" not in off else []
            shiny += effects.jewel_glints(base, pieces, bare)
            # Fog and smoke drift as a smoke of their own laid over them, rather than being warped.
            progress(0.18, "finding fog and smoke")
            haze = fog.Fog(base, finders if "fog" not in off else None, covered, int(key[4:12], 16), FPS)
            # Drips run, rather than being warped.
            progress(0.19, "finding drips")
            drips = liquid.Drips(base, finders if "drips" not in off else None, covered, int(key[6:14], 16), FPS)
            # Curtains sway on their own, around the text and people; solid things keep their shape.
            progress(0.20, "reading the scene (sky, water, curtains, solid things)")
            kinds = scene.Scene(base, scenes)
            keep = np.maximum((covered > 0).astype(np.float32), audience.anyone)
            # Standing water stays still under waves laid over it in perspective.
            water = kinds.of(liquid.WATER) * (kinds.sure >= liquid.WATER_SURE) if kinds.kinds is not None else np.zeros((side, side), np.float32)
            water = np.maximum(water, liquid.water_found(base, finders, np.maximum(keep, cut_out)))
            if "water" in off:
                water = np.zeros((side, side), np.float32)
            waves = liquid.Waves(base, water, np.maximum(keep, cut_out), int(key[10:18], 16), FPS)
            progress(0.23, "cutting out curtains and trees")
            swaying = "sway" not in off
            drapes = scene.Curtains(things.plate, (kinds.of({scene.CURTAIN}) > 0.5) & swaying, keep, lama, int(key[8:16], 16))
            trees = scene.Curtains(drapes.plate, things.bend & swaying, keep, lama, int(key[24:32] or "7", 16), stand=True)
            base = trees.plate
            found = ", ".join(f"{n} {k}" for k, n in sorted(things.count.items())) or "nothing else that moves"
            # The model's motion moves only what flows (sky, water); with too little of that it is not run at all.
            fluid = kinds.fluid()
            flowing = "model" not in off and (fluid is None or float(fluid.mean()) >= scene.FLUID_LEAST)
            say(f"{'a starfield' if stars else 'no starfield'}, {len(audience.people)} people ({audience.crowd} in a crowd), "
                f"{'curtains' if drapes.mask.any() else 'no curtains'}, {found}, {len(shiny)} glints "
                f"({len(pieces)} jewelry), {'fog' if haze.mask.any() else 'no fog'}, {drips.count} drips, "
                f"{'waves' if waves.mask.any() else 'no waves'}, "
                f"{'the model moving ' + ('everything else' if fluid is None else f'{fluid.mean():.0%} sky and water') if flowing else 'no model motion'}")
            if flowing:
                seed = int(key[:12], 16) % (2 ** 31) + random.randint(0, 999)
                frames = comfy.run(image_name, seed, lambda done, seconds: progress(
                    0.25 + 0.5 * done, f"the video model moving the sky and water ({seconds:.0f} s)"))
            pictures = [np.asarray(Image.open(f).convert("RGB"), dtype=np.float32) for f in frames]
            # The model's first frame is a little off from the rest (Wan's VAE makes it alone): measured from
            # the second. The starfield holds still under its own drift, and what moves in front of it eases to
            # still toward it rather than at its edge, where a stop pulled the edge out into a streak.
            still_sky = np.asarray(Image.fromarray((sky * 255).astype(np.uint8)).resize((motion.FLOW_SIZE, motion.FLOW_SIZE)), dtype=np.float32) / 255
            still_sky = np.maximum(still_sky, cv2.GaussianBlur(still_sky, (0, 0), SKY_EASE))
            # Behind people nothing moves but the people laid over it, and the model never moves one, even
            # one left out of the layers (one over the text).
            behind = cv2.resize(np.maximum(np.maximum(cut_out, audience.anyone), trees.mask), (motion.FLOW_SIZE, motion.FLOW_SIZE), interpolation=cv2.INTER_AREA)
            behind = np.maximum(behind, cv2.GaussianBlur(behind, (0, 0), SKY_EASE))
            still_sky = np.maximum(still_sky, np.clip(behind * 2, 0, 1))
            # Nor do the curtains, and the model's motion is held off solid things.
            hung = cv2.resize(drapes.mask, (motion.FLOW_SIZE, motion.FLOW_SIZE), interpolation=cv2.INTER_AREA)
            hung = np.maximum(hung, cv2.GaussianBlur(hung, (0, 0), SKY_EASE))
            solid = cv2.resize(kinds.solid(), (motion.FLOW_SIZE, motion.FLOW_SIZE), interpolation=cv2.INTER_AREA)
            still_sky = np.maximum(still_sky, np.maximum(np.clip(hung * 2, 0, 1), solid))
            if fluid is not None:
                still_sky = np.maximum(still_sky, 1 - cv2.resize(fluid, (motion.FLOW_SIZE, motion.FLOW_SIZE), interpolation=cv2.INTER_AREA))
            progress(0.76, "measuring the model's motion" if flowing else "no video model needed")
            if flowing:
                steps = effects.lengthened(motion.loop(pictures[1:], [] if wording == "hide" else text, people, still_sky))
            else:
                steps = effects.lengthened([np.zeros((motion.FLOW_SIZE, motion.FLOW_SIZE, 2), np.float32)] * FRAMES)
            still = np.asarray(shown, dtype=np.float32)
            sprayer = effects.Spray(where, int(key[:6], 16)) if wording == "spray" else None
            # The light leaves text alone, where it is in the frame, and eases off toward it; faces take it
            # as the rest does. A hard box here showed as a lighter or darker rectangle.
            boxes = np.zeros((OUT_H, OUT_W), np.float32)
            for box in words:
                boxes[extended.top:extended.top + side] = np.maximum(boxes[extended.top:extended.top + side], motion.soft_box(side, box, motion.TEXT_PAD, 0))
            text_in_frame = effects.unlit(boxes, OUT_W)
            patches = effects.lights((OUT_H, OUT_W)) if "light" not in off else []
            # Line boil on the drawn outlines of the people and things, the rest held still.
            boiling = effects.Boil(side, int(key[2:10], 16), effects.boil_lines(np.asarray(shown, dtype=np.float32),
                                   np.maximum(audience.anyone, things.mask))) if boil else None
            n = len(steps)
            clip = []
            for i, step in enumerate(steps):
                progress(0.78 + 0.17 * i / n, f"drawing frame {i + 1} of {n}")
                cover_frame = motion.warped(base, step)
                cover_frame = drips.over(cover_frame, i, n)
                cover_frame = waves.over(cover_frame, i, n)
                if stars:
                    cover_frame = effects.with_stars(cover_frame, stars, i, n)
                cover_frame = things.over(cover_frame, i, n, front=False)
                cover_frame = drapes.over(cover_frame, i, n)
                cover_frame = trees.over(cover_frame, i, n)
                cover_frame = audience.over(cover_frame, i, n)
                cover_frame = things.over(cover_frame, i, n, front=True)
                cover_frame = haze.over(cover_frame, i, n)
                if wording == "fade":
                    cover_frame = effects.faded(cover_frame, still, where, effects.shown_text(i, n))
                elif wording == "spray":
                    cover_frame = effects.faded(cover_frame, still, where, sprayer.amount(effects.shown_text(i, n)))
                if boiling:
                    cover_frame = boiling.over(cover_frame, i, n)
                frame = extended.frame(cover_frame)
                # A glint rides on what it is on: a person it is on carries it, and a point of the cover shows
                # where the flow brought it.
                places = []
                for x, y in shiny:
                    x, y = audience.follow(x, y, i, n)
                    row = min(max(int(y / side * motion.FLOW_SIZE), 0), motion.FLOW_SIZE - 1)
                    fx, fy = step[row, min(max(int(x / side * motion.FLOW_SIZE), 0), motion.FLOW_SIZE - 1)]
                    places.append((x - fx * side, y - fy * side))
                frame = effects.with_glints(frame, places, i, n, offset=(0, extended.top))
                frame = effects.lit(frame, patches, i, n, text_in_frame)
                clip.append(effects.swayed(frame, i, n) if sway else frame)
            # The last frame is the first; its grain is too, so the two are the same frame.
            seeds = list(range(n))
            seeds[-1] = seeds[0]
            progress(0.96, "saving the clip")
            grain = "grain" not in off
            encode([np.clip(np.round(motion.grained(f, s) if grain else f), 0, 255).astype(np.uint8) for f, s in zip(clip, seeds)], jobs.clip(key))
            seconds = time.time() - started
            jobs.remember(key, names)
            progress(1.0, "done")
            jobs.finish(key, seconds=seconds)
            say(f"saved {key}.mp4 in {seconds / 60:.1f} min")
        except Exception as error:  # the phone shows Failed and the log says why
            jobs.finish(key, error=str(error))
            say(f"{key} failed: {error}")
        finally:
            for f in frames:
                try:
                    os.remove(f)
                except OSError:
                    pass
            try:
                os.remove(os.path.join(inputs, image_name))
            except OSError:
                pass


def handler(jobs):
    class Handler(BaseHTTPRequestHandler):
        def private(self):
            # The home network, or the user's own devices on Tailscale (100.64.0.0/10, which Python does not count
            # as private), so the phone reaches it away from home too.
            try:
                address = ipaddress.ip_address(self.client_address[0])
                return address.is_private or address.is_loopback or address in TAILSCALE
            except ValueError:
                return False

        def answer(self, code, body, kind="application/json"):
            data = json.dumps(body).encode() if kind == "application/json" else body
            self.send_response(code)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def key(self):
            key = parse_qs(urlparse(self.path).query).get("key", [""])[0]
            return key if KEY.match(key) else None

        def do_GET(self):
            if not self.private():
                return self.answer(403, {"error": "home network only"})
            path = urlparse(self.path).path
            if path == "/health":
                return self.answer(200, {"ok": True, "name": "Vitrine Animate", "size": [OUT_W, OUT_H]})
            if path == "/clips":
                return self.answer(200, {"clips": jobs.kept()})
            key = self.key()
            if not key:
                return self.answer(400, {"error": "bad key"})
            if path == "/status":
                return self.answer(200, jobs.status(key))
            if path == "/clip":
                clip = jobs.clip(key)
                if not os.path.exists(clip):
                    return self.answer(404, {"error": "not made"})
                with open(clip, "rb") as f:
                    return self.answer(200, f.read(), "video/mp4")
            self.answer(404, {"error": "no such path"})

        def do_POST(self):
            if not self.private():
                return self.answer(403, {"error": "home network only"})
            key = self.key()
            if urlparse(self.path).path != "/animate" or not key:
                return self.answer(400, {"error": "bad request"})
            length = int(self.headers.get("Content-Length", 0))
            if not 0 < length <= 20 * 1024 * 1024:
                return self.answer(400, {"error": "bad image"})
            png = self.rfile.read(length)
            query = parse_qs(urlparse(self.path).query)
            names = {name: query[name][0].strip()[:200] for name in ("album", "artist", "text", "sway", "off", "boil") if query.get(name)}
            say(f"{key} received from {self.client_address[0]}")
            self.answer(200, jobs.add(key, png, names))

        def log_message(self, format, *args):
            pass

    return Handler


def tailscale_address():
    """This computer's name on the user's Tailscale network (MagicDNS), else its 100.x address; None without
    Tailscale. The name first: iOS lets an app use plain http with a name without dots, as a local one, but not
    with a 100.x address, which only Safari reaches."""
    try:
        status = json.loads(subprocess.run(["tailscale", "status", "--json"], capture_output=True, text=True, timeout=5).stdout)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    me = status.get("Self") or {}
    name = (me.get("DNSName") or "").split(".")[0]
    if name and (status.get("CurrentTailnet") or {}).get("MagicDNSEnabled"):
        return name
    return next((a for a in me.get("TailscaleIPs") or [] if a.startswith("100.")), None)


def lan_address():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        try:
            s.connect(("10.255.255.255", 1))
            return s.getsockname()[0]
        except OSError:
            return "127.0.0.1"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--comfy", required=True, help="the ComfyUI_windows_portable folder")
    parser.add_argument("--clips", required=True, help="where finished clips are kept")
    parser.add_argument("--port", type=int, default=8790)
    parser.add_argument("--host", default="0.0.0.0", help="127.0.0.1 keeps it to this computer, for a test")
    parser.add_argument("--comfy-port", type=int, default=8188)
    parser.add_argument("--lama", help="big-lama.pt, which paints labels out and the cover on past its edges")
    parser.add_argument("--faces", help="face_detection_yunet_2023mar.onnx, which finds faces to keep whole")
    parser.add_argument("--people", help="maskrcnn_resnet50_fpn_v2_coco-73cbd019.pth, which finds a crowd's people to move whole")
    parser.add_argument("--scene", help="the segformer-b5-ade folder, which finds curtains and what keeps its shape")
    parser.add_argument("--props", help="the folder holding grounding-dino-base and sam-vit-base, which find bees, clouds, flowers and trees to move")
    parser.add_argument("--keep-labels", action="store_true", help="leave Parental Advisory labels on covers")
    args = parser.parse_args()
    os.makedirs(args.clips, exist_ok=True)
    lama = args.lama if args.lama and os.path.exists(args.lama) else None
    if not lama:
        print(f"No LaMa model at {args.lama}: labels stay on covers and their edges are drawn out (see README.md).")
    faces = args.faces if args.faces and os.path.exists(args.faces) else None
    if not faces:
        print(f"No face model at {args.faces}: faces move with the rest (see README.md).")
    persons = args.people if args.people and os.path.exists(args.people) else None
    if not persons:
        print(f"No person model at {args.people}: a crowd moves with the model's motion (see README.md).")
    scenes = args.scene if args.scene and os.path.isdir(args.scene) else None
    if not scenes:
        print(f"No scene model at {args.scene}: curtains and solid things move with the model's motion (see README.md).")
    finders = args.props if args.props and os.path.isdir(os.path.join(args.props, "sam-vit-base")) else None
    if not finders:
        print(f"No prop models in {args.props}: bees, clouds, flowers and trees move with the model's motion (see README.md).")
    jobs = Jobs(args.clips)
    comfy = Comfy(args.comfy, args.comfy_port)
    comfy.start()
    threading.Thread(target=work, args=(jobs, comfy, lama, faces, args.keep_labels, persons, scenes, finders), daemon=True).start()
    server = ThreadingHTTPServer((args.host, args.port), handler(jobs))
    print()
    print(f"Vitrine Animate is running. In Vitrine's Animated Covers settings, set Computer to:  {lan_address()}:{args.port}")
    away = tailscale_address()
    if away:
        print(f"Away from home, with Tailscale on the iPhone too, use:  {away}:{args.port}  (it works at home as well)")
    print(f"Clips are kept in {args.clips}. Leave this window open while covers animate.")
    print()
    try:
        server.serve_forever()
    finally:
        if comfy.process:
            comfy.process.terminate()


if __name__ == "__main__":
    main()
