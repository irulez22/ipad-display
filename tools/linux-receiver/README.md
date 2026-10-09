# PadDisplay Linux Thin Client

Native Linux receiver for low-power laptops such as the Acer Aspire One Cloudbook.

## Install on antiX / Debian

```bash
sudo apt update
sudo apt install -y git build-essential pkg-config libsdl2-dev libsdl2-ttf-dev libgl1-mesa-dev libx11-dev \
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
sh tools/linux-receiver/build.sh
sh tools/linux-receiver/run.sh
```

The client listens on UDP 4821 for LAN discovery, TCP 4822 for video/control,
and TCP 4824 for PCM audio. Set **Receiver host** on the desktop to **auto**
(the default). The host discovers the receiver again after each disconnect,
so DHCP address changes need no settings update. Both machines must share a
LAN that allows broadcasts. With multiple receivers, enter the desired Linux
hostname; a fixed IP remains supported.

The Windows host keeps the Virtual Display Driver loaded and attaches only its
desktop output while the Cloudbook is connected. Disconnect or Stop detaches
that output, leaving your two physical displays active. Transient stream retries
keep it attached while the receiver remains reachable. This avoids restarting
the graphics driver on every session; Windows can still redraw briefly when
the desktop layout changes. Leave the engine running to await connections.

Architecture:

```
TCP 4822 H.264 -> FFmpeg/libavcodec -> VA-API if available -> OpenGL YUV presentation
TCP 4824 PCM   -> bounded audio queue -> SDL2 audio
SDL2 input     -> MOUSE_V1 / KEYBOARD_V1 -> desktop host
```

Local controls: F11 toggles fullscreen, Escape leaves fullscreen, and
Ctrl+Shift+Q exits. Logs are written to `~/.local/state/paddisplay/receiver.log`.

The receiver prefers VA-API. Direct surface mapping and an optimized copy from
GPU memory support older Intel i965 hardware, including the Cloudbook's Braswell
GPU. Drivers without direct mapping use normal frame download. The launchers no
longer force software decoding. After sampling 30 hardware frames, the receiver
automatically switches to software if readback consumes too much of the stream's
frame-time budget. It also falls back if readback fails. This preserves the
requested 60 fps on Braswell, where CPU decoding is faster than GPU readback.
For troubleshooting, you can still run:

    PADDISPLAY_DISABLE_VAAPI=1 sh tools/linux-receiver/run.sh

## Updating

Pull or merge your source changes, then launch with run.sh as above. It rebuilds
when the source or build script is newer than the binary. Build dependencies
must therefore remain installed.

Use the updated Windows host alongside the receiver. Linux keyboard packets now
use Windows virtual keys with a zero scan code; the host must support that
fallback. SDL scancodes are not Windows scancodes.

## Regression checks

From the repository root, with the build dependencies installed:

    python3 -m unittest discover -s tests -v

Native checks use dummy audio and require no desktop session. They verify
keyboard packets, audio prebuffer/overflow recovery, H.264 decoding and decoder
reset, fragmented socket reads, and shutdown on an idle connection.

Each new video connection resets the H.264 parser/decoder before processing new
data. Audio defaults to 48 kHz stereo signed 16-bit PCM, supports the optional
format handshake, and keeps queued audio bounded to 240 ms. After an underrun,
it pauses to rebuild its 80 ms prebuffer.

Keyboard letters, digits, common punctuation, navigation, modifiers, and keypad
keys are mapped. Punctuation uses Windows OEM virtual keys, so matching keyboard
layouts on both machines are still important. F11 remains local.

Measured end-to-end input latency and subjective speaker quality still require
interactive testing.

Cloudbook target on the tested Wi-Fi: 1366x768, 60 fps, maximum 8M bitrate.
Linux NVENC uses variable bitrate and flushes each encoded packet immediately.
The audio queue starts after 80 ms and is capped at 240 ms.


## Quiet audio and Wi-Fi bursts

Use the Cloudbook's mixer to adjust the PadDisplay playback stream separately
from system volume. PipeWire allows software amplification above 100%; reduce
it if loud passages distort. Windows loopback still reflects the source audio
level, so unusually quiet source applications can also affect the stream.

On the tested Intel Wi-Fi adapter, disabling power saving reduced bursts:

    sudo iw dev wlan0 set power_save off

This trades some battery life for streaming consistency. The Cloudbook has this
command in /etc/rc.local; its original is /etc/rc.local.paddisplay.bak.


Linux uses the captured Windows pointer while connected and hides its local SDL
pointer, avoiding two cursors with different delays. The local pointer returns
on disconnect. The audio stream uses the stable mixer name PadDisplay.
