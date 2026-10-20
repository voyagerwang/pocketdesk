#!/usr/bin/env python3
"""
[INPUT]: scripts/setup-mijia.sh 的真实进程封装与本地 uv 替身；目录仅替换为临时安装根。
[OUTPUT]: 验证终止安装会回收忽略信号的 uv 子进程，失败不会继续下一阶段，不访问真实 venv 或网络。
[POS]: tests 的米家安装取消回归；与登录事件和 Swift 会话测试共同约束子进程归属。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]


class SetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pocketdesk-mijia-setup-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.record = self.directory / "uv-record.jsonl"
        self.install = self.directory / "mijia"
        self.script = self.directory / "setup-mijia.sh"
        original = (ROOT / "scripts/setup-mijia.sh").read_text()
        self.assertEqual(original.count('MIJIA_DIR="$HOME/Library/Application Support/VoiceDeck/mijia"'), 1)
        self.script.write_text(original.replace(
            'MIJIA_DIR="$HOME/Library/Application Support/VoiceDeck/mijia"',
            'MIJIA_DIR="' + str(self.install) + '"'))
        self.fake = self.directory / "uv"
        self.fake.write_text("#!" + sys.executable + "\n" + '''
import json, os, signal, sys, time
for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(sig, signal.SIG_IGN)
with open(os.environ["POCKETDESK_TEST_UV_RECORD"], "a") as record:
    record.write(json.dumps({"pid": os.getpid(), "args": sys.argv[1:]}) + "\\n")
if os.environ.get("POCKETDESK_TEST_UV_FAIL"):
    sys.exit(17)
while True:
    time.sleep(0.1)
''')
        self.fake.chmod(0o700)

    def launch(self, installed=False, fail=False):
        if installed:
            python = self.install / "venv/bin/python"
            python.parent.mkdir(parents=True)
            python.write_text("#!/bin/sh\nexit 0\n")
            python.chmod(0o700)
        env = dict(os.environ, POCKETDESK_UV_PATH=str(self.fake),
                   POCKETDESK_TEST_UV_RECORD=str(self.record))
        if fail:
            env["POCKETDESK_TEST_UV_FAIL"] = "1"
        process = subprocess.Popen(["/bin/zsh", str(self.script), "--no-login"], env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        return process

    def wait_child(self):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if self.record.exists():
                rows = self.record.read_text().splitlines()
                if rows:
                    return json.loads(rows[0])
            time.sleep(0.01)
        self.fail("安装替身未启动")

    def test_each_cancel_signal_reaps_stubborn_child(self):
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            with self.subTest(signal=sig):
                self.record.unlink(missing_ok=True)
                process = self.launch()
                child = self.wait_child()
                try:
                    process.send_signal(sig)
                    stdout, _ = process.communicate(timeout=3)
                    self.assertEqual(process.returncode, 130)
                    self.assertNotIn("已安装", stdout)
                    self.assertEqual(child["args"][0], "venv")
                    with self.assertRaises(ProcessLookupError):
                        os.kill(child["pid"], 0)
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait()
                    try:
                        os.kill(child["pid"], signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_pip_install_child_is_also_reaped(self):
        process = self.launch(installed=True)
        child = self.wait_child()
        try:
            self.assertEqual(child["args"][:2], ["pip", "install"])
            process.terminate()
            process.communicate(timeout=3)
            self.assertEqual(process.returncode, 130)
            with self.assertRaises(ProcessLookupError):
                os.kill(child["pid"], 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            try:
                os.kill(child["pid"], signal.SIGKILL)
            except ProcessLookupError:
                pass

    def test_child_failure_stops_before_next_install_phase(self):
        process = self.launch(fail=True)
        stdout, _ = process.communicate(timeout=3)
        self.assertEqual(process.returncode, 17)
        self.assertEqual(len(self.record.read_text().splitlines()), 1)
        self.assertNotIn("已安装", stdout)


if __name__ == "__main__":
    unittest.main()
