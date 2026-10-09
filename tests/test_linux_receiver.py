"""Headless checks against the complete native Linux receiver."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

PACKAGES = ["sdl2", "SDL2_ttf", "libavcodec", "libavutil", "libswscale"]


class LinuxReceiverTests(unittest.TestCase):
    @unittest.skipUnless(os.name == "posix" and shutil.which("c++") and shutil.which("pkg-config"),
                         "requires Linux native build tools")
    def test_keyboard_audio_and_decoder_reconnect(self):
        if subprocess.run(["pkg-config", "--exists"] + PACKAGES).returncode:
            self.skipTest("Linux receiver development libraries are not installed")
        root = Path(__file__).resolve().parents[1]
        flags = shlex.split(subprocess.check_output(
            ["pkg-config", "--cflags", "--libs"] + PACKAGES, text=True))
        with tempfile.TemporaryDirectory() as folder:
            exe = Path(folder) / "receiver-check"
            subprocess.run(["c++", "-std=c++17", "-O1", "-pthread",
                            str(root / "tests/linux_receiver_test.cpp"), "-o", str(exe)]
                           + flags + ["-lGL", "-lX11"], check=True, timeout=90)
            subprocess.run([str(exe)], cwd=root, check=True, timeout=30)
