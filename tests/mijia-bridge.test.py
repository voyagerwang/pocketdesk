#!/usr/bin/env python3
"""
[INPUT]: scripts/mijia-bridge.py 与内存 SDK/API/官方规格替身；临时授权文件与隔离子进程。
[OUTPUT]: 验证认证/家庭隔离、灯开关最小能力、官方规格失败关闭、动作场景拒绝、写入/回执与凭据边界。
[POS]: tests 的米家协议验收；验证 Python 边界，Swift 的租约和持久去重由独立执行器测试覆盖。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""

import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "mijia-bridge.py"
SPEC = importlib.util.spec_from_file_location("pocketdesk_mijia_bridge", SCRIPT)
bridge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bridge)
DEVICE = {"did": "d1", "name": "客厅灯", "model": "test.light.v1", "home_id": "h1",
          "room_name": "客厅", "isOnline": True, "spec_type": "urn:miot-spec-v2:device:light:0000A001:test:1",
          "token": "SECRET_TOKEN", "mac": "SECRET_MAC", "localip": "SECRET_IP", "uid": "SECRET_UID"}
PROPERTIES = [
    {"name": "on", "description": "开关", "type": "bool", "rw": "rw", "range": None,
     "value-list": None, "method": {"siid": 2, "piid": 1}},
    {"name": "brightness", "description": "亮度", "type": "uint", "rw": "rw", "range": [0, 100, 5],
     "value-list": None, "method": {"siid": 2, "piid": 2}},
    {"name": "mode", "description": "模式", "type": "int", "rw": "rw", "range": None,
     "value-list": [{"value": 0, "description": "正常"}, {"value": 2, "description": "睡眠"}],
     "method": {"siid": 2, "piid": 3}},
    {"name": "temperature", "description": "温度", "type": "float", "rw": "r", "range": [-20, 50, .1],
     "value-list": None, "method": {"siid": 3, "piid": 1}},
    {"name": "command", "description": "命令", "type": "string", "rw": "w", "range": None,
     "value-list": None, "method": {"siid": 4, "piid": 1}},
]
ACTIONS = [{"name": "toggle", "description": "切换", "method": {"siid": 2, "aiid": 1}},
           {"name": "set-count", "description": "喂食", "method": {"siid": 2, "aiid": 2}}]
RAW_SPEC = {"type": DEVICE["spec_type"], "services": [{
    "iid": 2, "type": "urn:miot-spec-v2:service:light:00007802:test:1",
    "properties": [
        {"iid": 1, "type": "urn:miot-spec-v2:property:on:00000006:test:1", "format": "bool", "access": ["read", "write"]},
        {"iid": 2, "type": "urn:miot-spec-v2:property:brightness:0000000D:test:1", "format": "uint8", "access": ["read", "write"], "value-range": [0, 100, 5]},
    ], "actions": [{"iid": 1, "in": []}, {"iid": 2, "in": [5]}]}]}



class API:
    def __init__(self):
        self.auth_data = {"serviceToken": "SECRET_TOKEN"}
        self.devices = [copy.deepcopy(DEVICE)]
        self.homes = [{"id": "h1", "name": "我的家", "uid": "SECRET_OWNER", "location": "SECRET_ADDRESS"}]
        self.shared = []
        self.scenes = [{"scene_id": "s1", "name": "回家", "home_id": "h1", "uid": "SECRET_UID"}]
        self.calls = []
        self.failure = None
        self.read_code = 0
        self.write_code = 0
        self.action_code = 0
        self.scene_response = True
        self.value = True
        self.update_value = True
        self.raise_write = False
        self.write_response = None

    def check_new_msg(self, refresh_token=True):
        self.calls.append(("auth", refresh_token))
        if self.failure:
            raise self.failure
        return {}

    def get_devices_list(self, home_id=None):
        self.calls.append(("devices", home_id))
        if self.failure:
            raise self.failure
        return [copy.deepcopy(d) for d in self.devices if home_id is None or d.get("home_id") == home_id]

    def get_homes_list(self):
        self.calls.append(("homes",))
        if self.failure:
            raise self.failure
        return copy.deepcopy(self.homes)

    def get_shared_devices_list(self):
        self.calls.append(("shared",))
        return copy.deepcopy(self.shared)

    def get_scenes_list(self, home_id=None):
        self.calls.append(("scenes", home_id))
        return [copy.deepcopy(s) for s in self.scenes if home_id is None or s.get("home_id") == home_id]

    def get_devices_prop(self, method):
        self.calls.append(("read", copy.deepcopy(method)))
        return {**method, "code": self.read_code, "value": self.value}

    def _request(self, uri, data):
        self.calls.append(("rpc_source", uri, copy.deepcopy(data)))
        return [self.get_devices_prop(data["params"][0])]

    def set_devices_prop(self, method):
        self.calls.append(("write", copy.deepcopy(method)))
        if self.raise_write:
            raise Timeout("SECRET_TOKEN")
        if self.update_value:
            self.value = method["value"]
        if self.write_response is not None:
            return copy.deepcopy(self.write_response)
        return {**method, "code": self.write_code}

    def run_action(self, method):
        self.calls.append(("action", copy.deepcopy(method)))
        return {**method, "code": self.action_code}

    def run_scene(self, scene, home_id):
        self.calls.append(("scene", scene, home_id))
        return copy.deepcopy(self.scene_response)


class LoginError(Exception):
    pass


class Timeout(Exception):
    pass


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.api = API()
        self.info = {"properties": copy.deepcopy(PROPERTIES), "actions": copy.deepcopy(ACTIONS)}
        self.sdk = SimpleNamespace(__version__="5.0.0", get_device_info=self.get_info)
        self.spec_calls = []
        self.raw = copy.deepcopy(RAW_SPEC)

    def get_info(self, urn, cache_path=None):
        self.spec_calls.append((urn, cache_path))
        return copy.deepcopy(self.info)

    def call(self, operation, **kwargs):
        request = {"operation": operation, **kwargs}
        if operation in bridge.MUTATIONS:
            result = bridge.envelope({"operation": "prepare", "request": request}, Path("/unused"),
                                     sdk=self.sdk, api=self.api, raw_spec=lambda urn: copy.deepcopy(self.raw))
            if not result["ok"]:
                return result
            request = result["data"]["request"]
        return bridge.envelope(request, Path("/unused"), sdk=self.sdk,
                               api=self.api, raw_spec=lambda urn: copy.deepcopy(self.raw))

    def mutations(self):
        return [c for c in self.api.calls if c[0] in ("write", "action", "scene")]

    def assert_invalid(self, result):
        self.assertFalse(result["ok"], result)
        self.assertIn(result["error"]["kind"], ("invalid", "choice", "policy"))
        self.assertEqual(self.mutations(), [])

    def test_status_checks_real_homes_and_disables_hidden_refresh(self):
        result = self.call("status")
        self.assertEqual(result["data"], {"authenticated": True, "sdk_version": "5.0.0"})
        self.assertEqual(self.api.calls, [("homes",)])
        self.assertEqual(self.api._refresh_token(), self.api.auth_data)

    def test_real_device_auth_failure_never_reads_spec_or_mutates(self):
        self.api.failure = LoginError("SECRET_TOKEN")
        result = self.call("set_property", device="客厅灯", property="on", value=True)
        self.assertEqual(result["error"]["kind"], "auth")
        self.assertEqual(self.api.calls, [("devices", None)])
        self.assertEqual(self.mutations(), [])
        self.assertEqual(self.spec_calls, [])
        self.assertNotIn("SECRET", json.dumps(result))

    def test_network_auth_is_not_false_expiration(self):
        self.api.failure = Timeout("SECRET_TOKEN")
        self.assertEqual(self.call("status")["error"]["kind"], "network")

    def test_device_operations_never_depend_on_message_notification_probe(self):
        def forbidden_probe(*args, **kwargs):
            self.fail("消息接口不得阻止设备操作")
        self.api.check_new_msg = forbidden_probe
        operations = [("list_devices", {}), ("device_info", {"device": "d1"}),
                      ("get_property", {"device": "d1", "property": "2.1"}),
                      ("set_property", {"device": "d1", "property": "2.1", "value": False}),
                      ("list_scenes", {})]
        for operation, arguments in operations:
            with self.subTest(operation=operation):
                self.api.calls = []
                result = self.call(operation, home_id="h1", **arguments)
                self.assertTrue(result["ok"], result)
                self.assertNotIn(("homes",), self.api.calls)
                self.assertFalse(any(call[0] == "auth" for call in self.api.calls))

    def test_real_home_status_errors_keep_auth_and_network_distinct(self):
        for error, expected in ((LoginError("SECRET_AUTH"), "auth"),
                                (Timeout("SECRET_NETWORK"), "network"),
                                (RuntimeError("SECRET_API"), "api")):
            with self.subTest(error=type(error).__name__):
                self.api.calls = []
                self.api.failure = error
                result = self.call("status")
                self.assertFalse(result["ok"])
                self.assertEqual(result["error"]["kind"], expected)
                self.assertEqual(self.api.calls, [("homes",)])
                self.assertNotIn("SECRET", json.dumps(result))

    def test_real_device_network_failure_does_not_claim_expired_auth(self):
        self.api.failure = Timeout("SECRET_NETWORK")
        result = self.call("get_property", device="d1", home_id="h1", property="2.1")
        self.assertEqual(result["error"]["kind"], "network")
        self.assertEqual(self.api.calls, [("devices", "h1")])
        self.assertEqual(self.spec_calls, [])
        self.assertEqual(self.mutations(), [])

    def test_cloud_offline_flag_does_not_prevent_explicit_device_read(self):
        self.api.devices[0]["isOnline"] = False
        result = self.call("get_property", device="d1", home_id="h1", property="2.1")
        self.assertTrue(result["ok"], result)
        self.assertFalse(result["data"]["device"]["online"])
        self.assertEqual(result["data"]["source"], "cloud")
        self.assertEqual(len([call for call in self.api.calls if call[0] == "read"]), 1)

    def test_cloud_offline_flag_still_uses_fresh_scoped_write_validation(self):
        self.api.devices[0]["isOnline"] = False
        result = self.call("set_property", device="d1", home_id="h1", property="2.1", value=False)
        self.assertEqual(result["data"]["status"], "verified")
        self.assertEqual(len(self.mutations()), 1)
        self.assertEqual([call for call in self.api.calls if call[0] == "devices"],
                         [("devices", "h1"), ("devices", "h1")])
        self.assertEqual(len(self.spec_calls), 2, "准备与执行各核验一次，不跨进程复用旧规格")

    def test_empty_home_account_can_be_authenticated_without_inventing_devices(self):
        self.api.homes = []
        result = self.call("status")
        self.assertTrue(result["data"]["authenticated"])
        self.assertEqual(self.api.calls, [("homes",)])
        self.assertEqual(self.spec_calls, [])

    def test_device_fields_are_whitelisted(self):
        result = self.call("list_devices")
        safe = result["data"]["devices"][0]
        self.assertEqual(set(safe), {"did", "name", "model", "home_id", "room", "online", "spec_type"})
        self.assertNotIn("SECRET", json.dumps(result))
        self.assertEqual(safe["room"], "客厅")

    def test_home_list_keeps_real_names_and_whitelists_only_identity(self):
        self.api.homes.append({"id": 42, "name": "我的家", "roomlist": ["SECRET_ROOM"], "owner": "SECRET"})
        result = self.call("list_homes")
        self.assertEqual(result["data"], {"homes": [{"id": "h1", "name": "我的家"},
                                                  {"id": "42", "name": "我的家"}], "truncated": False})
        self.assertEqual(self.api.calls, [("homes",)])
        self.assertNotIn("SECRET", json.dumps(result))
        self.assertEqual(self.mutations(), [])

    def test_home_list_rejects_malformed_or_duplicate_ids(self):
        for homes in ({}, [None], [{"id": True, "name": "家"}], [{"id": "", "name": "家"}],
                      [{"id": "h1", "name": ""}], [{"id": "h1", "name": None}],
                      [{"id": " h1 ", "name": "家"}], [{"id": "h1", "name": "x" * 513}],
                      [{"id": "h1", "name": "家一"}, {"id": "h1", "name": "家二"}],
                      [{"id": 42, "name": "家一"}, {"id": "42", "name": "家二"}]):
            with self.subTest(homes=homes):
                self.api.homes = homes
                result = self.call("list_homes")
                self.assertFalse(result["ok"])
                self.assertEqual(result["error"]["kind"], "api")

    def test_home_list_limits_rows_but_validates_ids_beyond_limit(self):
        self.api.homes = [{"id": str(i), "name": f"家庭 {i}"} for i in range(bridge.RESULT_LIMIT + 1)]
        result = self.call("list_homes")
        self.assertEqual(len(result["data"]["homes"]), bridge.RESULT_LIMIT)
        self.assertTrue(result["data"]["truncated"])
        self.api.homes[-1]["id"] = "0"
        self.assertFalse(self.call("list_homes")["ok"])

    def test_home_list_sdk_error_has_no_device_or_shared_fallback(self):
        def failure():
            self.api.calls.append(("homes",))
            raise Timeout("SECRET_SDK_ERROR")
        self.api.get_homes_list = failure
        result = self.call("list_homes")
        self.assertEqual(result["error"]["kind"], "network")
        self.assertEqual(self.api.calls, [("homes",)])
        self.assertNotIn("SECRET", json.dumps(result))

    def unfiltered_devices(self, home_id=None):
        self.api.calls.append(("devices", home_id))
        return copy.deepcopy(self.api.devices)

    def unfiltered_scenes(self, home_id=None):
        self.api.calls.append(("scenes", home_id))
        return copy.deepcopy(self.api.scenes)

    def test_home_scope_filters_untrusted_device_results_before_name_resolution(self):
        self.api.devices.append({**DEVICE, "did": "d2", "home_id": "h2"})
        self.api.get_devices_list = self.unfiltered_devices
        result = self.call("list_devices", home_id="h1")
        self.assertEqual([d["did"] for d in result["data"]["devices"]], ["d1"])
        prepared = self.call("prepare", request={"operation": "set_property", "home_id": "h1",
                                                 "device": "客厅灯", "property": "on", "value": True})
        self.assertEqual(prepared["data"]["request"]["device"], "d1")
        self.assertEqual(prepared["data"]["request"]["home_id"], "h1")
        self.assertEqual(self.mutations(), [])
        self.assertNotIn(("shared",), self.api.calls)

    def room_devices(self, home_id=None):
        self.api.get_homes_list()
        return API.get_devices_list(self.api, home_id)

    def test_rooms_reuse_existing_home_fetch_and_keep_unassigned_devices(self):
        self.api.devices[0].pop("room_name")
        self.api.devices.append({**DEVICE, "did": "d2", "name": "未分房灯", "room_name": ""})
        self.api.homes[0].update(dids=["d1", "d2"], roomlist=[{"id": "r1", "name": "书房", "dids": ["d1"]}])
        self.api.get_devices_list = self.room_devices
        result = self.call("list_devices", home_id="h1")
        rows = {device["did"]: device for device in result["data"]["devices"]}
        self.assertEqual(set(rows), {"d1", "d2"})
        self.assertEqual(rows["d1"]["room"], "书房")
        self.assertEqual(rows["d2"]["room"], "")
        self.assertEqual(self.api.calls, [("homes",), ("devices", "h1")])

    def test_rooms_do_not_trigger_home_fetch_or_replace_existing_room(self):
        self.api.homes[0]["roomlist"] = [{"id": "r1", "name": "书房", "dids": ["d1"]}]
        self.assertEqual(self.call("list_devices", home_id="h1")["data"]["devices"][0]["room"], "客厅")
        self.assertEqual(self.api.calls, [("devices", "h1")])
        self.api.calls = []
        self.api.devices[0].pop("room_name")
        self.assertEqual(self.call("list_devices", home_id="h1")["data"]["devices"][0]["room"], "")
        self.assertEqual(self.api.calls, [("devices", "h1")])
        self.api.devices[0]["room_name"] = "设备原房间"
        self.api.get_devices_list = self.room_devices
        self.assertEqual(self.call("list_devices", home_id="h1")["data"]["devices"][0]["room"], "设备原房间")

    def test_foreign_or_ambiguous_room_membership_cannot_fill_room(self):
        self.api.devices[0].pop("room_name")
        self.api.get_devices_list = self.room_devices
        self.api.homes.append({"id": "h2", "name": "另一家", "roomlist": [
            {"id": "foreign", "name": "其他家庭卧室", "dids": ["d1"]}]})
        self.assertEqual(self.call("list_devices", home_id="h1")["data"]["devices"][0]["room"], "")
        self.api.homes[0]["roomlist"] = [{"id": "r1", "name": "书房", "dids": ["d1"]},
                                           {"id": "r2", "name": "卧室", "dids": ["d1"]}]
        self.api.calls = []
        self.assertEqual(self.call("list_devices", home_id="h1")["data"]["devices"][0]["room"], "")
        self.assertEqual(self.api.calls, [("homes",), ("devices", "h1")])

    def test_direct_foreign_device_id_cannot_bypass_scoped_read_or_write(self):
        self.api.devices.append({**DEVICE, "did": "d2", "home_id": "h2"})
        self.api.get_devices_list = self.unfiltered_devices
        requests = [{"operation": "device_info", "device": "d2", "home_id": "h1"},
                    {"operation": "get_property", "device": "d2", "home_id": "h1", "property": "2.1"},
                    {"operation": "set_property", "device": "d2", "home_id": "h1", "property": "2.1", "value": True},
                    {"operation": "action", "device": "d2", "home_id": "h1", "action": "2.1", "inputs": []}]
        for request in requests:
            with self.subTest(operation=request["operation"]):
                result = bridge.envelope(request, Path("/unused"), sdk=self.sdk, api=self.api, raw_spec=lambda urn: copy.deepcopy(self.raw))
                self.assertFalse(result["ok"])
                self.assertEqual(self.mutations(), [])
        self.assertEqual(self.spec_calls, [])
        self.assertNotIn(("devices", None), self.api.calls)
        self.assertNotIn(("shared",), self.api.calls)

    def test_scoped_device_membership_missing_or_malformed_fails_closed(self):
        self.api.get_devices_list = self.unfiltered_devices
        for home_id in (None, "", True, [], "x" * 513):
            with self.subTest(home_id=home_id):
                self.api.devices[0]["home_id"] = home_id
                result = self.call("set_property", device="d1", home_id="h1", property="on", value=True)
                self.assertFalse(result["ok"])
                self.assertEqual(result["error"]["kind"], "api")
                self.assertEqual(self.mutations(), [])

    def test_prepared_device_moving_to_another_home_is_not_written(self):
        self.api.get_devices_list = self.unfiltered_devices
        result = self.call("prepare", request={"operation": "set_property", "device": "d1", "home_id": "h1",
                                               "property": "on", "value": True})
        self.api.devices[0]["home_id"] = "h2"
        response = bridge.envelope(result["data"]["request"], Path("/unused"), sdk=self.sdk, api=self.api, raw_spec=lambda urn: copy.deepcopy(self.raw))
        self.assertFalse(response["ok"])
        self.assertEqual(self.mutations(), [])

    def test_scoped_sdk_failures_never_fall_back_to_all_homes_or_shared(self):
        def failure(home_id=None):
            self.api.calls.append(("scope", home_id))
            raise Timeout("SECRET_SDK_ERROR")
        self.api.get_devices_list = failure
        self.api.get_scenes_list = failure
        for operation in ("list_devices",):
            self.api.calls = []
            result = self.call(operation, home_id="h1")
            self.assertEqual(result["error"]["kind"], "network")
            self.assertEqual(self.api.calls, [("scope", "h1")])

    def test_scene_list_hides_all_metadata_without_sdk_call(self):
        self.api.scenes[0]["name"] = "PRIVATE_CAMERA_SCENE"
        result = self.call("list_scenes", home_id="h1")
        self.assertEqual(result["data"]["scenes"], [])
        self.assertIn("security_notice", result["data"])
        self.assertEqual(self.api.calls, [])
        self.assertNotIn("PRIVATE_CAMERA_SCENE", json.dumps(result))

    def test_scoped_scene_without_membership_never_executes(self):
        self.api.get_scenes_list = self.unfiltered_scenes
        del self.api.scenes[0]["home_id"]
        result = self.call("run_scene", scene="s1", home_id="h1")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["kind"], "policy")
        self.assertEqual(self.mutations(), [])

    def test_discovery_query_and_home_filter(self):
        self.api.devices.append({**DEVICE, "did": "d2", "name": "卧室灯", "home_id": "h2"})
        self.assertEqual(len(self.call("list_devices", query="灯", home_id="h2")["data"]["devices"]), 1)
        self.assertEqual(self.call("list_devices", query="test.light")["data"]["devices"][0]["did"], "d1")

    def test_device_ambiguity_returns_safe_candidates(self):
        self.api.devices.append({**DEVICE, "did": "d2", "home_id": "h2"})
        result = self.call("set_property", device="客厅灯", property="on", value=True)
        self.assertEqual(result["error"]["kind"], "choice")
        self.assertEqual(len(result["error"]["candidates"]), 2)
        self.assertNotIn("SECRET", json.dumps(result))
        self.assertEqual(self.mutations(), [])

    def test_repeated_exact_device_records_are_deduplicated(self):
        self.api.devices.append(copy.deepcopy(DEVICE))
        self.assertTrue(self.call("device_info", device="d1")["ok"])

    def test_conflicting_records_for_same_did_are_ambiguous(self):
        self.api.devices.append({**DEVICE, "name": "其他灯"})
        self.assertEqual(self.call("device_info", device="d1")["error"]["kind"], "choice")

    def test_partial_name_cannot_mutate(self):
        result = self.call("set_property", device="灯", property="on", value=True)
        self.assertEqual(result["error"]["kind"], "choice")
        self.assertEqual(self.mutations(), [])

    def test_shared_device_exact_did(self):
        self.api.shared = [{**DEVICE, "did": "d3", "home_id": "shared", "name": "共享灯"}]
        result = self.call("device_info", device="d3", home_id="shared")
        self.assertTrue(result["ok"], result)
        self.assertNotIn(("devices", "shared"), self.api.calls)

    def test_current_spec_type_and_no_auth_cache(self):
        result = self.call("device_info", device="客厅灯")
        self.assertTrue(result["ok"])
        self.assertEqual(self.spec_calls, [(DEVICE["spec_type"], None)])
        self.assertEqual(result["data"]["properties"][0]["id"], "2.1")

    def test_missing_spec_cannot_control(self):
        self.api.devices[0].pop("spec_type")
        self.assert_invalid(self.call("set_property", device="d1", property="on", value=True))

    def test_prepare_is_canonical_and_read_only(self):
        first = self.call("prepare", request={"operation": "set_property", "device": "客厅灯", "property": "on", "value": True})
        second = self.call("prepare", request={"operation": "set_property", "device": "d1", "property": "2.1", "value": True})
        self.assertEqual(first["data"]["request"], second["data"]["request"])
        self.assertEqual(first["data"]["request"], {"operation": "set_property", "device": "d1", "property": "2.1", "home_id": "h1", "value": True})
        self.assertFalse(first["mutating"])
        self.assertEqual(self.mutations(), [])

    def test_revalidate_prepared_request_after_device_change(self):
        result = self.call("prepare", request={"operation": "set_property", "device": "d1", "property": "on", "value": True})
        self.info["properties"][0]["rw"] = "r"
        self.assert_invalid(bridge.envelope(result["data"]["request"], Path("/unused"), sdk=self.sdk, api=self.api, raw_spec=lambda urn: copy.deepcopy(self.raw)))

    def test_disappeared_did_cannot_fall_back_to_reassigned_name(self):
        prepared = self.call("prepare", request={"operation": "set_property", "device": "d1", "property": "on", "value": True})
        self.api.devices = [{**DEVICE, "did": "d999", "name": "d1"}]
        result = bridge.envelope(prepared["data"]["request"], Path("/unused"), sdk=self.sdk, api=self.api, raw_spec=lambda urn: copy.deepcopy(self.raw))
        self.assert_invalid(result)

    def test_disappeared_property_id_cannot_fall_back_to_name(self):
        prepared = self.call("prepare", request={"operation": "set_property", "device": "d1", "property": "on", "value": True})
        self.info["properties"][0].update(name="2.1", method={"siid": 5, "piid": 9})
        result = bridge.envelope(prepared["data"]["request"], Path("/unused"), sdk=self.sdk, api=self.api, raw_spec=lambda urn: copy.deepcopy(self.raw))
        self.assert_invalid(result)

    def test_scene_prepare_and_execution_are_both_disabled(self):
        for request in ({"operation": "run_scene", "scene": "s1"},
                        {"operation": "prepare", "request": {"operation": "run_scene", "scene": "s1"}}):
            result = bridge.envelope(request, Path("/unused"), sdk=self.sdk, api=self.api)
            self.assertEqual(result["error"]["kind"], "policy")
        self.assertEqual(self.api.calls, [])

    def test_property_ambiguous_name_uses_number(self):
        self.info["properties"].append({**PROPERTIES[0], "method": {"siid": 5, "piid": 1}})
        self.raw["services"].append({**copy.deepcopy(self.raw["services"][0]), "iid": 5})
        result = self.call("get_property", device="d1", property="on")
        self.assertEqual(result["error"]["kind"], "choice")
        self.assertTrue(self.call("get_property", device="d1", property="2.1")["ok"])

    def test_nonreadable_and_nonwritable(self):
        self.assert_invalid(self.call("get_property", device="d1", property="command"))
        self.assert_invalid(self.call("set_property", device="d1", property="temperature", value=20.0))

    def test_boolean_integer_and_string_coercions_rejected(self):
        for value in (1, "true", None):
            with self.subTest(value=value):
                self.assert_invalid(self.call("set_property", device="d1", property="on", value=value))
        self.assert_invalid(self.call("set_property", device="d1", property="brightness", value=True))
        self.assert_invalid(self.call("set_property", device="d1", property="brightness", value="50"))

    def test_range_step_and_enumeration(self):
        for value in (-1, 101, 51):
            self.assert_invalid(self.call("set_property", device="d1", property="brightness", value=value))
        self.assert_invalid(self.call("set_property", device="d1", property="mode", value=1))
        self.assert_invalid(self.call("set_property", device="d1", property="mode", value=False))
        self.assertTrue(self.call("set_property", device="d1", property="brightness", value=55)["data"]["verified"])

    def test_float_nan_and_step_rejected(self):
        prop = {**PROPERTIES[3], "rw": "rw"}
        self.info["properties"][3] = prop
        self.assert_invalid(self.call("set_property", device="d1", property="temperature", value=float("nan")))
        self.assert_invalid(self.call("set_property", device="d1", property="temperature", value=20.05))

    def test_non_allowlisted_float_property_is_rejected_before_read_or_write(self):
        self.info["properties"][3]["rw"] = "rw"
        result = self.call("prepare", request={"operation": "set_property", "device": "d1", "property": "temperature", "value": 20.0})
        self.assert_invalid(result)
        self.assertFalse(any(c[0] == "read" for c in self.api.calls))

    def test_read_failure_code_checked(self):
        for code in (-704042011, -10007):
            with self.subTest(code=code):
                self.api.read_code = code
                result = self.call("get_property", device="d1", property="on")
                self.assertFalse(result["ok"])
                self.assertEqual(result["error"]["kind"], "api")
                self.assertEqual(result["error"]["code"], code)
                self.assertIn("离线", result["error"]["message"])
                self.assertNotIn("授权已失效", result["error"]["message"])

    def test_boolean_code_is_never_success(self):
        self.api.read_code = False
        self.assertFalse(self.call("get_property", device="d1", property="on")["ok"])
        self.api.write_code = False
        result = self.call("set_property", device="d1", property="on", value=False)
        self.assertEqual(result["data"]["status"], "unconfirmed")
        self.assertEqual(len(self.mutations()), 1)

    def test_write_exactly_once_and_readback_verifies(self):
        result = self.call("set_property", device="客厅灯", property="on", value=False)
        self.assertEqual(result["data"]["status"], "verified")
        self.assertTrue(result["data"]["verified"])
        self.assertEqual(len(self.mutations()), 1)
        self.assertEqual(len([c for c in self.api.calls if c[0] == "read"]), 1)
        rpc = [c for c in self.api.calls if c[0] == "rpc_source"]
        self.assertEqual(rpc[0][1:], ("/miotspec/prop/get", {"params": [{"did": "d1", "siid": 2, "piid": 1}], "datasource": 2}))

    def test_readback_mismatch_never_claims_complete_or_rewrites(self):
        self.api.update_value = False
        result = self.call("set_property", device="d1", property="on", value=False)
        self.assertTrue(result["data"]["accepted"])
        self.assertEqual(result["data"]["status"], "unconfirmed")
        self.assertFalse(result["data"]["verified"])
        self.assertEqual(len(self.mutations()), 1)

    def test_readback_failure_keeps_accepted_unknown(self):
        self.api.read_code = -1
        result = self.call("set_property", device="d1", property="on", value=False)
        self.assertEqual(result["data"]["status"], "unconfirmed")
        self.assertTrue(result["data"]["accepted"])
        self.assertEqual(len(self.mutations()), 1)

    def test_gateway_code_one_can_only_verify_through_readback(self):
        self.api.write_code = 1
        result = self.call("set_property", device="d1", property="on", value=False)
        self.assertEqual(result["data"]["status"], "verified")
        self.api.update_value = False
        result = self.call("set_property", device="d1", property="on", value=True)
        self.assertEqual(result["data"]["status"], "unconfirmed")

    def test_write_only_ack_is_accepted_without_verification(self):
        self.info["properties"][0]["rw"] = "w"
        result = self.call("set_property", device="d1", property="on", value=True)
        self.assertEqual(result["data"]["status"], "accepted")
        self.assertFalse(result["data"]["verified"])
        self.assertEqual(len([c for c in self.api.calls if c[0] == "read"]), 0)

    def test_negative_write_code_is_explicit_failure(self):
        self.api.write_code = -704030023
        result = self.call("set_property", device="d1", property="on", value=False)
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], -704030023)
        self.assertEqual(len(self.mutations()), 1)
        self.assertEqual(len([c for c in self.api.calls if c[0] == "read"]), 0)

    def test_write_timeout_is_unknown_and_never_retried(self):
        self.api.raise_write = True
        result = self.call("set_property", device="d1", property="on", value=False)
        self.assertEqual(result["data"]["status"], "unconfirmed")
        self.assertEqual(len(self.mutations()), 1)
        self.assertNotIn("SECRET", json.dumps(result))

    def test_foreign_target_receipt_is_unknown(self):
        self.api.write_response = {"code": 0, "did": "other", "siid": 2, "piid": 1}
        result = self.call("set_property", device="d1", property="on", value=False)
        self.assertEqual(result["data"]["status"], "unconfirmed")
        self.assertEqual(len(self.mutations()), 1)

    def test_all_actions_are_rejected_before_device_discovery(self):
        for inputs in ([], [2], ["打开另一个家庭的摄像头"]):
            result = self.call("action", device="d1", action="2.1", inputs=inputs)
            self.assertEqual(result["error"]["kind"], "policy")
        self.assertEqual(self.api.calls, [])
        self.assertEqual(self.spec_calls, [])

    def test_device_info_exposes_only_allowlisted_properties_and_no_actions(self):
        result = self.call("device_info", device="d1")
        self.assertEqual(result["data"]["actions"], [])
        self.assertEqual([p["id"] for p in result["data"]["properties"]], ["2.1", "2.2"])

    def test_official_spec_failure_blocks_all_capabilities_without_retry(self):
        for response in (Timeout("SECRET_SPEC"), {}, {"services": "invalid"}):
            with self.subTest(response=type(response).__name__):
                requests = []
                def unavailable(urn):
                    requests.append(urn)
                    if isinstance(response, Exception):
                        raise response
                    return response
                result = bridge.envelope({"operation": "device_info", "device": "d1", "home_id": "h1"},
                                         Path("/unused"), sdk=self.sdk, api=self.api, raw_spec=unavailable)
                self.assertFalse(result["ok"], result)
                self.assertEqual(requests, [DEVICE["spec_type"]])
                self.assertNotIn("data", result)
                self.assertEqual(self.mutations(), [])
                self.assertNotIn("SECRET", json.dumps(result))

    def test_official_spec_success_is_not_reused_across_operations(self):
        requests = []
        def fetch(urn):
            requests.append(urn)
            return copy.deepcopy(self.raw)
        for _ in range(2):
            result = bridge.envelope({"operation": "device_info", "device": "d1", "home_id": "h1"},
                                     Path("/unused"), sdk=self.sdk, api=self.api, raw_spec=fetch)
            self.assertTrue(result["ok"], result)
            self.assertEqual(result["data"]["actions"], [])
            self.assertEqual(len(result["data"]["properties"]), 2)
        self.assertEqual(requests, [DEVICE["spec_type"], DEVICE["spec_type"]])

    def test_cached_spec_failure_is_retried_on_new_explicit_operation(self):
        requests = []
        def recovering(urn):
            requests.append(urn)
            if len(requests) == 1:
                raise Timeout("SECRET_SPEC")
            return copy.deepcopy(self.raw)
        first = bridge.envelope({"operation": "device_info", "device": "d1", "home_id": "h1"},
                                Path("/unused"), sdk=self.sdk, api=self.api, raw_spec=recovering)
        self.assertFalse(first["ok"])
        self.assertEqual(len(requests), 1)
        second = bridge.envelope({"operation": "device_info", "device": "d1", "home_id": "h1"},
                                 Path("/unused"), sdk=self.sdk, api=self.api, raw_spec=recovering)
        self.assertTrue(second["ok"])
        self.assertEqual(second["data"]["actions"], [])
        self.assertEqual(len(requests), 2)

    def test_raw_action_spec_missing_ids_refuses_mutation(self):
        result = bridge.envelope({"operation": "action", "device": "d1", "action": "toggle"},
                                 Path("/unused"), sdk=self.sdk, api=self.api, raw_spec=lambda urn: {})
        self.assertFalse(result["ok"])
        self.assertEqual(self.mutations(), [])

    def test_scene_response_cannot_override_local_policy(self):
        for response in (True, False, {"code": 0}, {"code": 1}, {"success": True}):
            self.api.scene_response = response
            result = self.call("run_scene", scene="s1")
            self.assertEqual(result["error"]["kind"], "policy")
        self.assertEqual(self.api.calls, [])

    def test_invalid_request_fields_precede_auth_and_mutation(self):
        result = self.call("set_property", device="d1", property="on", value=True, token="SECRET")
        self.assert_invalid(result)
        self.assertEqual(self.api.calls, [])


class FileAndProcessTests(unittest.TestCase):
    def test_credentials_permissions_and_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            parent.chmod(0o700)
            path = parent / "auth.json"
            path.write_text(json.dumps({k: "SECRET" for k in ("ua", "ssecurity", "userId", "cUserId", "serviceToken")}))
            path.chmod(0o600)
            bridge.check_auth_path(path)
            path.chmod(0o644)
            with self.assertRaises(bridge.BridgeError):
                bridge.check_auth_path(path)
            path.chmod(0o600)
            link = parent / "linked.json"
            link.symlink_to(path)
            with self.assertRaises(bridge.BridgeError):
                bridge.check_auth_path(link)

    def test_missing_and_malformed_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            parent.chmod(0o700)
            path = parent / "auth.json"
            for contents in (None, "invalid", "{}"):
                if contents is not None:
                    path.write_text(contents)
                    path.chmod(0o600)
                with self.assertRaises(bridge.BridgeError) as error:
                    bridge.check_auth_path(path)
                self.assertEqual(error.exception.payload["kind"], "auth")

    def test_cli_single_envelope_and_strict_json(self):
        for request in ('{} {}', '{"operation":"status","operation":"action"}',
                        '{"operation":"set_property","device":"d1","property":"on","value":NaN}',
                        '{"operation":"status","token":"SECRET"}'):
            result = subprocess.run([sys.executable, "-I", "-B", str(SCRIPT), "--auth", "/unused"],
                                    input=request, text=True, capture_output=True, check=True)
            self.assertEqual(len(result.stdout.splitlines()), 1)
            envelope = json.loads(result.stdout)
            self.assertEqual(envelope["error"]["kind"], "invalid")
            self.assertNotIn("SECRET", result.stdout + result.stderr)

    def test_sdk_version_rejects_future_schema(self):
        original = bridge.importlib.import_module
        bridge.importlib.import_module = lambda name: SimpleNamespace(__version__="6.0.0")
        try:
            with self.assertRaises(bridge.BridgeError) as error:
                bridge.load_sdk()
            self.assertEqual(error.exception.payload["kind"], "setup")
        finally:
            bridge.importlib.import_module = original


if __name__ == "__main__":
    unittest.main(verbosity=2)
