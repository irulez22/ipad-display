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
| 0x11 | TOUCH_V2 | iPad -> Windows | count (u8), then count × 7-byte contacts: id (u16 BE), phase (u8), X (u16 BE), Y (u16 BE) |
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
