@echo off
rem Starts Vitrine Animate with ComfyUI's own Python. VITRINE_ANIMATE is the folder that holds
rem ComfyUI_windows_portable, clips and models (big-lama.pt, the face model and the person model); it defaults to D:\VitrineAnimate.
if "%VITRINE_ANIMATE%"=="" set VITRINE_ANIMATE=D:\VitrineAnimate
title Vitrine Animate
"%VITRINE_ANIMATE%\ComfyUI_windows_portable\python_embeded\python.exe" -I "%~dp0vitrine_animate.py" --comfy "%VITRINE_ANIMATE%\ComfyUI_windows_portable" --clips "%VITRINE_ANIMATE%\clips" --lama "%VITRINE_ANIMATE%\models\big-lama.pt" --faces "%VITRINE_ANIMATE%\models\face_detection_yunet_2023mar.onnx" --people "%VITRINE_ANIMATE%\models\maskrcnn_resnet50_fpn_v2_coco-73cbd019.pth"
pause
