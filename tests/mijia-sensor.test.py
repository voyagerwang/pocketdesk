#!/usr/bin/env python3
"""
[INPUT]: 米家桥接/只读查询/安全策略源码与内存家庭、规格、SDK回执；时间由替身固定。
[OUTPUT]: 单次环境查询目标消歧、一次发现、设备读取与云回退上限、真实来源/单位/更新时间及旧灯开关行为回归。
[POS]: 温湿度只读协议的隔离验收；不访问网络、正式凭据或设备，不缓存家庭数据。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
import copy
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("sensor_bridge", ROOT / "scripts/mijia-bridge.py")
bridge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bridge)
NOW = 1791849600
SENSOR = {"did": "sensor-1", "name": "温湿度计", "home_id": "home-1", "room": "客厅", "online": False,
          "model": "fixture.sensor", "spec_type": "urn:miot-spec-v2:device:temperature-humidity-sensor:0000A00A:fixture:1",
          "token": "SECRET", "mac": "SECRET", "localip": "SECRET"}
PARSED = {"properties": [
    {"name": "temperature", "type": "float", "rw": "rw", "method": {"siid": 3, "piid": 1}},
    {"name": "relative-humidity", "type": "uint", "rw": "rw", "method": {"siid": 3, "piid": 2}},
], "actions": []}
RAW = {"type": SENSOR["spec_type"], "services": [{"iid": 3,
    "type": "urn:miot-spec-v2:service:temperature-humidity-sensor:00007814:fixture:1", "properties": [
        {"iid": 1, "type": "urn:miot-spec-v2:property:temperature:00000020:fixture:1", "format": "float",
         "unit": "celsius", "access": ["read", "write"], "value-range": [-30, 100, 0.1]},
        {"iid": 2, "type": "urn:miot-spec-v2:property:relative-humidity:0000000C:fixture:1", "format": "uint8",
         "unit": "percentage", "access": ["read", "write"], "value-range": [0, 100, 1]},
    ]}]}


class Timeout(Exception):
    pass


class LoginError(Exception):
    pass


class API:
    def __init__(self):
        self.auth_data = {}
        self.devices = [copy.deepcopy(SENSOR)]
        self.calls = []
        self.device_reply = {"code": 0, "value": 50, "updateTime": NOW - 2}
        self.cloud_reply = {"code": 0, "value": 49, "updateTime": NOW - 3600}

    def get_devices_list(self, home_id=None):
        self.calls.append(("devices", home_id))
        return copy.deepcopy(self.devices)  # 故意不按家庭过滤，核验桥接自身隔离。

    def _request(self, path, data):
        self.calls.append(("read", path, copy.deepcopy(data)))
        reply = self.device_reply if data["datasource"] == 2 else self.cloud_reply
        if isinstance(reply, Exception):
            raise reply
        return [{**data["params"][0], **copy.deepcopy(reply)}]

    def get_devices_prop(self, method):
        self.calls.append(("legacy_cloud", copy.deepcopy(method)))
        return {**method, **copy.deepcopy(self.cloud_reply)}

    def set_devices_prop(self, method):
        raise AssertionError("只读查询禁止写入")


class SensorTests(unittest.TestCase):
    def setUp(self):
        self.api = API()
        self.raw, self.parsed = copy.deepcopy(RAW), copy.deepcopy(PARSED)
        self.spec_calls, self.raw_calls = [], []
        self.sdk = SimpleNamespace(__version__="5.0.0", get_device_info=self.info)

    def info(self, urn, cache_path=None):
        self.spec_calls.append(urn)
        return copy.deepcopy(self.parsed)

    def raw_info(self, urn):
        self.raw_calls.append(urn)
        return copy.deepcopy(self.raw)

    def call(self, request=None, **kwargs):
        request = request or {"operation": "query_environment", "home_id": "home-1", "metric": "humidity", **kwargs}
        with patch.object(bridge._sensor.time, "time", return_value=NOW):
            return bridge.envelope(request, Path("/unused"), sdk=self.sdk, api=self.api, raw_spec=self.raw_info)

    def sources(self):
        return [entry[2]["datasource"] for entry in self.api.calls if entry[0] == "read"]

    def test_offline_directly_reads_cloud_once(self):
        result = self.call()
        self.assertTrue(result["ok"], result)
        self.assertFalse(result["mutating"])
        data = result["data"]
        self.assertEqual((data["metric"], data["value"], data["source"]), ("humidity", 49, "cloud"))
        self.assertEqual((data["updated_at"], data["observed_at"]), (NOW - 3600, NOW))
        self.assertEqual(data["property"]["unit"], "percentage")
        self.assertEqual(data["property"]["rw"], "r")
        self.assertEqual(self.sources(), [3])
        self.assertEqual([x for x in self.api.calls if x[0] == "devices"], [("devices", "home-1")])
        self.assertEqual(len(self.spec_calls), 1)
        self.assertEqual(len(self.raw_calls), 1)
        self.assertNotIn("SECRET", json.dumps(result))

    def test_online_device_success_does_not_query_cloud(self):
        self.api.devices[0]["online"] = True
        self.api.device_reply.update(value=-12.3, updateTime=(NOW - 2) * 1000)
        result = self.call(metric="temperature")
        self.assertTrue(result["ok"], result)
        self.assertEqual(self.sources(), [2])
        self.assertEqual(result["data"]["source"], "device")
        self.assertEqual(result["data"]["updated_at"], NOW - 2)
        self.assertEqual(result["data"]["property"]["unit"], "celsius")

    def test_device_failure_falls_back_to_cloud_at_most_once(self):
        for reply in [Timeout("SECRET"), {"code": -704042011}, {"code": 0}, {"code": 0, "value": "49"}]:
            with self.subTest(reply=type(reply).__name__):
                self.api.calls = []
                self.api.devices[0]["online"] = True
                self.api.device_reply = reply
                self.api.cloud_reply["updateTime"] = NOW
                result = self.call()
                self.assertTrue(result["ok"], result)
                self.assertEqual(self.sources(), [2, 3])
                self.assertEqual(result["data"]["source"], "cloud")

    def test_cloud_failure_does_not_retry(self):
        self.api.devices[0]["online"] = True
        self.api.device_reply = Timeout("SECRET")
        self.api.cloud_reply = Timeout("SECRET")
        result = self.call()
        self.assertEqual(result["error"]["kind"], "network")
        self.assertEqual(self.sources(), [2, 3])
        self.assertNotIn("SECRET", json.dumps(result))

    def test_auth_failure_does_not_retry(self):
        self.api.devices[0]["online"] = True
        self.api.device_reply = LoginError("SECRET")
        self.assertEqual(self.call()["error"]["kind"], "auth")
        self.assertEqual(self.sources(), [2])

    def test_online_flag_does_not_coerce_other_types(self):
        for value in [None, False, 1, "true", "online"]:
            with self.subTest(value=value):
                self.api.calls = []
                self.api.devices[0]["online"] = value
                self.assertTrue(self.call()["ok"])
                self.assertEqual(self.sources(), [3])

    def test_cloud_cache_miss_does_not_send_rpc_or_suggest_retrying_for_live_value(self):
        self.api.cloud_reply = {"code": -704042011}
        result = self.call()
        self.assertEqual(self.sources(), [3])
        self.assertEqual(result["error"]["message"], "米家未返回可用的湿度云端记录。")
        self.assertNotIn("网关", json.dumps(result, ensure_ascii=False))
        self.assertNotIn("刷新", json.dumps(result, ensure_ascii=False))

    def test_exact_name_room_or_identifier(self):
        self.api.devices.append({**SENSOR, "did": "sensor-2", "name": "另一个", "room": "卧室"})
        for query in ["温湿度计", "客厅", "sensor-1"]:
            with self.subTest(query=query):
                self.assertEqual(self.call(query=query)["data"]["device"]["did"], "sensor-1")

    def test_ambiguous_target_never_fetches_spec_or_values(self):
        self.api.devices.append({**SENSOR, "did": "sensor-2"})
        for request in [{}, {"query": "客厅"}, {"query": "温湿度计"}, {"query": "温湿"}]:
            with self.subTest(request=request):
                result = self.call(**request)
                self.assertEqual(result["error"]["kind"], "choice")
                self.assertEqual(len(result["error"]["candidates"]), 2)
                self.assertEqual(self.spec_calls, [])
                self.assertEqual(self.sources(), [])

    def test_home_filter_and_sensitive_devices_remain_hidden(self):
        self.api.devices += [{**SENSOR, "did": "other-home", "home_id": "home-2"},
            {**SENSOR, "did": "secret", "name": "SECRET_CAMERA", "spec_type": "urn:miot-spec-v2:device:camera:0000A01C:fixture:1"}]
        result = self.call()
        self.assertEqual(result["data"]["device"]["did"], "sensor-1")
        self.assertNotIn("SECRET", json.dumps(result))

    def test_no_sensor_and_missing_metric_are_specific(self):
        self.api.devices = []
        self.assertEqual(self.call()["error"]["kind"], "unsupported")
        self.api.devices = [copy.deepcopy(SENSOR)]
        self.raw["services"][0]["properties"].pop()
        result = self.call()
        self.assertEqual(result["error"]["kind"], "unsupported")
        self.assertIn("湿度", result["error"]["message"])
        self.assertEqual(self.sources(), [])

    def test_duplicate_metric_needs_property_choice(self):
        self.raw["services"].append({**copy.deepcopy(self.raw["services"][0]), "iid": 4})
        self.parsed["properties"].append({**self.parsed["properties"][1], "method": {"siid": 4, "piid": 2}})
        self.assertEqual(self.call()["error"]["kind"], "choice")
        self.assertEqual(self.sources(), [])

    def test_invalid_metric_scope_and_extra_fields_precede_discovery(self):
        for request in [{"operation": "query_environment", "metric": "humidity"},
                        {"operation": "query_environment", "metric": "humidity", "home_id": ""},
                        {"operation": "query_environment", "metric": "pressure", "home_id": "home-1"},
                        {"operation": "query_environment", "metric": True, "home_id": "home-1"},
                        {"operation": "query_environment", "metric": "humidity", "home_id": "home-1", "value": 1}]:
            with self.subTest(request=request):
                self.assertEqual(self.call(request)["error"]["kind"], "invalid")
                self.assertEqual(self.api.calls, [])

    def test_read_value_and_target_are_validated(self):
        for value in [None, True, "49", -1, 101, 49.5, float("nan"), float("inf")]:
            with self.subTest(value=value):
                self.api.cloud_reply["value"] = value
                result = self.call()
                self.assertEqual(result["error"]["kind"], "api")
                self.assertIn("湿度", result["error"]["message"])
        self.api.cloud_reply.update(value=49, did="unexpected-device")
        self.assertEqual(self.call()["error"]["kind"], "api")

    def test_unknown_time_never_uses_observed_time(self):
        self.api.cloud_reply.pop("updateTime")
        result = self.call()["data"]
        self.assertIsNone(result["updated_at"])
        self.assertEqual(result["observed_at"], NOW)
        self.assertNotIn("update_time", result)

    def test_trusted_time_accepts_only_bounded_seconds_or_milliseconds(self):
        for value, expected in [(NOW, NOW), (NOW * 1000, NOW), (NOW - .5, NOW - .5),
                                (946684800000, 946684800), (946684800, 946684800)]:
            with self.subTest(value=value):
                self.assertEqual(bridge._sensor.trusted_updated_at(value, NOW), expected)
        for value in [None, True, False, str(NOW), 0, -1, 100, 946684799, NOW + 1, (NOW + 1) * 1000,
                      float("nan"), float("inf"), 10 ** 1000, NOW * 1_000_000]:
            with self.subTest(value=str(value)[:20]):
                self.assertIsNone(bridge._sensor.trusted_updated_at(value, NOW))

    def test_generic_sensor_read_has_same_freshness(self):
        self.api.devices[0]["online"] = True
        result = self.call({"operation": "get_property", "device": "sensor-1", "home_id": "home-1", "property": "3.2"})
        self.assertTrue(result["ok"], result)
        self.assertEqual(self.sources(), [2])
        self.assertEqual(result["data"]["property"]["unit"], "percentage")
        self.assertEqual(result["data"]["updated_at"], NOW - 2)

    def test_generic_light_read_keeps_cloud_strategy(self):
        device = {**SENSOR, "online": True, "spec_type": "urn:miot-spec-v2:device:light:0000A001:fixture:1"}
        self.api.devices = [device]
        self.parsed = {"properties": [{"name": "on", "type": "bool", "rw": "rw", "method": {"siid": 2, "piid": 1}}], "actions": []}
        self.raw = {"type": device["spec_type"], "services": [{"iid": 2, "type": "urn:miot-spec-v2:service:light:00007802:fixture:1",
            "properties": [{"iid": 1, "type": "urn:miot-spec-v2:property:on:00000006:fixture:1", "format": "bool", "access": ["read", "write"]}]}]}
        self.api.cloud_reply["value"] = True
        result = self.call({"operation": "get_property", "device": "sensor-1", "home_id": "home-1", "property": "2.1"})
        self.assertTrue(result["ok"], result)
        self.assertEqual(self.sources(), [])
        self.assertEqual(len([x for x in self.api.calls if x[0] == "legacy_cloud"]), 1)
        self.assertEqual(result["data"]["source"], "cloud")
        self.assertIsNone(result["data"]["property"]["unit"])


if __name__ == "__main__":
    unittest.main()
