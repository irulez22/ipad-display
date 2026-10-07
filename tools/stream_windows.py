#!/usr/bin/env python3
"""Capture the Windows desktop with FFmpeg and stream H.264 to PadDisplay."""
import argparse
import json
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

VIDEO_H264 = 0x01
DISCONNECT = 0x04
AUDIO_PCM = 0x20
AUDIO_PCM_V2 = 0x21
CONFIG = 0x03
PROTOCOL_VERSION = 1
TOUCH_V1 = 0x10
TOUCH_V2 = 0x11
PORT = 4822
AUDIO_PORT = 4824
MAX_TOUCH_CONTACTS = 10
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
            self.ipad_hello = dict(hello or {})

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
    while not stop_event.wait(1.0):
        video, audio, touches, started, last_video_time, last_audio_time, ipad_hello = stats.snapshot()
        video_mbps = (video - last_video) * 8.0 / 1000000.0
        audio_kbps = (audio - last_audio) * 8.0 / 1000.0
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
    return int(float(text) * multiplier)


def one_frame_vbv(bitrate, fps):
    bits_per_second = bitrate_to_bits_per_second(bitrate)
    bits_per_frame = max(64000, int(round(bits_per_second / max(1, fps))))
    return "%dk" % max(1, int(round(bits_per_frame / 1000.0)))


def send_packet(sock, packet_type, payload=b"", lock=None):
    frame = struct.pack(">IB", len(payload), packet_type) + payload
    if lock is None:
        sock.sendall(frame)
    else:
        with lock:
            sock.sendall(frame)


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


def input_loop(sock, monitor_rect, stats=None):
    if monitor_rect is None:
        print("Touch: matching stream monitor not found; touch input disabled.")
        return

    try:
        injector = NativeTouchInjector(monitor_rect)
    except Exception as exc:
        print("Touch: native injection unavailable: %s" % exc)
        return

    print("Touch: native Windows multi-touch mapped to monitor rect %s" % (monitor_rect,))
    print("Touch injector: %s" % ("synthetic pointer device" if injector.synthetic_device is not None else "legacy InjectTouchInput fallback"))
    print("Touch ABI: POINTER_INFO=%d bytes, POINTER_TOUCH_INFO=%d bytes" % (
        ctypes.sizeof(POINTER_INFO), ctypes.sizeof(POINTER_TOUCH_INFO)
    ))
    saw_touch = False

    try:
        while True:
            header = read_exactly(sock, 5)
            if header is None:
                return
            length, packet_type = struct.unpack(">IB", header)
            payload = read_exactly(sock, length)
            if payload is None:
                return

            if packet_type == CONFIG:
                try:
                    text = payload.decode("utf-8", "replace")
                    print("iPad hello: %s" % text, flush=True)
                    try:
                        hello = json.loads(text)
                        if stats is not None and isinstance(hello, dict):
                            stats.set_ipad_hello(hello)
                    except Exception:
                        pass
                except Exception:
                    pass
            elif packet_type == TOUCH_V2:
                contacts = parse_touch_v2(payload)
                if contacts:
                    if not saw_touch:
                        print("Touch: received first TOUCH_V2 packet from iPad (%d contact(s))." % len(contacts))
                        saw_touch = True
                    injector.inject(contacts)
                    if stats is not None:
                        stats.add_touch()
            elif packet_type == TOUCH_V1 and len(payload) == 5:
                phase = payload[0]
                x = struct.unpack(">H", payload[1:3])[0] / 65535.0
                y = struct.unpack(">H", payload[3:5])[0] / 65535.0
                injector.inject([(0, phase, x, y)])
                if stats is not None:
                    stats.add_touch()
    except (OSError, RuntimeError):
        return
    except Exception as exc:
        print("Touch injection error: %s" % exc)


def audio_loop(host, port, helper_path, stats=None):
    print("Audio: connecting dedicated stream to %s:%d..." % (host, port))
    try:
        audio_sock = socket.create_connection((host, port), timeout=5)
        audio_sock.settimeout(None)
        audio_sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    except (ConnectionRefusedError, ConnectionAbortedError, ConnectionResetError, TimeoutError, OSError) as exc:
        print("Audio: dedicated connection failed: %s" % exc)
        return

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

    chunk = 3840  # 20 ms of 48kHz stereo s16le
    pending = bytearray()
    sequence = 0
    try:
        while True:
            data = proc.stdout.read(chunk)
            if not data:
                break

            # Pipe reads are not guaranteed to preserve the helper's write
            # boundaries. Never discard a partial stereo PCM frame: carrying
            # those bytes forward is essential or all subsequent samples can
            # become byte-shifted and sound like static/garbled audio.
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

        # Send any final complete PCM frames without losing alignment.
        usable = len(pending) - (len(pending) % 4)
        if usable:
            pcm = bytes(pending[:usable])
            timestamp_us = int(time.monotonic() * 1000000.0)
            payload = struct.pack(">IQ", sequence & 0xffffffff, timestamp_us) + pcm
            send_packet(audio_sock, AUDIO_PCM_V2, payload)
            if stats is not None:
                stats.add_audio(usable)
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
        if proc.poll() is None:
            proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


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

    if shutil.which(args.ffmpeg) is None and args.ffmpeg == "ffmpeg":
        sys.exit("ffmpeg was not found in PATH.")

    width, height = args.size.lower().split("x", 1)
    width_i, height_i = int(width), int(height)
    vbv_bufsize = one_frame_vbv(args.bitrate, args.fps)

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
            vbv_bufsize,
            "-rc-lookahead",
            "0",
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
        return

    with sock:
        sock.settimeout(None)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

        hello = ('{"protocol":%d,"host":"windows","audio_pcm_v2":true,"audio_port":%d}' %
                 (PROTOCOL_VERSION, args.audio_port)).encode("utf-8")
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
                args=(args.host, args.audio_port, args.audio_loopback, stats),
                daemon=True,
            )
            audio_thread.start()
        else:
            print("Audio: disabled for this transport.")

        print("Connected. Starting desktop capture; press Ctrl+C to stop.")
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, bufsize=0)
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
            raise SystemExit(130)


if __name__ == "__main__":
    main()
