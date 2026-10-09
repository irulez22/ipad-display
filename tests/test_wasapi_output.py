"""The Windows CRT must preserve every PCM byte, including LF and Ctrl-Z."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class WasapiOutputTests(unittest.TestCase):
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
