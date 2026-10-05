#!/usr/bin/env python3
"""Capture the Windows desktop with FFmpeg and stream H.264 to PadDisplay."""
import argparse
import ctypes
import shutil
import socket
import struct
import subprocess
import sys
import threading

VIDEO_H264 = 0x01
DISCONNECT = 0x04
TOUCH = 0x10
PORT = 4822

MOUSEEVENTF_MOVE = 0x0001
MOUSEEVENTF_LEFTDOWN = 0x0002
MOUSEEVENTF_LEFTUP = 0x0004
MOUSEEVENTF_ABSOLUTE = 0x8000
MOUSEEVENTF_VIRTUALDESK = 0x4000
SM_XVIRTUALSCREEN = 76
SM_YVIRTUALSCREEN = 77
SM_CXVIRTUALSCREEN = 78
SM_CYVIRTUALSCREEN = 79

def send_packet(sock, packet_type, payload=b""):
    sock.sendall(struct.pack(">IB", len(payload), packet_type) + payload)

def read_exactly(sock, length):
    chunks = []
    left = length
    while left:
        data = sock.recv(left)
        if not data:
            return None
        chunks.append(data)
        left -= len(data)
    return b"".join(chunks)

def find_touch_monitor(width, height):
    if sys.platform != "win32":
        return None

    user32 = ctypes.windll.user32
    rects = []

    class RECT(ctypes.Structure):
        _fields_ = [("left", ctypes.c_long), ("top", ctypes.c_long),
                    ("right", ctypes.c_long), ("bottom", ctypes.c_long)]

    callback_type = ctypes.WINFUNCTYPE(
        ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p,
        ctypes.POINTER(RECT), ctypes.c_longlong
    )

    @callback_type
    def callback(hmonitor, hdc, rect_ptr, data):
        rect = rect_ptr.contents
        rects.append((rect.left, rect.top, rect.right, rect.bottom))
        return 1

    user32.EnumDisplayMonitors(None, None, callback, 0)
    matches = [
        r for r in rects
        if (r[2] - r[0]) == width and (r[3] - r[1]) == height
    ]
    return matches[0] if matches else None

def inject_touch_as_mouse(x_norm, y_norm, monitor_rect):
    if sys.platform != "win32" or monitor_rect is None:
        return

    user32 = ctypes.windll.user32
    left, top, right, bottom = monitor_rect
    px = left + x_norm * max(1, (right - left - 1))
    py = top + y_norm * max(1, (bottom - top - 1))

    vx = user32.GetSystemMetrics(SM_XVIRTUALSCREEN)
    vy = user32.GetSystemMetrics(SM_YVIRTUALSCREEN)
    vw = user32.GetSystemMetrics(SM_CXVIRTUALSCREEN)
    vh = user32.GetSystemMetrics(SM_CYVIRTUALSCREEN)

    ax = int(round((px - vx) * 65535.0 / max(1, vw - 1)))
    ay = int(round((py - vy) * 65535.0 / max(1, vh - 1)))
    user32.mouse_event(
        MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK,
        ax, ay, 0, 0
    )

def input_loop(sock, monitor_rect):
    if monitor_rect is None:
        print("Touch: no 1280x960 monitor found; touch input disabled.")
        return

    print("Touch: mapped to monitor rect %s" % (monitor_rect,))
    user32 = ctypes.windll.user32 if sys.platform == "win32" else None

    try:
        while True:
            header = read_exactly(sock, 5)
            if header is None:
                return
            length, packet_type = struct.unpack(">IB", header)
            payload = read_exactly(sock, length)
            if payload is None:
                return

            if packet_type != TOUCH or len(payload) != 5:
                continue

            phase = payload[0]
            x = struct.unpack(">H", payload[1:3])[0] / 65535.0
            y = struct.unpack(">H", payload[3:5])[0] / 65535.0

            inject_touch_as_mouse(x, y, monitor_rect)

            if user32 is not None:
                if phase == 0:
                    user32.mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
                elif phase in (2, 3):
                    user32.mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)
    except OSError:
        return

def main():
    p = argparse.ArgumentParser(description="Stream the Windows desktop to PadDisplay")
    p.add_argument("host", help="iPad IP address")
    p.add_argument("--ffmpeg", default="ffmpeg", help="FFmpeg executable/path")
    p.add_argument("--fps", type=int, default=60)
    p.add_argument("--size", default="1280x960")
    p.add_argument("--bitrate", default="6M")
    p.add_argument("--chunk", type=int, default=4096)
    p.add_argument("--encoder", choices=("nvenc", "x264"), default="nvenc")
    p.add_argument("--capture", choices=("ddagrab", "gdigrab"), default="ddagrab")
    p.add_argument("--display", type=int, default=0, help="DXGI output index on the selected adapter")
    p.add_argument("--adapter", type=int, default=None, help="Direct3D 11 adapter index for ddagrab")
    args = p.parse_args()

    if shutil.which(args.ffmpeg) is None and args.ffmpeg == "ffmpeg":
        sys.exit("ffmpeg was not found in PATH.")

    width, height = args.size.lower().split("x", 1)
    width_i, height_i = int(width), int(height)

    if args.capture == "ddagrab":
        capture = []
        if args.adapter is not None:
            capture += [
                "-init_hw_device", "d3d11va=grab:%d" % args.adapter,
                "-filter_hw_device", "grab",
            ]
        capture += [
            "-filter_complex",
            "ddagrab=output_idx=%d:framerate=%d" % (args.display, args.fps),
        ]
    else:
        vf = "scale=%s:%s:force_original_aspect_ratio=decrease,pad=%s:%s:(ow-iw)/2:(oh-ih)/2" % (
            width, height, width, height
        )
        capture = [
            "-f", "gdigrab", "-framerate", str(args.fps), "-i", "desktop",
            "-vf", vf,
        ]

    if args.encoder == "nvenc":
        encode = [
            "-c:v", "h264_nvenc",
            "-preset", "p1",
            "-tune", "ull",
            "-profile:v", "baseline",
        ] + ([] if args.capture == "ddagrab" else [
            "-pix_fmt", "yuv420p",
        ]) + [
            "-rc", "cbr",
            "-b:v", args.bitrate,
            "-maxrate", args.bitrate,
            "-bufsize", args.bitrate,
            "-g", str(args.fps),
            "-bf", "0",
            "-zerolatency", "1",
            "-delay", "0",
            "-forced-idr", "1",
            "-aud", "1",
        ]
    else:
        encode = [
            "-c:v", "libx264",
            "-preset", "ultrafast",
            "-tune", "zerolatency",
            "-profile:v", "baseline",
            "-pix_fmt", "yuv420p",
            "-b:v", args.bitrate,
            "-maxrate", args.bitrate,
            "-bufsize", args.bitrate,
            "-g", str(args.fps),
            "-keyint_min", str(args.fps),
            "-x264-params", "scenecut=0:slices=1:repeat-headers=1:aud=1:bframes=0",
        ]

    cmd = [
        args.ffmpeg, "-hide_banner", "-loglevel", "warning", "-fflags", "nobuffer"
    ] + capture + ["-an"] + encode + ["-f", "h264", "pipe:1"]

    print("Connecting to %s:%d..." % (args.host, PORT))
    print("Capture: %s%s, encoder: %s, resolution: %s, fps: %d, bitrate: %s" % (
        args.capture,
        (" adapter %d display %d" % (args.adapter, args.display)
         if args.capture == "ddagrab" and args.adapter is not None
         else " display %d" % args.display if args.capture == "ddagrab" else ""),
        args.encoder, args.size, args.fps, args.bitrate
    ))

    with socket.create_connection((args.host, PORT), timeout=5) as sock:
        sock.settimeout(None)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

        monitor_rect = find_touch_monitor(width_i, height_i)
        touch_thread = threading.Thread(
            target=input_loop, args=(sock, monitor_rect), daemon=True
        )
        touch_thread.start()

        print("Connected. Starting desktop capture; press Ctrl+C to stop.")
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, bufsize=0)
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
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()

if __name__ == "__main__":
    main()
