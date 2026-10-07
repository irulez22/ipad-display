# PadDisplay protocol v1

The iPad listens on TCP port **4822** for video/touch and **4824** for Wi-Fi audio.

Each frame contains a 4-byte unsigned big-endian payload length, a 1-byte packet type, then exactly payload-length bytes.

| Type | Name | Direction | Payload |
|---|---|---|---|
| 0x01 | VIDEO_H264 | Windows -> iPad | Arbitrary H.264 Annex-B stream bytes |
| 0x02 | PING | Reserved | Reserved |
| 0x03 | CONFIG | Either | UTF-8 JSON capability/version hello |
| 0x04 | DISCONNECT | Either | Empty |
| 0x10 | TOUCH_V1 | iPad -> Windows | Legacy 5-byte packet: phase (u8), normalized X (u16 BE), normalized Y (u16 BE) |
| 0x11 | TOUCH_V2 | iPad/touchscreen receiver -> Windows | count (u8), then count × 7-byte contacts: id (u16 BE), phase (u8), X (u16 BE), Y (u16 BE) |
| 0x12 | MOUSE_V1 | Windows laptop receiver -> Windows host | action (u8), button (u8), X (u16 BE), Y (u16 BE), wheel delta (i16 BE). Actions: 0 move, 1 button down, 2 button up, 3 vertical wheel. Buttons: 0 none, 1 left, 2 right, 3 middle, 4 X1, 5 X2. |
| 0x13 | KEYBOARD_V1 | Windows laptop receiver -> Windows host | action (u8: 0 down, 1 up), virtual-key (u16 BE), scan code (u16 BE), flags (u8; bit 0 extended-key). |
| 0x20 | AUDIO_PCM | Windows -> iPad (TCP 4824) | Legacy 48 kHz stereo signed 16-bit LE PCM. |
| 0x21 | AUDIO_PCM_V2 | Windows -> iPad (TCP 4824) | sequence (u32 BE), monotonic timestamp µs (u64 BE), then 48 kHz stereo signed 16-bit LE PCM. |

The parser reconstructs NAL units across network packet boundaries. SPS (NAL 7) and PPS (NAL 8) must precede picture data. Send regular IDR frames.

Touch phases are 0=down, 1=move, 2=up, 3=cancel. X and Y are normalized to 0...65535 across the displayed iPad surface.

TOUCH_V2 assigns a stable contact ID to each UIKit UITouch for the lifetime of that finger contact and supports up to 10 simultaneous contacts. The Windows host maps those normalized contacts to the selected virtual monitor and injects them with the Win32 InitializeTouchInjection / InjectTouchInput APIs, so applications receive native Windows touch/pointer input rather than mouse emulation.

TOUCH_V1 remains accepted by the Windows host as a single-contact compatibility path.

On connection, both endpoints may send CONFIG JSON describing protocol version and supported capabilities. Protocol v1 advertises dedicated audio on TCP 4824 and AUDIO_PCM_V2 support.

AUDIO_PCM_V2 mirrors the Windows default render endpoint while Wi-Fi is active. The dedicated TCP 4824 connection prevents H.264 head-of-line blocking. Sequence numbers expose gaps and the monotonic sender timestamp enables jitter diagnostics. The iPad uses an adaptive AudioQueue prebuffer that starts near 120 ms, increases after underruns, and slowly returns toward the low-latency target after stable playback. USB transport intentionally sends no audio.


## Discovery

PadDisplay advertises the video/touch endpoint on the local network with Bonjour/mDNS as `_paddisplay._tcp.local.` on TCP 4822. TXT metadata includes the protocol version, app version/build, and dedicated audio port.

The Windows launcher prefers USB when usbmux is available. For Wi-Fi it first resolves the Bonjour service and verifies TCP 4822. If mDNS resolution is unavailable, it falls back to the configured legacy IP address so discovery failures do not prevent streaming.

## Runtime telemetry

The Windows streamer writes a small JSON status file under `%LOCALAPPDATA%\PadDisplay\status.json`. It contains transport, host, uptime, current video/audio throughput, packet ages, touch count, and the most recent CONFIG handshake received from the iPad. The non-elevated launcher reads this file to display live health without requiring direct IPC with the elevated engine.


## Battery telemetry

While the main video/touch connection is active, the iPad sends an updated CONFIG JSON approximately every five seconds. The payload reuses the normal capability/version fields and also includes `battery_percent` and `battery_state` (`charging`, `full`, `unplugged`, or `unknown`). The Windows streamer merges the most recent values into its status JSON and the launcher displays them in the live health line.

Battery voltage is intentionally not required by the protocol because public iOS APIs do not expose it reliably. The diagnostics collector performs a best-effort search for additional power fields such as voltage/capacity when jailbreak tools expose them.

## Diagnostics

`tools/collect_diagnostics.sh` creates a timestamped bundle under `diagnostics/`. It captures repository/build metadata, Windows version/GPU, virtual-display devices, the PadDisplay scheduled task, relevant processes, live status JSON, iPad package/app versions, updater state/log, app log, system uptime, USB visibility, and best-effort battery/power information. The Windows launcher exposes this through its Diagnostics button and opens the diagnostics folder after collection.


## Laptop receiver input

The Windows laptop receiver behaves like a normal desktop input device rather than emulating iPad touch. Mouse movement, left/right/middle buttons and wheel events are sent as MOUSE_V1. Keyboard key-down/key-up events are sent as KEYBOARD_V1 and injected on the host with Win32 SendInput. The mouse coordinates remain normalized to the receiver surface and are mapped to the selected virtual monitor.

F11 is reserved locally by the laptop receiver for fullscreen/windowed toggle. Escape leaves fullscreen locally; once windowed, Escape is forwarded normally. Touch pointer packets remain supported only for an actual touchscreen-capable laptop.


## Thin-client session mode

Windows laptop receivers advertise `session_mode: "thin_client"` in CONFIG. The host generates a `session_id` for each connection attempt and advertises the same session intent. This keeps the existing H.264 transport compatible while allowing laptop-specific capabilities to evolve independently from the iPad display path.

Current channel responsibilities are:

- TCP 4822: H.264 video, CONFIG/session control, mouse, keyboard and optional touchscreen input.
- TCP 4824: dedicated 48 kHz stereo PCM audio using AUDIO_PCM_V2.

The laptop path uses native mouse and keyboard input as first-class controls. Touch injection is optional and lazily initialized only when TOUCH_V1/TOUCH_V2 packets are actually received, so failure or absence of touch support cannot disable mouse, keyboard, wheel or trackpad scrolling.

The receiver keeps video decode and presentation on bounded worker queues. The access-unit queue is capped at two AUs and the presentation queue at one decoded frame. Producers block briefly when a queue is full rather than intentionally discarding frames, limiting runaway latency while preserving lossless backpressure.
