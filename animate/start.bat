@echo off
rem Starts Vitrine Animate with ComfyUI's own Python. VITRINE_ANIMATE is the folder that holds
rem ComfyUI_windows_portable and clips; it defaults to D:\VitrineAnimate.
if "%VITRINE_ANIMATE%"=="" set VITRINE_ANIMATE=D:\VitrineAnimate
title Vitrine Animate
"%VITRINE_ANIMATE%\ComfyUI_windows_portable\python_embeded\python.exe" -I "%~dp0vitrine_animate.py" --comfy "%VITRINE_ANIMATE%\ComfyUI_windows_portable" --clips "%VITRINE_ANIMATE%\clips"
pause
