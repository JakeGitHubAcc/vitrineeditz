"""Vitrine Animate: turns album covers into subtle looping animations on this computer's GPU.

The iPhone (Shared/AnimatedArtwork/SGCoverAnimator.x) sends a cover's 3:4 lock screen frame as PNG; this
server queues it, has ComfyUI animate it with Wan 2.2 TI2V-5B (workflow.json), cross-fades the end of the
clip into its start so it loops without a jump, and keeps the MP4 in CLIPS_DIR, where the phone downloads
it. One job runs at a time. Run it with ComfyUI's own Python (start.bat), which has everything it imports.

    POST /animate?key=K   body: PNG       -> {"state": "queued"|"running"|"done", "position": n}
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
KEY = re.compile(r"^[0-9a-f]{16,64}$")

# The phone sends its 3:4 extended cover: the square cover across the frame's width, centered, its edges
# drawn out above and below. Only the square is animated: given the drawn-out edges, which have no detail,
# the model invents blotches there that flicker, so they stay as the phone drew them and the moving square
# is laid back over them, its top and bottom feathered into the still frame.
# Wan 2.2 TI2V-5B works in multiples of 32 and 4n+1 frames at 24 fps; a 640 square fits an 8 GB card, and
# 73 frames is three seconds before the loop's fade.
SIDE, FRAMES, FPS = 640, 73, 24
WIDTH, HEIGHT = SIDE, SIDE
# The clip the phone gets: 3:4 at three quarters of an iPhone's width, the size SGMotionPixels downloads.
OUT_W, OUT_H = 768, 1024
# Rows at the square's top and bottom that fade from the animation into the still frame.
FEATHER = 24
# Frames at the end blended into the start, so the loop has no seam: half a second.
FADE = 12

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
            if os.path.exists(self.clip(key)):
                return {"state": "done"}
            current = self.state.get(key, {}).get("state")
            if current in ("queued", "running"):
                return self.status_locked(key)
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


def looped(frames):
    """The clip without its last FADE frames, those blended over the first FADE so the end leads into the
    start: out[i] = frames[i + FADE] for the body, and the tail fades from frames[N - FADE + j] to
    frames[j], whose next frame on the wrap is frames[FADE]."""
    n = len(frames)
    if n <= 3 * FADE:
        return frames
    body = frames[FADE:n - FADE]
    tail = []
    for j in range(FADE):
        t = (j + 1) / (FADE + 1)
        tail.append((frames[n - FADE + j] * (1 - t) + frames[j] * t).astype(np.uint8))
    return body + tail


def still_and_square(png):
    """The phone's frame at OUT_W x OUT_H, and its cover square at SIDE for the model."""
    frame = Image.open(io.BytesIO(png)).convert("RGB").resize((OUT_W, OUT_H), Image.LANCZOS)
    top = (OUT_H - OUT_W) // 2
    square = frame.crop((0, top, OUT_W, top + OUT_W)).resize((SIDE, SIDE), Image.LANCZOS)
    return np.asarray(frame, dtype=np.float32), square


def composed(still, animated):
    """Each animated square, scaled to the frame's width, laid over the still frame at the cover's place,
    fading in over FEATHER rows at its top and bottom."""
    top = (OUT_H - OUT_W) // 2
    ramp = np.ones(OUT_W, dtype=np.float32)
    edge = np.linspace(0, 1, FEATHER + 2, dtype=np.float32)[1:-1]
    ramp[:FEATHER], ramp[-FEATHER:] = edge, edge[::-1]
    alpha = ramp[:, None, None]
    region = still[top:top + OUT_W]
    out = []
    for square in animated:
        moving = np.asarray(Image.fromarray(square.astype(np.uint8)).resize((OUT_W, OUT_W), Image.LANCZOS), dtype=np.float32)
        frame = still.copy()
        frame[top:top + OUT_W] = region * (1 - alpha) + moving * alpha
        out.append(frame)
    return out


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


def work(jobs, comfy):
    inputs = os.path.join(comfy.root, "ComfyUI", "input")
    while True:
        key, png = jobs.next()
        started = time.time()
        print(f"[{time.strftime('%H:%M:%S')}] animating {key}")
        image_name = f"vitrine_{key}.png"
        frames = []
        try:
            still, square = still_and_square(png)
            square.save(os.path.join(inputs, image_name))
            seed = int(key[:12], 16) % (2 ** 31) + random.randint(0, 999)
            frames = comfy.run(image_name, seed)
            pictures = [np.asarray(Image.open(f).convert("RGB"), dtype=np.float32) for f in frames]
            clip = composed(still, looped(pictures))
            encode([np.clip(f, 0, 255).astype(np.uint8) for f in clip], jobs.clip(key))
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
    args = parser.parse_args()
    os.makedirs(args.clips, exist_ok=True)
    jobs = Jobs(args.clips)
    comfy = Comfy(args.comfy, args.comfy_port)
    comfy.start()
    threading.Thread(target=work, args=(jobs, comfy), daemon=True).start()
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
