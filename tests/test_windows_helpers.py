"""Checks against the native Windows audio and desktop-display helpers."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class WindowsHelperTests(unittest.TestCase):
    @unittest.skipUnless(os.name == "nt" and shutil.which("cl"), "requires MSVC environment")
    def test_binary_pcm_stdout(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as folder:
            exe = Path(folder) / "wasapi-check.exe"
            subprocess.run(["cl", "/nologo", "/EHsc", "/O2",
                            str(root / "tests/wasapi_output_test.cpp"),
                            "/Fo:" + str(Path(folder) / "check.obj"),
                            "/Fe:" + str(exe), "ole32.lib"], check=True, timeout=90)
            self.assertEqual(subprocess.check_output([str(exe)], timeout=5), bytes(range(256)))


    @unittest.skipUnless(os.name == "nt" and shutil.which("cl"), "requires MSVC environment")
    def test_desktop_attachment(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as folder:
            exe = Path(folder) / "display-check.exe"
            subprocess.run(["cl", "/nologo", "/EHsc", "/O2",
                            str(root / "tests/display_target_test.cpp"),
                            "/Fo:" + str(Path(folder) / "check.obj"),
                            "/Fe:" + str(exe), "user32.lib", "dxgi.lib"], check=True, timeout=90)
            subprocess.run([str(exe)], check=True, timeout=5)
