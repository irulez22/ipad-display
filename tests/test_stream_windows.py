import ctypes
import io
import socket
import struct
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import stream_windows as stream


class StreamTests(unittest.TestCase):
    def test_linux_encoder_avoids_constant_bitrate_padding(self):
        for transport, expected in (("Linux", "vbr"), ("Windows", "cbr")):
            with self.subTest(transport=transport), patch.object(
                sys, "argv", ["stream", "localhost", "--transport", transport]
            ), patch.object(stream.shutil, "which", return_value="ffmpeg"), patch.object(
                stream.socket, "create_connection", return_value=MagicMock()
            ), patch.object(stream, "send_packet"), patch.object(
                stream, "find_touch_monitor", return_value=(0, 0, 1366, 768)
            ), patch.object(stream.threading, "Thread"), patch.object(
                stream.subprocess, "Popen", side_effect=OSError("test capture boundary")
            ) as capture, patch("sys.stdout", io.StringIO()):
                self.assertEqual(stream.main(), 1)
                command = capture.call_args.args[0]
                self.assertEqual(command[command.index("-rc") + 1], expected)
                self.assertEqual(command[command.index("-maxrate") + 1], "6M")
                self.assertEqual(command[command.index("-flush_packets") + 1], "1")
                capture_filter = command[command.index("-filter_complex") + 1]
                self.assertIn("draw_mouse=" + ("1" if transport == "Linux" else "0"), capture_filter)

    def test_input_abi_size(self):
        self.assertEqual(ctypes.sizeof(stream.INPUT), 40 if ctypes.sizeof(ctypes.c_void_p) == 8 else 28)
        self.assertEqual(stream.INPUT.ki.offset, stream.INPUT.mi.offset)

    def test_keyboard_full_input_and_vk_fallback(self):
        user32 = Mock()
        user32.SendInput.return_value = 1
        with patch.object(stream.sys, "platform", "win32"), patch.object(
            stream.ctypes, "WinDLL", return_value=user32, create=True
        ):
            self.assertTrue(stream.inject_keyboard_packet(struct.pack(">BHHB", 0, 65, 0, 0)))
            args = user32.SendInput.call_args.args
            value = ctypes.cast(args[1], ctypes.POINTER(stream.INPUT)).contents
            self.assertEqual(args[2], ctypes.sizeof(stream.INPUT))
            self.assertEqual(value.ki.wVk, 65)
            self.assertEqual(value.ki.dwFlags, 0)
            self.assertTrue(stream.inject_keyboard_packet(struct.pack(">BHHB", 1, 65, 30, 1)))
            value = ctypes.cast(user32.SendInput.call_args.args[1], ctypes.POINTER(stream.INPUT)).contents
            self.assertEqual(value.ki.wVk, 0)
            self.assertEqual(value.ki.dwFlags, 0x0B)
            self.assertFalse(stream.inject_keyboard_packet(struct.pack(">BHHB", 9, 65, 30, 0)))

    def test_fragmented_read_and_quiet_input(self):
        sock = Mock()
        sock.recv.side_effect = [b"a", socket.timeout(), b"bc", b"d"]
        self.assertEqual(stream.read_exactly(sock, 4), b"abcd")
        self.assertEqual(stream.read_exactly(sock, 0), b"")

    def test_eof_and_oversized_input(self):
        sock = Mock()
        sock.recv.side_effect = [b"a", b""]
        self.assertIsNone(stream.read_exactly(sock, 2))
        for length in (-1, stream.MAX_PAYLOAD + 1):
            with self.assertRaises(ValueError):
                stream.read_exactly(sock, length)

    def test_packet_wire_format(self):
        sock = Mock()
        stream.send_packet(sock, stream.VIDEO_H264, b"abc")
        sock.sendall.assert_called_once_with(b"\x00\x00\x00\x03\x01abc")

    def test_touch_validation(self):
        contact = struct.pack(">HBHH", 42, 1, 65535, 0)
        self.assertEqual(stream.parse_touch_v2(b"\x01" + contact), [(42, 1, 1.0, 0.0)])
        for payload in (b"", b"\x01", b"\x02" + contact * 2,
                        b"\x01" + struct.pack(">HBHH", 1, 4, 0, 0),
                        b"\x0b" + contact * 11):
            self.assertEqual(stream.parse_touch_v2(payload), [])

    def test_oversized_frame_stops_before_body_read(self):
        sock = Mock()
        sock.recv.return_value = struct.pack(">IB", stream.MAX_PAYLOAD + 1, stream.CONFIG)
        stream.input_loop(sock, None)
        sock.recv.assert_called_once_with(5)

    def test_disconnect_stops_input(self):
        sock = Mock()
        sock.recv.return_value = struct.pack(">IB", 0, stream.DISCONNECT)
        stream.input_loop(sock, None)
        sock.recv.assert_called_once_with(5)

    def test_bitrate_and_telemetry_merge(self):
        self.assertEqual(stream.bitrate_to_bits_per_second("1.5M"), 1500000)
        self.assertEqual(stream.one_frame_vbv("6M", 60), "100k")
        for value in ("0", "-3M", "nan", "inf", "bad"):
            with self.assertRaises((ValueError, OverflowError)):
                stream.bitrate_to_bits_per_second(value)
        stats = stream.StreamStats()
        stats.set_ipad_hello({"app": "1", "name": "iPad"})
        stats.set_ipad_hello({"battery_percent": 50})
        self.assertEqual(stats.snapshot()[-1], {"app": "1", "name": "iPad", "battery_percent": 50})

    def test_monitor_coordinates_include_negative_origins(self):
        self.assertEqual(stream._monitor_point((-1920, -100, 0, 980), 0, 0), (-1920, -100))
        self.assertEqual(stream._monitor_point((-1920, -100, 0, 980), 65535, 65535), (-1, 979))

    def test_audio_startup_failure_closes_socket(self):
        sock = Mock()
        with patch.object(stream.socket, "create_connection", return_value=sock), patch.object(
            stream.subprocess, "Popen", side_effect=OSError("missing helper")
        ):
            stream.audio_loop("localhost", 4824, "helper", "ffmpeg")
        sock.close.assert_called_once()

    def test_audio_invalid_header_reaps_helper(self):
        sock = Mock()
        proc = Mock()
        proc.stdout = io.BytesIO(b"PDAUDIO 48000 2 f32 3\n")
        proc.stdin = proc.stderr = None
        proc.poll.return_value = None
        with patch.object(stream.socket, "create_connection", return_value=sock), patch.object(
            stream.subprocess, "Popen", return_value=proc
        ):
            stream.audio_loop("localhost", 4824, "helper", "ffmpeg")
        proc.terminate.assert_called_once()
        proc.wait.assert_called_once_with(timeout=2)
        self.assertTrue(proc.stdout.closed)
        sock.close.assert_called_once()

    def test_audio_converter_failure_reaps_helper(self):
        sock = Mock()
        proc = Mock()
        proc.stdout = io.BytesIO(b"PDAUDIO 48000 2 f32 8\n")
        proc.stdin = proc.stderr = None
        proc.poll.return_value = None
        with patch.object(stream.socket, "create_connection", return_value=sock), patch.object(
            stream.subprocess, "Popen", side_effect=[proc, OSError("missing converter")]
        ) as popen:
            stream.audio_loop("localhost", 4824, "helper", "ffmpeg")
        command = popen.call_args_list[1].args[0]
        self.assertEqual(command[command.index("-flush_packets") + 1], "1")
        proc.terminate.assert_called_once()
        self.assertTrue(proc.stdout.closed)
        sock.close.assert_called_once()

    def test_cli_rejects_invalid_options_before_connect(self):
        for option in (["--fps", "0"], ["--chunk", "-1"], ["--size", "123x456"],
                       ["--port", "65536"], ["--bitrate", "nan"], ["--touch-width", "100"]):
            with self.subTest(option=option), patch.object(sys, "argv", ["stream", "host"] + option), patch.object(
                stream.shutil, "which", return_value="ffmpeg"
            ), patch.object(stream.socket, "create_connection") as connect, patch("sys.stderr", io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    stream.main()
                self.assertEqual(error.exception.code, 2)
                connect.assert_not_called()


if __name__ == "__main__":
    unittest.main()
