"""Vitrine Animate: turns album covers into subtle looping animations on this computer's GPU.

The iPhone (Shared/AnimatedArtwork/SGCoverAnimator.x) sends an album's cover as PNG; this server queues it,
takes any Parental Advisory label off it (label.py), has ComfyUI animate it with Wan 2.2 TI2V-5B
(workflow.json), morphs the clip's end back into its start so it ends on the frame it starts on, lays it
into the lock screen's 3:4 frame with the cover's edges drawn out as the phone draws them, and keeps the
MP4 in the clips folder, where the phone downloads it. One job runs at a time. Run it with ComfyUI's own
Python (start.bat), which has everything it imports.

    POST /animate?key=K   body: PNG       -> {"state": "queued"|"running"|"done", "position": n}
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
from scipy.ndimage import gaussian_filter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import label  # noqa: E402

KEY = re.compile(r"^[0-9a-f]{16,64}$")

# Only the cover's square is animated: given the drawn-out edges, which have no detail, the model invents
# blotches there that flicker, so they are drawn still, as SGExtendedClip.m draws them, and the moving
# square is laid over them, its top and bottom feathered into them.
# Wan 2.2 TI2V-5B works in multiples of 32 and 4n+1 frames at 24 fps; a 640 square fits an 8 GB card, and
# 73 frames is three seconds.
SIDE, FRAMES, FPS = 640, 73, 24
WIDTH, HEIGHT = SIDE, SIDE
# The clip the phone gets: 3:4 at three quarters of an iPhone's width, the size SGMotionPixels downloads.
OUT_W, OUT_H = 768, 1024
# Where the clip may turn back to its start, as a share of it, and the fewest and most frames it takes to
# get there, as many as the clip's own pace needs.
LATE, RETURN_MIN, RETURN_MAX = 0.6, 4, 12
# SGExtendedClip.m's numbers, so the edges are drawn as the phone draws them: the share of the cover cut off
# each edge, the blur next to the cover and far from it as shares of its side and how far the far one has
# taken over, the feather of the cover's top and bottom, the far wash's color, and the shade for controls.
EDGE_TRIM = 0.006
NEAR_BLUR, FAR_BLUR, BLEND_REACH = 0.012, 0.09, 0.45
COVER_FEATHER = 0.05
SATURATION, BRIGHTNESS = 1.2, -0.06
SHADE_FROM, SHADE_ALPHA = 0.6, 0.4

POSITIVE = (
    "Gentle, natural movement brings this still picture to life as a cinemagraph. A soft breeze sways the "
    "trees, branches, leaves and grass. People breathe slowly and shift their weight a little; their hair and "
    "clothes stir. Clouds drift, water ripples, rain and snow fall, smoke curls, lights shimmer. Fixed static "
    "camera: no zoom, no pan, no tilt. Text, logos and lettering stay sharp and unchanged, and everything "
    "keeps its shape, colors and composition."
)
NEGATIVE = (
    "frozen, static image, no motion, still frame, "
    "camera movement, zoom, pan, dolly, shaking, fast motion, sudden motion, morphing, warping, melting, "
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
        self.images = {}         # key -> PNG bytes, until its job runs
        self.state = {}          # key -> {"state", "started", "error"}
        self.durations = []      # seconds the last few jobs took, for the progress estimate

    def clip(self, key):
        return os.path.join(self.clips, key + ".mp4")

    def add(self, key, png):
        with self.lock:
            current = self.state.get(key, {}).get("state")
            if current in ("queued", "running"):
                return self.status_locked(key)
            # Sent again (Animate Again on the phone): the old loop goes, and a new one is made.
            if os.path.exists(self.clip(key)):
                os.remove(self.clip(key))
            self.images[key] = png
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
            return key, self.images.pop(key)

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


def morph(a, b, steps):
    """`steps` frames moving from `a` to `b` along their optical flow, each pixel carried to where it goes
    rather than faded, so nothing shows twice. The last is `b`."""
    import cv2
    gray = [cv2.cvtColor(np.clip(f, 0, 255).astype(np.uint8), cv2.COLOR_RGB2GRAY) for f in (a, b)]
    flow = cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_MEDIUM).calc(gray[0], gray[1], None)
    h, w = gray[0].shape
    x, y = np.meshgrid(np.arange(w, dtype=np.float32), np.arange(h, dtype=np.float32))
    out = []
    for k in range(1, steps):
        t = k / steps   # at a steady pace, as the clip moves: easing in and out reads as a stop
        # a(p) is b(p + flow(p)): at t, a pixel has gone t of the way. Both ends are carried to t and mixed.
        from_a = cv2.remap(a, x - t * flow[..., 0], y - t * flow[..., 1], cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
        from_b = cv2.remap(b, x + (1 - t) * flow[..., 0], y + (1 - t) * flow[..., 1], cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
        out.append(from_a * (1 - t) + from_b * t)
    out.append(b.copy())
    return out


def looped(frames):
    """The clip ending on the frame it starts on. The model's first frame is a little off from the rest (Wan's
    VAE makes it alone), so the clip starts on the second. It runs to the frame in its last part nearest
    the start, then morphs from there back to the start at the pace the clip moves at."""
    frames = [f.astype(np.float32) for f in frames[1:]]
    first = frames[0]
    late = range(int(LATE * len(frames)), len(frames))
    turn = min(late, key=lambda i: float(np.abs(frames[i] - first).mean()))
    pace = np.mean([np.abs(frames[i + 1] - frames[i]).mean() for i in range(turn)])
    steps = int(np.clip(round(float(np.abs(frames[turn] - first).mean()) / max(pace, 1e-3)), RETURN_MIN, RETURN_MAX))
    return frames[:turn + 1] + morph(frames[turn], first, steps)


def to_linear(c):
    c = c / 255
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def to_srgb(c):
    c = np.clip(c, 0, 1)
    return 255 * np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)


class Extended:
    """The lock screen frame SGExtendedClip.m draws, from a cover: the cover across the frame's width,
    centered, its edges drawn out above and below (lightly blurred next to it, heavily far from it, in
    linear light as Core Image blurs), its top and bottom feathered into them, and the bottom shaded. Here
    the cover's square can be any frame of its animation."""

    def __init__(self, cover):
        w, h = cover.size
        trim = (round(w * EDGE_TRIM), round(h * EDGE_TRIM), w - round(w * EDGE_TRIM), h - round(h * EDGE_TRIM))
        self.cover = cover.convert("RGB").crop(trim).resize((OUT_W, OUT_W), Image.LANCZOS)
        side = OUT_W
        self.top = top = round(OUT_H * 0.5 - side / 2)
        light = to_linear(np.asarray(self.cover, dtype=np.float32))
        # The cover clamped out past the frame on every side, far enough for the far blur.
        pad = int(4 * FAR_BLUR * side)
        clamped = np.pad(light, ((top + pad, OUT_H - top - side + pad), (pad, pad), (0, 0)), mode="edge")
        crop = (slice(pad, pad + OUT_H), slice(pad, pad + OUT_W))
        near = gaussian_filter(clamped, (side * NEAR_BLUR, side * NEAR_BLUR, 0))[crop]
        far = gaussian_filter(clamped, (side * FAR_BLUR, side * FAR_BLUR, 0))[crop]
        luma = (far @ np.array([0.2125, 0.7154, 0.0721], dtype=np.float32))[..., None]
        far = luma + (far - luma) * SATURATION + BRIGHTNESS
        # Near over the cover, giving way to far BLEND_REACH of its side above and below it.
        y = np.arange(OUT_H, dtype=np.float32) + 0.5
        reach = BLEND_REACH * side
        mask = np.clip(1 - (top - y) / reach, 0, 1) * np.clip(1 - (y - top - side) / reach, 0, 1)
        mask = mask[:, None, None]
        self.streaks = to_srgb(near * mask + far * (1 - mask)).astype(np.float32)
        inside = np.arange(side, dtype=np.float32) + 0.5
        self.feather = np.clip(np.minimum(inside, side - inside) / (COVER_FEATHER * side), 0, 1)[:, None, None]
        shade = SHADE_ALPHA * np.clip((y - OUT_H * (1 - SHADE_FROM)) / (OUT_H * SHADE_FROM), 0, 1)
        self.unshaded = (1 - shade)[:, None, None]

    def square(self):
        """The cover the model animates, at SIDE."""
        return self.cover.resize((SIDE, SIDE), Image.LANCZOS)

    def frame(self, square):
        """The frame with `square`, a frame of the animation at any size, as the cover."""
        moving = np.asarray(Image.fromarray(np.clip(square, 0, 255).astype(np.uint8)).resize((OUT_W, OUT_W), Image.LANCZOS), dtype=np.float32)
        frame = self.streaks.copy()
        region = frame[self.top:self.top + OUT_W]
        frame[self.top:self.top + OUT_W] = region * (1 - self.feather) + moving * self.feather
        return frame * self.unshaded


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


def work(jobs, comfy, lama):
    inputs = os.path.join(comfy.root, "ComfyUI", "input")
    while True:
        key, png = jobs.next()
        started = time.time()
        print(f"[{time.strftime('%H:%M:%S')}] animating {key}")
        image_name = f"vitrine_{key}.png"
        frames = []
        try:
            cover = cover_of(png)
            if lama:
                cover, box = label.clean(cover, lama)
                if box:
                    print(f"[{time.strftime('%H:%M:%S')}] took the Parental Advisory label off {key} at {box}")
            extended = Extended(cover)
            extended.square().save(os.path.join(inputs, image_name))
            seed = int(key[:12], 16) % (2 ** 31) + random.randint(0, 999)
            frames = comfy.run(image_name, seed)
            pictures = [np.asarray(Image.open(f).convert("RGB"), dtype=np.float32) for f in frames]
            clip = [extended.frame(square) for square in looped(pictures)]
            encode([np.clip(np.round(f), 0, 255).astype(np.uint8) for f in clip], jobs.clip(key))
            seconds = time.time() - started
            jobs.finish(key, seconds=seconds)
            print(f"[{time.strftime('%H:%M:%S')}] saved {key}.mp4 in {seconds / 60:.1f} min")
        except Exception as error:  # the phone shows Failed and the log says why
            jobs.finish(key, error=str(error))
            print(f"[{time.strftime('%H:%M:%S')}] {key} failed: {error}")
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
            print(f"[{time.strftime('%H:%M:%S')}] {key} received from {self.client_address[0]}")
            self.answer(200, jobs.add(key, png))

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
    parser.add_argument("--lama", help="big-lama.pt, which takes Parental Advisory labels off covers")
    parser.add_argument("--keep-labels", action="store_true", help="leave Parental Advisory labels on covers")
    args = parser.parse_args()
    os.makedirs(args.clips, exist_ok=True)
    lama = None
    if not args.keep_labels:
        if args.lama and os.path.exists(args.lama):
            lama = args.lama
        else:
            print(f"No LaMa model at {args.lama}, so Parental Advisory labels stay on covers (see README.md).")
    jobs = Jobs(args.clips)
    comfy = Comfy(args.comfy, args.comfy_port)
    comfy.start()
    threading.Thread(target=work, args=(jobs, comfy, lama), daemon=True).start()
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
