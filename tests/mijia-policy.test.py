#!/usr/bin/env python3
"""
[INPUT]: 米家真实桥接与纯策略，既有内存 SDK/API 替身和合成的官方格式 MIOT 规格。
[OUTPUT]: 验证敏感设备隐藏、URN 正向授权、动作/场景硬拒绝和温湿度只读/单位/数值边界，不读取凭据或联网。
[POS]: 米家安全边界回归；直接 ID、prepare 和执行路径分别验证，避免只保护模型工具说明。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
import copy
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import unittest


SPEC = importlib.util.spec_from_file_location("mijia_policy_fixtures", Path(__file__).with_name("mijia-bridge.test.py"))
fixtures = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixtures)
bridge, policy = fixtures.bridge, fixtures.bridge._policy


class SecurityPolicyTests(unittest.TestCase):
    def setUp(self):
        self.api = fixtures.API()
        self.raw = copy.deepcopy(fixtures.RAW_SPEC)
        self.parsed = {"properties": copy.deepcopy(fixtures.PROPERTIES), "actions": copy.deepcopy(fixtures.ACTIONS)}
        self.spec_calls = []
        def spec(urn, cache_path=None):
            self.spec_calls.append(urn)
            return copy.deepcopy(self.parsed)
        self.sdk = SimpleNamespace(__version__="5.0.0", get_device_info=spec)

    def call(self, request):
        return bridge.envelope(request, Path("/UNUSED-NO-AUTH-READ"), sdk=self.sdk,
                               api=self.api, raw_spec=lambda _: copy.deepcopy(self.raw))

    def assert_no_device_io(self):
        self.assertFalse(any(c[0] in ("read", "write", "action", "scene", "rpc_source") for c in self.api.calls))

    def assert_blocked(self, request):
        result = self.call(request)
        self.assertFalse(result["ok"], result)
        self.assert_no_device_io()
        return result

    def test_sensitive_and_unknown_devices_hidden_even_when_named_light(self):
        for kind, code in (("camera", "0000A01C"), ("lock", "0000A038"), ("speaker", "0000A015"),
                           ("gateway", "0000A019"), ("sensor", "0000A008"), ("unknown", "0000FFFF")):
            self.api.devices.append({**fixtures.DEVICE, "did": "PRIVATE_" + kind,
                                     "name": "客厅灯 PRIVATE_" + kind,
                                     "spec_type": f"urn:miot-spec-v2:device:{kind}:{code}:test:1"})
        result = self.call({"operation": "list_devices", "home_id": "h1"})
        self.assertEqual([d["did"] for d in result["data"]["devices"]], ["d1"])
        self.assertTrue(result["data"]["restricted_devices_hidden"])
        self.assertNotIn("PRIVATE_", json.dumps(result))
        self.assertEqual(self.spec_calls, [])

    def test_urn_namespace_category_and_numeric_identity_are_required(self):
        for urn in ("urn:vendor:device:light:0000A001:test:1", "urn:miot-spec-v2:device:camera:0000A001:test:1",
                    "urn:miot-spec-v2:device:light:0000FFFF:test:1", "urn:miot-spec-v2:service:light:0000A001:test:1",
                    "urn:miot-spec-v2:device:light:0000A001:test:1\n", "light", None):
            with self.subTest(urn=urn):
                self.api.devices[0]["spec_type"] = urn
                self.assertEqual(self.call({"operation": "list_devices"})["data"]["devices"], [])
        self.assertEqual(self.spec_calls, [])

    def test_direct_sensitive_id_read_info_prepare_and_write_never_touch_device(self):
        self.api.devices[0].update(name="PRIVATE_CAMERA", spec_type="urn:miot-spec-v2:device:camera:0000A01C:test:1")
        for operation in ("device_info", "get_property", "set_property", "prepare"):
            request = {"operation": operation, "device": "d1", "home_id": "h1"}
            if operation != "device_info":
                request["property"] = "2.1"
            if operation in ("set_property", "prepare"):
                request["value"] = False
            if operation == "prepare":
                request = {"operation": "prepare", "request": {**request, "operation": "set_property"}}
            result = self.assert_blocked(request)
            self.assertNotIn("PRIVATE_CAMERA", json.dumps(result))
        self.assertEqual(self.spec_calls, [])

    def test_prepared_light_becoming_camera_is_rechecked_at_execution(self):
        plan = self.call({"operation": "prepare", "request": {"operation": "set_property", "device": "d1",
                         "home_id": "h1", "property": "2.1", "value": False}})
        self.assertTrue(plan["ok"])
        self.api.devices[0]["spec_type"] = "urn:miot-spec-v2:device:camera:0000A01C:test:1"
        self.assert_blocked(plan["data"]["request"])

    def test_prepared_property_becoming_private_is_rechecked_at_execution(self):
        plan = self.call({"operation": "prepare", "request": {"operation": "set_property", "device": "d1",
                         "home_id": "h1", "property": "2.1", "value": False}})
        self.assertTrue(plan["ok"])
        self.raw["services"][0]["properties"][0]["type"] = "urn:vendor:property:on:00000006:test:1"
        self.assert_blocked(plan["data"]["request"])

    def test_all_actions_and_scenes_rejected_without_sdk_discovery(self):
        for request in ({"operation": "action", "device": "d1", "home_id": "h1", "action": "2.1", "inputs": []},
                        {"operation": "action", "device": "d1", "home_id": "h1", "action": "2.2", "inputs": ["打开另一家的摄像头"]},
                        {"operation": "run_scene", "scene": "s1", "home_id": "h1"}):
            self.assertEqual(self.assert_blocked(request)["error"]["kind"], "policy")
            self.assertEqual(self.assert_blocked({"operation": "prepare", "request": request})["error"]["kind"], "policy")
        self.assertEqual(self.api.calls, [])
        self.assertEqual(self.spec_calls, [])

    def test_scene_names_never_leave_bridge(self):
        self.api.scenes = [{"scene_id": "PRIVATE", "name": "PRIVATE_CAMERA_SCENE", "home_id": "h1"}]
        result = self.call({"operation": "list_scenes", "home_id": "h1"})
        self.assertEqual(result["data"]["scenes"], [])
        self.assertNotIn("PRIVATE", json.dumps(result))
        self.assertEqual(self.api.calls, [])

    def test_official_spec_must_match_whole_device_urn(self):
        self.raw["type"] += ":DIFFERENT"
        self.assert_blocked({"operation": "get_property", "device": "d1", "property": "2.1"})

    def test_other_services_and_vendor_property_cannot_borrow_on_name(self):
        for service, prop in (("urn:miot-spec-v2:service:camera-control:00007830:test:1", "urn:miot-spec-v2:property:on:00000006:test:1"),
                              ("urn:miot-spec-v2:service:light:00007802:test:1", "urn:vendor:property:on:00000006:test:1"),
                              ("urn:miot-spec-v2:service:light:00007802:test:1", "urn:miot-spec-v2:property:privacy-mode:00000006:test:1")):
            self.raw["services"][0]["type"] = service
            self.raw["services"][0]["properties"][0]["type"] = prop
            self.assert_blocked({"operation": "get_property", "device": "d1", "property": "2.1"})

    def test_string_disguised_as_on_is_not_exposed_or_read(self):
        self.raw["services"][0]["properties"][0]["format"] = "string"
        self.parsed["properties"][0]["type"] = "string"
        result = self.call({"operation": "device_info", "device": "d1"})
        self.assertEqual([p["id"] for p in result["data"]["properties"]], ["2.2"])
        self.assert_blocked({"operation": "get_property", "device": "d1", "property": "2.1"})

    def test_string_property_id_is_rejected_even_on_allowed_light(self):
        self.assert_blocked({"operation": "get_property", "device": "d1", "property": "4.1"})
        self.assert_blocked({"operation": "set_property", "device": "d1", "home_id": "h1", "property": "4.1", "value": "execute"})

    def test_schema_readonly_cannot_be_overridden_by_sdk_rw(self):
        self.raw["services"][0]["properties"][0]["access"] = ["read"]
        self.assert_blocked({"operation": "set_property", "device": "d1", "home_id": "h1", "property": "2.1", "value": True})

    def test_sdk_names_and_enumerations_cannot_add_private_text_to_allowed_property(self):
        self.parsed["properties"][0].update(name="PRIVATE_COMMAND", description="PRIVATE_COMMAND",
                                              **{"value-list": [{"value": "PRIVATE_VALUE", "description": "PRIVATE_DESCRIPTION"}]})
        result = self.call({"operation": "device_info", "device": "d1"})
        self.assertTrue(result["ok"])
        self.assertNotIn("PRIVATE_", json.dumps(result))

    def test_official_sensitive_enum_rejects_capability(self):
        self.raw["services"][0]["properties"][0]["value-list"] = [{"value": "PRIVATE_VALUE"}]
        result = self.assert_blocked({"operation": "get_property", "device": "d1", "property": "2.1"})
        self.assertNotIn("PRIVATE_VALUE", json.dumps(result))

    def test_duplicate_service_and_property_ids_fail_closed(self):
        self.raw["services"].append(copy.deepcopy(self.raw["services"][0]))
        self.assert_blocked({"operation": "get_property", "device": "d1", "property": "2.1"})
        self.raw = copy.deepcopy(fixtures.RAW_SPEC)
        self.raw["services"][0]["properties"].append(copy.deepcopy(self.raw["services"][0]["properties"][0]))
        self.assert_blocked({"operation": "get_property", "device": "d1", "property": "2.1"})

    def test_readable_value_string_cannot_exfiltrate(self):
        self.api.value = "https://example.invalid/?token=SYNTHETIC_PRIVATE"
        result = self.call({"operation": "get_property", "device": "d1", "property": "2.1"})
        self.assertFalse(result["ok"])
        self.assertNotIn("SYNTHETIC_PRIVATE", json.dumps(result))

    def test_unsigned_format_caps_apply_without_explicit_range(self):
        for format_name, maximum in (("uint8", 255), ("uint16", 65535), ("uint32", 2**32 - 1)):
            with self.subTest(format_name=format_name):
                raw_property = self.raw["services"][0]["properties"][1]
                raw_property["format"] = format_name
                raw_property.pop("value-range", None)
                props = policy.safe_properties(self.api.devices[0], self.parsed["properties"], self.raw)
                prop = next(p for p in props if p["name"] == "brightness")
                self.assertEqual(prop["range"], [0, maximum, 1])
                self.assertTrue(policy.safe_value(prop, maximum))
                for value in (maximum + 1, 2**40, -1, True, float(maximum)):
                    self.assertFalse(policy.safe_value(prop, value))
                    request = {"operation": "set_property", "device": "d1", "home_id": "h1", "property": "2.2", "value": value}
                    self.assert_blocked({"operation": "prepare", "request": request})
                    self.assert_blocked(request)

    def test_unsigned_readback_and_cloud_reads_obey_format_range_and_exact_step(self):
        for format_name, bounds, invalid_value in (("uint8", None, 256), ("uint32", None, 2**32),
                                                   ("uint8", [0, 100, 5], 101), ("uint8", [0, 100, 5], 51),
                                                   ("uint32", [0, 2**32 - 1, 3], 2**32 - 2)):
            with self.subTest(format_name=format_name, bounds=bounds, value=invalid_value):
                self.api.calls = []
                raw_property = self.raw["services"][0]["properties"][1]
                raw_property.update(format=format_name, **{"value-range": bounds})
                self.api.value, self.api.update_value = invalid_value, False
                read = self.call({"operation": "get_property", "device": "d1", "property": "2.2"})
                self.assertFalse(read["ok"])
                write = self.call({"operation": "set_property", "device": "d1", "home_id": "h1", "property": "2.2", "value": 0})
                self.assertEqual(write["data"]["status"], "unconfirmed")
                self.assertNotIn("value", write["data"])
                self.assertEqual(sum(c[0] == "write" for c in self.api.calls), 1)

    def test_invalid_unsigned_spec_range_and_enum_fail_closed(self):
        raw_property = self.raw["services"][0]["properties"][1]
        for bounds in ([0, 256, 1], [-1, 100, 1], [0, 100, 0], [0, 100, 0.5], [0, 100, True]):
            raw_property["value-range"] = bounds
            self.assert_blocked({"operation": "get_property", "device": "d1", "property": "2.2"})
        raw_property.pop("value-range")
        raw_property["value-list"] = [{"value": 256}]
        self.assert_blocked({"operation": "get_property", "device": "d1", "property": "2.2"})

    def test_write_readback_string_is_dropped_and_never_retried(self):
        self.api.update_value = False
        self.api.value = "SYNTHETIC_PRIVATE"
        result = self.call({"operation": "set_property", "device": "d1", "home_id": "h1", "property": "2.1", "value": True})
        self.assertEqual(result["data"]["status"], "unconfirmed")
        self.assertNotIn("SYNTHETIC_PRIVATE", json.dumps(result))
        self.assertEqual(sum(c[0] == "write" for c in self.api.calls), 1)

    def test_current_mesh_switch_standard_on_survives_and_other_services_hidden(self):
        urn = "urn:miot-spec-v2:device:switch:0000A003:zimi-dhkg01:2:0000C808"
        self.api.devices[0].update(model="zimi.switch.dhkg01", spec_type=urn)
        self.raw["type"] = urn
        self.raw["services"][0]["type"] = "urn:miot-spec-v2:service:switch:0000780C:zimi-dhkg01:1:0000C808"
        self.raw["services"].append({"iid": 10, "type": "urn:miot-spec-v2:service:indicator-light:00007803:zimi-dhkg01:2", "properties": []})
        info = self.call({"operation": "device_info", "device": "d1"})
        self.assertEqual([p["id"] for p in info["data"]["properties"]], ["2.1"])
        self.assertEqual(info["data"]["actions"], [])
        result = self.call({"operation": "set_property", "device": "d1", "home_id": "h1", "property": "2.1", "value": False})
        self.assertEqual(result["data"]["status"], "verified")
        self.assertEqual(sum(c[0] == "write" for c in self.api.calls), 1)


class SensorPolicyTests(unittest.TestCase):
    call = SecurityPolicyTests.call
    assert_blocked = SecurityPolicyTests.assert_blocked
    assert_no_device_io = SecurityPolicyTests.assert_no_device_io

    def setUp(self):
        SecurityPolicyTests.setUp(self)
        urn = "urn:miot-spec-v2:device:temperature-humidity-sensor:0000A00A:miaomiaoce-t9:1"
        self.api.devices[0].update(model="miaomiaoce.sensor_ht.t9", spec_type=urn, name="温湿度计")
        self.raw = {"type": urn, "services": [{"iid": 3,
            "type": "urn:miot-spec-v2:service:temperature-humidity-sensor:00007814:miaomiaoce-t9:1",
            "properties": [
                {"iid": 1001, "type": "urn:miot-spec-v2:property:temperature:00000020:miaomiaoce-t9:1",
                 "format": "float", "access": ["read", "notify"], "unit": "celsius", "value-range": [-30, 100, 0.1]},
                {"iid": 1002, "type": "urn:miot-spec-v2:property:relative-humidity:0000000C:miaomiaoce-t9:1",
                 "format": "uint8", "access": ["read", "notify"], "unit": "percentage", "value-range": [0, 100, 1]}]}]}
        self.parsed = {"properties": [
            {"name": "temperature", "description": "温度", "type": "float", "rw": "r",
             "method": {"siid": 3, "piid": 1001}, "range": [-30, 100, 0.1], "value-list": None},
            {"name": "relative-humidity", "description": "湿度", "type": "uint", "rw": "r",
             "method": {"siid": 3, "piid": 1002}, "range": [0, 100, 1], "value-list": None}], "actions": []}

    def policy_properties(self):
        return policy.safe_properties(self.api.devices[0], self.parsed["properties"], self.raw)

    def test_actual_standard_sensor_exposes_only_readonly_temperature_and_humidity(self):
        self.assertEqual(policy.device_kind(self.api.devices[0]), policy.SENSOR_KIND)
        props = self.policy_properties()
        self.assertEqual([(p["name"], p["rw"], p["unit"]) for p in props],
                         [("temperature", "r", "celsius"), ("relative-humidity", "r", "percentage")])
        devices = self.call({"operation": "list_devices", "home_id": "h1"})
        self.assertEqual([d["did"] for d in devices["data"]["devices"]], ["d1"])
        info = self.call({"operation": "device_info", "device": "d1", "home_id": "h1"})
        self.assertEqual([p["id"] for p in info["data"]["properties"]], ["3.1001", "3.1002"])
        self.assertEqual(info["data"]["actions"], [])
        self.assert_no_device_io()

    def test_sensor_read_returns_only_valid_finite_numeric_value(self):
        for property_id, value in (("3.1001", -5.3), ("3.1001", 25.4), ("3.1002", 64)):
            self.api.value = value
            result = self.call({"operation": "get_property", "device": "d1", "home_id": "h1", "property": property_id})
            self.assertTrue(result["ok"], result)
            self.assertEqual(result["data"]["value"], value)
        self.assertFalse(any(c[0] in ("write", "action", "scene") for c in self.api.calls))

    def test_sensor_write_prepare_and_direct_execution_are_always_refused(self):
        for raw, parsed in zip(self.raw["services"][0]["properties"], self.parsed["properties"]):
            raw["access"].append("write")
            parsed["rw"] = "rw"
        self.assertTrue(all(p["rw"] == "r" for p in self.policy_properties()))
        for property_id, value in (("3.1001", 23.0), ("3.1002", 64)):
            request = {"operation": "set_property", "device": "d1", "home_id": "h1", "property": property_id, "value": value}
            self.assert_blocked({"operation": "prepare", "request": request})
            self.assert_blocked(request)

    def test_missing_or_wrong_units_cannot_be_inferred_from_names(self):
        for unit in (None, "fahrenheit", "celsius PRIVATE", "percentage"):
            self.raw["services"][0]["properties"][0]["unit"] = unit
            self.assertEqual([p["name"] for p in self.policy_properties()], ["relative-humidity"])
            self.assert_blocked({"operation": "get_property", "device": "d1", "property": "3.1001"})
        self.raw["services"][0]["properties"][0]["unit"] = "celsius"
        self.raw["services"][0]["properties"][1]["unit"] = "ratio"
        self.assertEqual([p["name"] for p in self.policy_properties()], ["temperature"])

    def test_sensor_standard_service_property_codes_and_sdk_primitive_must_match(self):
        original = copy.deepcopy(self.raw)
        for field, value in (("service", "urn:miot-spec-v2:service:temperature-humidity-sensor:00007815:miaomiaoce-t9:1"),
                             ("property", "urn:miot-spec-v2:property:temperature:00000021:miaomiaoce-t9:1"),
                             ("property", "urn:vendor:property:temperature:00000020:miaomiaoce-t9:1")):
            self.raw = copy.deepcopy(original)
            target = self.raw["services"][0] if field == "service" else self.raw["services"][0]["properties"][0]
            target["type"] = value
            self.assert_blocked({"operation": "get_property", "device": "d1", "property": "3.1001"})
        self.raw = original
        self.parsed["properties"][0]["type"] = "string"
        self.assert_blocked({"operation": "get_property", "device": "d1", "property": "3.1001"})

    def test_camera_with_sensor_service_stays_hidden_and_unreadable(self):
        self.api.devices[0]["spec_type"] = "urn:miot-spec-v2:device:camera:0000A01C:miaomiaoce-t9:1"
        self.raw["type"] = self.api.devices[0]["spec_type"]
        self.assertEqual(self.call({"operation": "list_devices"})["data"]["devices"], [])
        self.assert_blocked({"operation": "get_property", "device": "d1", "property": "3.1001"})

    def test_sensor_cannot_gain_light_control_by_adding_standard_on_property(self):
        self.raw["services"][0]["properties"].append({"iid": 9,
            "type": "urn:miot-spec-v2:property:on:00000006:miaomiaoce-t9:1", "format": "bool", "access": ["read", "write"]})
        self.parsed["properties"].append({"name": "on", "type": "bool", "rw": "rw", "method": {"siid": 3, "piid": 9}})
        self.assertEqual(len(self.policy_properties()), 2)
        self.assert_blocked({"operation": "set_property", "device": "d1", "home_id": "h1", "property": "3.9", "value": True})

    def test_sensor_invalid_values_are_never_returned(self):
        for property_id, values in (("3.1001", (True, "25.4", None, float("nan"), float("inf"), 101, -31, 25.45, 10**400)),
                                    ("3.1002", (True, "64", None, 64.0, -1, 101, 2**40))):
            for value in values:
                self.api.value = value
                result = self.call({"operation": "get_property", "device": "d1", "property": property_id})
                self.assertFalse(result["ok"], (property_id, value, result))
                self.assertNotIn("data", result)
        self.assertFalse(any(c[0] in ("write", "action", "scene") for c in self.api.calls))

    def test_sensor_invalid_or_absent_ranges_fail_closed(self):
        for bounds in (None, [], [-30, 100, 0], [-30, float("inf"), .1], [-300, 100, .1], [-30, 1001, .1], [-30, 100, True]):
            self.raw["services"][0]["properties"][0]["value-range"] = bounds
            self.assert_blocked({"operation": "get_property", "device": "d1", "property": "3.1001"})
        self.raw["services"][0]["properties"][0]["value-range"] = [-30, 100, .1]
        for bounds in (None, [0, 255, 1], [-1, 100, 1]):
            self.raw["services"][0]["properties"][1]["value-range"] = bounds
            self.assert_blocked({"operation": "get_property", "device": "d1", "property": "3.1002"})

    def test_sensor_foreign_home_and_actions_remain_blocked(self):
        self.api.devices[0]["home_id"] = "h2"
        self.assert_blocked({"operation": "get_property", "device": "d1", "home_id": "h1", "property": "3.1001"})
        self.assert_blocked({"operation": "action", "device": "d1", "home_id": "h2", "action": "3.1", "inputs": []})
        self.assert_blocked({"operation": "run_scene", "home_id": "h2", "scene": "s1"})


if __name__ == "__main__":
    unittest.main(verbosity=2)
