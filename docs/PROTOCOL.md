# PadDisplay protocol v0

The iPad listens on TCP port **4822**.

Each frame contains a 4-byte unsigned big-endian payload length, a 1-byte packet type, then exactly payload-length bytes.

| Type | Name | Direction | Payload |
|---|---|---|---|
| 0x01 | VIDEO_H264 | Windows -> iPad | Arbitrary H.264 Annex-B stream bytes |
| 0x02 | PING | Reserved | Reserved |
| 0x03 | CONFIG | Reserved | Reserved |
| 0x04 | DISCONNECT | Either | Empty |
| 0x10 | TOUCH | iPad -> Windows | 5 bytes: phase (u8), normalized X (u16 BE), normalized Y (u16 BE) |

The parser reconstructs NAL units across network packet boundaries. SPS (NAL 7) and PPS (NAL 8) must precede picture data. Send regular IDR frames.

Touch phases are 0=down, 1=move, 2=up, 3=cancel. X and Y are normalized to 0...65535 across the displayed iPad surface. The current Windows host maps these events to mouse move/down/up on the 1280x960 PadDisplay monitor.

Future versions will replace mouse emulation with native Windows pointer/touch injection and will multiplex control, video, reverse input, audio and telemetry over TCP or usbmux.
