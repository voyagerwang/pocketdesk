#!/usr/bin/env python3
"""
[INPUT]: requests 会话、固定 MIOT 公开规格端点和可选私有缓存目录；不接收或保存米家账号凭据。
[OUTPUT]: 分阶段限时请求、每次调用的规格成功/失败复用、完整 URN 的七天公开规格缓存与脱敏错误。
[POS]: 米家桥接的传输边界；仅缓存公开规格与单次家庭 owner 查询，设备归属和实际控制始终走实时接口。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
import contextlib
import contextvars
import hashlib
import importlib
import json
import os
from pathlib import Path
import re
import stat
import time
from urllib.parse import parse_qs, urlsplit
import uuid


HTTP_TIMEOUT = (5, 12)
SPEC_TTL = 7 * 24 * 60 * 60
SPEC_LIMIT = 1024 * 1024
_stage = contextvars.ContextVar("mijia_network_stage", default="米家服务")


class NetworkFailure(Exception):
    def __init__(self, kind, message):
        super().__init__(message)
        self.payload = {"kind": kind, "message": message}


def safe_error(error, stage=None):
    if isinstance(error, NetworkFailure):
        return error.payload
    stage = stage or _stage.get()
    classes = {cls.__name__ for cls in type(error).__mro__}
    if "LoginError" in classes:
        kind = "auth"
    elif "APIError" in classes and re.match(r"^code: (-10020|-10030),", str(error)):
        kind = "auth"
    elif classes.intersection({"Timeout", "ConnectTimeout", "ReadTimeout", "ConnectionError", "RequestException"}) and "HTTPError" not in classes:
        kind = "network"
    else:
        kind = "api"
    message = {"auth": "米家授权已失效，请在电脑上重新扫码连接。",
               "network": f"{stage}暂时没有响应，请稍后重试。",
               "api": f"{stage}返回的数据无法核对，请稍后重试。"}[kind]
    return {"kind": kind, "message": message}


def request_stage(url):
    parsed = urlsplit(url)
    if parsed.hostname == "miot-spec.org":
        return "设备规格服务"
    path = parsed.path
    if "gethome" in path:
        return "米家家庭清单"
    if "device_list" in path:
        return "米家设备清单"
    if "/miotspec/prop/get" in path:
        return "米家设备属性"
    if "/miotspec/prop/set" in path or "/miotspec/action" in path:
        return "米家设备控制"
    if "Scene" in path:
        return "米家场景服务"
    return "米家账号服务"


def spec_urn(method, url, kwargs):
    parsed = urlsplit(url)
    if (method.upper() != "GET" or parsed.scheme != "https" or parsed.netloc != "miot-spec.org" or
            parsed.path != "/miot-spec-v2/instance" or parsed.fragment):
        return None
    params = kwargs.get("params")
    if params is None:
        params = parse_qs(parsed.query)
        if set(params) != {"type"} or len(params["type"]) != 1:
            return None
        urn = params["type"][0]
    elif isinstance(params, dict) and set(params) == {"type"} and not parsed.query:
        urn = params["type"]
    else:
        return None
    return urn if isinstance(urn, str) and urn.startswith("urn:") and len(urn) <= 512 else None


def valid_spec(value, urn):
    if (not isinstance(value, dict) or not isinstance(value.get("description"), str) or
            not isinstance(value.get("services"), list) or value.get("type") != urn):
        return False
    for service in value["services"]:
        if (not isinstance(service, dict) or type(service.get("iid")) is not int or
                not isinstance(service.get("type"), str) or
                any(not isinstance(service.get(key, []), list) or
                    any(not isinstance(item, dict) for item in service.get(key, []))
                    for key in ("properties", "actions", "events"))):
            return False
    return True


class SpecCache:
    def __init__(self, directory, now=time.time):
        self.directory = Path(directory) if directory is not None else None
        self.now = now

    def path(self, urn):
        return self.directory / (hashlib.sha256(urn.encode("utf-8")).hexdigest() + ".json")

    def read(self, urn):
        if self.directory is None:
            return None
        try:
            if self.directory.is_symlink() or self.directory.parent.is_symlink():
                return None
            file = self.path(urn)
            info = file.lstat()
            if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600 or not 0 < info.st_size <= SPEC_LIMIT:
                return None
            entry = json.loads(file.read_text(encoding="utf-8"))
            saved_at = entry.get("saved_at")
            if (entry.get("version") == 1 and entry.get("urn") == urn and
                    type(saved_at) in (int, float) and 0 <= self.now() - saved_at <= SPEC_TTL and
                    valid_spec(entry.get("spec"), urn)):
                return entry["spec"]
        except (OSError, ValueError, TypeError, AttributeError):
            pass
        return None

    def write(self, urn, spec):
        if self.directory is None or not valid_spec(spec, urn):
            return
        temporary = None
        try:
            data = json.dumps({"version": 1, "urn": urn, "saved_at": self.now(), "spec": spec},
                              ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode("utf-8")
            if len(data) > SPEC_LIMIT or self.directory.is_symlink() or self.directory.parent.is_symlink():
                return
            self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            self.directory.chmod(0o700)
            temporary = self.directory / (".spec-" + uuid.uuid4().hex)
            descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(data)
            os.replace(temporary, self.path(urn))
        except (OSError, ValueError, TypeError):
            pass
        finally:
            if temporary is not None:
                try:
                    temporary.unlink(missing_ok=True)
                except OSError:
                    pass


@contextlib.contextmanager
def memoized_homes(api):
    """仅本次工具内复用 SDK 每页重复读取的 owner 清单；下一次工具重新查询。"""
    original = getattr(api, "get_homes_list", None)
    if not callable(original):
        yield lambda: None
        return
    values = []
    def get_homes():
        if not values:
            values.append(original())
        return values[0]
    api.get_homes_list = get_homes
    try:
        yield lambda: values[0] if values else None
    finally:
        api.get_homes_list = original


@contextlib.contextmanager
def bounded_http(interactive=False, cache_dir=None):
    requests = importlib.import_module("requests")
    original = requests.sessions.Session.request
    cached, disk = {}, SpecCache(cache_dir)
    stage_token = _stage.set("米家服务")

    def request(session, method, url, **kwargs):
        stage = request_stage(url)
        _stage.set(stage)
        if not interactive or "timeout" not in kwargs:
            kwargs["timeout"] = HTTP_TIMEOUT
        urn = None if interactive else spec_urn(method, url, kwargs)
        if urn in cached:
            value = cached[urn]
            if isinstance(value, Exception):
                raise value
            return value
        stored = disk.read(urn) if urn else None
        if stored is not None:
            response = requests.Response()
            response.status_code, response.encoding, response.url = 200, "utf-8", url
            response._content = json.dumps(stored, ensure_ascii=False).encode("utf-8")
            cached[urn] = response
            return response
        try:
            response = original(session, method, url, **kwargs)
            status = getattr(response, "status_code", 200)
            if not interactive and status >= 400:
                kind = "auth" if status == 401 and stage != "设备规格服务" else "api"
                message = "米家授权已失效，请在电脑上重新扫码连接。" if kind == "auth" else f"{stage}暂时不可用（HTTP {status}），请稍后重试。"
                raise NetworkFailure(kind, message)
        except Exception as error:
            if interactive:
                raise
            safe = safe_error(error, stage)
            failure = NetworkFailure(safe["kind"], safe["message"])
            if urn:
                cached[urn] = failure
            raise failure from None
        if urn:
            cached[urn] = response
            try:
                if response.status_code == 200 and len(response.content) <= SPEC_LIMIT:
                    disk.write(urn, response.json())
            except (ValueError, TypeError, AttributeError):
                pass
        return response

    requests.sessions.Session.request = request
    try:
        yield requests
    finally:
        requests.sessions.Session.request = original
        _stage.reset(stage_token)
