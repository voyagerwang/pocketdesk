#!/usr/bin/env python3
"""
[INPUT]: scripts/mijia-bridge.py、内存登录 SDK 与隔离子进程；所有凭据和二维码均为测试替身。
[OUTPUT]: 验证扫码事件顺序、即时刷新、错误分类、敏感输出隔离和独占暂存，不接触真实账号或网络。
[POS]: tests 的米家登录进程边界验收；正式凭据替换、会话取消与页面投影由 Swift/Web 测试覆盖。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""

import contextlib
import importlib.util
import io
import json
import logging
import os
from pathlib import Path
import select
import stat
import subprocess
import sys
import tempfile
import textwrap
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "mijia-bridge.py"
SPEC = importlib.util.spec_from_file_location("pocketdesk_mijia_login", SCRIPT)
bridge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bridge)
LOGIN_URL = "https://account.xiaomi.com/longPolling/login?l=FAKE_QR_TICKET"
SECRET = "PRIVATE_SERVICE_TOKEN_MUST_NOT_ESCAPE"
AUTH = {"ua": "test", "ssecurity": SECRET, "userId": "u", "cUserId": "c", "serviceToken": SECRET}


class LoginError(Exception):
    pass


class ReadTimeout(Exception):
    pass


class API:
    def __init__(self, destination):
        self.destination = Path(destination)
        self.auth_data = {}
        self.failure = None
        self.login_data = {"loginUrl": LOGIN_URL, "lp": "PRIVATE_LONG_POLL_URL", "serviceToken": SECRET}
        self.calls = []
        self.complete_without_saving = False

    def _get_qr_login_data(self):
        self.calls.append("qr")
        print(SECRET)
        print(SECRET, file=sys.stderr)
        logging.getLogger("mijiaAPI").critical(SECRET)
        return self.login_data

    def _complete_qr_login(self, login_data):
        self.calls.append("complete")
        assert login_data is self.login_data
        print(SECRET)
        if self.failure:
            raise self.failure
        self.auth_data = dict(AUTH)
        if not self.complete_without_saving:
            self._save_auth_data()
        return self.auth_data


class LoginTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pocketdesk-mijia-login-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.destination = self.directory / "session" / "auth.json"
        self.api = API(self.destination)
        self.sdk = SimpleNamespace(mijiaAPI=lambda destination: self.api)

    def run_login(self):
        self.events, self.capture, self.errors = [], io.StringIO(), io.StringIO()
        with (patch.object(bridge, "load_sdk", return_value=self.sdk),
              patch.object(bridge, "bounded_http", return_value=contextlib.nullcontext()),
              contextlib.redirect_stdout(self.capture), contextlib.redirect_stderr(self.errors)):
            bridge.login_events(self.destination, self.events.append)
        return self.events

    def test_success_emits_only_qr_and_complete_after_private_save(self):
        events = self.run_login()
        self.assertEqual(events, [{"event": "qr", "login_url": LOGIN_URL, "expires_in": 120},
                                  {"event": "complete"}])
        self.assertEqual(self.api.calls, ["qr", "complete"])
        self.assertEqual(stat.S_IMODE(self.destination.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.destination.parent.stat().st_mode), 0o700)
        self.assertEqual(json.loads(self.destination.read_text())["serviceToken"], SECRET)
        self.assertEqual(self.capture.getvalue(), "")
        self.assertEqual(self.errors.getvalue(), "")
        self.assertNotIn(SECRET, json.dumps(events))
        self.assertNotIn("PRIVATE_LONG_POLL_URL", json.dumps(events))

    def test_terminal_follows_saved_auth_validation(self):
        self.api.complete_without_saving = True
        self.assertEqual(self.run_login()[-1]["kind"], "auth")
        self.assertEqual(len(self.events), 2)

    def test_invalid_auth_after_save_cannot_report_complete(self):
        self.api.auth_data = {}
        def incomplete(_):
            self.api._save_auth_data()
        self.api._complete_qr_login = incomplete
        self.assertEqual(self.run_login()[-1]["kind"], "auth")

    def test_old_credentials_are_never_read_or_replaced(self):
        self.destination.parent.mkdir()
        self.destination.write_text("KEEP_EXISTING_AUTH")
        self.assertEqual(self.run_login()[0]["kind"], "auth")
        self.assertEqual(self.destination.read_text(), "KEEP_EXISTING_AUTH")
        self.assertEqual(self.api.calls, [])

    def test_symlink_destination_rejected_without_changing_target(self):
        target = self.directory / "real-auth.json"
        target.write_text("KEEP_EXISTING_AUTH")
        self.destination.parent.mkdir()
        self.destination.symlink_to(target)
        self.assertEqual(self.run_login()[0]["kind"], "auth")
        self.assertEqual(target.read_text(), "KEEP_EXISTING_AUTH")

    def test_symlink_parent_rejected(self):
        target = self.directory / "real"
        target.mkdir()
        self.destination.parent.symlink_to(target)
        self.assertEqual(self.run_login()[0]["kind"], "auth")
        self.assertEqual(list(target.iterdir()), [])

    def test_concurrent_destination_creation_cannot_replace_old_auth(self):
        def race(_):
            self.destination.write_text("KEEP_COMPETING_AUTH")
            self.api.auth_data = dict(AUTH)
            self.api._save_auth_data()
        self.api._complete_qr_login = race
        self.assertEqual(self.run_login()[-1]["event"], "error")
        self.assertEqual(self.destination.read_text(), "KEEP_COMPETING_AUTH")

    def test_sdk_expiry_has_distinct_terminal(self):
        self.api.failure = LoginError("code: -1, message: 超时，请重试")
        self.assertEqual(self.run_login()[-1]["kind"], "expired")

    def test_transport_failure_before_expiry_is_network(self):
        self.api.failure = ReadTimeout(SECRET)
        self.assertEqual(self.run_login()[-1]["kind"], "network")
        self.assertNotIn(SECRET, json.dumps(self.events))

    def test_elapsed_expiry_classifies_unknown_long_poll_failure(self):
        self.api.failure = LoginError(SECRET)
        with patch.object(bridge.time, "monotonic", side_effect=[10.0, 130.0]):
            self.assertEqual(self.run_login()[-1]["kind"], "expired")

    def test_auth_failure_is_sanitized(self):
        self.api.failure = LoginError(SECRET)
        self.assertEqual(self.run_login()[-1]["kind"], "auth")
        self.assertNotIn(SECRET, json.dumps(self.events))

    def test_regional_xiaomi_account_qr_completes(self):
        regional = "https://sgp.account.xiaomi.com/longPolling/login?l=FAKE_REGION_TICKET"
        self.api.login_data["loginUrl"] = regional
        events = self.run_login()
        self.assertEqual(events, [{"event": "qr", "login_url": regional, "expires_in": 120},
                                  {"event": "complete"}])
        self.assertEqual(self.api.calls, ["qr", "complete"])

    def test_exact_and_regional_account_dns_labels_are_accepted(self):
        for host in ("account.xiaomi.com", "sgp.account.xiaomi.com", "eu.account.xiaomi.com",
                     "region-1.account.xiaomi.com", "a.b.account.xiaomi.com", "SGP.ACCOUNT.XIAOMI.COM"):
            with self.subTest(host=host):
                self.assertTrue(bridge.valid_login_url(f"https://{host}/longPolling/login?l=fake"))

    def test_fake_account_suffixes_and_url_authority_ambiguities_rejected(self):
        for authority in ("evilaccount.xiaomi.com", "account.xiaomi.com.evil.example",
                          "sgp.account.xiaomi.com.evil.example", "sgp-account.xiaomi.com",
                          "sgp.account.xiaomi.com:443", "account.xiaomi.com:",
                          "user@sgp.account.xiaomi.com", "user:password@account.xiaomi.com",
                          "sgp.account.xiaomi.com@evil.example", ".account.xiaomi.com",
                          "sgp..account.xiaomi.com", "_sgp.account.xiaomi.com",
                          "-sgp.account.xiaomi.com", "sgp-.account.xiaomi.com",
                          "sgp%2eaccount.xiaomi.com", "account.xiaomi.com."):
            with self.subTest(authority=authority):
                self.assertFalse(bridge.valid_login_url(f"https://{authority}/longPolling/login?l=fake"))
        for suffix in ("#", "#fragment", "\x00", "\x7f", "\x85", "\t", "\n"):
            with self.subTest(suffix=suffix):
                self.assertFalse(bridge.valid_login_url(LOGIN_URL + suffix))

    def test_invalid_qr_never_reaches_terminal_login_call(self):
        for value in (None, {}, "https://evil.example/longPolling/login?l=x",
                      "https://account.xiaomi.com@evil.example/longPolling/login?l=x",
                      "https://account.xiaomi.com/longPolling/other?l=x",
                      "https://account.xiaomi.com/longPolling/login",
                      "https://account.xiaomi.com/longPolling/login?l=x#secret",
                      "http://account.xiaomi.com/longPolling/login?l=x",
                      LOGIN_URL + "\n", LOGIN_URL + "x" * 8192):
            with self.subTest(value=value):
                self.api.calls = []
                self.api.login_data = {"loginUrl": value, "lp": SECRET}
                events = self.run_login()
                self.assertEqual(len(events), 1)
                self.assertEqual(events[0]["kind"], "auth")
                self.assertEqual(self.api.calls, ["qr"])

    def test_runtime_check_only_imports_sdk(self):
        with patch.object(bridge, "load_sdk", return_value=self.sdk) as load:
            self.assertEqual(bridge.check_runtime(), {"ok": True, "sdk_version": "5.0.0"})
        load.assert_called_once_with()
        self.assertEqual(self.api.calls, [])
        self.assertFalse(self.destination.exists())

    def test_runtime_check_failure_suppresses_exception_and_output(self):
        def fail():
            print(SECRET)
            print(SECRET, file=sys.stderr)
            raise RuntimeError(SECRET)
        capture, errors = io.StringIO(), io.StringIO()
        with (patch.object(bridge, "load_sdk", side_effect=fail), contextlib.redirect_stdout(capture),
              contextlib.redirect_stderr(errors)):
            result = bridge.check_runtime()
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["kind"], "setup")
        self.assertEqual(capture.getvalue() + errors.getvalue(), "")
        self.assertNotIn(SECRET, json.dumps(result))

    def test_http_wrapper_preserves_long_poll_and_bounds_default_requests(self):
        calls = []
        class Session:
            def request(self, method, url, **kwargs):
                calls.append(kwargs)
        requests = SimpleNamespace(sessions=SimpleNamespace(Session=Session))
        with patch.object(bridge.importlib, "import_module", return_value=requests):
            with bridge.bounded_http(interactive=True):
                Session().request("GET", "https://example.invalid")
                Session().request("GET", "https://example.invalid", timeout=120)
        self.assertEqual(calls, [{"timeout": (5, 12)}, {"timeout": 120}])

    def test_cli_qr_is_flushed_before_wait_and_cancellation_leaves_formal_auth(self):
        formal = self.directory / "formal.json"
        formal.write_text("KEEP_FORMAL_AUTH")
        code = textwrap.dedent("""
            import contextlib, importlib.util, sys, time
            from types import SimpleNamespace
            spec = importlib.util.spec_from_file_location('worker', sys.argv[1])
            worker = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(worker)
            class API:
                def __init__(self, destination): self.auth_data = {}
                def _get_qr_login_data(self):
                    print('SECRET_STDOUT')
                    print('SECRET_STDERR', file=sys.stderr)
                    return {'loginUrl':'https://account.xiaomi.com/longPolling/login?l=fake',
                            'lp':'SECRET_LONG_POLL'}
                def _complete_qr_login(self, data): time.sleep(60)
            worker.load_sdk = lambda: SimpleNamespace(mijiaAPI=API)
            worker.bounded_http = lambda **kwargs: contextlib.nullcontext()
            sys.argv = ['worker', '--login-events', '--auth', sys.argv[2]]
            worker.main()
        """)
        process = subprocess.Popen([sys.executable, "-I", "-B", "-c", code, str(SCRIPT),
                                    str(self.destination)], stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        try:
            ready, _, _ = select.select([process.stdout], [], [], 5)
            self.assertTrue(ready, "二维码必须在等待授权前立即输出")
            event = json.loads(process.stdout.readline())
            self.assertEqual(event["event"], "qr")
            self.assertIsNone(process.poll())
        finally:
            process.terminate()
            stdout, stderr = process.communicate(timeout=5)
        self.assertEqual(stdout + stderr, "")
        self.assertEqual(formal.read_text(), "KEEP_FORMAL_AUTH")
        self.assertFalse(self.destination.exists())


if __name__ == "__main__":
    unittest.main()
