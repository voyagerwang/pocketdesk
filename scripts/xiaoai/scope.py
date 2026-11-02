"""
[INPUT]: 系统不可变的家庭/设备白名单、原米家账号、私有家庭选择和只读家庭设备接口；业务端点自行验证凭据，不走SDK账号消息预检或登录刷新。
[OUTPUT]: 默认拒绝的账号/家庭/OH2身份及MIOT/MiNA请求校验；MiNA只放开“放指定音乐”和“停下来”，睡眠读取与成员证明都走冻结家庭的只读端点，睡眠写入仅允许恢复开启。
[POS]: 音箱全部云请求的授权边界；缺失、篡改、换家庭、设备迁出或无法核验都停止，不提供解锁命令。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
import asyncio
import contextlib
import hashlib
import io
import json
import logging
import os
from pathlib import Path
import stat
import sys

ROOT = Path.home() / "Library/Application Support/VoiceDeck"
LOCK = ROOT / "mijia/scope-lock.json"
IDENTITY = ("account", "deviceID", "miotDID", "hardware")


def private_json(path, sealed=False):
    path = Path(path)
    info = path.lstat()
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077
            or info.st_size > 65536 or sealed and not info.st_flags & stat.UF_IMMUTABLE):
        raise PermissionError("权限锁文件不可确认")
    return json.loads(path.read_text())


def validate(lock, config, home, auth):
    if lock.get("version") != 1 or lock.get("hardware") != "OH2":
        raise PermissionError("仅允许冻结的OH2")
    if any(not isinstance(lock.get(k), str) or not lock[k] or len(lock[k]) > 256
           for k in (*IDENTITY, "homeID")):
        raise PermissionError("权限锁不完整")
    if any(config.get(k) != lock[k] for k in IDENTITY):
        raise PermissionError("禁止切换到其他音箱或账号")
    if (home.get("homeID") != lock["homeID"] or home.get("account") != lock["account"]
            or hashlib.sha256(str(auth.get("userId")).encode()).hexdigest() != lock["account"]):
        raise PermissionError("家庭或账号不在冻结范围")
    return lock


def local(config=None):
    lock = private_json(LOCK, sealed=True)
    config = config if config is not None else private_json(ROOT / "xiaoai/config.json")
    return validate(lock, config, private_json(ROOT / "mijia/home-scope.json", sealed=True),
                    private_json(ROOT / "mijia/auth.json"))


def guard_miot(lock, uri, data):
    params = data.get("params") if isinstance(data, dict) else None
    if uri == "/miotspec/action":
        if (not isinstance(params, dict) or set(params) != {"did", "siid", "aiid", "in"}
                or params["did"] != lock["miotDID"] or type(params["siid"]) is not int
                or type(params["aiid"]) is not int or (params["siid"], params["aiid"]) != (5, 3)
                or not isinstance(params["in"], list) or len(params["in"]) != 1
                or not isinstance(params["in"][0], str) or len(params["in"][0]) > 1000):
            raise PermissionError("禁止目标音箱以外的动作")
        return
    if uri not in ("/miotspec/prop/get", "/miotspec/prop/set") or not isinstance(params, list) or len(params) != 1:
        raise PermissionError("禁止通用设备接口")
    row = params[0]
    fields = {"did", "siid", "piid"} | ({"value"} if uri.endswith("/set") else set())
    if (not isinstance(row, dict) or set(row) != fields or row.get("did") != lock["miotDID"]
            or type(row.get("siid")) is not int or type(row.get("piid")) is not int
            or (row["siid"], row["piid"]) != (5, 3)
            or "value" in row and (type(row["value"]) is not bool or row["value"] is not True)):
        raise PermissionError("仅允许读取绑定OH2睡眠或恢复开启，禁止解除睡眠")


def _mina_message(data):
    message = data.get("message")
    try:
        return json.loads(message) if isinstance(message, str) else message
    except (TypeError, ValueError):
        return None


def guard_mina(lock, uri, data):
    if (uri != "/remote/ubus" or not isinstance(data, dict) or str(data.get("deviceId")) != lock["deviceID"]
            or data.get("path") != "mediaplayer"):
        raise PermissionError("禁止枚举或操作其他音箱")
    method = data.get("method")
    if method == "player_play_music":
        return
    # 只允许“停下来”这一个动作：用户喊停闹钟；不允许调音量、切内容或播放别的。
    payload = _mina_message(data)
    if (method == "player_play_operation" and isinstance(payload, dict) and set(payload) <= {"action", "media"}
            and payload.get("action") in ("pause", "stop") and payload.get("media") == "app_ios"):
        return
    raise PermissionError("禁止枚举或操作其他音箱")


def member_rows(lock, rows):
    matches = [row for row in rows if str(row.get("did")) == lock["miotDID"]
               and str(row.get("home_id")) == lock["homeID"] and row.get("model") == "xiaomi.wifispeaker.oh2"]
    if len(matches) != 1:
        raise PermissionError("冻结家庭中找不到已绑定OH2")


async def isolated(mode, timeout):
    """在独立安装的SDK进程里跑一次只读检查，输出只有JSON；不继承本进程的凭据或接口。"""
    python = ROOT / "mijia/venv/bin/python"
    process = await asyncio.create_subprocess_exec(str(python), "-I", "-B", str(Path(__file__).resolve()), mode,
                  stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
    try:
        output, _ = await asyncio.wait_for(process.communicate(), timeout=timeout)
        if process.returncode != 0:
            raise PermissionError("无法核验冻结家庭，已拒绝设备访问")
        return json.loads(output)
    finally:
        if process.returncode is None:
            process.kill()
            await process.wait()


async def verify_member(config=None):
    before = local(config)
    if (await isolated("--member", 18)).get("allowed") is not True:
        raise PermissionError("无法核验冻结家庭，已拒绝设备访问")
    if local(config) != before:
        raise PermissionError("核验过程中权限锁发生变化")
    return before


async def read_sleep():
    """睡眠状态只读一次：门店式设备属性端点比会话式MIOT更稳，读不到就抛出而不是猜。"""
    local()
    value = (await isolated("--sleep", 15)).get("sleep")
    if type(value) is not bool:
        raise RuntimeError("无法核验音箱睡眠状态")
    return value


def check_sleep():
    lock = local()
    from mijiaAPI import mijiaAPI
    auth_path = ROOT / "mijia/auth.json"
    api = mijiaAPI(str(auth_path))
    request = api._request
    def scoped_request(uri, data, *args, **kwargs):
        params = data.get("params") if isinstance(data, dict) else None
        if uri != "/miotspec/prop/get":
            raise PermissionError("睡眠读取只允许属性端点")
        if (not isinstance(params, list) or len(params) != 1
                or str(params[0].get("did")) != lock["miotDID"]
                or (params[0].get("siid"), params[0].get("piid")) != (5, 3)):
            raise PermissionError("睡眠读取只允许冻结OH2的5.3")
        return request(uri, data, *args, **{**kwargs, "refresh_token": False})
    api._request = scoped_request
    transport = api.session.request
    api.session.request = lambda *args, **kwargs: transport(*args, **{**kwargs, "timeout": 8})
    result = api._request("/miotspec/prop/get",
                          {"params": [{"did": lock["miotDID"], "siid": 5, "piid": 3}], "datasource": 2})
    if (not isinstance(result, list) or len(result) != 1 or result[0].get("code") != 0
            or str(result[0].get("did")) != lock["miotDID"] or type(result[0].get("value")) is not bool):
        raise RuntimeError("无法核验音箱睡眠状态")
    return result[0]["value"]


def check_member():
    lock = local()
    # 复用已安装SDK，但只开放一个固定家庭的只读端点；不查询账号的家庭或音箱总表。
    from mijiaAPI import mijiaAPI
    auth_path = ROOT / "mijia/auth.json"
    auth = private_json(auth_path)
    api = mijiaAPI(str(auth_path))
    request = api._request
    def scoped_request(uri, data, *args, **kwargs):
        if uri != "/home/home_device_list" or str(data.get("home_id")) != lock["homeID"]:
            raise PermissionError("禁止其他家庭接口")
        # 当前固定家庭端点自行验证凭据；禁用SDK的消息预检与自动登录刷新。
        # 过期直接拒绝，不额外访问账号级接口，也不因失败重放设备请求。
        return request(uri, data, refresh_token=False)
    api._request = scoped_request
    def owner(home):
        if str(home) != lock["homeID"]:
            raise PermissionError("禁止其他家庭")
        return str(auth["userId"])
    api._get_home_owner = owner
    transport = api.session.request
    api.session.request = lambda *args, **kwargs: transport(*args, **{**kwargs, "timeout": 8})
    member_rows(lock, api.get_devices_list(home_id=lock["homeID"]))


if __name__ == "__main__":
    logging.disable(logging.CRITICAL)
    if "--sleep" in sys.argv:
        try:
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                sleep = check_sleep()
        except Exception:
            raise SystemExit(1)
        print(json.dumps({"sleep": sleep}))
        raise SystemExit(0)
    try:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            check_member()
        print('{"allowed":true}')
    except Exception:
        print('{"allowed":false}')
        raise SystemExit(1)
