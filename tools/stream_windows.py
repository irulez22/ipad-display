#!/usr/bin/env python3
"""Capture the Windows desktop with FFmpeg and stream H.264 to PadDisplay."""
import argparse
import json
from contextlib import ExitStack
import os
import ctypes
from ctypes import wintypes
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
import uuid

VIDEO_H264 = 0x01
DISCONNECT = 0x04
AUDIO_PCM = 0x20
AUDIO_PCM_V2 = 0x21
AUDIO_FORMAT = 0x22
CONFIG = 0x03
PROTOCOL_VERSION = 1
TOUCH_V1 = 0x10
TOUCH_V2 = 0x11
MOUSE_V1 = 0x12
KEYBOARD_V1 = 0x13
PORT = 4822
AUDIO_PORT = 4824
MAX_TOUCH_CONTACTS = 10
MAX_PAYLOAD = 8 * 1024 * 1024
SM_XVIRTUALSCREEN = 76
SM_YVIRTUALSCREEN = 77

PT_TOUCH = 2
TOUCH_FEEDBACK_DEFAULT = 0x1

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

# The launcher passes physical monitor coordinates. Keep this Python process in
# the same coordinate space before any GetSystemMetrics/SendInput calls.
if sys.platform == "win32":
    try:
        ctypes.windll.user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
    except Exception:
        try:
            ctypes.windll.shcore.SetProcessDpiAwareness(2)
        except Exception:
            try:
                ctypes.windll.user32.SetProcessDPIAware()
            except Exception:
                pass


class StreamStats:
    def __init__(self):
        self.lock = threading.Lock()
        self.video_bytes = 0
        self.audio_bytes = 0
        self.touch_packets = 0
        self.started = time.monotonic()
        self.last_video = None
        self.last_audio = None
        self.ipad_hello = {}

    def add_video(self, count):
        with self.lock:
            self.video_bytes += count
            self.last_video = time.monotonic()

    def add_audio(self, count):
        with self.lock:
            self.audio_bytes += count
            self.last_audio = time.monotonic()

    def add_touch(self):
        with self.lock:
            self.touch_packets += 1

    def set_ipad_hello(self, hello):
        with self.lock:
            self.ipad_hello.update(hello or {})

    def snapshot(self):
        with self.lock:
            return (
                self.video_bytes,
                self.audio_bytes,
                self.touch_packets,
                self.started,
                self.last_video,
                self.last_audio,
                dict(self.ipad_hello),
            )


def watchdog_loop(stats, proc, stop_event, stall_seconds=5.0):
    while not stop_event.wait(1.0):
        _, _, _, started, last_video, _, _ = stats.snapshot()
        now = time.monotonic()
        if last_video is None:
            if now - started > stall_seconds:
                print("Watchdog: no video produced for %.1fs; restarting streamer." % stall_seconds, flush=True)
                if proc.poll() is None:
                    proc.terminate()
                return
        elif now - last_video > stall_seconds:
            print("Watchdog: video stalled for %.1fs; restarting streamer." % (now - last_video), flush=True)
            if proc.poll() is None:
                proc.terminate()
            return


def status_loop(stats, stop_event, status_file=None, transport="unknown", host="unknown"):
    last_video = 0
    last_audio = 0
    last_sample = time.monotonic()
    while not stop_event.wait(1.0):
        video, audio, touches, started, last_video_time, last_audio_time, ipad_hello = stats.snapshot()
        sample_time = time.monotonic()
        interval = max(0.001, sample_time - last_sample)
        video_mbps = (video - last_video) * 8.0 / 1000000.0 / interval
        audio_kbps = (audio - last_audio) * 8.0 / 1000.0 / interval
        last_sample = sample_time
        elapsed = int(time.monotonic() - started)
        now = time.monotonic()
        video_age = "-" if last_video_time is None else "%.1fs" % (now - last_video_time)
        audio_age = "-" if last_audio_time is None else "%.1fs" % (now - last_audio_time)
        print(
            "Status: %ds | video %.2f Mbps age %s | audio %.0f kbps age %s | touch packets %d"
            % (elapsed, video_mbps, video_age, audio_kbps, audio_age, touches),
            flush=True,
        )
        if status_file:
            payload = {
                "state": "running",
                "transport": transport,
                "host": host,
                "uptime_s": elapsed,
                "video_mbps": round(video_mbps, 3),
                "audio_kbps": round(audio_kbps, 1),
                "video_age_s": None if last_video_time is None else round(now - last_video_time, 2),
                "audio_age_s": None if last_audio_time is None else round(now - last_audio_time, 2),
                "touch_packets": touches,
                "protocol": ipad_hello.get("protocol"),
                "ipad_app": ipad_hello.get("app"),
                "ipad_build": ipad_hello.get("build"),
                "ipad_name": ipad_hello.get("name"),
                "ipad_device": ipad_hello.get("device"),
                "ipad_width": ipad_hello.get("width"),
                "ipad_height": ipad_hello.get("height"),
                "battery_percent": ipad_hello.get("battery_percent"),
                "battery_state": ipad_hello.get("battery_state"),
                "updated_unix": time.time(),
            }
            try:
                directory = os.path.dirname(status_file)
                if directory:
                    os.makedirs(directory, exist_ok=True)
                temp_path = status_file + ".tmp"
                with open(temp_path, "w", encoding="utf-8") as handle:
                    json.dump(payload, handle, separators=(",", ":"))
                os.replace(temp_path, status_file)
            except OSError:
                pass
        last_video = video
        last_audio = audio


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


class POINTER_TYPE_INFO_UNION(ctypes.Union):
    _fields_ = [("touchInfo", POINTER_TOUCH_INFO)]


class POINTER_TYPE_INFO(ctypes.Structure):
    _anonymous_ = ("info",)
    _fields_ = [
        ("type", wintypes.DWORD),
        ("info", POINTER_TYPE_INFO_UNION),
    ]


# SendInput requires the full union size even when sending only a keyboard event.
class MOUSEINPUT(ctypes.Structure):
    _fields_ = [
        ("dx", ctypes.c_int32), ("dy", ctypes.c_int32),
        ("mouseData", ctypes.c_uint32), ("dwFlags", ctypes.c_uint32),
        ("time", ctypes.c_uint32), ("dwExtraInfo", ctypes.c_size_t),
    ]


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [
        ("wVk", ctypes.c_uint16), ("wScan", ctypes.c_uint16),
        ("dwFlags", ctypes.c_uint32), ("time", ctypes.c_uint32),
        ("dwExtraInfo", ctypes.c_size_t),
    ]


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [
        ("uMsg", ctypes.c_uint32), ("wParamL", ctypes.c_uint16),
        ("wParamH", ctypes.c_uint16),
    ]


class INPUTUNION(ctypes.Union):
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("hi", HARDWAREINPUT)]


class INPUT(ctypes.Structure):
    _anonymous_ = ("u",)
    _fields_ = [("type", ctypes.c_uint32), ("u", INPUTUNION)]


def bitrate_to_bits_per_second(value):
    text = str(value).strip().lower()
    multiplier = 1
    if text.endswith("k"):
        multiplier = 1000
        text = text[:-1]
    elif text.endswith("m"):
        multiplier = 1000 * 1000
        text = text[:-1]
    elif text.endswith("g"):
        multiplier = 1000 * 1000 * 1000
        text = text[:-1]
    result = int(float(text) * multiplier)
    if result <= 0:
        raise ValueError("bitrate must be positive")
    return result


def one_frame_vbv(bitrate, fps):
    bits_per_second = bitrate_to_bits_per_second(bitrate)
    bits_per_frame = max(64000, int(round(bits_per_second / max(1, fps))))
    return "%dk" % max(1, int(round(bits_per_frame / 1000.0)))


def send_packet(sock, packet_type, payload=b"", lock=None):
    if len(payload) > MAX_PAYLOAD:
        raise ValueError("packet exceeds 8 MiB limit")
    frame = struct.pack(">IB", len(payload), packet_type) + payload
    if lock is None:
        sock.sendall(frame)
    else:
        with lock:
            sock.sendall(frame)


def read_exactly(sock, length):
    if not 0 <= length <= MAX_PAYLOAD:
        raise ValueError("packet length must be between 0 and 8 MiB")
    chunks = []
    left = length
    while left:
        try:
            data = sock.recv(left)
        except socket.timeout:
            continue
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

        self.user32 = ctypes.WinDLL("user32", use_last_error=True)
        self.monitor_rect = monitor_rect
        self.max_contacts = max_contacts
        self.active = {}
        self.synthetic_device = None

        create_synth = getattr(self.user32, "CreateSyntheticPointerDevice", None)
        inject_synth = getattr(self.user32, "InjectSyntheticPointerInput", None)
        if create_synth is not None and inject_synth is not None:
            create_synth.argtypes = [wintypes.DWORD, wintypes.ULONG, wintypes.DWORD]
            create_synth.restype = wintypes.HANDLE
            inject_synth.argtypes = [
                wintypes.HANDLE,
                ctypes.POINTER(POINTER_TYPE_INFO),
                wintypes.UINT,
            ]
            inject_synth.restype = wintypes.BOOL
            device = create_synth(PT_TOUCH, max_contacts, TOUCH_FEEDBACK_DEFAULT)
            if device:
                self.synthetic_device = device
                self.inject_synthetic = inject_synth

        if self.synthetic_device is None:
            self.user32.InitializeTouchInjection.argtypes = [wintypes.UINT, wintypes.DWORD]
            self.user32.InitializeTouchInjection.restype = wintypes.BOOL
            self.user32.InjectTouchInput.argtypes = [
                wintypes.UINT,
                ctypes.POINTER(POINTER_TOUCH_INFO),
            ]
            self.user32.InjectTouchInput.restype = wintypes.BOOL

            if not self.user32.InitializeTouchInjection(max_contacts, TOUCH_FEEDBACK_DEFAULT):
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
                POINTER_FLAG_INRANGE
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

        # Keep optional touch fields disabled until the basic injection path is
        # stable. Windows only reads rcContact/orientation/pressure when the
        # corresponding touchMask bits are set.
        contact.touchFlags = 0
        contact.touchMask = 0
        return contact

    def inject(self, contacts):
        if not contacts:
            return

        changes = {contact_id: (phase, x, y) for contact_id, phase, x, y in contacts}

        # InjectTouchInput expects each frame to describe all contacts on the
        # desktop, not just the contacts that changed since the previous frame.
        frame = []

        # Existing contacts first. UP/CANCEL must use the previous injected
        # position or Windows rejects the whole sequence.
        for contact_id, (old_x, old_y) in list(self.active.items()):
            if contact_id in changes:
                phase, new_x, new_y = changes[contact_id]
                if phase in (PD_TOUCH_UP, PD_TOUCH_CANCEL):
                    frame.append((contact_id, phase, old_x, old_y))
                else:
                    frame.append((contact_id, PD_TOUCH_MOVE, new_x, new_y))
            else:
                frame.append((contact_id, PD_TOUCH_MOVE, old_x, old_y))

        # Add genuinely new contacts.
        for contact_id, (phase, x, y) in changes.items():
            if contact_id not in self.active and phase == PD_TOUCH_DOWN:
                frame.append((contact_id, PD_TOUCH_DOWN, x, y))

        if not frame:
            return

        active_after = set(self.active)
        for contact_id, phase, _, _ in frame:
            if phase == PD_TOUCH_DOWN:
                active_after.add(contact_id)
            elif phase in (PD_TOUCH_UP, PD_TOUCH_CANCEL):
                active_after.discard(contact_id)
        primary_id = min(set(self.active) | {c[0] for c in frame if c[1] == PD_TOUCH_DOWN}) if (self.active or any(c[1] == PD_TOUCH_DOWN for c in frame)) else None

        array_type = POINTER_TOUCH_INFO * len(frame)
        native = array_type()
        for i, (contact_id, phase, x_norm, y_norm) in enumerate(frame):
            native[i] = self._make_contact(
                contact_id,
                phase,
                x_norm,
                y_norm,
                primary=(contact_id == primary_id),
            )

        ctypes.set_last_error(0)
        if self.synthetic_device is not None:
            vx = self.user32.GetSystemMetrics(SM_XVIRTUALSCREEN)
            vy = self.user32.GetSystemMetrics(SM_YVIRTUALSCREEN)
            synth_type = POINTER_TYPE_INFO * len(frame)
            synth = synth_type()
            for i in range(len(frame)):
                synth[i].type = PT_TOUCH
                synth[i].touchInfo = native[i]
                synth[i].touchInfo.pointerInfo.ptPixelLocation.x -= vx
                synth[i].touchInfo.pointerInfo.ptPixelLocation.y -= vy
                synth[i].touchInfo.pointerInfo.ptPixelLocationRaw.x -= vx
                synth[i].touchInfo.pointerInfo.ptPixelLocationRaw.y -= vy
            if not self.inject_synthetic(self.synthetic_device, synth, len(frame)):
                raise ctypes.WinError(ctypes.get_last_error())
        else:
            if not self.user32.InjectTouchInput(len(frame), native):
                raise ctypes.WinError(ctypes.get_last_error())

        for contact_id, phase, x_norm, y_norm in frame:
            if phase in (PD_TOUCH_DOWN, PD_TOUCH_MOVE):
                self.active[contact_id] = (x_norm, y_norm)
            elif phase in (PD_TOUCH_UP, PD_TOUCH_CANCEL):
                self.active.pop(contact_id, None)


def parse_touch_v2(payload):
    if not payload:
        return []
    count = payload[0]
    expected = 1 + count * 7
    if count > MAX_TOUCH_CONTACTS or len(payload) != expected:
        return []

    contacts = []
    seen = set()
    offset = 1
    for _ in range(count):
        contact_id, phase, x_raw, y_raw = struct.unpack(
            ">HBHH", payload[offset : offset + 7]
        )
        if phase not in (0, 1, 2, 3) or contact_id in seen:
            return []
        seen.add(contact_id)
        contacts.append(
            (contact_id, phase, x_raw / 65535.0, y_raw / 65535.0)
        )
        offset += 7
    return contacts


def _monitor_point(monitor_rect, x_raw, y_raw):
    left, top, right, bottom = monitor_rect
    x = int(round(left + (x_raw / 65535.0) * max(1, right - left - 1)))
    y = int(round(top + (y_raw / 65535.0) * max(1, bottom - top - 1)))
    return x, y


def inject_mouse_packet(payload, monitor_rect):
    if sys.platform != "win32" or monitor_rect is None or len(payload) != 8:
        return False

    action, button, x_raw, y_raw, wheel = struct.unpack(">BBHHh", payload)
    if action not in (0, 1, 2, 3) or button > 5:
        return False
    if action in (1, 2) and button == 0:
        return False
    x, y = _monitor_point(monitor_rect, x_raw, y_raw)

    user32 = ctypes.WinDLL("user32", use_last_error=True)
    INPUT_MOUSE = 0
    MOUSEEVENTF_MOVE = 0x0001
    MOUSEEVENTF_LEFTDOWN = 0x0002
    MOUSEEVENTF_LEFTUP = 0x0004
    MOUSEEVENTF_RIGHTDOWN = 0x0008
    MOUSEEVENTF_RIGHTUP = 0x0010
    MOUSEEVENTF_MIDDLEDOWN = 0x0020
    MOUSEEVENTF_MIDDLEUP = 0x0040
    MOUSEEVENTF_WHEEL = 0x0800
    MOUSEEVENTF_XDOWN = 0x0080
    MOUSEEVENTF_XUP = 0x0100
    MOUSEEVENTF_ABSOLUTE = 0x8000
    MOUSEEVENTF_VIRTUALDESK = 0x4000
    XBUTTON1 = 0x0001
    XBUTTON2 = 0x0002

    vx = user32.GetSystemMetrics(76)
    vy = user32.GetSystemMetrics(77)
    vw = max(1, user32.GetSystemMetrics(78))
    vh = max(1, user32.GetSystemMetrics(79))
    dx = int(round((x - vx) * 65535.0 / max(1, vw - 1)))
    dy = int(round((y - vy) * 65535.0 / max(1, vh - 1)))

    flags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK
    data = 0
    if action == 1:
        flags |= {1:MOUSEEVENTF_LEFTDOWN, 2:MOUSEEVENTF_RIGHTDOWN, 3:MOUSEEVENTF_MIDDLEDOWN,
                  4:MOUSEEVENTF_XDOWN, 5:MOUSEEVENTF_XDOWN}.get(button, 0)
        if button == 4: data = XBUTTON1
        elif button == 5: data = XBUTTON2
    elif action == 2:
        flags |= {1:MOUSEEVENTF_LEFTUP, 2:MOUSEEVENTF_RIGHTUP, 3:MOUSEEVENTF_MIDDLEUP,
                  4:MOUSEEVENTF_XUP, 5:MOUSEEVENTF_XUP}.get(button, 0)
        if button == 4: data = XBUTTON1
        elif button == 5: data = XBUTTON2
    elif action == 3:
        flags |= MOUSEEVENTF_WHEEL
        data = ctypes.c_uint32(ctypes.c_int32(wheel).value).value

    inp = INPUT()
    inp.type = INPUT_MOUSE
    inp.mi = MOUSEINPUT(dx, dy, data, flags, 0, 0)
    sent = user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))
    if sent != 1:
        raise ctypes.WinError(ctypes.get_last_error())
    return True


def inject_keyboard_packet(payload):
    if sys.platform != "win32" or len(payload) != 6:
        return False

    action, vk, scan, flags = struct.unpack(">BHHB", payload)
    if action not in (0, 1) or flags & ~1 or vk > 255 or scan > 255:
        return False
    if not vk and not scan:
        return False
    user32 = ctypes.WinDLL("user32", use_last_error=True)
    INPUT_KEYBOARD = 1
    KEYEVENTF_EXTENDEDKEY = 0x0001
    KEYEVENTF_KEYUP = 0x0002
    KEYEVENTF_SCANCODE = 0x0008

    dw_flags = KEYEVENTF_SCANCODE if scan else 0
    if flags & 0x01:
        dw_flags |= KEYEVENTF_EXTENDEDKEY
    if action == 1:
        dw_flags |= KEYEVENTF_KEYUP

    inp = INPUT()
    inp.type = INPUT_KEYBOARD
    inp.ki = KEYBDINPUT(0 if scan else vk, scan, dw_flags, 0, 0)
    sent = user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))
    if sent != 1:
        raise ctypes.WinError(ctypes.get_last_error())
    return True


def input_loop(sock, monitor_rect, stats=None):
    # Laptop mouse/keyboard input must never depend on the optional touch
    # injector. Touch is initialized lazily and only used for TOUCH_* packets.
    injector = None
    touch_init_attempted = False
    saw_touch = False

    def get_touch_injector():
        nonlocal injector, touch_init_attempted
        if touch_init_attempted:
            return injector
        touch_init_attempted = True
        if monitor_rect is None:
            print("Touch: no matching stream monitor; touch packets disabled (mouse/keyboard remain enabled).")
            return None
        try:
            injector = NativeTouchInjector(monitor_rect)
            print("Touch: native Windows multi-touch mapped to monitor rect %s" % (monitor_rect,))
            print("Touch injector: %s" % (
                "synthetic pointer device" if injector.synthetic_device is not None
                else "legacy InjectTouchInput fallback"
            ))
        except Exception as exc:
            print("Touch: native injection unavailable: %s (mouse/keyboard remain enabled)." % exc)
            injector = None
        return injector

    print("Input: laptop mouse, wheel and keyboard enabled.")
    try:
        while True:
            header = read_exactly(sock, 5)
            if header is None:
                return
            length, packet_type = struct.unpack(">IB", header)
            payload = read_exactly(sock, length)
            if payload is None:
                return

            if packet_type == DISCONNECT:
                return
            if packet_type == CONFIG:
                try:
                    text = payload.decode("utf-8", "replace")
                    print("Client hello: %s" % text, flush=True)
                    try:
                        hello = json.loads(text)
                        if stats is not None and isinstance(hello, dict):
                            stats.set_ipad_hello(hello)
                    except Exception:
                        pass
                except Exception:
                    pass
            elif packet_type == MOUSE_V1:
                if inject_mouse_packet(payload, monitor_rect) and stats is not None:
                    stats.add_touch()
            elif packet_type == KEYBOARD_V1:
                inject_keyboard_packet(payload)
            elif packet_type == TOUCH_V2:
                touch = get_touch_injector()
                contacts = parse_touch_v2(payload)
                if touch is not None and contacts:
                    if not saw_touch:
                        print("Touch: received first TOUCH_V2 packet (%d contact(s))." % len(contacts))
                        saw_touch = True
                    touch.inject(contacts)
                    if stats is not None:
                        stats.add_touch()
            elif packet_type == TOUCH_V1 and len(payload) == 5:
                touch = get_touch_injector()
                if touch is not None:
                    phase = payload[0]
                    x = struct.unpack(">H", payload[1:3])[0] / 65535.0
                    y = struct.unpack(">H", payload[3:5])[0] / 65535.0
                    touch.inject([(0, phase, x, y)])
                    if stats is not None:
                        stats.add_touch()
    except (OSError, RuntimeError, ValueError):
        return
    except Exception as exc:
        print("Input injection error: %s" % exc)


def audio_loop(host, port, helper_path, ffmpeg_path, stats=None):
    with ExitStack() as resources:
        _audio_loop(host, port, helper_path, ffmpeg_path, stats, resources)


def stop_process(proc):
    if proc.poll() is None:
        proc.terminate()
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    for pipe in (proc.stdin, proc.stdout, proc.stderr):
        if pipe is not None:
            pipe.close()


def _audio_loop(host, port, helper_path, ffmpeg_path, stats, resources):
    print("Audio: connecting dedicated stream to %s:%d..." % (host, port))
    audio_sock = None
    deadline = time.monotonic() + 5.0
    last_error = None
    while audio_sock is None and time.monotonic() < deadline:
        try:
            audio_sock = socket.create_connection((host, port), timeout=1)
        except (ConnectionRefusedError, ConnectionAbortedError, ConnectionResetError, TimeoutError, OSError) as exc:
            last_error = exc
            time.sleep(0.1)
    if audio_sock is None:
        print("Audio: dedicated connection failed after retries: %s" % last_error, flush=True)
        return
    resources.callback(audio_sock.close)
    audio_sock.settimeout(5)
    audio_sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    hello = ('{"protocol":%d,"host":"windows","channel":"audio","audio_pcm_v2":true}' %
             PROTOCOL_VERSION).encode("utf-8")
    send_packet(audio_sock, CONFIG, hello)
    print("Audio: Wi-Fi mirror enabled on dedicated TCP stream (48 kHz stereo PCM v2).")
    try:
        proc = subprocess.Popen(
            [helper_path],
            stdout=subprocess.PIPE,
            stderr=None,
            bufsize=0,
        )
    except Exception as exc:
        print("Audio: could not start WASAPI loopback helper: %s" % exc)
        return

    resources.callback(stop_process, proc)

    # The helper begins stdout with one ASCII metadata line, then raw native
    # WASAPI mix-format samples.
    header = proc.stdout.readline(256)
    if not header:
        try:
            proc.wait(timeout=1)
        except Exception:
            pass
        print("Audio: WASAPI helper exited before format handshake (code %s)." %
              proc.poll(), flush=True)
        return

    try:
        parts = header.decode("ascii", "strict").strip().split()
        if len(parts) != 5 or parts[0] != "PDAUDIO":
            raise ValueError("unexpected helper header %r" % header)
        sample_rate = int(parts[1])
        channels = int(parts[2])
        format_name = parts[3]
        block_align = int(parts[4])
        sample_bytes = {"s16": 2, "s32": 4, "f32": 4}[format_name]
        if not 8000 <= sample_rate <= 384000 or not 1 <= channels <= 32 or block_align != channels * sample_bytes:
            raise ValueError("invalid helper format")
    except Exception as exc:
        print("Audio: invalid WASAPI helper format handshake: %s" % exc, flush=True)
        return

    input_formats = {"s16": "s16le", "s32": "s32le", "f32": "f32le"}
    ffmpeg_input_format = input_formats[format_name]

    # Let FFmpeg/libswresample own all sample-format/channel/rate conversion.
    # The network wire format stays fixed at 48 kHz stereo signed 16-bit PCM.
    convert_cmd = [
        ffmpeg_path,
        "-hide_banner",
        "-loglevel", "warning",
        "-f", ffmpeg_input_format,
        "-ar", str(sample_rate),
        "-ac", str(channels),
        "-i", "pipe:0",
        "-vn",
        "-af", "aresample=48000:async=1:first_pts=0",
        "-ar", "48000",
        "-ac", "2",
        "-f", "s16le",
        "-flush_packets", "1",
        "pipe:1",
    ]
    try:
        converter = subprocess.Popen(
            convert_cmd,
            stdin=proc.stdout,
            stdout=subprocess.PIPE,
            stderr=None,
            bufsize=0,
        )
    except Exception as exc:
        print("Audio: could not start FFmpeg audio converter: %s" % exc, flush=True)
        return

    resources.callback(stop_process, converter)

    # Tell Linux only about the canonical converted wire format.
    send_packet(
        audio_sock,
        AUDIO_FORMAT,
        struct.pack(">IBBH", 48000, 2, 1, 4),
    )
    print(
        "Audio: WASAPI %d Hz, %d ch, %s -> FFmpeg -> 48000 Hz stereo s16le."
        % (sample_rate, channels, format_name),
        flush=True,
    )

    chunk = 3840  # 20 ms of 48 kHz stereo s16le
    pending = bytearray()
    sequence = 0
    try:
        while True:
            data = converter.stdout.read(chunk)
            if not data:
                break

            pending.extend(data)
            while len(pending) >= chunk:
                pcm = bytes(pending[:chunk])
                timestamp_us = int(time.monotonic() * 1000000.0)
                payload = struct.pack(">IQ", sequence & 0xffffffff, timestamp_us) + pcm
                send_packet(audio_sock, AUDIO_PCM_V2, payload)
                sequence = (sequence + 1) & 0xffffffff
                if stats is not None:
                    stats.add_audio(chunk)
                del pending[:chunk]

        usable = len(pending) - (len(pending) % 4)
        if usable:
            pcm = bytes(pending[:usable])
            timestamp_us = int(time.monotonic() * 1000000.0)
            payload = struct.pack(">IQ", sequence & 0xffffffff, timestamp_us) + pcm
            send_packet(audio_sock, AUDIO_PCM_V2, payload)
            if stats is not None:
                stats.add_audio(usable)

        converter_rc = converter.wait(timeout=2)
        if converter_rc != 0:
            print("Audio: FFmpeg converter exited with code %d." % converter_rc, flush=True)
    except (ConnectionAbortedError, ConnectionResetError, BrokenPipeError, OSError):
        pass
    finally:
        try:
            send_packet(audio_sock, DISCONNECT)
        except OSError:
            pass
        try:
            audio_sock.close()
        except OSError:
            pass


def main():
    p = argparse.ArgumentParser(description="Stream the Windows desktop to PadDisplay")
    p.add_argument("host", help="iPad IP address or localhost proxy")
    p.add_argument("--port", type=int, default=PORT, help="TCP port")
    p.add_argument("--ffmpeg", default="ffmpeg", help="FFmpeg executable/path")
    p.add_argument("--fps", type=int, default=60)
    p.add_argument("--size", default="1280x960")
    p.add_argument("--bitrate", default="6M")
    p.add_argument("--chunk", type=int, default=16384)
    p.add_argument("--encoder", choices=("nvenc", "x264"), default="nvenc")
    p.add_argument("--capture", choices=("ddagrab", "gdigrab"), default="ddagrab")
    p.add_argument("--display", type=int, default=0, help="DXGI output index on the selected adapter")
    p.add_argument("--adapter", type=int, default=None, help="Direct3D 11 adapter index for ddagrab")
    p.add_argument("--touch-left", type=int, default=None)
    p.add_argument("--touch-top", type=int, default=None)
    p.add_argument("--touch-width", type=int, default=None)
    p.add_argument("--touch-height", type=int, default=None)
    p.add_argument("--audio-loopback", default=None, help="WASAPI loopback helper executable; enables mirrored audio")
    p.add_argument("--audio-port", type=int, default=AUDIO_PORT, help="Dedicated Wi-Fi audio TCP port")
    p.add_argument("--status-file", default=None, help="Write live JSON telemetry for the launcher")
    p.add_argument("--transport", default="unknown", help="Transport label for telemetry")
    args = p.parse_args()
    session_id = uuid.uuid4().hex

    if shutil.which(args.ffmpeg) is None and args.ffmpeg == "ffmpeg":
        sys.exit("ffmpeg was not found in PATH.")

    try:
        width, height = args.size.lower().split("x", 1)
        width_i, height_i = int(width), int(height)
        if width_i <= 0 or height_i <= 0 or width_i % 2 or height_i % 2:
            raise ValueError("size must contain positive even dimensions (e.g. 1280x960)")
        if not 1 <= args.fps <= 240:
            raise ValueError("fps must be between 1 and 240")
        if not 1 <= args.chunk <= MAX_PAYLOAD:
            raise ValueError("chunk must be between 1 and 8388608 bytes")
        if not 1 <= args.port <= 65535 or not 1 <= args.audio_port <= 65535:
            raise ValueError("ports must be between 1 and 65535")
        if args.display < 0 or (args.adapter is not None and args.adapter < 0):
            raise ValueError("display and adapter indices must be nonnegative")
        touch = (args.touch_left, args.touch_top, args.touch_width, args.touch_height)
        if any(v is not None for v in touch):
            if any(v is None for v in touch) or args.touch_width <= 0 or args.touch_height <= 0:
                raise ValueError("provide all four touch coordinates with positive width and height")
        vbv_bufsize = one_frame_vbv(args.bitrate, args.fps)
    except (ValueError, OverflowError) as exc:
        p.error(str(exc))

    if args.capture == "ddagrab":
        capture = []
        if args.adapter is not None:
            capture += [
                "-init_hw_device", "d3d11va=grab:%d" % args.adapter,
                "-filter_hw_device", "grab",
            ]
        capture += [
            "-filter_complex",
            "ddagrab=output_idx=%d:framerate=%d:draw_mouse=0" % (args.display, args.fps),
        ]
        if args.encoder == "x264":
            capture[-1] += ",hwdownload,format=bgra,scale=%d:%d,format=yuv420p" % (width_i, height_i)
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
            "-draw_mouse",
            "0",
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
            "p3",
            "-tune",
            "ull",
            "-profile:v",
            "high",
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
            vbv_bufsize,
            "-rc-lookahead",
            "0",
            "-spatial-aq",
            "1",
            "-aq-strength",
            "8",
            "-g",
            str(args.fps),
            "-bf",
            "0",
            "-refs",
            "1",
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

    print("Connecting to %s:%d..." % (args.host, args.port))
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
    if args.encoder == "nvenc":
        print("NVENC low-latency: rc-lookahead=0, refs=1, VBV=%s (~1 frame), no frame dropping" % vbv_bufsize)

    try:
        sock = socket.create_connection((args.host, args.port), timeout=5)
    except (ConnectionRefusedError, ConnectionAbortedError, ConnectionResetError, TimeoutError, OSError) as exc:
        print("Connect failed: %s" % exc)
        return 1

    with sock:
        sock.settimeout(5)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

        hello = json.dumps({
            "protocol": PROTOCOL_VERSION,
            "host": "windows",
            "session_id": session_id,
            "session_mode": "thin_client" if args.transport in ("Windows", "Linux") else "display",
            "audio_pcm_v2": True,
            "audio_port": args.audio_port,
            "width": width_i,
            "height": height_i,
            "fps": args.fps,
            "bitrate": args.bitrate,
        }, separators=(",", ":")).encode("utf-8")
        send_packet(sock, CONFIG, hello)

        if None not in (args.touch_left, args.touch_top, args.touch_width, args.touch_height):
            monitor_rect = (
                args.touch_left,
                args.touch_top,
                args.touch_left + args.touch_width,
                args.touch_top + args.touch_height,
            )
        else:
            monitor_rect = find_touch_monitor(width_i, height_i)
        stats = StreamStats()
        stop_status = threading.Event()
        status_thread = threading.Thread(
            target=status_loop,
            args=(stats, stop_status, args.status_file, args.transport, args.host),
            daemon=True,
        )
        status_thread.start()

        touch_thread = threading.Thread(
            target=input_loop,
            args=(sock, monitor_rect, stats),
            daemon=True,
        )
        touch_thread.start()

        send_lock = threading.Lock()
        audio_thread = None
        if args.audio_loopback:
            audio_thread = threading.Thread(
                target=audio_loop,
                args=(args.host, args.audio_port, args.audio_loopback, args.ffmpeg, stats),
                daemon=True,
            )
            audio_thread.start()
        else:
            print("Audio: disabled for this transport.")

        print("Connected. Starting desktop capture; press Ctrl+C to stop.")
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, bufsize=0)
        except OSError as exc:
            stop_status.set()
            print("Capture could not start: %s" % exc)
            return 1
        watchdog_thread = threading.Thread(
            target=watchdog_loop,
            args=(stats, proc, stop_status),
            daemon=True,
        )
        watchdog_thread.start()
        try:
            while True:
                data = proc.stdout.read(args.chunk)
                if not data:
                    break
                send_packet(sock, VIDEO_H264, data, send_lock)
                stats.add_video(len(data))
        except KeyboardInterrupt:
            print("\nStopping...")
            interrupted = True
        except (ConnectionAbortedError, ConnectionResetError, BrokenPipeError, OSError) as exc:
            print("Transport disconnected: %s" % exc)
            interrupted = False
        else:
            interrupted = False
        finally:
            stop_status.set()
            if proc.poll() is None:
                proc.terminate()
            try:
                send_packet(sock, DISCONNECT, lock=send_lock)
            except OSError:
                pass
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()

        if interrupted:
            return 130
        return 0 if proc.returncode == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
