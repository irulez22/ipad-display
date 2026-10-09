"""Exercise the Linux receiver's actual socket reader without SDL/FFmpeg."""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


@unittest.skipUnless(os.name == "posix" and shutil.which("c++"), "requires POSIX sockets and C++")
class ReceiverSocketTests(unittest.TestCase):
    def test_fragmented_read_eof_and_shutdown_while_idle(self):
        source = (Path(__file__).resolve().parents[1] /
                  "tools/linux-receiver/PadDisplayReceiverLinux.cpp").read_text()
        reader = source[source.index("static bool ReadExact("):source.index("static bool SendAll(")]
        harness = r"""
#include <atomic>
#include <cassert>
#include <cerrno>
#include <chrono>
#include <thread>
#include <sys/socket.h>
#include <sys/select.h>
#include <unistd.h>
static std::atomic<bool> running{true};
READER
int main() {
    int sockets[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
    char buffer[4]{};
    std::thread writer([&] {
        assert(send(sockets[0], "ab", 2, 0) == 2);
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        assert(send(sockets[0], "cd", 2, 0) == 2);
    });
    assert(ReadExact(sockets[1], buffer, sizeof(buffer)));
    assert(buffer[0] == 'a' && buffer[3] == 'd');
    writer.join();
    std::thread stopper([] {
        std::this_thread::sleep_for(std::chrono::milliseconds(30));
        running = false;
    });
    auto start = std::chrono::steady_clock::now();
    assert(!ReadExact(sockets[1], buffer, sizeof(buffer)));
    assert(std::chrono::steady_clock::now() - start < std::chrono::seconds(2));
    stopper.join();
    running = true;
    close(sockets[0]);
    assert(!ReadExact(sockets[1], buffer, sizeof(buffer)));
    close(sockets[1]);
}
""".replace("READER", reader)
        with tempfile.TemporaryDirectory() as folder:
            cpp = Path(folder) / "socket_check.cpp"
            exe = Path(folder) / "socket_check"
            cpp.write_text(harness)
            subprocess.run(["c++", "-std=c++17", "-pthread", str(cpp), "-o", str(exe)],
                           check=True, timeout=30)
            subprocess.run([str(exe)], check=True, timeout=5)
