# Vitrine Animate

Animates album covers on your own computer for the lock screen's **Animate this album's cover**
(Settings → Mod Settings → lock screen). The phone sends the playing album's cover with the album's
name and artist, and this:

- takes the Parental Advisory label off: it uses Apple's catalog copy of the cover when that is the
  same picture of the same edition (`catalog.py`), else finds the label by OCR and paints it out with LaMa (`label.py`);
- animates it with Wan 2.2 TI2V-5B in ComfyUI, but only to measure the motion: the cover's own pixels
  are moved along the clip's optical flow (`motion.py`), so its colors and detail stay its own. The
  camera's part of the motion is taken out and the rest softened and capped; text does not move and
  faces move only as a whole. The end turns back along the motion, so the clip ends on its first frame;
- cuts people out, each on their own, over the background painted in behind them (`crowd.py`): a
  crowd's people sway slowly from where they stand and breathe, and the main person only breathes and
  sways a hair, so no body is bent out of shape;
- finds things that move on their own by name with Grounding DINO and outlines them with SAM
  (`props.py`): bees, butterflies and birds hover, clouds drift, flowers nod on their stems, and trees,
  bushes and grass bend from where they stand;
- has curtains sway on their own, as fabric hanging does, and keeps the model's motion off solid things
  such as a stage, a floor or walls, so their shape stays (`scene.py`);
- paints the cover on a little above and below it and fades that into a smooth blur (`frame.py`);
- does what the phone's **Text on animated covers** and **Camera sway** settings ask (`effects.py`): the
  text kept still, faded out and back in over the loop, or painted out, and a slow, slight sway of the
  whole picture; and what a photo's light does: a starfield drifts and twinkles on its own, small shiny
  things (a ring, a chain) catch a glint, and the light slowly shifts. The loop is about 8 seconds, the
  motion played over itself;
- adds a light film grain, and hands the MP4 back.

The phone keeps it for good, so it plays with the computer off, on the lock screen, behind the player
(with the player's background on Animated) and on the album's page, for every song of the album without a
Canvas or animated cover. The player's ⋯ and an album page's ⋯ have it too, under **Animated Cover**. Finished clips are also kept in `clips/`. The two settings apply to covers sent after they are
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
- `models/maskrcnn_resnet50_fpn_v2_coco-73cbd019.pth`, torchvision's Mask R-CNN v2 weights, from
  `https://download.pytorch.org/models/maskrcnn_resnet50_fpn_v2_coco-73cbd019.pth`
- `models/grounding-dino-base/` and `models/sam-vit-base/`, the Hugging Face models
  `IDEA-Research/grounding-dino-base` and `facebook/sam-vit-base` (the JSON, text and safetensors files)
- `models/segformer-b5-ade/`, the Hugging Face model `nvidia/segformer-b5-finetuned-ade-640-640`
  (`config.json`, `preprocessor_config.json` and `pytorch_model.bin`)
- the label finder's OCR in ComfyUI's Python:
  `ComfyUI_windows_portable\python_embeded\python.exe -m pip install rapidocr_onnxruntime`

To leave labels on, add `--keep-labels` to the command in `start.bat`.

## Use

1. Double-click `start.bat`. It starts ComfyUI and prints the address to enter on the phone, such as
   `192.168.1.20:8790`. The first time, allow it through Windows Firewall on **Private** networks.
2. On the phone, with Full-screen artwork on, set **Computer** to that address, play a song from the
   album and tap **Animate this album's cover**. Allow local network access when iOS asks.
3. A clip takes about 4 minutes on an RTX 4060, plus about 10 the first time while the models load.
   The row reads Waiting, Animating and Saved. Music can keep playing with the phone locked.
   **Animate Again** makes a new loop in place of the old one.

### Away from home

The server only answers your home network, and devices on your own [Tailscale](https://tailscale.com)
network. To animate covers and get them from anywhere:

1. Install Tailscale on the computer and on the iPhone, and sign in to the same account on both.
2. Start `start.bat` again. It prints a second address, `100.x.y.z:8790`.
3. On the phone, set **Computer** to that address. It works at home too, so it can stay set.

If the phone can't reach it, allow Python through Windows Firewall on **Public** networks as well. Windows
may treat Tailscale's connection as public.

Only requests from the home network are answered. The covers' album and artist names go to Apple's
iTunes Search API to find a clean copy. Settings are at the top of each file: the model's size, length and
prompt in `vitrine_animate.py`, how much things move and the grain in `motion.py`, how a crowd sways in `crowd.py`, curtains and what keeps its shape in `scene.py`, and the edges' blur
in `frame.py`. The graph ComfyUI runs is `workflow.json`.
