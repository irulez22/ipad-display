# Maintenance and verification

The reliability overhaul addresses host input ABI/validation, packet bounds, audio startup cleanup, iPad channel ownership and send failures, bounded H.264 parsing, decoder parameter changes, receiver shutdown waits, saved launcher settings, nonblocking diagnostics, and preservation of local source during rebuilds.

## Before a release

1. Run python -m unittest discover -s tests -v on Windows and Linux.
2. Build the iPad application with THEOS set; compile the Windows launcher and native receivers.
3. Run the macOS parser job (Foundation is required to execute Objective-C tests).
4. On hardware, test USB/Wi-Fi reconnection, resolution changes, mouse/keyboard/touch, audio start/stop, receiver exit while idle, and a sustained stream.
5. Use tools/prepare_release.sh to stage a package; --publish explicitly publishes it.

## Remaining architectural limits

- Protocol v1 trusts the connected peer and carries unencrypted video/input. Pairing/authentication requires coordinated changes across every host and receiver.
- Several deployment scripts retain machine-specific paths, driver assumptions, and scheduled-task setup.
- The repository still tracks historic build binaries/debug output. Ignore rules prevent new untracked output from appearing; tracked artifacts were retained.
- Hardware performance and calibration need the actual iPad/GPU/laptop. Compilation and socket tests do not establish latency, visual quality, or audio synchronization.
- Force-terminating the host bypasses Python cleanup; graceful audio lifecycle across forced scheduled-task termination remains a separate integration concern.
- iPad presentation preserves backpressure in normal operation but gives up waiting after one second when the display layer is stalled, allowing teardown to progress.

## Protocol expectations

Send H.264 access-unit delimiters (AUD, NAL 9), in-band SPS/PPS, and regular IDR frames. A TCP packet is a transport chunk, not a video frame. The iPad limits individual NAL units to 8 MiB and assembled access units to 16 MiB, discarding an oversized access unit until the next AUD.

Audio belongs on port 4824; video belongs on port 4822. The iPad ignores channel-mismatched media so decoder and audio state stay on their respective receiver queues.

## Local verification (2026-10-09)

- 15 regression tests passed in WSL, including native socket fragmentation, EOF, and shutdown.
- 14 host regression tests passed on Windows.
- The arm64 iPad application compiled and linked with Theos.
- The Windows launcher and native receiver compiled to temporary output without installation.
- PowerShell parsing, rebuild shell syntax, and Git whitespace checks passed.
- Linux development dependencies were installed in WSL; the full native Linux receiver now builds successfully.
- macOS parser execution and real-device/GPU playback have not been run locally.

## Linux-focused follow-up

The Linux path is the active development target. Added correct virtual-key
encoding, decoder reset on reconnect, FFmpeg input padding, audio disconnect
handling, legacy PCM compatibility, validated audio formats, and bounded audio
rebuffering. All 16 regression checks pass, including headless native tests.
run.sh rebuilds after source changes. No deployment to the laptop was performed.
