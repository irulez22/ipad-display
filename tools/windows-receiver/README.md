# PadDisplay Windows Receiver

This is the Windows counterpart to the jailbroken iPad PadDisplay client. It lets a second Windows PC or laptop act as the remote display endpoint for the existing PadDisplay host streamer.

## Current capabilities

- Listens on TCP 4822 using PadDisplay protocol v1.
- Receives the existing H.264 stream from the main Windows host.
- Uses FFmpeg for low-latency H.264 decoding.
- Runs as a background/tray listener while idle, leaving the laptop desktop fully usable.
- Opens the remote display window only when the host connects, and hides back to the tray on disconnect.
- Renders the remote display in a resizable WinForms window.
- F11 toggles fullscreen; Escape exits fullscreen.
- Sends mouse down/move/up back to the host using TOUCH_V1, so the laptop can interact with the streamed virtual monitor.
- Uses the same host-side NVENC/DDAGrab stream path as the iPad client.

Native Windows multi-touch and mirrored audio are planned next; the protocol already has suitable packet types for both.

## Receiver laptop setup

1. Copy or clone the `tools/windows-receiver` folder onto the receiver laptop.
2. Make sure `ffmpeg.exe` is either in PATH or placed next to `PadDisplayReceiver.exe`.
3. Run `run_receiver.bat`. It builds the receiver into:
   `%LOCALAPPDATA%\PadDisplayReceiver\PadDisplayReceiver.exe`
4. Allow TCP 4822 through Windows Firewall when prompted.
5. Note the laptop hostname or LAN IP address.

The receiver does not require WSL once the folder is on the laptop. It builds against the .NET Framework C# compiler already present on standard Windows installations.

## Main host setup

In the normal PadDisplay launcher, set **Receiver host** to the laptop hostname or LAN IP, for example:

`192.168.68.72`

Leave **Receiver host** blank to return to normal iPad USB/Wi-Fi behavior.

When Receiver host is populated, PadDisplay skips iPad USB/Bonjour selection and keeps the stream pinned to that Windows receiver.

## Direct command-line host mode

The privileged host launcher also accepts:

`-ReceiverHost <hostname-or-ip>`

For example:

`powershell.exe -ExecutionPolicy Bypass -File tools\launch_windows.ps1 -NonInteractive -ReceiverHost 192.168.68.72`

The selected virtual display, resolution, FPS, bitrate, and touch coordinate mapping remain controlled by the normal PadDisplay host settings.


## Laptop-native usage model

The receiver is not a replacement Windows shell. The laptop remains its own normal Windows PC with its own desktop, apps, taskbar, keyboard, networking, and files. PadDisplay Receiver simply adds a remote-display window when the host connects.

For laptop targets, the PadDisplay host automatically selects the 1920x1080 streaming mode when Receiver host is populated. The host virtual display remains an extended monitor on the main PC, while the laptop continues to run its own OS underneath the receiver window.
