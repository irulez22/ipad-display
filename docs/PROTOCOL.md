# PadDisplay protocol v0

The iPad listens on TCP port **4822**.

Each frame contains a 4-byte unsigned big-endian payload length, a 1-byte packet type, then exactly payload-length bytes.

| Type | Name | Payload |
|---|---|---|
| 0x01 | VIDEO_H264 | Arbitrary H.264 Annex-B stream bytes |
| 0x02 | PING | Reserved |
| 0x03 | CONFIG | Reserved |
| 0x04 | DISCONNECT | Empty |

The parser reconstructs NAL units across network packet boundaries. SPS (NAL 7) and PPS (NAL 8) must precede picture data. Send regular IDR frames.

Future versions will multiplex control, video, reverse input, audio and telemetry over TCP or usbmux.
