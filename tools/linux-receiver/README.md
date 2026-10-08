# PadDisplay Linux Thin Client

Native Linux receiver for low-power laptops such as the Acer Aspire One Cloudbook.

## Install on antiX / Debian

```bash
sudo apt update
sudo apt install -y git build-essential pkg-config libsdl2-dev \
  libavcodec-dev libavutil-dev libswscale-dev libva-dev vainfo ffmpeg
```

Verify Intel H.264 hardware decode:

```bash
vainfo
ffmpeg -hide_banner -hwaccels
```

You want `vaapi` in the FFmpeg list and an H.264 decode profile in `vainfo`.

## Build and run

```bash
cd ~/ipad-display
./tools/linux-receiver/build.sh
./tools/linux-receiver/run.sh
```

The client listens on TCP 4822 for video/control and TCP 4824 for PCM audio.
Set **Receiver host** on the desktop to the Cloudbook's LAN IP.

Architecture:

```
TCP 4822 H.264 -> FFmpeg/libavcodec -> VA-API if available -> SDL2 fullscreen
TCP 4824 PCM   -> bounded audio queue -> SDL2 audio
SDL2 input     -> MOUSE_V1 / KEYBOARD_V1 -> desktop host
```

Local controls: F11 toggles fullscreen, Escape leaves fullscreen, and
Ctrl+Shift+Q exits. Logs are written to `~/.local/state/paddisplay/receiver.log`.

This first Linux build prefers VA-API decode but copies decoded frames into an
SDL texture for presentation. Once the Cloudbook is running reliably, the next
optimization is a zero-copy VA-API/DRM or VA-API/OpenGL presentation path.
