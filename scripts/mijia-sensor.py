#!/usr/bin/env python3
"""
[INPUT]: 米家桥接的单次家庭发现/官方规格/回执核验、最小能力策略与固定只读SDK接口。
[OUTPUT]: 温湿度单次查询及统一属性读数来源、可信更新时间和本次读取时间；离线仅datasource=3纯缓存，在线最多一次直读再查缓存。
[POS]: 米家桥接的只读编排；只在唯一安全目标上读取，不缓存私有设备资料、不控制设备、不把查询时间当测量时间。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
import time


METRICS = {"temperature": ("temperature", "温度"), "humidity": ("relative-humidity", "湿度")}
EARLIEST_UPDATE = 946684800  # 2000-01-01 UTC；早于米家设备存在的时间不作为测量依据。


def trusted_updated_at(value, observed_at):
    """只接受服务返回的数值Unix秒/毫秒；布尔、字符串、未来或异常范围一律未知。"""
    if type(value) not in (int, float) or not EARLIEST_UPDATE <= value <= observed_at * 1000:
        return None
    seconds = value / 1000 if value >= EARLIEST_UPDATE * 1000 else value
    if not EARLIEST_UPDATE <= seconds <= observed_at:
        return None
    return seconds


class SensorQuery:
    def __init__(self, bridge, *, policy, error, clean_device, clean_property, limit):
        self.bridge, self.policy, self.error = bridge, policy, error
        self.clean_device, self.clean_property, self.limit = clean_device, clean_property, limit

    def query(self, request):
        metric = request["metric"]
        name, label = METRICS[metric]
        rows = [row for row in self.bridge.devices(request["home_id"])
                if self.policy.device_kind(row) == self.policy.SENSOR_KIND]
        if not rows:
            raise self.error("unsupported", "所选家庭未找到支持的温湿度计。")
        query = request.get("query")
        if query:
            matches = [row for row in rows if query in tuple(self.clean_device(row).get(key)
                       for key in ("did", "name", "room"))]
        else:
            matches = rows
        if len(matches) != 1:
            raise self.error("choice", "请指定一个温湿度计的准确名称、房间或编号。",
                candidates=[self.clean_device(row) for row in (matches or rows)[:self.limit]])
        device = matches[0]
        properties = [prop for prop in self.bridge.spec(device)["properties"]
                      if prop.get("name") == name and "r" in prop.get("rw", "")]
        if not properties:
            raise self.error("unsupported", f"这台温湿度计没有可读取的{label}。")
        if len(properties) != 1:
            raise self.error("choice", f"这台设备有多个{label}读数，请指定属性编号。",
                candidates=[self.clean_property(prop) for prop in properties[:self.limit]])
        return {"metric": metric, **self.read(device, properties[0])}

    def read(self, device, prop):
        if "r" not in prop.get("rw", ""):
            raise self.error("invalid", "该属性不可读取。")
        method = {"did": self.clean_device(device)["did"], "siid": prop["method"]["siid"],
                  "piid": prop["method"]["piid"]}
        sensor = self.policy.device_kind(device) == self.policy.SENSOR_KIND
        if sensor and self.clean_device(device)["online"] is True:
            try:
                return self.fetch(device, prop, method, "device")
            except Exception as error:
                # 授权错误不重试；其他直读失败最多回退一次云记录，永不写设备。
                if self.bridge.network_error(error)["kind"] == "auth":
                    raise
        return self.fetch(device, prop, method, "cloud", sensor=sensor)

    def fetch(self, device, prop, method, source, sensor=True):
        if sensor:
            raw = self.bridge.api._request("/miotspec/prop/get", {
                "params": [method], "datasource": 2 if source == "device" else 3})
        else:
            # 灯/开关保留原SDK云端读取策略，不因新增传感器查询增加请求。
            raw = self.bridge.api.get_devices_prop(method)
        label = "湿度" if prop.get("name") == "relative-humidity" else "温度" if prop.get("name") == "temperature" else "属性"
        try:
            response = self.bridge.item_receipt(raw, method)
        except self.error as error:
            if sensor and source == "cloud" and "code" in error.payload:
                raise self.error("api", f"米家未返回可用的{label}云端记录。", code=error.payload["code"]) from None
            raise
        if "value" not in response or not self.policy.safe_value(prop, response["value"]):
            raise self.error("api", f"米家未返回可确认的{label}读数。")
        observed = time.time()
        return {"device": self.clean_device(device), "property": self.clean_property(prop),
                "value": response["value"], "source": source,
                "updated_at": trusted_updated_at(response.get("updateTime"), observed),
                "observed_at": observed}
