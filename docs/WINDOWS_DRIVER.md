# PadDisplay Windows indirect display driver

PadDisplay will use a Windows UMDF Indirect Display Driver (IDD) based on Microsoft's IddCx sample.

## Development target

- Windows 11 25H2
- Windows build observed during development: 26200.9457
- Visual Studio 2022 / MSBuild
- Windows SDK/WDK 10.0.26100.0
- x64
- IddCx

## First milestone

Before integrating networking or NVENC, prove the IDD lifecycle:

1. Build Microsoft's unmodified IndirectDisplay sample.
2. Install/start the sample software device.
3. Confirm Windows enumerates an additional display.
4. Fork the sample into this repository as PadDisplay.
5. Reduce it to one monitor and advertise PadDisplay modes:
   - 1280x960 @ 60 Hz (preferred)
   - 1600x1200 @ 60 Hz
   - 1024x768 @ 60 Hz
   - 2048x1536 @ 30 Hz (experimental)
6. Replace the sample swap-chain no-op with PadDisplay frame processing.

## Intended frame path

Windows compositor -> IddCx swap chain -> D3D11 surface -> NVENC H.264 -> PadDisplay protocol -> iPad VideoToolbox

The important architectural goal is to keep the virtual display at the stream resolution. That avoids capturing and scaling a physical desktop.

## Notes

The Microsoft sample is development scaffolding, not production driver code. Keep its TODO warnings in mind when adapting it. The first PadDisplay driver should enumerate exactly one virtual monitor.
