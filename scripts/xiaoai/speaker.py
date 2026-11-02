"""
[INPUT]: 独立MiService/aiohttp、私有账号及OH2配置，audio.py提供可选系统音色音频。
[OUTPUT]: 识别读取和独立无Cookie会话的小爱默认音色播报；音频出口同时服务备用音色与唤醒音乐，回复音色按配置而非出口是否存在选择，播放前核验睡眠且尊重用户设置，不自动唤醒，不触发密码回退。
[POS]: 音箱云接口边界；凭据只在本机，工作台及模型不接触它，所有设备写入固定到一台OH2。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
import hashlib
import json
import logging
import os
from pathlib import Path
import time

from aiohttp import ClientSession, ClientTimeout, DummyCookieJar
from miservice import MiAccount, MiIOService as SDKMiIOService, MiNAService as SDKMiNAService
import scope as permission_scope

ROOT = Path.home() / "Library/Application Support/VoiceDeck"
STATE = ROOT / "xiaoai"
SEED = ROOT / "mijia/auth.json"


def read_private(path):
    path = Path(path)
    if path.is_symlink() or path.stat().st_uid != os.getuid() or path.stat().st_mode & 0o077:
        raise RuntimeError("私有配置权限异常")
    return json.loads(path.read_text())


def save_private(path, value):
    path = Path(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.parent.chmod(0o700)
    tmp = path.with_name(path.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as out:
        json.dump(value, out, ensure_ascii=False)
        out.flush()
        os.fsync(out.fileno())
    os.replace(tmp, path)
    path.chmod(0o600)


def account_hash(auth):
    return hashlib.sha256(str(auth["userId"]).encode()).hexdigest()


class SessionAccount(MiAccount):
    """仅以已有账号续期，不进入SDK的密码/验证码回退与敏感错误日志。"""
    def __init__(self, session, expected):
        super().__init__(session, "", "", None)
        self.expected = expected
        self.token_path = STATE / "mina-auth.json"
        self.seed = read_private(SEED)
        if account_hash(self.seed) != expected:
            raise RuntimeError("小米账号已变化，需要重新绑定音箱")
        self.token = {k: self.seed[k] for k in ("userId", "deviceId", "passToken")}
        if self.token_path.exists():
            stored = read_private(self.token_path)
            if account_hash(stored) == expected:
                self.token.update(stored)

    async def login(self, sid):
        if sid not in {"micoapi", "xiaomiio"}:
            raise RuntimeError("不支持的音箱服务")
        # SDK在401时会清空内存，保留本机已授权的账号种子，最多由调用方下一轮只读重试。
        if self.token is None:
            self.token = {k: self.seed[k] for k in ("userId", "deviceId", "passToken")}
        result = await self._serviceLogin(f"serviceLogin?sid={sid}&_json=true")
        if result.get("code") != 0 or result.get("notificationUrl"):
            raise RuntimeError("小米登录需要重新验证，请在电脑米家连接中扫码")
        if account_hash(result) != self.expected:
            raise RuntimeError("小米服务账号不一致")
        token = await self._securityTokenService(result["location"], result["nonce"], result["ssecurity"])
        self.token.update({k: result[k] for k in ("userId", "passToken")})
        self.token[sid] = [result["ssecurity"], token]
        save_private(self.token_path, self.token)
        return True

    async def mi_request(self, sid, url, data, headers, relogin=True):
        # 读接口可下一轮恢复；写接口不允许SDK自动重新发送。
        return await super().mi_request(sid, url, data, headers, relogin=False)


class MiIOService(SDKMiIOService):
    async def miio_request(self, uri, data):
        boundary = permission_scope.local()
        permission_scope.guard_miot(boundary, uri, data)
        await permission_scope.verify_member()
        return await super().miio_request(uri, data)


class MiNAService(SDKMiNAService):
    async def mina_request(self, uri, data=None):
        boundary = permission_scope.local()
        permission_scope.guard_mina(boundary, uri, data)
        await permission_scope.verify_member()
        return await super().mina_request(uri, data)


class Speaker:
    # 未经 __aenter__ 构造时默认按原生音色处理，避免把“有没有音频出口”当成“用哪种音色”。
    voice_output = False

    def __init__(self, config):
        self.config = config
        self.session = None
        self.audio = None

    async def __aenter__(self):
        await permission_scope.verify_member(self.config)
        logging.getLogger("miservice").setLevel(logging.CRITICAL)
        self.session = ClientSession(timeout=ClientTimeout(total=20), trust_env=False)
        try:
            self.account = SessionAccount(self.session, self.config["account"])
            self.mina = MiNAService(self.account)
            self.miio = MiIOService(self.account)
            self.verified = True
            # 音频出口两种用途：备用音色播报、到点放唤醒音乐。出口本身与“回复用哪种音色”分开，
            # 装了唤醒音乐不代表回复要换音色。
            self.voice_output = self.config.get("speechOutput") == "audio"
            if self.voice_output or self.config.get("alarmFile"):
                from audio import AudioOutput
                self.audio = await AudioOutput(STATE / "audio",
                    lambda url: self.mina.play_by_music_url(self.config["deviceID"], url)).__aenter__()
            return self
        except BaseException:
            await self.session.close()
            raise

    async def __aexit__(self, *_):
        if self.audio:
            await self.audio.__aexit__()
        await self.session.close()

    def check_account(self):
        permission_scope.local(self.config)
        if account_hash(read_private(SEED)) != self.config["account"]:
            raise RuntimeError("小米账号已变化，需要重新绑定音箱")

    async def records(self):
        try:
            return await self._records_once()
        except PermissionError:
            # 会话过期只重新登一次再读；写接口永不因此重放。
            await self.account.login("micoapi")
            return await self._records_once()

    async def _records_once(self):
        self.check_account()
        await permission_scope.verify_member(self.config)
        if not self.account.token or "micoapi" not in self.account.token:
            await self.account.login("micoapi")
        token = self.account.token
        cookies = {"deviceId": self.config["deviceID"], "userId": token["userId"],
                   "serviceToken": token["micoapi"][1]}
        async with self.session.get("https://userprofile.mina.mi.com/device_profile/v2/conversation",
                params={"source": "dialogu", "hardware": "OH2", "timestamp": str(int(time.time() * 1000)),
                        "limit": "20"}, cookies=cookies, allow_redirects=False) as response:
            if response.status in (401, 403):
                raise PermissionError("音箱会话已过期")
            value = await response.json(content_type=None)
            if response.status != 200 or value.get("code") != 0:
                raise RuntimeError("暂时无法读取音箱识别结果")
            data = value.get("data")
            data = json.loads(data) if isinstance(data, str) else data
            records = data.get("records") if isinstance(data, dict) else None
            if not isinstance(records, list):
                raise RuntimeError("音箱识别结果格式异常")
            return records[:20]

    async def sleep_mode(self):
        # 会话式MIOT对本账号长期返回-127限流，改走米家只读属性端点；范围仍只有冻结OH2的5.3。
        return await permission_scope.read_sleep()

    async def set_sleep(self, value):
        if type(value) is not bool:
            raise ValueError("睡眠状态必须为布尔值")
        result = await self.miio.miot_request("prop/set", [{"did": self.config["miotDID"],
                    "siid": 5, "piid": 3, "value": value}])
        if not isinstance(result, list) or len(result) != 1 or result[0].get("code") != 0:
            raise RuntimeError("音箱睡眠设置结果未确认")
        if await self.sleep_mode() is not value:
            raise RuntimeError("音箱睡眠状态尚未生效，不自动重发设置")

    async def stop_playback(self):
        """只停当前播放，不改音量、不换内容；用户喊停闹钟时用。"""
        self.check_account()
        if not await self.mina.player_stop(self.config["deviceID"]):
            raise RuntimeError("音箱未确认停止播放")

    async def say(self, text):
        self.check_account()
        # 睡眠是用户设备状态，不能为了播报擅自解除；状态未知也不继续写入。
        if await self.sleep_mode():
            raise PermissionError("音箱处于睡眠模式，未自动唤醒或播报")
        if self.voice_output:
            return await self.audio.say(text)
        await self.native_say(text)

    async def native_say(self, text):
        # OH2的固定文字播报动作。禁止把模型输出解释成设备动作或命令。
        # 与持续识别读取隔离；不继承不同小米服务互相污染的会话Cookie。
        async with ClientSession(cookie_jar=DummyCookieJar(), timeout=ClientTimeout(total=20), trust_env=False) as session:
            account = SessionAccount(session, self.config["account"])
            code = await MiIOService(account).miot_action(self.config["miotDID"], [5, 3], [text])
        if code != 0:
            raise RuntimeError("音箱未确认接受播报")
