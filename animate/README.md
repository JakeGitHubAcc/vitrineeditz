# Vitrine Animate

Animates album covers on your own computer for the lock screen's **Animate this album's cover**
(Settings → Mod Settings → lock screen). The phone sends the playing album's cover; this takes any
Parental Advisory label off it (OCR finds it, LaMa paints in what was behind it), animates it with
Wan 2.2 TI2V-5B in ComfyUI, morphs its end back into its start along the motion's optical flow, so
the clip ends on the frame it starts on, draws the extended edges around it as the phone does, and
hands the MP4 back. The phone keeps it for good, so it plays with the computer off. Finished clips are also kept in `clips/`.

## Setup (Windows, NVIDIA, 8 GB VRAM or more)

In one folder (`D:\VitrineAnimate` unless `VITRINE_ANIMATE` says otherwise):

- `ComfyUI_windows_portable/`, from the ComfyUI release `ComfyUI_windows_portable_nvidia.7z`
- in `ComfyUI_windows_portable/ComfyUI/models/`:
  - `diffusion_models/wan2.2_ti2v_5B_fp16.safetensors` (Comfy-Org/Wan_2.2_ComfyUI_Repackaged)
  - `text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors` (Comfy-Org/Wan_2.1_ComfyUI_repackaged)
  - `vae/wan2.2_vae.safetensors` (Comfy-Org/Wan_2.2_ComfyUI_Repackaged)
- `models/big-lama.pt`, from the release `add_big_lama` of Sanster/models on GitHub
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

Only requests from the home network are answered. Settings (size, length, prompt) are at the top of
`vitrine_animate.py`; the graph ComfyUI runs is `workflow.json`.
