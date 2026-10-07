# PadDisplay Windows Receiver

PadDisplay Receiver turns a Windows laptop into a dedicated PadDisplay endpoint using the same low-latency design principles as the iPad client.

## Architecture

The receiver is native C++ and keeps decoded video on the GPU:

```
TCP H.264 Annex-B
  -> AUD-delimited access units
  -> Media Foundation H.264 hardware decoder MFT
  -> D3D11-backed NV12 surfaces
  -> D3D11 video processor
  -> DXGI fullscreen swap chain
```

There is no raw-BGRA pipe, managed per-frame copy, WinForms Bitmap allocation, or GDI scaling in the video path.

The host remains unchanged at the protocol level. It still sends protocol-v1 VIDEO_H264 packets, CONFIG metadata, and regular AUD/SPS/PPS/IDR data. The iPad client remains fully compatible.

## Input

The receiver sends input back over the same TCP connection:

- Native touchscreen/pen pointer events use `WM_POINTER` and send `TOUCH_V2`.
- Mouse is a compatibility fallback and sends `TOUCH_V1`.
- Coordinates are normalized to 0..65535 across the kiosk surface.

The main host maps these packets to the selected virtual monitor and injects native Windows touch.

## Kiosk behavior

The receiver is a persistent fullscreen kiosk application.

Before the host connects it displays a simple waiting screen. When video arrives, D3D11 presentation replaces the waiting screen. If the connection drops, the receiver returns to the waiting screen and continues listening on TCP 4822.

## Native laptop mode

For the current laptop panel, the PadDisplay host defaults Windows-receiver sessions to:

- 1366x768
- 60 fps
- 8 Mbps CBR
- NVENC ultra-low-latency settings

This avoids encoding 1080p only to scale it back down on a 1366x768 panel.

## Build on the receiver laptop

Requirements:

- Windows 10/11
- Visual Studio 2022 Community with **Desktop development with C++**
- Windows SDK

Then run:

```bat
tools\windows-receiver\run_receiver.bat
```

The executable is built to:

```
%LOCALAPPDATA%\PadDisplayReceiver\PadDisplayReceiver.exe
```

FFmpeg is no longer required on the receiver laptop.

Allow TCP 4822 through Windows Firewall when prompted.

## Main host

Set **Receiver host** in the normal PadDisplay launcher to the receiver laptop hostname or LAN IP. Leave it blank for normal iPad USB/Wi-Fi operation.

When Receiver host is populated, the host stays pinned to that Windows receiver and selects 1366x768 by default.
