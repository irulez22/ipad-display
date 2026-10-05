#!/usr/bin/env python3
"""Capture the Windows desktop with FFmpeg and stream H.264 to PadDisplay."""
import argparse
import ctypes
from ctypes import wintypes
import shutil
import socket
import struct
import subprocess
import sys
import threading

VIDEO_H264 = 0x01
DISCONNECT = 0x04
TOUCH_V1 = 0x10
TOUCH_V2 = 0x11
PORT = 4822
MAX_TOUCH_CONTACTS = 10

PT_TOUCH = 2
TOUCH_FEEDBACK_NONE = 0x3

POINTER_FLAG_NEW = 0x00000001
POINTER_FLAG_INRANGE = 0x00000002
POINTER_FLAG_INCONTACT = 0x00000004
POINTER_FLAG_PRIMARY = 0x00002000
POINTER_FLAG_DOWN = 0x00010000
POINTER_FLAG_UPDATE = 0x00020000
POINTER_FLAG_UP = 0x00040000

TOUCH_MASK_CONTACTAREA = 0x00000001
TOUCH_MASK_ORIENTATION = 0x00000002
TOUCH_MASK_PRESSURE = 0x00000004

PD_TOUCH_DOWN = 0
PD_TOUCH_MOVE = 1
PD_TOUCH_UP = 2
PD_TOUCH_CANCEL = 3


class POINTER_INFO(ctypes.Structure):
    _fields_ = [
        ("pointerType", wintypes.DWORD),
        ("pointerId", wintypes.UINT),
        ("frameId", wintypes.UINT),
        ("pointerFlags", wintypes.DWORD),
        ("sourceDevice", wintypes.HANDLE),
        ("hwndTarget", wintypes.HWND),
        ("ptPixelLocation", wintypes.POINT),
        ("ptHimetricLocation", wintypes.POINT),
        ("ptPixelLocationRaw", wintypes.POINT),
        ("ptHimetricLocationRaw", wintypes.POINT),
        ("dwTime", wintypes.DWORD),
        ("historyCount", wintypes.UINT),
        ("InputData", ctypes.c_int32),
        ("dwKeyStates", wintypes.DWORD),
        ("PerformanceCount", ctypes.c_uint64),
        ("ButtonChangeType", wintypes.DWORD),
    ]


class POINTER_TOUCH_INFO(ctypes.Structure):
    _fields_ = [
        ("pointerInfo", POINTER_INFO),
        ("touchFlags", wintypes.DWORD),
        ("touchMask", wintypes.DWORD),
        ("rcContact", wintypes.RECT),
        ("rcContactRaw", wintypes.RECT),
        ("orientation", wintypes.UINT),
        ("pressure", wintypes.UINT),
    ]


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
        _fields_ = [
            ("left", ctypes.c_long),
            ("top", ctypes.c_long),
            ("right", ctypes.c_long),
            ("bottom", ctypes.c_long),
        ]

    callback_type = ctypes.WINFUNCTYPE(
        ctypes.c_int,
        ctypes.c_void_p,
        ctypes.c_void_p,
        ctypes.POINTER(RECT),
        ctypes.c_longlong,
    )

    @callback_type
    def callback(hmonitor, hdc, rect_ptr, data):
        rect = rect_ptr.contents
        rects.append((rect.left, rect.top, rect.right, rect.bottom))
        return 1

    user32.EnumDisplayMonitors(None, None, callback, 0)
    matches = [
        r
        for r in rects
        if (r[2] - r[0]) == width and (r[3] - r[1]) == height
    ]
    return matches[0] if matches else None


class NativeTouchInjector:
    def __init__(self, monitor_rect, max_contacts=MAX_TOUCH_CONTACTS):
        if sys.platform != "win32":
            raise RuntimeError("Native touch injection is only available on Windows")
        if monitor_rect is None:
            raise RuntimeError("No matching Windows monitor was found for touch mapping")

        self.user32 = ctypes.windll.user32
        self.monitor_rect = monitor_rect
        self.max_contacts = max_contacts
        self.active = set()

        self.user32.InitializeTouchInjection.argtypes = [wintypes.UINT, wintypes.DWORD]
        self.user32.InitializeTouchInjection.restype = wintypes.BOOL
        self.user32.InjectTouchInput.argtypes = [
            wintypes.UINT,
            ctypes.POINTER(POINTER_TOUCH_INFO),
        ]
        self.user32.InjectTouchInput.restype = wintypes.BOOL

        if not self.user32.InitializeTouchInjection(max_contacts, TOUCH_FEEDBACK_NONE):
            raise ctypes.WinError(ctypes.get_last_error())

    def _screen_point(self, x_norm, y_norm):
        left, top, right, bottom = self.monitor_rect
        x = int(round(left + x_norm * max(1, right - left - 1)))
        y = int(round(top + y_norm * max(1, bottom - top - 1)))
        return x, y

    def _make_contact(self, contact_id, phase, x_norm, y_norm, primary=False):
        x, y = self._screen_point(x_norm, y_norm)
        contact = POINTER_TOUCH_INFO()
        pi = contact.pointerInfo
        pi.pointerType = PT_TOUCH
        pi.pointerId = int(contact_id) + 1
        pi.ptPixelLocation = wintypes.POINT(x, y)
        pi.ptPixelLocationRaw = wintypes.POINT(x, y)

        if phase == PD_TOUCH_DOWN:
            pi.pointerFlags = (
                POINTER_FLAG_NEW
                | POINTER_FLAG_INRANGE
                | POINTER_FLAG_INCONTACT
                | POINTER_FLAG_DOWN
            )
        elif phase == PD_TOUCH_MOVE:
            pi.pointerFlags = (
                POINTER_FLAG_INRANGE
                | POINTER_FLAG_INCONTACT
                | POINTER_FLAG_UPDATE
            )
        else:
            pi.pointerFlags = POINTER_FLAG_UP

        if primary:
            pi.pointerFlags |= POINTER_FLAG_PRIMARY

        contact.touchFlags = 0
        contact.touchMask = (
            TOUCH_MASK_CONTACTAREA
            | TOUCH_MASK_ORIENTATION
            | TOUCH_MASK_PRESSURE
        )
        radius = 3
        contact.rcContact = wintypes.RECT(x - radius, y - radius, x + radius, y + radius)
        contact.rcContactRaw = contact.rcContact
        contact.orientation = 90
        contact.pressure = 32000
        return contact

    def inject(self, contacts):
        if not contacts:
            return

        array_type = POINTER_TOUCH_INFO * len(contacts)
        native = array_type()

        down_ids = {c[0] for c in contacts if c[1] == PD_TOUCH_DOWN}
        future_active = set(self.active) | down_ids
        primary_id = min(future_active) if future_active else None

        for i, (contact_id, phase, x_norm, y_norm) in enumerate(contacts):
            native[i] = self._make_contact(
                contact_id,
                phase,
                x_norm,
                y_norm,
                primary=(contact_id == primary_id),
            )

        if not self.user32.InjectTouchInput(len(contacts), native):
            raise ctypes.WinError(ctypes.get_last_error())

        for contact_id, phase, _, _ in contacts:
            if phase == PD_TOUCH_DOWN:
                self.active.add(contact_id)
            elif phase in (PD_TOUCH_UP, PD_TOUCH_CANCEL):
                self.active.discard(contact_id)


def parse_touch_v2(payload):
    if not payload:
        return []
    count = payload[0]
    expected = 1 + count * 7
    if count > MAX_TOUCH_CONTACTS or len(payload) != expected:
        return []

    contacts = []
    offset = 1
    for _ in range(count):
        contact_id, phase, x_raw, y_raw = struct.unpack(
            ">HBHH", payload[offset : offset + 7]
        )
        contacts.append(
            (contact_id, phase, x_raw / 65535.0, y_raw / 65535.0)
        )
        offset += 7
    return contacts


def input_loop(sock, monitor_rect):
    if monitor_rect is None:
        print("Touch: matching stream monitor not found; touch input disabled.")
        return

    try:
        injector = NativeTouchInjector(monitor_rect)
    except Exception as exc:
        print("Touch: native injection unavailable: %s" % exc)
        return

    print("Touch: native Windows multi-touch mapped to monitor rect %s" % (monitor_rect,))

    try:
        while True:
            header = read_exactly(sock, 5)
            if header is None:
                return
            length, packet_type = struct.unpack(">IB", header)
            payload = read_exactly(sock, length)
            if payload is None:
                return

            if packet_type == TOUCH_V2:
                contacts = parse_touch_v2(payload)
                if contacts:
                    injector.inject(contacts)
            elif packet_type == TOUCH_V1 and len(payload) == 5:
                phase = payload[0]
                x = struct.unpack(">H", payload[1:3])[0] / 65535.0
                y = struct.unpack(">H", payload[3:5])[0] / 65535.0
                injector.inject([(0, phase, x, y)])
    except (OSError, RuntimeError):
        return
    except Exception as exc:
        print("Touch injection error: %s" % exc)


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
            width,
            height,
            width,
            height,
        )
        capture = [
            "-f",
            "gdigrab",
            "-framerate",
            str(args.fps),
            "-i",
            "desktop",
            "-vf",
            vf,
        ]

    if args.encoder == "nvenc":
        encode = [
            "-c:v",
            "h264_nvenc",
            "-preset",
            "p1",
            "-tune",
            "ull",
            "-profile:v",
            "baseline",
        ] + ([] if args.capture == "ddagrab" else [
            "-pix_fmt",
            "yuv420p",
        ]) + [
            "-rc",
            "cbr",
            "-b:v",
            args.bitrate,
            "-maxrate",
            args.bitrate,
            "-bufsize",
            args.bitrate,
            "-g",
            str(args.fps),
            "-bf",
            "0",
            "-zerolatency",
            "1",
            "-delay",
            "0",
            "-forced-idr",
            "1",
            "-aud",
            "1",
        ]
    else:
        encode = [
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-tune",
            "zerolatency",
            "-profile:v",
            "baseline",
            "-pix_fmt",
            "yuv420p",
            "-b:v",
            args.bitrate,
            "-maxrate",
            args.bitrate,
            "-bufsize",
            args.bitrate,
            "-g",
            str(args.fps),
            "-keyint_min",
            str(args.fps),
            "-x264-params",
            "scenecut=0:slices=1:repeat-headers=1:aud=1:bframes=0",
        ]

    cmd = [
        args.ffmpeg,
        "-hide_banner",
        "-loglevel",
        "warning",
        "-fflags",
        "nobuffer",
    ] + capture + ["-an"] + encode + ["-f", "h264", "pipe:1"]

    print("Connecting to %s:%d..." % (args.host, PORT))
    print(
        "Capture: %s%s, encoder: %s, resolution: %s, fps: %d, bitrate: %s"
        % (
            args.capture,
            (
                " adapter %d display %d" % (args.adapter, args.display)
                if args.capture == "ddagrab" and args.adapter is not None
                else " display %d" % args.display
                if args.capture == "ddagrab"
                else ""
            ),
            args.encoder,
            args.size,
            args.fps,
            args.bitrate,
        )
    )

    with socket.create_connection((args.host, PORT), timeout=5) as sock:
        sock.settimeout(None)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

        monitor_rect = find_touch_monitor(width_i, height_i)
        touch_thread = threading.Thread(
            target=input_loop,
            args=(sock, monitor_rect),
            daemon=True,
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
