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
    p.add_argument("--size", default="1280x720", help="encoded resolution, e.g. 1280x720")
    p.add_argument("--bitrate", default="6M")
    p.add_argument("--chunk", type=int, default=32768)
    args = p.parse_args()

    if shutil.which(args.ffmpeg) is None and args.ffmpeg == "ffmpeg":
        sys.exit("ffmpeg was not found in PATH. Install FFmpeg on Windows first.")

    width, height = args.size.lower().split("x", 1)
    vf = "scale=%s:%s:force_original_aspect_ratio=decrease,pad=%s:%s:(ow-iw)/2:(oh-ih)/2" % (
        width, height, width, height
    )
    cmd = [
        args.ffmpeg, "-hide_banner", "-loglevel", "warning",
        "-f", "gdigrab", "-framerate", str(args.fps), "-i", "desktop",
        "-vf", vf,
        "-an", "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
        "-profile:v", "baseline", "-pix_fmt", "yuv420p",
        "-b:v", args.bitrate, "-maxrate", args.bitrate, "-bufsize", args.bitrate,
        "-g", str(args.fps), "-keyint_min", str(args.fps),
        "-x264-params", "scenecut=0:slices=1:repeat-headers=1",
        "-f", "h264", "pipe:1"
    ]

    print("Connecting to %s:%d..." % (args.host, PORT))
    with socket.create_connection((args.host, PORT), timeout=5) as sock:
        sock.settimeout(None)
        print("Connected. Starting desktop capture; press Ctrl+C to stop.")
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)
        try:
            while True:
                data = proc.stdout.read(args.chunk)
                if not data:
                    break
                send_packet(sock, VIDEO_H264, data)
        except KeyboardInterrupt:
            print("\nStopping...")
        finally:
            if proc.poll() is None:
                proc.terminate()
            try:
                send_packet(sock, DISCONNECT)
            except OSError:
                pass
            proc.wait(timeout=5)

if __name__ == "__main__":
    main()
