"""Vitrine Animate: turns album covers into subtle looping animations on this computer's GPU.

The iPhone (Shared/AnimatedArtwork/SGCoverAnimator.x) sends an album's cover as PNG with the album's name
and artist; this server queues it and makes its loop:

1. the cover without its Parental Advisory label: Apple's catalog's copy when it has the same picture
   (catalog.py), else the label painted out (label.py);
2. what moves: Wan 2.2 TI2V-5B in ComfyUI (workflow.json) animates the cover, and the optical flow of its
   frames, softened, with text and faces held, moves the cover's own pixels (motion.py), so its colors,
   detail and faces stay its own; the end turns back along the motion to the first frame;
3. the lock screen's 3:4 frame around it (frame.py), what the phone's Text and Camera sway settings ask
   for (effects.py), and a light film grain;

and keeps the MP4 in the clips folder, where the phone downloads it. One job runs at a time. Run it with
ComfyUI's own Python (start.bat), which has everything it imports.

    POST /animate?key=K&album=A&artist=R&text=keep|fade|hide&sway=0|1
                                       body: PNG -> {"state": "queued"|"running"|"done", "position": n}
                                                        (a cover sent again is animated again)
    GET  /status?key=K                    -> {"state": ..., "progress": 0..1, "position": n, "error": ...}
    GET  /clip?key=K                      -> the MP4
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
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import catalog  # noqa: E402
import effects  # noqa: E402
import label  # noqa: E402
import motion  # noqa: E402
from frame import OUT_H, OUT_W, Extended, shown as shown_cover  # noqa: E402

KEY = re.compile(r"^[0-9a-f]{16,64}$")

# Wan 2.2 TI2V-5B works in multiples of 32 and 4n+1 frames at 24 fps; a 640 square fits an 8 GB card, and
# 73 frames is three seconds. Its frames are only measured for their motion (motion.py).
SIDE, FRAMES, FPS = 640, 73, 24
WIDTH, HEIGHT = SIDE, SIDE

POSITIVE = (
    "A nearly still cinemagraph of this picture with only slight, slow, natural movement. People stay in "
    "place and only breathe gently: they do not sway, turn, walk or move their heads or arms. A soft breeze "
    "stirs leaves, grass, hair and fabric a little. Clouds drift, water ripples, rain and snow fall, smoke "
    "curls, lights shimmer. Fixed static camera: no zoom, no pan, no tilt. Text, logos and lettering stay "
    "unchanged, and everything keeps its shape, colors and composition."
)
NEGATIVE = (
    "frozen, static image, no motion, still frame, "
    "camera movement, zoom, pan, dolly, shaking, swaying, turning head, gesturing, walking, fast motion, sudden motion, morphing, warping, melting, "
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

    def add(self, key, png, names):
        with self.lock:
            current = self.state.get(key, {}).get("state")
            if current in ("queued", "running"):
                return self.status_locked(key)
            # Sent again (Animate Again on the phone): the old loop goes, and a new one is made.
            if os.path.exists(self.clip(key)):
                os.remove(self.clip(key))
            self.images[key] = (png, names)
            self.queue.append(key)
            self.state[key] = {"state": "queued"}
            self.lock.notify()
            return self.status_locked(key)

    def status(self, key):
        with self.lock:
            return self.status_locked(key)

    def status_locked(self, key):
        if os.path.exists(self.clip(key)):
            return {"state": "done"}
        job = self.state.get(key)
        if not job:
            return {"state": "unknown"}
        answer = {"state": job["state"]}
        if job["state"] == "queued":
            answer["position"] = self.queue.index(key) if key in self.queue else 0
        elif job["state"] == "running":
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
        with open(os.path.join(HERE, "workflow.json"), encoding="utf-8") as f:
            self.workflow = json.load(f)

    def up(self):
        try:
            with urllib.request.urlopen(self.url + "/system_stats", timeout=3) as r:
                return r.status == 200
        except OSError:
            return False

    def start(self):
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
                sys.exit("ComfyUI stopped while starting; see animate/comfyui.log")
            time.sleep(1)
        sys.exit("ComfyUI did not start within five minutes; see animate/comfyui.log")

    def run(self, image_name, seed):
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
        while True:
            time.sleep(3)
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
        stream.options = {"crf": "18", "preset": "slow", "movflags": "+faststart"}
        for frame in frames:
            for packet in stream.encode(av.VideoFrame.from_ndarray(frame, format="rgb24")):
                container.mux(packet)
        for packet in stream.encode():
            container.mux(packet)
    os.replace(partial, path)


def say(text):
    print(f"[{time.strftime('%H:%M:%S')}] {text}")


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


def work(jobs, comfy, lama, faces, keep_labels):
    inputs = os.path.join(comfy.root, "ComfyUI", "input")
    while True:
        key, png, names = jobs.next()
        started = time.time()
        say(f"animating {key} ({names.get('album') or 'no album name'})")
        image_name = f"vitrine_{key}.png"
        frames = []
        try:
            cover, lines = clean_cover(cover_of(png), names, lama, keep_labels)
            shown = shown_cover(cover)
            # Text and faces as boxes in shares of the cover's side; the trim it is shown with is a hair's.
            text = [tuple(v / cover.width for v in box) for _, score, box in lines if score > 0.5]
            people = [tuple(v / shown.width for v in box) for box in motion.faces(np.asarray(shown), faces)]
            wording = names.get("text", "keep") if text and lama else "keep"
            sway = names.get("sway") == "1"
            say(f"{len(text)} lines of text ({wording}), {len(people)} faces, {'a' if sway else 'no'} camera sway")
            # Hidden text is painted out of what moves; faded text is painted out under the text laid over it.
            erased, where = effects.plate(shown, text, lama) if wording != "keep" else (None, None)
            moving = erased if wording == "hide" else shown
            extended = Extended(erased if erased is not None else shown, lama)
            moving.resize((SIDE, SIDE), Image.LANCZOS).save(os.path.join(inputs, image_name))
            seed = int(key[:12], 16) % (2 ** 31) + random.randint(0, 999)
            frames = comfy.run(image_name, seed)
            pictures = [np.asarray(Image.open(f).convert("RGB"), dtype=np.float32) for f in frames]
            # The model's first frame is a little off from the rest (Wan's VAE makes it alone): measured from
            # the second.
            steps = motion.loop(pictures[1:], [] if wording == "hide" else text, people)
            if wording == "fade" or sway:
                steps = effects.lengthened(steps)
            base = np.asarray(erased if wording == "fade" else moving, dtype=np.float32)
            still = np.asarray(shown, dtype=np.float32)
            n = len(steps)
            clip = []
            for i, step in enumerate(steps):
                cover_frame = motion.warped(base, step)
                if wording == "fade":
                    cover_frame = effects.faded(cover_frame, still, where, effects.shown_text(i, n))
                frame = extended.frame(cover_frame)
                clip.append(effects.swayed(frame, i, n) if sway else frame)
            # The last frame is the first; its grain is too, so the two are the same frame.
            seeds = list(range(n))
            seeds[-1] = seeds[0]
            encode([np.clip(np.round(motion.grained(f, s)), 0, 255).astype(np.uint8) for f, s in zip(clip, seeds)], jobs.clip(key))
            seconds = time.time() - started
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
            try:
                address = ipaddress.ip_address(self.client_address[0])
                return address.is_private or address.is_loopback
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
            names = {name: query[name][0].strip()[:200] for name in ("album", "artist", "text", "sway") if query.get(name)}
            say(f"{key} received from {self.client_address[0]}")
            self.answer(200, jobs.add(key, png, names))

        def log_message(self, format, *args):
            pass

    return Handler


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
    parser.add_argument("--keep-labels", action="store_true", help="leave Parental Advisory labels on covers")
    args = parser.parse_args()
    os.makedirs(args.clips, exist_ok=True)
    lama = args.lama if args.lama and os.path.exists(args.lama) else None
    if not lama:
        print(f"No LaMa model at {args.lama}: labels stay on covers and their edges are drawn out (see README.md).")
    faces = args.faces if args.faces and os.path.exists(args.faces) else None
    if not faces:
        print(f"No face model at {args.faces}: faces move with the rest (see README.md).")
    jobs = Jobs(args.clips)
    comfy = Comfy(args.comfy, args.comfy_port)
    comfy.start()
    threading.Thread(target=work, args=(jobs, comfy, lama, faces, args.keep_labels), daemon=True).start()
    server = ThreadingHTTPServer((args.host, args.port), handler(jobs))
    print()
    print(f"Vitrine Animate is running. In Vitrine's lock screen settings, set Computer to:  {lan_address()}:{args.port}")
    print(f"Clips are kept in {args.clips}. Leave this window open while covers animate.")
    print()
    try:
        server.serve_forever()
    finally:
        if comfy.process:
            comfy.process.terminate()


if __name__ == "__main__":
    main()
