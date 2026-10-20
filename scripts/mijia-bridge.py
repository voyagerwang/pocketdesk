#!/usr/bin/env python3
"""
[INPUT]: 外部安装的 mijiaAPI 5.0.0、mijia-network.py 传输、mijia-policy.py 最小能力策略、mijia-sensor.py 只读查询、私有认证文件和 JSON 请求。
[OUTPUT]: stdout 脱敏回执；标准灯/开关基础属性与温湿度只读查询，敏感及未知设备/动作默认拒绝；读取明确设备/云端来源及可信更新时间，提供扫码事件、运行时检查与云端离线提示。
[POS]: scripts 的米家隔离进程边界；Swift 管理会话与家庭策略，本文件实时核对家庭设备目标、复用已取得家庭资料补房间，或将新授权写入独立暂存文件。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""

import argparse
import contextlib
import importlib
import importlib.util
import io
import json
import logging
import math
import os
from pathlib import Path
import re
import stat
import sys
import time
from urllib.parse import urlsplit


_NETWORK_SPEC = importlib.util.spec_from_file_location(
    "pocketdesk_mijia_network", Path(__file__).with_name("mijia-network.py"))
_network = importlib.util.module_from_spec(_NETWORK_SPEC)
_NETWORK_SPEC.loader.exec_module(_network)
_POLICY_SPEC = importlib.util.spec_from_file_location(
    "pocketdesk_mijia_policy", Path(__file__).with_name("mijia-policy.py"))
_policy = importlib.util.module_from_spec(_POLICY_SPEC)
_POLICY_SPEC.loader.exec_module(_policy)
_SENSOR_SPEC = importlib.util.spec_from_file_location(
    "pocketdesk_mijia_sensor", Path(__file__).with_name("mijia-sensor.py"))
_sensor = importlib.util.module_from_spec(_SENSOR_SPEC)
_SENSOR_SPEC.loader.exec_module(_sensor)
SDK_VERSION = "5.0.0"
REQUEST_LIMIT = 65536
RESULT_LIMIT = 200
HTTP_TIMEOUT = _network.HTTP_TIMEOUT
bounded_http = _network.bounded_http
LOGIN_TTL = 120
MUTATIONS = {"set_property", "action", "run_scene"}
FIELDS = {
    "status": set(),
    "list_homes": set(),
    "list_devices": {"query", "home_id"},
    "device_info": {"device", "home_id"},
    "get_property": {"device", "property", "home_id"},
    "query_environment": {"metric", "query", "home_id"},
    "set_property": {"device", "property", "value", "home_id"},
    "list_scenes": {"query", "home_id"},
    "run_scene": {"scene", "home_id"},
    "action": {"device", "action", "inputs", "home_id"},
    "prepare": {"request"},
}


class BridgeError(Exception):
    def __init__(self, kind, message, **details):
        super().__init__(message)
        self.payload = {"kind": kind, "message": message, **details}


def invalid(message):
    raise BridgeError("invalid", message)


def text(value, field, optional=False):
    if value is None and optional:
        return None
    if not isinstance(value, str) or not value.strip() or len(value) > 512:
        invalid(f"{field}必须是长度不超过 512 的非空文字。")
    return value.strip()


def scalar(value):
    return value is None or type(value) in (bool, int, str) or (
        type(value) is float and math.isfinite(value))


def clean_text(value):
    return str(value)[:512] if type(value) in (str, int) else ""


def clean_device(item):
    result = {key: clean_text(item.get(key)) for key in
              ("did", "name", "model", "home_id", "spec_type")}
    result["room"] = clean_text(item.get("room")) or clean_text(item.get("room_name"))
    online = item.get("online", item.get("isOnline"))
    result["online"] = online if type(online) is bool else None
    return result


def spec_id(item, iid):
    method = item.get("method", {})
    if not isinstance(method, dict) or any(type(method.get(k)) is not int or
                                          method[k] <= 0 for k in ("siid", iid)):
        raise BridgeError("api", "设备规格缺少有效的服务或功能编号。")
    return f"{method['siid']}.{method[iid]}"


def clean_property(item):
    result = {"id": spec_id(item, "piid"), "name": clean_text(item.get("name")),
              "description": clean_text(item.get("description")),
              "type": clean_text(item.get("type")), "rw": clean_text(item.get("rw")),
              "unit": item.get("unit") if item.get("unit") in ("celsius", "percentage") else None}
    value_range = item.get("range")
    result["range"] = value_range if isinstance(value_range, list) and all(
        type(v) in (int, float) and math.isfinite(v) for v in value_range) else None
    result["value_list"] = [{"value": v["value"],
                            "description": clean_text(v.get("description"))}
                           for v in item.get("value-list") or []
                           if isinstance(v, dict) and "value" in v and scalar(v["value"])]
    return result


def equal_value(left, right):
    if type(left) is bool or type(right) is bool:
        return type(left) is type(right) and left == right
    return scalar(left) and scalar(right) and left == right


def validate_value(prop, value):
    kind = prop.get("type")
    allowed = {"bool": lambda v: type(v) is bool,
               "int": lambda v: type(v) is int,
               "uint": lambda v: type(v) is int and v >= 0,
               "float": lambda v: type(v) in (int, float) and math.isfinite(v),
               "string": lambda v: isinstance(v, str) and len(v) <= 4096}
    if kind not in allowed or not allowed[kind](value):
        invalid(f"属性 {clean_text(prop.get('name'))} 的值必须符合 {clean_text(kind)} 类型。")
    if kind == "float":
        value = float(value)
        if value == 0:
            value = 0.0
    value_range = prop.get("range")
    if value_range is not None:
        if (not isinstance(value_range, list) or len(value_range) not in (2, 3) or
                any(type(n) not in (int, float) or not math.isfinite(n) for n in value_range)):
            raise BridgeError("api", "设备属性范围规格无效，未发送操作。")
        low, high = value_range[:2]
        if kind not in ("int", "uint", "float") or low > high or not low <= value <= high:
            invalid("属性值超出设备规格允许的范围。")
        if len(value_range) == 3:
            step = value_range[2]
            if step <= 0:
                raise BridgeError("api", "设备属性步长规格无效，未发送操作。")
            ratio = (value - low) / step
            if not math.isclose(ratio, round(ratio), rel_tol=1e-9, abs_tol=1e-7):
                invalid("属性值不符合设备规格规定的步长。")
    choices = prop.get("value-list")
    if choices:
        if not isinstance(choices, list) or any(not isinstance(v, dict) or "value" not in v
                                               for v in choices):
            raise BridgeError("api", "设备属性枚举规格无效，未发送操作。")
        if not any(equal_value(value, entry["value"]) for entry in choices):
            invalid("属性值不属于设备规格允许的枚举选项。")
    return value


def validate_request(request):
    if not isinstance(request, dict):
        invalid("工具请求必须是一个 JSON 对象。")
    operation = request.get("operation")
    if not isinstance(operation, str) or operation not in FIELDS:
        invalid("不支持的米家操作。")
    if set(request) - FIELDS[operation] - {"operation"}:
        invalid("工具请求包含此操作不支持的参数。")
    for key in ("device", "property", "scene", "action", "query", "home_id"):
        if key in request:
            text(request[key], key)
    if operation == "query_environment":
        if type(request.get("metric")) is not str or request["metric"] not in _sensor.METRICS:
            invalid("环境指标仅支持 humidity 或 temperature。")
        text(request.get("home_id"), "家庭")
    if operation == "prepare":
        nested = request.get("request")
        if not isinstance(nested, dict) or nested.get("operation") not in MUTATIONS:
            invalid("prepare 仅允许准备一次设备写入、动作或场景。")
        validate_request(nested)
    return operation


def load_sdk():
    try:
        sdk = importlib.import_module("mijiaAPI")
    except ImportError:
        raise BridgeError("setup", "米家连接组件尚未安装，请先运行米家安装脚本。")
    logging.getLogger("mijiaAPI").disabled = True
    if getattr(sdk, "__version__", None) != SDK_VERSION:
        raise BridgeError("setup", f"米家连接组件必须固定为 mijiaAPI {SDK_VERSION}，请重新安装。")
    return sdk


def check_auth_path(path):
    if path.is_symlink() or path.parent.is_symlink():
        raise BridgeError("auth", "米家授权文件必须保存在独立私有目录，不能使用符号链接。")
    if not path.is_file():
        raise BridgeError("auth", "尚未连接米家，请先在电脑上扫码授权。")
    if (stat.S_IMODE(path.stat().st_mode) & 0o077 or
            stat.S_IMODE(path.parent.stat().st_mode) & 0o077):
        raise BridgeError("auth", "米家授权文件权限不安全，请重新运行米家扫码授权。")
    try:
        auth = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise BridgeError("auth", "米家授权文件无法读取，请重新扫码授权。")
    required = ("ua", "ssecurity", "userId", "cUserId", "serviceToken")
    if not isinstance(auth, dict) or any(not auth.get(k) for k in required):
        raise BridgeError("auth", "米家授权不完整，请重新扫码授权。")


class Bridge:
    network_error = staticmethod(_network.safe_error)

    def __init__(self, sdk, api, auth_path, raw_spec=None):
        self.sdk, self.api, self.auth_path = sdk, api, auth_path
        self.raw_spec = raw_spec
        self.raw_spec_cache = {}
        self.cached_homes = lambda: None
        self.attempted = False
        self.receipt = {}
        self.sensor = _sensor.SensorQuery(self, policy=_policy, error=BridgeError,
            clean_device=clean_device, clean_property=clean_property, limit=RESULT_LIMIT)

    def authenticate(self, operation):
        # 业务接口自行验证凭据，取消消息接口预检；显式状态查询核实真实家庭接口。
        self.api._refresh_token = lambda: self.api.auth_data
        if operation == "status":
            self.homes()

    @staticmethod
    def rows(rows, label):
        if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
            raise BridgeError("api", f"米家返回的{label}列表格式无法确认。")
        return rows

    def homes(self):
        result, seen = [], set()
        for row in self.rows(self.api.get_homes_list(), "家庭"):
            iid, name = row.get("id"), row.get("name")
            if (type(iid) not in (str, int) or not str(iid).strip() or
                    str(iid) != str(iid).strip() or len(str(iid)) > 512 or
                    not isinstance(name, str) or not name.strip() or len(name) > 512):
                raise BridgeError("api", "米家家庭的编号或名称无法确认，请稍后重试。")
            iid = str(iid)
            if iid in seen:
                raise BridgeError("api", "米家返回了重复的家庭编号，请稍后重试。")
            seen.add(iid)
            result.append({"id": iid, "name": name})
        return {"homes": result[:RESULT_LIMIT], "truncated": len(result) > RESULT_LIMIT}

    def scoped_rows(self, rows, home_id, label):
        rows = self.rows(rows, label)
        if home_id is None:
            return rows
        # 只接受有明确归属的记录；SDK 忽略家庭筛选时也不能扩大目标集合。
        if any(type(row.get("home_id")) not in (str, int) or
               not str(row["home_id"]).strip() or len(str(row["home_id"])) > 512 for row in rows):
            raise BridgeError("api", f"米家返回的{label}缺少可确认的家庭归属，未执行操作。")
        return [row for row in rows if str(row["home_id"]) == home_id]

    def room_names(self, home_id):
        homes = self.cached_homes()
        if home_id is None or not isinstance(homes, list):
            return {}
        homes = [h for h in homes if isinstance(h, dict) and clean_text(h.get("id")) == home_id]
        if len(homes) != 1 or not isinstance(homes[0].get("roomlist"), list):
            return {}
        result, ambiguous = {}, set()
        for room in homes[0]["roomlist"]:
            if (not isinstance(room, dict) or not isinstance(room.get("name"), str) or
                    not room["name"].strip() or len(room["name"]) > 512 or not isinstance(room.get("dids"), list)):
                continue
            dids = {str(did) for did in room["dids"] if type(did) in (str, int) and 0 < len(str(did)) <= 512}
            for did in dids:
                if did in result:
                    ambiguous.add(did)
                result[did] = room["name"]
        return {did: name for did, name in result.items() if did not in ambiguous}

    def devices(self, home_id=None):
        if home_id == "shared":
            rows = self.rows(self.api.get_shared_devices_list(), "设备")
        else:
            rows = self.rows(self.api.get_devices_list(home_id=home_id), "设备")
            if home_id is None and hasattr(self.api, "get_shared_devices_list"):
                rows += self.rows(self.api.get_shared_devices_list(), "共享设备")
        rows = self.scoped_rows(rows, home_id, "设备")
        rooms = self.room_names(home_id)
        result, seen = [], set()
        for row in rows:
            did = clean_text(row.get("did"))
            if not did:
                raise BridgeError("api", "米家设备缺少可确认的编号。")
            if did in rooms and not (clean_text(row.get("room")) or clean_text(row.get("room_name"))):
                row = {**row, "room": rooms[did]}
            # 同一物理设备的重复记录合并；跨家庭资料冲突保留，交由选择器拒绝。
            identity = (did, clean_text(row.get("home_id")))
            safe = clean_device(row)
            fingerprint = json.dumps(safe, sort_keys=True, ensure_ascii=False)
            if (identity, fingerprint) not in seen:
                seen.add((identity, fingerprint))
                result.append(row)
        return result

    def resolve(self, rows, identifier, iid, label, sanitizer):
        identifier = text(identifier, label)
        matches = [row for row in rows if clean_text(row.get(iid)) == identifier]
        if not matches:
            matches = [row for row in rows if clean_text(row.get("name")) == identifier]
        if len(matches) != 1:
            candidates = matches or [row for row in rows if identifier.casefold() in
                                      clean_text(row.get("name")).casefold()]
            raise BridgeError("choice", f"请提供准确的{label}名称或编号。" if not matches else
                              f"发现同名{label}，请指定其中一个编号。",
                              candidates=[sanitizer(row) for row in candidates[:RESULT_LIMIT]])
        return matches[0]

    def device(self, request):
        rows = self.devices(request.get("home_id"))
        identifier = text(request.get("device"), "设备")
        if any(not _policy.device_kind(item) and identifier in
               (clean_text(item.get("did")), clean_text(item.get("name"))) for item in rows):
            raise _policy.PolicyError(_policy.NOTICE)
        devices = [item for item in rows if _policy.device_kind(item)]
        return self.resolve(devices, request.get("device"),
                            "did", "设备", clean_device)

    def spec(self, device):
        _policy.require_device(device)
        urn = clean_text(device.get("spec_type"))
        if not urn.startswith("urn:"):
            raise BridgeError("invalid", "这台设备没有可用的 MIOT 规格，暂不支持直接控制。")
        info = self.sdk.get_device_info(urn, cache_path=None)
        if not isinstance(info, dict):
            raise BridgeError("api", "米家返回的设备规格格式无效。")
        self.rows(info.get("properties", []), "属性")
        self.rows(info.get("actions", []), "动作")
        return {"properties": _policy.safe_properties(device, info.get("properties", []), self.official_spec(device)),
                "actions": []}

    def capability(self, spec, name):
        rows = spec.get("properties", [])
        iid = "piid"
        name = text(name, "属性")
        matches = [row for row in rows if name == spec_id(row, iid)]
        if not matches:
            matches = [row for row in rows if name in
                       (row.get("name"), str(row.get("name", "")).replace("-", "_"))]
        if len(matches) != 1:
            raise BridgeError("choice", "请从设备当前规格中选择准确的功能编号。",
                              candidates=[clean_property(row) for row in (matches or rows)[:RESULT_LIMIT]])
        return matches[0]

    def official_spec(self, device):
        urn = device["spec_type"]
        if urn in self.raw_spec_cache:
            if isinstance(self.raw_spec_cache[urn], Exception):
                raise self.raw_spec_cache[urn]
            return self.raw_spec_cache[urn]
        try:
            if self.raw_spec is not None:
                spec = self.raw_spec(urn)
            else:
                import requests
                response = requests.get("https://miot-spec.org/miot-spec-v2/instance",
                                        params={"type": urn}, timeout=HTTP_TIMEOUT)
                response.raise_for_status()
                spec = response.json()
            if not isinstance(spec, dict) or not isinstance(spec.get("services"), list):
                raise BridgeError("api", "无法核实设备的安全规格，未发送操作。")
        except Exception as error:
            self.raw_spec_cache[urn] = error
            raise
        self.raw_spec_cache[urn] = spec
        return spec

    def prepare(self, request):
        operation = validate_request(request)
        _policy.require_operation(operation)
        device = self.device(request)
        spec = self.spec(device)
        canonical = {"operation": operation, "device": clean_text(device["did"])}
        if clean_text(device.get("home_id")):
            canonical["home_id"] = clean_text(device["home_id"])
        capability = self.capability(spec, request.get("property"))
        label = f"{clean_text(device.get('name'))} · {clean_text(capability.get('description') or capability.get('name'))}"
        if "w" not in capability.get("rw", ""):
            invalid("该属性不可写入，未发送操作。")
        if "value" not in request:
            invalid("设置属性必须提供 value。")
        if not _policy.safe_value(capability, request["value"]):
            invalid("属性值不符合设备格式、范围或步长，未发送操作。")
        canonical.update(property=spec_id(capability, "piid"), value=validate_value(capability, request["value"]))
        return {"request": canonical, "label": label}, device, capability

    def item_receipt(self, response, method, mutating=False):
        if isinstance(response, list) and len(response) == 1:
            response = response[0]
        if not isinstance(response, dict) or type(response.get("code")) is not int:
            raise BridgeError("api", "米家没有返回可确认的执行代码。")
        for key in ("did", "siid", "piid", "aiid"):
            if key in response and key in method and response[key] != method[key]:
                raise BridgeError("api", "米家返回的执行目标与本次请求不一致。")
        code = response["code"]
        if code != 0 and not (mutating and code == 1):
            if code in (-704042011, -10007):
                raise BridgeError("api", "米家云端无法连接这台设备（云端离线）。请在米家 App 核对远程连接；蓝牙 Mesh 设备需要兼容的 Mesh 网关，手机蓝牙直连不能替代。", code=code)
            raise BridgeError("api", "米家拒绝了本次设备操作。", code=code)
        return response

    def mutation(self, request):
        prepared, target, capability = self.prepare(request)
        canonical = prepared["request"]
        if canonical != request:
            invalid("设备目标或规格已发生变化，请重新准备操作；未发送任何指令。")
        operation = canonical["operation"]
        label = prepared["label"]
        data = {"label": label, "accepted": False, "verified": False,
                "status": "unconfirmed", "message": f"{label}：操作结果尚未确认，请在米家中核对；不会自动重发。"}
        self.receipt = data
        data["device"] = clean_device(target)
        method = {"did": canonical["device"], "siid": capability["method"]["siid"],
                  "piid": capability["method"]["piid"]}
        data["property"] = clean_property(capability)
        data["requested_value"] = canonical["value"]
        method["value"] = canonical["value"]
        self.attempted = True
        response = self.item_receipt(self.api.set_devices_prop(method), method, mutating=True)
        data["accepted"] = True
        if "r" in capability.get("rw", ""):
            try:
                read_method = {k: v for k, v in method.items() if k != "value"}
                raw = self.api._request("/miotspec/prop/get", {"params": [read_method], "datasource": 2})
                read = self.item_receipt(raw, read_method)
                if "value" in read and _policy.safe_value(capability, read["value"]):
                    data["value"] = read["value"]
                    if equal_value(read["value"], canonical["value"]):
                        display_value = json.dumps(canonical["value"], ensure_ascii=False)
                        data.update(status="verified", verified=True, message=f"{label} 已设置为 {display_value}，并已读回核实。")
            except Exception:
                pass
        elif response["code"] == 0:
            data.update(status="accepted", message=f"{label}：米家已确认写入指令；该属性不可读回核实。")
        return data

    def handle(self, request):
        operation = validate_request(request)
        _policy.require_operation(operation)
        if operation == "status":
            return {"authenticated": True, "sdk_version": SDK_VERSION}
        if operation == "list_homes":
            return self.homes()
        if operation == "list_scenes":
            return {"scenes": [], "truncated": False, "security_notice": _policy.NOTICE}
        if operation == "prepare":
            return self.prepare(request["request"])[0]
        if operation in MUTATIONS:
            return self.mutation(request)
        if operation == "list_devices":
            rows = self.devices(request.get("home_id"))
            hidden = any(not _policy.device_kind(row) for row in rows)
            rows = [row for row in rows if _policy.device_kind(row)]
            query = request.get("query", "").casefold()
            rows = [row for row in rows if query in clean_text(row.get("name")).casefold() or
                    query in clean_text(row.get("model")).casefold()]
            return {"devices": [clean_device(row) for row in rows[:RESULT_LIMIT]],
                "truncated": len(rows) > RESULT_LIMIT, "restricted_devices_hidden": hidden,
                "security_notice": _policy.NOTICE}
        if operation == "query_environment":
            return self.sensor.query(request)
        device = self.device(request)
        spec = self.spec(device)
        if operation == "device_info":
            return {"device": clean_device(device),
                    "properties": [clean_property(p) for p in spec.get("properties", [])],
                    "actions": [], "security_notice": _policy.NOTICE}
        prop = self.capability(spec, request.get("property"))
        return self.sensor.read(device, prop)


def is_network(error):
    return any(cls.__name__ in ("Timeout", "ConnectTimeout", "ReadTimeout", "ConnectionError",
                               "HTTPError", "RequestException") for cls in type(error).__mro__)


def envelope(request, auth_path, sdk=None, api=None, raw_spec=None):
    bridge = None
    mutating = False
    try:
        operation = validate_request(request)
        mutating = operation in MUTATIONS
        sdk = sdk or load_sdk()
        if api is None:
            check_auth_path(auth_path)
            try:
                api = sdk.mijiaAPI(str(auth_path))
            except Exception:
                raise BridgeError("auth", "米家授权文件无法使用，请重新扫码授权。")
        bridge = Bridge(sdk, api, auth_path, raw_spec)
        with _network.memoized_homes(api) as cached_homes:
            bridge.cached_homes = cached_homes
            bridge.authenticate(operation)
            data = bridge.handle(request)
        return {"ok": True, "data": data, "mutating": mutating}
    except _policy.PolicyError as error:
        return {"ok": False, "error": {"kind": "policy", "message": str(error)}, "mutating": mutating}
    except BridgeError as error:
        # 有明确拒绝码可报告失败；响应结构不明可能已经执行，保留待核实且不重发。
        if bridge and bridge.attempted and error.payload["kind"] == "api" and "code" not in error.payload:
            return {"ok": True, "data": bridge.receipt, "mutating": True}
        return {"ok": False, "error": error.payload, "mutating": mutating}
    except Exception as error:
        if bridge and bridge.attempted:
            return {"ok": True, "data": bridge.receipt, "mutating": True}
        return {"ok": False, "error": _network.safe_error(error), "mutating": mutating}


def interactive_login(auth_path, qr_path=None):
    sdk = load_sdk()
    if auth_path.is_symlink() or auth_path.parent.is_symlink():
        raise BridgeError("auth", "授权目录或文件不能是符号链接。")
    previous_umask = os.umask(0o077)
    try:
        auth_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        auth_path.parent.chmod(0o700)
        if auth_path.exists():
            auth_path.chmod(0o600)
        try:
            api = sdk.mijiaAPI(str(auth_path))
        except (ValueError, KeyError):
            raise BridgeError("auth", "旧授权文件无效，请先移走旧文件再重新扫码。")
        if qr_path:
            def show_qr(url, **kwargs):
                import qrcode
                qrcode.make(url).save(qr_path)
                Path(qr_path).chmod(0o600)
                print(f"请用米家 App 扫描二维码图片：{qr_path}", file=sys.stderr)
            api._print_qr = show_qr
        with bounded_http(interactive=True), contextlib.redirect_stdout(sys.stderr):
            api.login()
        auth_path.chmod(0o600)
        check_auth_path(auth_path)
        return {"ok": True, "data": {"authenticated": True, "sdk_version": SDK_VERSION}, "mutating": False}
    finally:
        os.umask(previous_umask)


@contextlib.contextmanager
def quiet_sdk():
    """登录只输出自有事件，第三方打印、日志和异常正文均不越界。"""
    previous_level = logging.root.manager.disable
    with open(os.devnull, "w", encoding="utf-8") as sink:
        with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
            logging.disable(logging.CRITICAL)
            try:
                yield
            finally:
                logging.disable(previous_level)


def valid_login_url(value):
    if (not isinstance(value, str) or len(value) > 8192 or "#" in value or
            any(c.isspace() or ord(c) < 32 or 0x7f <= ord(c) <= 0x9f for c in value)):
        return False
    try:
        parsed = urlsplit(value)
        hostname = parsed.hostname or ""
        # 小米按账号区域返回 sgp 等子域；点边界与 DNS 标签校验共同拒绝伪造后缀。
        account_host = hostname == "account.xiaomi.com" or hostname.endswith(".account.xiaomi.com")
        dns_labels = len(hostname) <= 253 and all(re.fullmatch(
            r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label) for label in hostname.split("."))
        return (parsed.scheme == "https" and account_host and dns_labels and
                parsed.username is None and parsed.password is None and parsed.port is None and
                parsed.netloc.lower() == hostname and parsed.path == "/longPolling/login" and
                bool(parsed.query))
    except ValueError:
        return False


def login_events(auth_path, emit):
    """新账号先落暂存文件；正式凭据的原子替换属于上层会话管理器。"""
    qr_started = None
    previous_umask = os.umask(0o077)
    try:
        with quiet_sdk():
            sdk = load_sdk()
            if auth_path.is_symlink() or auth_path.parent.is_symlink() or auth_path.exists():
                raise BridgeError("auth", "请重新开始连接，以创建独立的米家授权会话。")
            auth_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            auth_path.parent.chmod(0o700)
            api = sdk.mijiaAPI(str(auth_path))
            if not all(callable(getattr(api, name, None)) for name in
                       ("_get_qr_login_data", "_complete_qr_login")):
                raise BridgeError("setup", "米家连接组件不支持二维码登录，请重新安装。")

            def save_staged_auth():
                # 独占创建防止误传正式文件或竞争替换；不会覆盖任何已有凭据。
                api.auth_data["saveTime"] = int(time.time() * 1000)
                descriptor = os.open(auth_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                                     getattr(os, "O_NOFOLLOW", 0), 0o600)
                with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                    json.dump(api.auth_data, stream, ensure_ascii=False, allow_nan=False)

            api._save_auth_data = save_staged_auth
            with bounded_http(interactive=True):
                login_data = api._get_qr_login_data()
                if not isinstance(login_data, dict) or not valid_login_url(login_data.get("loginUrl")):
                    raise BridgeError("auth", "米家未返回有效的登录二维码，请重新生成。")
                qr_started = time.monotonic()
                emit({"event": "qr", "login_url": login_data["loginUrl"], "expires_in": LOGIN_TTL})
                api._complete_qr_login(login_data)
            check_auth_path(auth_path)
        terminal = {"event": "complete"}
    except Exception as error:
        expired = qr_started is not None and (
            time.monotonic() - qr_started >= LOGIN_TTL or
            (type(error).__name__ == "LoginError" and
             error.args == ("code: -1, message: 超时，请重试",)))
        if expired:
            kind, message = "expired", "二维码已过期，请重新生成后扫码。"
        elif isinstance(error, BridgeError):
            kind, message = error.payload["kind"], error.payload["message"]
        elif is_network(error):
            kind, message = "network", "暂时无法连接米家，请检查网络后重新生成二维码。"
        elif isinstance(error, (ImportError, OSError)):
            kind, message = "setup", "米家连接组件或授权目录不可用，请检查后重试。"
        else:
            kind, message = "auth", "米家授权未完成，请重新生成二维码并在米家 App 中确认。"
        terminal = {"event": "error", "kind": kind, "message": message}
    finally:
        os.umask(previous_umask)
    emit(terminal)


def check_runtime():
    try:
        with quiet_sdk():
            load_sdk()
        return {"ok": True, "sdk_version": SDK_VERSION}
    except Exception:
        return {"ok": False, "error": {"kind": "setup", "message":
                f"米家连接组件未就绪，请安装 mijiaAPI {SDK_VERSION}。"}}


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            invalid("JSON 请求含重复字段。")
        result[key] = value
    return result


def main():
    parser = argparse.ArgumentParser(description="PocketDesk 米家隔离桥接器")
    parser.add_argument("--auth")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--login", action="store_true")
    modes.add_argument("--login-events", action="store_true")
    modes.add_argument("--check-runtime", action="store_true")
    parser.add_argument("--qr-path")
    args = parser.parse_args()
    if args.check_runtime:
        print(json.dumps(check_runtime(), ensure_ascii=False, separators=(",", ":")))
        return
    if not args.auth:
        parser.error("米家请求必须指定 --auth。")
    auth_path = Path(args.auth).expanduser().absolute()
    if args.login_events:
        event_output = sys.stdout
        def emit(event):
            print(json.dumps(event, ensure_ascii=False, allow_nan=False, separators=(",", ":")),
                  file=event_output, flush=True)
        login_events(auth_path, emit)
        return
    try:
        if args.login:
            result = interactive_login(auth_path, args.qr_path)
        else:
            raw = sys.stdin.read(REQUEST_LIMIT + 1)
            if len(raw) > REQUEST_LIMIT:
                invalid("工具请求过长。")
            request = json.loads(raw, object_pairs_hook=unique_object,
                                 parse_constant=lambda value: invalid("JSON 不允许 NaN 或 Infinity。"))
            validate_request(request)
            # 第三方库的输出与错误文本不得穿过凭据边界。
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                sdk = load_sdk()
                with bounded_http(cache_dir=auth_path.parent / "spec-cache"):
                    result = envelope(request, auth_path, sdk=sdk)
    except BridgeError as error:
        result = {"ok": False, "error": error.payload, "mutating": False}
    except (json.JSONDecodeError, UnicodeError):
        result = {"ok": False, "error": {"kind": "invalid", "message": "请输入单个有效 JSON 请求。"}, "mutating": False}
    except Exception as error:
        kind = "network" if is_network(error) else "auth" if args.login else "unknown"
        result = {"ok": False, "error": {"kind": kind, "message": "米家连接未完成，请检查网络或重新扫码授权。"}, "mutating": False}
    print(json.dumps(result, ensure_ascii=False, allow_nan=False, separators=(",", ":")))


if __name__ == "__main__":
    main()
