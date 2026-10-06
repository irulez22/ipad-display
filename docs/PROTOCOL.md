# PadDisplay protocol v0

The iPad listens on TCP port **4822**.

Each frame contains a 4-byte unsigned big-endian payload length, a 1-byte packet type, then exactly payload-length bytes.

| Type | Name | Direction | Payload |
|---|---|---|---|
| 0x01 | VIDEO_H264 | Windows -> iPad | Arbitrary H.264 Annex-B stream bytes |
| 0x02 | PING | Reserved | Reserved |
| 0x03 | CONFIG | Reserved | Reserved |
| 0x04 | DISCONNECT | Either | Empty |
| 0x10 | TOUCH_V1 | iPad -> Windows | Legacy 5-byte packet: phase (u8), normalized X (u16 BE), normalized Y (u16 BE) |
| 0x11 | TOUCH_V2 | iPad -> Windows | count (u8), then count × 7-byte contacts: id (u16 BE), phase (u8), X (u16 BE), Y (u16 BE) |
| 0x20 | AUDIO_PCM | Windows -> iPad | 48 kHz, stereo, signed 16-bit little-endian PCM. Used only on Wi-Fi transport. |

The parser reconstructs NAL units across network packet boundaries. SPS (NAL 7) and PPS (NAL 8) must precede picture data. Send regular IDR frames.

Touch phases are 0=down, 1=move, 2=up, 3=cancel. X and Y are normalized to 0...65535 across the displayed iPad surface.

TOUCH_V2 assigns a stable contact ID to each UIKit UITouch for the lifetime of that finger contact and supports up to 10 simultaneous contacts. The Windows host maps those normalized contacts to the selected virtual monitor and injects them with the Win32 InitializeTouchInjection / InjectTouchInput APIs, so applications receive native Windows touch/pointer input rather than mouse emulation.

TOUCH_V1 remains accepted by the Windows host as a single-contact compatibility path.

Future protocol revisions may multiplex control, video, reverse input, audio and telemetry over TCP or usbmux.

AUDIO_PCM mirrors the Windows default render endpoint while the Wi-Fi transport is active. USB transport intentionally sends no audio. Packet boundaries do not imply timestamps; the iPad feeds PCM to a low-latency AudioQueue in arrival order.
