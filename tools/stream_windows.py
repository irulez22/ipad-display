#!/usr/bin/env python3
"""Capture the Windows desktop with FFmpeg and stream H.264 to PadDisplay."""
import argparse
import shutil
import socket
import struct
import subprocess
import sys

VIDEO_H264 = 0x01
DISCONNECT = 0x04
PORT = 4822

def send_packet(sock, packet_type, payload=b""):
    sock.sendall(struct.pack(">IB", len(payload), packet_type) + payload)

def main():
    p = argparse.ArgumentParser(description="Stream the Windows desktop to PadDisplay")
    p.add_argument("host", help="iPad IP address")
    p.add_argument("--ffmpeg", default="ffmpeg", help="FFmpeg executable/path")
    p.add_argument("--fps", type=int, default=30)
    p.add_argument("--size", default="1280x720")
    p.add_argument("--bitrate", default="6M")
    p.add_argument("--chunk", type=int, default=4096)
    p.add_argument("--encoder", choices=("nvenc", "x264"), default="nvenc",\n                   help="H.264 encoder (default: nvenc)")\n    p.add_argument("--capture", choices=("ddagrab", "gdigrab"), default="ddagrab",\n                   help="Windows capture backend (default: ddagrab)")\n    p.add_argument("--display", type=int, default=0,\n                   help="ddagrab output index (default: 0)")
    args = p.parse_args()

    if shutil.which(args.ffmpeg) is None and args.ffmpeg == "ffmpeg":
        sys.exit("ffmpeg was not found in PATH.")

    width, height = args.size.lower().split("x", 1)
    vf = "scale=%s:%s:force_original_aspect_ratio=decrease,pad=%s:%s:(ow-iw)/2:(oh-ih)/2" % (
        width, height, width, height
    )

    if args.capture == "ddagrab":
        # Desktop Duplication keeps capture and scaling in D3D11 GPU memory.
        # scale_d3d11 converts BGRA desktop frames to NV12 for NVENC.
        vf = "ddagrab=output_idx=%d:framerate=%d,scale_d3d11=%s:%s:format=nv12" % (
            args.display, args.fps, width, height
        )
        common = [
            args.ffmpeg, "-hide_banner", "-loglevel", "warning",
            "-fflags", "nobuffer",
            "-filter_complex", vf,
            "-an",
        ]
    else:
        # Compatibility fallback. This captures via GDI and scales on the CPU.
        vf = "scale=%s:%s:force_original_aspect_ratio=decrease,pad=%s:%s:(ow-iw)/2:(oh-ih)/2" % (
            width, height, width, height
        )
        common = [
            args.ffmpeg, "-hide_banner", "-loglevel", "warning",
            "-fflags", "nobuffer",
            "-f", "gdigrab", "-framerate", str(args.fps), "-i", "desktop",
            "-vf", vf, "-an",
        ]
