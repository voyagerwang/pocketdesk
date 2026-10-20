#!/usr/bin/env python3
"""
[INPUT]: 小米返回的设备类型 URN、官方 MIOT 原始规格及 SDK 解析属性；不访问账号、网络或文件。
[OUTPUT]: 默认拒绝的最小能力策略；灯/开关基础控制及标准温湿度传感器只读查询，按原始身份、单位、位宽与范围核对数值。
[POS]: 米家桥接的纯安全决策；列表、规格、准备、执行及读回共用，模型与设备名称不能扩大权限。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
import math
import re


NOTICE = "安全范围仅开放灯和开关的基础属性，以及温湿度传感器的只读查询；摄像头、门锁、音箱、网关、其他设备及场景暂不开放。"
SENSOR_KIND = "temperature-humidity-sensor"
DEVICE_TYPES = {"light": "0000A001", "switch": "0000A003", SENSOR_KIND: "0000A00A"}
SERVICE_TYPES = {"light": "00007802", "switch": "0000780C", SENSOR_KIND: "00007814"}
PROPERTY_TYPES = {"on": ("00000006", "bool", "开关"),
                  "brightness": ("0000000D", "uint", "亮度"),
                  "temperature": ("00000020", "float", "温度"),
                  "relative-humidity": ("0000000C", "uint", "湿度")}
DEVICE_PROPERTIES = {"light": {"on", "brightness"}, "switch": {"on"},
                     SENSOR_KIND: {"temperature", "relative-humidity"}}
SENSOR_UNITS = {"temperature": "celsius", "relative-humidity": "percentage"}
UINT_MAXIMUM = {"uint8": 0xFF, "uint16": 0xFFFF, "uint32": 0xFFFFFFFF}


class PolicyError(Exception):
    """只携带固定安全说明，不回传被隐藏的设备或属性名称。"""


def urn_kind(value, category):
    if not isinstance(value, str) or len(value) > 512:
        return None
    parts = value.split(":")
    if (len(parts) not in (7, 8) or parts[:3] != ["urn", "miot-spec-v2", category] or
            any(not re.fullmatch(r"[A-Za-z0-9_.-]+", part) for part in parts[3:]) or
            not re.fullmatch(r"[0-9A-F]{8}", parts[4]) or not parts[6].isdigit()):
        return None
    return parts[3], parts[4]


def device_kind(device):
    kind = urn_kind(device.get("spec_type"), "device")
    return kind[0] if kind and DEVICE_TYPES.get(kind[0]) == kind[1] else None


def require_device(device):
    if device_kind(device) is None:
        raise PolicyError(NOTICE)


def require_operation(operation):
    if operation in ("action", "run_scene"):
        raise PolicyError("为避免敏感控制或跨家庭联动，PocketDesk 暂不执行设备动作和场景。")


def finite_number(value):
    return type(value) is int or (type(value) is float and math.isfinite(value))


def bounded_range(format_name, value_range):
    if format_name == "bool":
        return None
    if format_name == "float":
        if (not isinstance(value_range, list) or len(value_range) != 3 or
                any(not finite_number(value) for value in value_range)):
            raise PolicyError("温度范围无法核对，未开放该传感器功能。")
        low, high, step = value_range
        if not -273.15 <= low <= high <= 1000 or not 0 < step <= 1000:
            raise PolicyError("温度范围不符合安全边界，未开放该传感器功能。")
        return list(value_range)
    maximum = UINT_MAXIMUM[format_name]
    if value_range is None:
        return [0, maximum, 1]
    if (not isinstance(value_range, list) or len(value_range) not in (2, 3) or
            any(type(value) is not int for value in value_range)):
        raise PolicyError("设备属性范围无法核对，未开放任何设备功能。")
    low, high = value_range[:2]
    step = value_range[2] if len(value_range) == 3 else 1
    if not 0 <= low <= high <= maximum or not 0 < step <= maximum:
        raise PolicyError("设备属性范围超出其格式，未开放任何设备功能。")
    return [low, high, step]


def safe_choices(values, primitive, value_range):
    if values is None:
        return None
    if not isinstance(values, list):
        raise PolicyError("设备属性枚举无法核对，未开放任何设备功能。")
    result = []
    for item in values:
        value = item.get("value") if isinstance(item, dict) else None
        if not safe_value({"type": primitive, "range": value_range}, value):
            raise PolicyError("设备属性枚举无法核对，未开放任何设备功能。")
        result.append({"value": value, "description": str(value)})
    return result


def safe_properties(device, parsed, raw):
    """授权依据只来自标准 URN；SDK 的名称与功能编号只用于交叉核对。"""
    require_device(device)
    kind = device_kind(device)
    if not isinstance(raw, dict) or raw.get("type") != device.get("spec_type"):
        raise PolicyError("设备规格身份无法核对，未开放任何设备功能。")
    services = raw.get("services")
    if not isinstance(services, list):
        raise PolicyError("设备规格无法核对，未开放任何设备功能。")
    allowed = {}
    seen_services = set()
    for service in services:
        if not isinstance(service, dict):
            raise PolicyError("设备规格无法核对，未开放任何设备功能。")
        siid = service.get("iid")
        if type(siid) is not int or siid <= 0 or siid in seen_services:
            raise PolicyError("设备服务编号无法唯一核对，未开放任何设备功能。")
        seen_services.add(siid)
        if urn_kind(service.get("type"), "service") != (kind, SERVICE_TYPES[kind]):
            continue
        seen_properties = set()
        for prop in service.get("properties", []):
            if not isinstance(prop, dict):
                raise PolicyError("设备属性规格无法核对，未开放任何设备功能。")
            piid = prop.get("iid")
            if type(piid) is not int or piid <= 0 or piid in seen_properties:
                raise PolicyError("设备属性编号无法唯一核对，未开放任何设备功能。")
            seen_properties.add(piid)
            identity = urn_kind(prop.get("type"), "property")
            if not identity or identity[0] not in DEVICE_PROPERTIES[kind]:
                continue
            code, primitive, label = PROPERTY_TYPES[identity[0]]
            if identity[1] != code:
                continue
            formats = ("bool",) if primitive == "bool" else ("uint8", "uint16", "uint32")
            unit = None
            if kind == SENSOR_KIND:
                unit = SENSOR_UNITS[identity[0]]
                formats = ("float",) if primitive == "float" else ("uint8",)
                if prop.get("unit") != unit:
                    continue
            access = prop.get("access")
            if prop.get("format") not in formats or not isinstance(access, list):
                continue
            rw = ("r" if "read" in access else "") + ("w" if kind != SENSOR_KIND and "write" in access else "")
            if rw:
                value_range = bounded_range(prop["format"], prop.get("value-range"))
                if kind == SENSOR_KIND and identity[0] == "relative-humidity" and value_range[1] > 100:
                    raise PolicyError("湿度范围不符合百分比，未开放该传感器功能。")
                allowed[(siid, piid)] = (identity[0], primitive, label, rw,
                                       value_range, safe_choices(prop.get("value-list"), primitive, value_range), unit)
    result, seen = [], set()
    for prop in parsed:
        method = prop.get("method", {})
        key = (method.get("siid"), method.get("piid"))
        if key not in allowed:
            continue
        if key in seen:
            raise PolicyError("设备属性无法唯一核对，未开放任何设备功能。")
        seen.add(key)
        name, primitive, label, access, value_range, choices, unit = allowed[key]
        if prop.get("type") != primitive:
            continue
        rw = "".join(flag for flag in access if flag in prop.get("rw", ""))
        if rw:
            safe = {"method": {"siid": key[0], "piid": key[1]}, "type": primitive,
                    "name": name, "description": label, "rw": rw,
                    "range": value_range, "value-list": choices}
            if unit is not None:
                safe["unit"] = unit
            result.append(safe)
    return result


def safe_value(prop, value):
    if prop.get("type") == "bool":
        return type(value) is bool
    if prop.get("type") == "float":
        if not finite_number(value):
            return False
        bounds = prop.get("range")
        if (not isinstance(bounds, list) or len(bounds) != 3 or
                any(not finite_number(bound) for bound in bounds)):
            return False
        low, high, step = bounds
        if not -273.15 <= low <= value <= high <= 1000 or not 0 < step <= 1000:
            return False
        if abs(math.remainder(value - low, step)) > min(step * 0.0001, 0.0001):
            return False
        choices = prop.get("value-list")
        return not choices or any(type(item.get("value")) in (int, float) and item["value"] == value for item in choices)
    if prop.get("type") != "uint" or type(value) is not int:
        return False
    bounds = prop.get("range")
    if (not isinstance(bounds, list) or len(bounds) != 3 or
            any(type(bound) is not int for bound in bounds)):
        return False
    low, high, step = bounds
    if not 0 <= low <= value <= high <= UINT_MAXIMUM["uint32"] or step <= 0 or (value - low) % step:
        return False
    choices = prop.get("value-list")
    return not choices or any(type(item.get("value")) is int and item["value"] == value for item in choices)
