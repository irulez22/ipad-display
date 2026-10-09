# PadDisplay

Use a jailbroken iPad Air (iOS 10.3.3), Windows laptop, or Linux laptop as a display for a Windows PC. The host captures a selected monitor with FFmpeg, streams H.264, and receives touch or mouse/keyboard input. A virtual display driver provides an extended desktop; selecting a physical monitor mirrors that monitor.

## Start here

- **Windows host:** build the launcher with tools/build_windows_launcher.ps1, then run tools/launch_windows.bat. Choose the display, resolution, frame rate, and bitrate. Leave Receiver host empty for iPad USB/Bonjour discovery, or enter a laptop receiver's address.
- **iPad:** open PadDisplay. Video/input listens on TCP 4822; Wi-Fi audio uses TCP 4824. USB uses usbmux/iproxy forwarding and disables audio.
- **Windows receiver:** see [receiver setup](tools/windows-receiver/README.md).
- **Linux receiver:** see [dependencies and build instructions](tools/linux-receiver/README.md).
- **Virtual monitor:** see [driver setup](docs/WINDOWS_DRIVER.md). The driver is separate from the receivers.

The launcher/setup scripts retain machine-specific paths for Josh's Windows/WSL installation. Adjust those paths for another machine. The streaming CLI is usable independently.

## Stream directly from Windows

Install Python 3 and an FFmpeg build supporting your capture/encoder combination, then run:

    python tools/stream_windows.py RECEIVER_IP --capture gdigrab --encoder x264 --size 1280x960 --fps 30 --bitrate 6M

The default CLI path uses Desktop Duplication (ddagrab), NVIDIA NVENC, 1280x960 at 60 fps, and 6 Mbit/s. The launcher configures monitor modes and capture indices; the direct CLI does not create or resize a Windows monitor. See [streaming options and troubleshooting](docs/WINDOWS_STREAMING.md).

## Build the iPad app

From WSL/Linux with Theos and an iOS SDK:

    export THEOS="$HOME/theos"
    make
    make package

The arm64 app targets iOS 10. Packages are written to packages/.

**tools/rebuild-ipad.sh builds the current checkout and preserves local changes.** By default it also publishes a release, rebuilds the desktop launcher, and stages an iPad update. To use its build-only workflow:

    PADDISPLAY_NO_RELEASE=1 PADDISPLAY_NO_DESKTOP=1 PADDISPLAY_NO_DEVICE_TRIGGER=1 bash tools/rebuild-ipad.sh

Fetching/merging upstream changes is a separate Git operation.

## Checks

    python -m unittest discover -s tests -v

Tests cover host framing, Windows input structure layout, malformed input, CLI validation, audio startup cleanup, and native Linux receiver shutdown. The socket test requires a C++ compiler on Linux and skips on Windows. CI also compiles the Windows launcher and runs Objective-C Annex-B parser tests on macOS.

## Project layout

| Path | Purpose |
|---|---|
| src/ | iPad UI, TCP receivers, H.264/VideoToolbox playback, PCM audio |
| tools/stream_windows.py | Capture/encode host, input injection, audio, telemetry |
| tools/windows-launcher/ | Windows settings, engine controls, diagnostics |
| tools/windows-receiver/ | Native Windows receiver; C# source is the older implementation |
| tools/linux-receiver/ | SDL/OpenGL/FFmpeg receiver |
| windows/driver/, VirtualDisplayDriver/ | Driver development and bundled virtual-display assets |
| layout/ | iPad updater and launch daemon |
| tests/ | Regression checks |

See [protocol](docs/PROTOCOL.md) and [maintenance notes](docs/MAINTENANCE.md).

The protocol has no pairing, authentication, or encryption. Use it only on a trusted network; a connected receiver can send desktop input to the host. Do not expose these ports to the internet.
