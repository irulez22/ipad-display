# Live Windows desktop streaming

This is the Phase 2 test path. It mirrors the Windows desktop to PadDisplay in real time. It does **not** create an extended Windows monitor yet.

## Requirements

- PadDisplay open on the iPad and listening on TCP 4822.
- PC and iPad reachable over the same network.
- Python 3 on Windows.
- FFmpeg for Windows available as `ffmpeg.exe` in PATH.

Run this script from **Windows PowerShell or Command Prompt**, not inside WSL, because FFmpeg's `gdigrab` input captures the Windows desktop.

## Run

From the repository directory:

    python tools/stream_windows.py 192.168.68.51

Replace the address with the iPad's current IP.

Defaults are 1280x720, 30 fps, and 6 Mbit/s. Examples:

    python tools/stream_windows.py 192.168.68.51 --fps 30 --size 1280x720 --bitrate 6M
    python tools/stream_windows.py 192.168.68.51 --fps 30 --size 1920x1080 --bitrate 10M

Press Ctrl+C to stop.

## What this proves

Windows desktop capture -> low-latency H.264 -> PadDisplay protocol -> iPad hardware-backed presentation.

The next major milestone after this is a Windows indirect/virtual display so Windows can extend the desktop onto the iPad instead of mirroring an existing display.
