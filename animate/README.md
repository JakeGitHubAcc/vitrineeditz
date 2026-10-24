# Vitrine Animate

Animates album covers on your own computer for the lock screen's **Animate this album's cover**
(Settings → Mod Settings → lock screen). The phone sends the playing album's cover with the album's
name and artist, and this:

- takes the Parental Advisory label off: it uses Apple's catalog copy of the cover when that is the
  same picture (`catalog.py`), else finds the label by OCR and paints it out with LaMa (`label.py`);
- animates it with Wan 2.2 TI2V-5B in ComfyUI, but only to measure the motion: the cover's own pixels
  are moved along the clip's optical flow (`motion.py`), so its colors and detail stay its own. The
  camera's part of the motion is taken out and the rest softened and capped; text does not move and
  faces move only as a whole. The end turns back along the motion, so the clip ends on its first frame;
- paints the cover on a little above and below it and fades that into a smooth blur (`frame.py`);
- does what the phone's **Text on animated covers** and **Camera sway** settings ask (`effects.py`): the
  text kept still, faded out and back in over the loop, or painted out, and a slow, slight sway of the
  whole picture. Either makes the loop about 8 seconds, the motion played over itself;
- adds a light film grain, and hands the MP4 back.

The phone keeps it for good, so it plays with the computer off, on the lock screen and behind the player
(with the player's background on Animated) for every song of the album without a Canvas or animated
cover. Finished clips are also kept in `clips/`. The two settings apply to covers sent after they are
changed; **Animate Again** remakes one.

## Setup (Windows, NVIDIA, 8 GB VRAM or more)

In one folder (`D:\VitrineAnimate` unless `VITRINE_ANIMATE` says otherwise):

- `ComfyUI_windows_portable/`, from the ComfyUI release `ComfyUI_windows_portable_nvidia.7z`
- in `ComfyUI_windows_portable/ComfyUI/models/`:
  - `diffusion_models/wan2.2_ti2v_5B_fp16.safetensors` (Comfy-Org/Wan_2.2_ComfyUI_Repackaged)
  - `text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors` (Comfy-Org/Wan_2.1_ComfyUI_repackaged)
  - `vae/wan2.2_vae.safetensors` (Comfy-Org/Wan_2.2_ComfyUI_Repackaged)
- `models/big-lama.pt`, from the release `add_big_lama` of Sanster/models on GitHub
- `models/face_detection_yunet_2023mar.onnx`, from opencv/opencv_zoo on GitHub
  (`models/face_detection_yunet`)
- the label finder's OCR in ComfyUI's Python:
  `ComfyUI_windows_portable\python_embeded\python.exe -m pip install rapidocr_onnxruntime`

To leave labels on, add `--keep-labels` to the command in `start.bat`.

## Use

1. Double-click `start.bat`. It starts ComfyUI and prints the address to enter on the phone, such as
   `10.0.0.185:8790`. The first time, allow it through Windows Firewall on **Private** networks.
2. On the phone, with Full-screen artwork on, set **Computer** to that address, play a song from the
   album and tap **Animate this album's cover**. Allow local network access when iOS asks.
3. A clip takes about 4 minutes on an RTX 4060, plus about 10 the first time while the models load.
   The row reads Waiting, Animating and Saved. Music can keep playing with the phone locked.
   **Animate Again** makes a new loop in place of the old one.

Only requests from the home network are answered. The covers' album and artist names go to Apple's
iTunes Search API to find a clean copy. Settings are at the top of each file: the model's size, length and
prompt in `vitrine_animate.py`, how much things move and the grain in `motion.py`, and the edges' blur
in `frame.py`. The graph ComfyUI runs is `workflow.json`.
