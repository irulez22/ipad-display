# iPad Display

Experimental low-latency second-display client for a jailbroken first-generation iPad Air (iPad4,2) running iOS 10.3.3.

## Phase 1

PC -> TCP -> framed H.264 Annex-B -> VideoToolbox-compatible presentation -> iPad display.

The iPad app listens on TCP port 4822. This first milestone proves networking, stream framing, H.264 parsing and hardware-backed presentation before USB transport, touch input and the Windows virtual display are added.

## Build

This is a Theos application targeting arm64 and iOS 10. A convenient Windows workflow is WSL2 + Theos + an iOS SDK.

    make package

The resulting .deb is written under packages/.

## Protocol v0

Each packet is:

    uint32 payload_length   big endian
    uint8  packet_type
    bytes  payload

Types:

- 0x01 H.264 Annex-B data
- 0x02 ping
- 0x03 configuration (reserved)
- 0x04 disconnect

Start testing at 1280x720, 30 fps, H.264 with SPS/PPS in-band and regular IDR frames.

See docs/PROTOCOL.md for details.
