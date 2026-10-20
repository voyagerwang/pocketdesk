#!/usr/bin/env python3
"""
[INPUT]: mijia-network.py 的有界 HTTP 上下文、requests 替身与唯一临时公开规格缓存目录。
[OUTPUT]: 验证同规格请求成功/失败去重、账号/设备请求不缓存，以及公开规格缓存的隔离、过期和损坏恢复。
[POS]: tests 的米家网络延迟回归；不联网、不读写正式授权或缓存，JSON 响应均为合成规格。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "mijia-network.py"
URL = "https://miot-spec.org/miot-spec-v2/instance"
URN = "urn:miot-spec-v2:device:light:0000A001:test-v1:1"
OTHER_URN = "urn:miot-spec-v2:device:light:0000A001:test-v1:2"


class Timeout(Exception):
    pass


class HTTPError(Exception):
    pass


class Response:
    def __init__(self, payload=None):
        self.status_code = 200
        self.headers = {}
        self.encoding = "utf-8"
        self.url = URL
        self._content = json.dumps(payload or {}).encode()

    @property
    def content(self):
        return self._content

    @property
    def text(self):
        return self._content.decode("utf-8")

    def json(self):
        return json.loads(self.text)

    def raise_for_status(self):
        if self.status_code >= 400:
            error = HTTPError("isolated response failure")
            error.response = self
            raise error


class NetworkTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.cache = Path(self.temporary.name) / "spec-cache"
        self.calls = []
        self.payload = {"type": URN, "description": "隔离灯", "services": [
            {"iid": 2, "type": "urn:miot-spec-v2:service:light:00007802:test:1", "properties": [], "actions": []}]}
        self.failure = None
        self.status = 200
        state = self

        class Session:
            def request(self, method, url, **kwargs):
                state.calls.append((method, url, copy.deepcopy(kwargs)))
                if state.failure:
                    raise state.failure
                response = Response(state.payload)
                response.status_code = state.status
                response.url = url
                return response

        self.requests = SimpleNamespace(Session=Session, sessions=SimpleNamespace(Session=Session), Response=Response)
        self.modules = patch.dict("sys.modules", {"requests": self.requests})
        self.modules.start()
        spec = importlib.util.spec_from_file_location("isolated_mijia_network", SCRIPT)
        self.network = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.network)

    def tearDown(self):
        self.modules.stop()
        self.temporary.cleanup()

    def get(self, urn=URN, url=URL):
        return self.requests.Session().request("GET", url, params={"type": urn})

    def test_same_spec_success_is_fetched_once_per_operation(self):
        with self.network.bounded_http():
            first = self.get()
            second = self.get()
            self.assertEqual(first.json(), second.json())
        self.assertEqual(len(self.calls), 1)
        with self.network.bounded_http():
            self.get()
        self.assertEqual(len(self.calls), 2, "无磁盘目录时不跨操作持久复用")

    def test_sdk_query_url_and_action_params_share_one_spec_fetch(self):
        with self.network.bounded_http():
            first = self.requests.Session().request("GET", URL + "?type=" + URN)
            second = self.get()
        self.assertEqual(first.json(), second.json())
        self.assertEqual(len(self.calls), 1)

    def test_same_spec_network_failure_is_not_retried_in_operation(self):
        self.failure = Timeout("isolated spec timeout")
        with self.network.bounded_http():
            for _ in range(3):
                with self.assertRaises(self.network.NetworkFailure) as result:
                    self.get()
                self.assertEqual(result.exception.payload["kind"], "network")
                self.assertIn("设备规格", result.exception.payload["message"])
        self.assertEqual(len(self.calls), 1)
        with self.network.bounded_http():
            with self.assertRaises(self.network.NetworkFailure):
                self.get()
        self.assertEqual(len(self.calls), 2, "新显式操作可重新请求，不永久记住网络失败")

    def test_different_full_urns_never_share_schema(self):
        with self.network.bounded_http():
            first = self.get()
            self.payload = {"type": OTHER_URN, "description": "隔离新版灯", "services": [
                {"iid": 9, "type": "urn:miot-spec-v2:service:light:00007802:test:2"}]}
            second = self.get(OTHER_URN)
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(first.json()["type"], URN)
        self.assertEqual(second.json()["type"], OTHER_URN)

    def test_account_and_device_posts_are_never_cached(self):
        with self.network.bounded_http(cache_dir=self.cache):
            for endpoint in ("https://api.io.mi.com/app/homeroom/gethome",
                             "https://api.io.mi.com/app/home/device_list",
                             "https://api.io.mi.com/app/miotspec/prop/set"):
                for _ in range(2):
                    self.requests.Session().request("POST", endpoint, data={"data": "isolated-secret"})
        self.assertEqual(len(self.calls), 6)
        self.assertFalse(any(self.cache.rglob("*.json")))

    def test_non_miot_host_and_post_do_not_enter_spec_cache(self):
        with self.network.bounded_http():
            for _ in range(2):
                self.get(url="https://miot-spec.org.evil.example/miot-spec-v2/instance")
                self.requests.Session().request("POST", URL, params={"type": URN})
        self.assertEqual(len(self.calls), 4)

    def test_spec_cache_refuses_ambiguous_urls_or_extra_parameters(self):
        cases = [("http://miot-spec.org/miot-spec-v2/instance", {"type": URN}),
                 ("https://user@miot-spec.org/miot-spec-v2/instance", {"type": URN}),
                 ("https://miot-spec.org:443/miot-spec-v2/instance", {"type": URN}),
                 (URL + "#fragment", {"type": URN}),
                 (URL + "?type=" + URN, {"type": URN}),
                 (URL, {"type": URN, "account": "isolated-secret"}),
                 (URL, {"type": "not-a-urn"})]
        with self.network.bounded_http(cache_dir=self.cache):
            for url, params in cases:
                for _ in range(2):
                    self.requests.Session().request("GET", url, params=params)
        self.assertEqual(len(self.calls), 2 * len(cases))
        self.assertFalse(any(self.cache.rglob("*.json")))

    def test_successful_public_spec_is_reused_across_operations(self):
        with self.network.bounded_http(cache_dir=self.cache):
            self.get()
        self.assertEqual(len(self.calls), 1)
        with self.network.bounded_http(cache_dir=self.cache):
            self.assertEqual(self.get().json(), self.payload)
        self.assertEqual(len(self.calls), 1)
        files = list(self.cache.rglob("*.json"))
        self.assertEqual(len(files), 1)
        self.assertEqual(files[0].stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.cache.stat().st_mode & 0o777, 0o700)

    def test_network_failure_never_becomes_persistent_cache(self):
        self.failure = Timeout("isolated failure")
        with self.network.bounded_http(cache_dir=self.cache):
            with self.assertRaises(self.network.NetworkFailure):
                self.get()
        self.assertFalse(any(self.cache.rglob("*.json")))
        self.failure = None
        with self.network.bounded_http(cache_dir=self.cache):
            self.assertEqual(self.get().json(), self.payload)
        self.assertEqual(len(self.calls), 2)

    def test_corrupt_cache_falls_back_to_fresh_network(self):
        with self.network.bounded_http(cache_dir=self.cache):
            self.get()
        for path in self.cache.rglob("*.json"):
            path.write_text("corrupt cache")
        with self.network.bounded_http(cache_dir=self.cache):
            self.assertEqual(self.get().json(), self.payload)
        self.assertEqual(len(self.calls), 2)

    def test_cache_write_failure_does_not_turn_network_success_into_failure(self):
        self.cache.write_text("a file blocks the cache directory")
        with self.network.bounded_http(cache_dir=self.cache):
            self.assertEqual(self.get().json(), self.payload)
            self.assertEqual(self.get().json(), self.payload)
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.cache.read_text(), "a file blocks the cache directory")

    def test_cache_expiration_and_future_timestamp_fail_closed(self):
        now = [1_800_000_000]
        cache = self.network.SpecCache(self.cache, now=lambda: now[0])
        cache.write(URN, self.payload)
        now[0] += self.network.SPEC_TTL
        self.assertEqual(cache.read(URN), self.payload)
        now[0] += 1
        self.assertIsNone(cache.read(URN))
        now[0] = 1_799_999_999
        self.assertIsNone(cache.read(URN))

    def test_expired_cache_fetches_current_schema(self):
        with self.network.bounded_http(cache_dir=self.cache):
            self.get()
        path = next(self.cache.glob("*.json"))
        stored = json.loads(path.read_text())
        stored["saved_at"] -= self.network.SPEC_TTL + 10
        path.write_text(json.dumps(stored))
        self.payload["description"] = "新鲜网络规格"
        with self.network.bounded_http(cache_dir=self.cache):
            self.assertEqual(self.get().json()["description"], "新鲜网络规格")
        self.assertEqual(len(self.calls), 2)

    def test_persistent_cache_uses_full_urn_and_rejects_mismatched_record(self):
        cache = self.network.SpecCache(self.cache)
        cache.write(URN, self.payload)
        self.assertIsNone(cache.read(OTHER_URN))
        wrong = dict(self.payload, type=OTHER_URN)
        cache.write(OTHER_URN, wrong)
        self.assertEqual(cache.read(URN)["type"], URN)
        self.assertEqual(cache.read(OTHER_URN)["type"], OTHER_URN)
        self.assertNotEqual(cache.path(URN), cache.path(OTHER_URN))
        cache.path(URN).write_bytes(cache.path(OTHER_URN).read_bytes())
        self.assertIsNone(cache.read(URN))

    def test_oversize_or_malformed_schema_never_persists(self):
        for payload in ({"services": []}, {"description": "bad", "services": [None]},
                        dict(self.payload, type=OTHER_URN),
                        dict(self.payload, description="x" * self.network.SPEC_LIMIT)):
            with self.subTest(payload_type=type(payload).__name__):
                self.payload = payload
                with self.network.bounded_http(cache_dir=self.cache):
                    self.get()
                    self.get()
                self.assertFalse(any(self.cache.rglob("*.json")))
        self.assertEqual(len(self.calls), 4, "不能持久化的响应仍在同一操作内去重")

    def test_missing_type_is_returned_live_but_never_persisted(self):
        self.payload.pop("type")
        for _ in range(2):
            with self.network.bounded_http(cache_dir=self.cache):
                self.assertEqual(self.get().json(), self.payload)
                self.assertEqual(self.get().json(), self.payload)
        self.assertEqual(len(self.calls), 2, "缺少完整URN归属的规格只能本次复用")
        self.assertFalse(any(self.cache.rglob("*.json")))

    def test_private_regular_cache_files_only(self):
        cache = self.network.SpecCache(self.cache)
        cache.write(URN, self.payload)
        path = cache.path(URN)
        path.chmod(0o644)
        self.assertIsNone(cache.read(URN))
        path.chmod(0o600)
        saved = path.read_bytes()
        path.unlink()
        external = Path(self.temporary.name) / "outside.json"
        external.write_bytes(saved)
        external.chmod(0o600)
        path.symlink_to(external)
        self.assertIsNone(cache.read(URN))

    def test_timeout_applies_to_normal_calls_but_preserves_login_long_poll(self):
        with self.network.bounded_http():
            self.requests.Session().request("POST", "https://api.io.mi.com/app/device_list", timeout=120)
        self.assertEqual(self.calls[-1][2]["timeout"], self.network.HTTP_TIMEOUT)
        with self.network.bounded_http(interactive=True):
            self.requests.Session().request("GET", "https://account.xiaomi.com/longPolling/login", timeout=120)
        self.assertEqual(self.calls[-1][2]["timeout"], 120)

    def test_http_auth_failure_and_spec_service_failure_are_distinct(self):
        self.status = 401
        with self.network.bounded_http():
            with self.assertRaises(self.network.NetworkFailure) as auth:
                self.requests.Session().request("POST", "https://api.io.mi.com/app/homeroom/gethome")
            self.assertEqual(auth.exception.payload["kind"], "auth")
            with self.assertRaises(self.network.NetworkFailure) as spec:
                self.get()
            self.assertEqual(spec.exception.payload["kind"], "api")
            self.assertIn("设备规格", spec.exception.payload["message"])
            with self.assertRaises(self.network.NetworkFailure):
                self.get()
        self.assertEqual(len(self.calls), 2)

    def test_sdk_auth_codes_are_not_confused_with_network_or_generic_api_errors(self):
        APIError = type("APIError", (Exception,), {})
        LoginError = type("LoginError", (Exception,), {})
        cases = [(APIError("code: -10020, SECRET_TOKEN"), "auth"),
                 (APIError("code: -10030, SECRET_TOKEN"), "auth"),
                 (LoginError("SECRET_TOKEN"), "auth"),
                 (Timeout("SECRET_TOKEN"), "network"),
                 (APIError("code: -9999, SECRET_TOKEN"), "api")]
        for error, expected in cases:
            with self.subTest(kind=expected, error=type(error).__name__):
                result = self.network.safe_error(error, "米家设备属性")
                self.assertEqual(result["kind"], expected)
                self.assertNotIn("SECRET", json.dumps(result))

    def test_household_owner_memo_is_only_for_one_sdk_operation(self):
        calls = []
        def homes():
            calls.append(1)
            return [{"id": "isolated-home"}]
        api = SimpleNamespace(get_homes_list=homes)
        with self.network.memoized_homes(api):
            api.get_homes_list()
            api.get_homes_list()
        self.assertEqual(len(calls), 1)
        api.get_homes_list()
        self.assertEqual(len(calls), 2)
        self.assertIs(api.get_homes_list, homes)


if __name__ == "__main__":
    unittest.main(verbosity=2)
