# Windows desktop streaming

The Windows host captures an existing monitor and sends video to the iPad or a Windows/Linux receiver. To extend the desktop, install/configure a virtual display first; see [driver setup](WINDOWS_DRIVER.md).

## Requirements

- Python 3 on Windows.
- FFmpeg with ddagrab/h264_nvenc for the default GPU path, or gdigrab/libx264 for software capture/encoding.
- A receiver listening on TCP 4822. Allow TCP 4824 on the receiver for optional Wi-Fi audio.
- Run capture on Windows, not inside WSL.

## Commands

Software compatibility path:

    python tools/stream_windows.py RECEIVER_IP --capture gdigrab --encoder x264 --size 1280x960 --fps 30 --bitrate 6M

Default NVIDIA path, selecting a DXGI output:

    python tools/stream_windows.py RECEIVER_IP --capture ddagrab --encoder nvenc --display 0 --size 1280x960 --fps 60 --bitrate 6M

--adapter N selects the D3D11 adapter. With ddagrab/NVENC, capture retains the selected monitor's actual resolution; set its Windows mode to match --size (the launcher does this). The ddagrab/x264 path downloads and scales frames in software.

Other options:

- --ffmpeg PATH: executable to run.
- --audio-loopback PATH: WASAPI loopback helper; converts audio through FFmpeg to 48 kHz stereo signed 16-bit PCM.
- --audio-port N: dedicated audio port (default 4824).
- --port N: video/input port (default 4822).
- --touch-left X --touch-top Y --touch-width W --touch-height H: physical monitor rectangle for input.
- --status-file PATH --transport NAME: launcher telemetry.

All four touch coordinates must be supplied together. Sizes must have positive even dimensions; frame rates are 1?240. Packet chunks are capped at 8 MiB.

## Troubleshooting

- **No connection:** keep the receiver open, check its address/firewall, and confirm another host is not already connected.
- **NVENC unavailable:** try the software compatibility command above.
- **Wrong screen/input location:** verify the selected adapter/output and physical monitor coordinates. The launcher preserves the saved display device name when available.
- **Keyboard ignored:** rebuild/use the current host; its SendInput structure includes the full Windows union size.
- **Audio unavailable:** verify the helper path, FFmpeg, TCP 4824, and Wi-Fi transport. USB intentionally disables audio.
- **Stalls:** the host terminates capture after five seconds without video progress and bounds socket sends. The launcher retries streaming; a direct CLI run exits and must be restarted.
- **Diagnostics:** use the launcher Diagnostics button or bash tools/collect_diagnostics.sh. Bundles go under diagnostics/.

Press Ctrl+C to stop direct streaming. The desktop launcher controls the scheduled engine separately.
