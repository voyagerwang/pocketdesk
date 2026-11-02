"""
[INPUT]: speaker.py 的绑定OH2云接口、已有工作台助手HTTP入口和私有配置，audio.py 的唤醒音乐出口。
[OUTPUT]: 新语音到所选工作台的持久会话与“小精灵回复”标识播报；SQLite发送前占用，未知结果不重试，重启不补发；到点只播用户安装的唤醒音乐，回执只认音箱实际取文件；本机回环的定时入口需要私有token。
[POS]: 可选语音通道，不实现模型/业务执行；远程8786为默认，本机8787仅由明确选择使用，切换不串会话。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
import asyncio
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import time
from urllib.parse import urlsplit
import uuid

from aiohttp import ClientSession, ClientTimeout, web
from intent import alarm_intent
from speaker import STATE, Speaker, read_private, save_private

POLL_SECONDS = 2
ALARM_TICK = 2
# 迟到超过10分钟不再补播：早上八点的起床铃九点响没有意义，如实记成错过。
ALARM_LATE_LIMIT = 600
ALARM_MAX_AHEAD = 30 * 86400
# 只在闹钟真的响过之后的这段时间里允许喊停：音乐约两分钟，留一点余量，也避免误掐用户自己在放的东西。
ALARM_STOP_WINDOW = 180
CONTROL_FILE = "control.json"
MAX_AGE_SECONDS = 60
MAX_QUEUE = 8
TARGETS = {"remote": "http://127.0.0.1:8786", "local": "http://127.0.0.1:8787"}
PREFIX = re.compile(r"^(?:小爱同学[，,。\s]*)?(?:小精灵|小精靈|波波|小E|小e)[，,。！!：:\s]*")
SELECTORS = (("本机", re.compile(r"^(?:在|用|交给)?(?:本机|这台电脑)[，,。：:\s]*")),
             ("远程", re.compile(r"^(?:在|用|交给)?(?:另一台电脑|远程电脑|远程)[，,。：:\s]*")))


def parse_command(query, default):
    if not isinstance(query, str) or len(query) > 16000:
        return None
    match = PREFIX.match(query.strip())
    if not match:
        return None
    text = query.strip()[match.end():].strip()
    target = default
    for label, pattern in SELECTORS:
        found = pattern.match(text)
        if found:
            target = "local" if label == "本机" else "remote"
            text = text[found.end():].strip()
            break
    return target, text


def valid_target(url):
    parsed = urlsplit(url)
    return (parsed.scheme == "http" and parsed.hostname == "127.0.0.1" and parsed.port in (8786, 8787)
            and parsed.path in ("", "/") and not parsed.query and not parsed.fragment and not parsed.username)


def speech_reply(value):
    if value.get("captureError"):
        return "工作台保存没有成功，请到工作台查看这次对话。"
    text = value.get("reply")
    if not isinstance(text, str) or not text.strip():
        return "工作台没有返回可播报的结果，请查看工作台对话。"
    text = re.sub(r"```[\s\S]*?```", "代码请到工作台查看。", text)
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"https?://\S+", "链接请到工作台查看", text)
    text = re.sub(r"(?m)^\s*(?:#{1,6}\s*|[-*]\s+)", "", text)
    text = re.sub(r"[*`_]+", "", text).strip()
    return text if len(text) <= 450 else text[:420] + "。完整结果请到工作台查看。"


class Ledger:
    def __init__(self, path):
        path = Path(path)
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.db = sqlite3.connect(path)
        path.chmod(0o600)
        self.db.row_factory = sqlite3.Row
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS turns (
                id TEXT PRIMARY KEY, created REAL NOT NULL, target TEXT NOT NULL,
                text TEXT NOT NULL, session TEXT, status TEXT NOT NULL,
                reply TEXT, tts TEXT, updated REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS timings (
                turn_id TEXT NOT NULL, stage TEXT NOT NULL, elapsed_ms INTEGER NOT NULL,
                PRIMARY KEY (turn_id, stage)
            );
            CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS alarms (
                id TEXT PRIMARY KEY, due REAL NOT NULL, status TEXT NOT NULL,
                created REAL NOT NULL, fired REAL, reason TEXT
            );
        """)
        # 上一进程的排队/发送中请求只保留待核对，不在恢复中重新发给业务服务。
        self.db.execute("UPDATE turns SET status='unknown' WHERE status IN ('queued','sending')")
        self.db.commit()

    def session(self, target, reset=False):
        key = "session:" + target
        row = self.db.execute("SELECT value FROM metadata WHERE key=?", (key,)).fetchone()
        if row and not reset:
            return row[0]
        value = "xiaoai:" + target + ":" + str(uuid.uuid4())
        self.db.execute("INSERT OR REPLACE INTO metadata VALUES (?,?)", (key, value))
        self.db.commit()
        return value

    def reserve(self, record, device_id, default, started, now):
        try:
            stamp = float(record["time"]) / 1000
        except (KeyError, TypeError, ValueError):
            return None
        if not started <= stamp <= now + 5 or now - stamp > MAX_AGE_SECONDS:
            return None
        parsed = parse_command(record.get("query"), default)
        if parsed is None:
            return None
        target, text = parsed
        identity = record.get("requestId") or json.dumps([record["time"], record["query"]], ensure_ascii=False)
        key = hashlib.sha256((device_id + ":" + str(identity)).encode()).hexdigest()
        session = self.session(target)
        with self.db:
            cursor = self.db.execute("INSERT OR IGNORE INTO turns VALUES (?,?,?,?,?,'queued',NULL,NULL,?)",
                                     (key, stamp, target, text, session, now))
        return key if cursor.rowcount else None

    def add_alarm(self, key, due, now):
        with self.db:
            cursor = self.db.execute("INSERT OR IGNORE INTO alarms (id,due,status,created) VALUES (?,?,'scheduled',?)",
                                     (key, due, now))
        return bool(cursor.rowcount)

    def recover_alarms(self):
        """进程在响铃中途被杀会留下 ringing 的僵尸记录；启动时如实标成被打断，不冒充播过。"""
        with self.db:
            return self.db.execute("UPDATE alarms SET status='failed', reason='interrupted' WHERE status='ringing'").rowcount

    def due_alarms(self, now):
        return [dict(row) for row in self.db.execute(
            "SELECT * FROM alarms WHERE status='scheduled' AND due<=? ORDER BY due", (now,))]

    def set_alarm(self, key, **values):
        allowed = {"status", "reason", "fired"}
        if not values or not set(values) <= allowed:
            raise ValueError("非法闹钟字段")
        with self.db:
            self.db.execute("UPDATE alarms SET " + ",".join(f"{k}=?" for k in values) + " WHERE id=?",
                            (*values.values(), key))

    def alarms(self):
        return [dict(row) for row in self.db.execute("SELECT * FROM alarms ORDER BY due DESC LIMIT 50")]

    def cancel_alarm(self, key):
        with self.db:
            cursor = self.db.execute("UPDATE alarms SET status='cancelled' WHERE id=? AND status='scheduled'", (key,))
        return bool(cursor.rowcount)

    def timing(self, key, stage, elapsed):
        with self.db:
            self.db.execute("INSERT OR REPLACE INTO timings VALUES (?,?,?)",
                            (key, stage, max(0, round(elapsed * 1000))))

    def get(self, key):
        return dict(self.db.execute("SELECT * FROM turns WHERE id=?", (key,)).fetchone())

    def set(self, key, **values):
        allowed = {"status", "reply", "tts", "session"}
        if not values or not set(values) <= allowed:
            raise ValueError("非法台账字段")
        with self.db:
            self.db.execute("UPDATE turns SET " + ",".join(f"{k}=?" for k in values) + ",updated=? WHERE id=?",
                            (*values.values(), time.time(), key))


class Workbench:
    def __init__(self, session, targets):
        self.session = session
        self.targets = targets
        if any(not valid_target(url) for url in targets.values()):
            raise ValueError("工作台只允许已配置的本机服务或UU回环转发")

    async def request(self, target, path, body=None, timeout=180):
        base = self.targets[target].rstrip("/")
        async with self.session.request("POST" if body is not None else "GET", base + path,
                json=body, allow_redirects=False, timeout=ClientTimeout(total=timeout)) as response:
            if response.status != 200:
                raise RuntimeError("工作台请求未确认")
            value = await response.json()
            if not isinstance(value, dict):
                raise RuntimeError("工作台返回格式异常")
            return value

    async def check(self, target):
        value = await self.request(target, "/api/assistant/runtime", timeout=8)
        if value.get("mode") != "legacy" and value.get("available") is not True:
            raise RuntimeError("所选电脑的工作台助手未就绪")

    async def chat(self, target, session, text):
        return await self.request(target, "/api/assistant/chat", {
            "message": text, "sessionKey": session,
            "context": {"kind": "global", "title": "OH2 音箱对话"}})


class Bridge:
    def __init__(self, config, speaker, workbench, ledger, started=None, root=None):
        self.config, self.speaker, self.workbench, self.ledger = config, speaker, workbench, ledger
        self.root = Path(root) if root else STATE
        self.started = time.time() if started is None else started
        self.queue = asyncio.Queue(maxsize=MAX_QUEUE)
        self.phase = "starting"

    def status(self, phase, **details):
        self.phase = phase
        save_private(self.root / "status.json", {"phase": phase, "updatedAt": time.time(),
                     "defaultTarget": self.config["defaultTarget"], **details})

    async def receive(self, records, now=None):
        now = time.time() if now is None else now
        for record in sorted(records, key=lambda r: str(r.get("time", ""))):
            key = self.ledger.reserve(record, self.config["deviceID"], self.config["defaultTarget"], self.started, now)
            if not key:
                continue
            if self.queue.full():
                self.ledger.set(key, status="not_sent", reply="音箱任务过多，未发送。")
                continue
            self.queue.put_nowait(key)

    async def speak(self, key, text):
        started = time.monotonic()
        self.ledger.set(key, tts="sending")
        try:
            receipt = await self.speaker.say("小精灵回复，" + text)
            self.ledger.set(key, tts=receipt or "accepted")
        except Exception:
            self.ledger.set(key, tts="unknown")
            self.status("speech_unconfirmed")
        finally:
            self.ledger.timing(key, "speech_request", time.monotonic() - started)

    async def execute(self, key):
        turn = self.ledger.get(key)
        if turn["status"] != "queued":
            return
        self.ledger.timing(key, "recognition_to_execute", time.time() - turn["created"])
        text, target = turn["text"], turn["target"]
        if not text or text in ("换个话题", "开始新话题", "新话题"):
            if text:
                session = self.ledger.session(target, reset=True)
                self.ledger.set(key, session=session)
            reply = "我在，你说。默认交给另一台电脑的工作台。" if target == "remote" else "我在，这次交给本机工作台。"
            self.ledger.set(key, status="done", reply=reply)
            await self.speak(key, reply)
            return
        # 到点叫醒是音箱自己的能力，确定性处理，不交给远端工作台；远端只会口头答应，什么也不会定。
        intent = alarm_intent(text)
        if intent is not None and intent[0] == "stop":
            _, reply = await self.stop_alarm()
            self.ledger.set(key, status="done", reply=reply)
            await self.speak(key, reply)
            self.status("listening")
            return
        if intent is not None:
            reply = self.handle_alarm_intent(intent)
            self.ledger.set(key, status="done", reply=reply)
            await self.speak(key, reply)
            self.status("listening")
            return
        # 检查属于发送前准备，可安全失败；此后任何网络错误都不能自动重派。
        checked = time.monotonic()
        try:
            await self.workbench.check(target)
        except Exception:
            reply = "暂时连不上所选电脑的工作台，这条指令没有发送。请确认UU远程连接在线。"
            self.ledger.set(key, status="not_sent", reply=reply)
            self.ledger.timing(key, "workbench_check", time.monotonic() - checked)
            await self.speak(key, reply)
            return
        self.ledger.timing(key, "workbench_check", time.monotonic() - checked)
        # OH2的媒体暂停不能视为取消原生助手；它还可能压住随后的播报。
        # 保留原生回答，由固定play-text输出工作台结果，不盲停音箱媒体通道。
        self.ledger.set(key, status="sending")
        self.status("working", target=target)
        dispatched = time.monotonic()
        try:
            # 中途播报也要走完整权限/睡眠/云端链路，不能用它挡住已返回的业务结果。
            value = await self.workbench.chat(target, turn["session"], text)
            reply = speech_reply(value)
            self.ledger.set(key, status="done", reply=reply)
        except Exception:
            reply = "这条请求的结果暂时没核实，我不会重复发送。请到所选工作台查看音箱对话。"
            self.ledger.set(key, status="unknown", reply=reply)
        finally:
            self.ledger.timing(key, "workbench_chat", time.monotonic() - dispatched)
        await self.speak(key, reply)
        self.status("listening")

    async def stop_alarm(self):
        """只停最近真的响过的闹钟；没有响过就不动播放器，免得掐掉用户自己在放的东西。"""
        now = time.time()
        recent = [row for row in self.ledger.alarms()
                  if row["status"] in ("ringing", "done") and row.get("fired") and now - row["fired"] <= ALARM_STOP_WINDOW]
        if not recent:
            pending = [row for row in self.ledger.alarms() if row["status"] == "scheduled"]
            if pending and self.ledger.cancel_alarm(pending[0]["id"]):
                return True, "还没开始响，那条闹钟我取消了。"
            return False, "现在没有闹钟在响。"
        try:
            await self.speaker.stop_playback()
        except Exception:
            return False, "停不下来，音箱没有确认；可以直接对小爱说停止播放。"
        for row in recent:
            self.ledger.set_alarm(row["id"], status="stopped", reason="user_stopped")
        self.status("alarm_stopped")
        return True, "好，音乐停了。"

    def handle_alarm_intent(self, intent):
        due, reply = intent
        pending = [row for row in self.ledger.alarms() if row["status"] == "scheduled"]
        if due == "cancel":
            if not pending:
                return "现在没有还没响的闹钟。"
            return reply if self.ledger.cancel_alarm(pending[0]["id"]) else "这条闹钟没取消成功，稍后再试。"
        if self.alarm_file() is None:
            return "还没装唤醒音乐，先在音箱通道装一段音乐，我才能到点放给你听。"
        if due - time.time() > ALARM_MAX_AHEAD:
            return "太远了，我只能定三十天以内的。"
        if not self.ledger.add_alarm(uuid.uuid4().hex, due, time.time()):
            return "这条闹钟没定上，再说一次试试。"
        return reply

    def alarm_file(self):
        name = self.config.get("alarmFile")
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,80}", name) or name.startswith("."):
            return None
        return self.root / "audio" / "alarm" / name

    async def fire_alarm(self, row):
        """到点只放音乐：不解除睡眠、不推测音量、失败就如实记原因，不重复播。"""
        key, now = row["id"], time.time()
        if now - row["due"] > ALARM_LATE_LIMIT:
            self.ledger.set_alarm(key, status="missed", reason="late")
            return
        path = self.alarm_file()
        audio = self.speaker.audio
        if audio is None or path is None or not path.is_file():
            self.ledger.set_alarm(key, status="failed", reason="no_music")
            self.status("alarm_unavailable")
            return
        self.ledger.set_alarm(key, status="ringing", fired=now)
        # 闹钟是用户亲自排定的出声时刻：睡眠开关或读不到状态都不拦，只如实记进台账。
        # 普通播报仍严格拒绝睡眠（见 Speaker.say），这里不解除、也不改写睡眠状态。
        try:
            sleep = "on" if await self.speaker.sleep_mode() else "off"
        except Exception:
            sleep = "unknown"
        try:
            receipt = await audio.play_alarm(path)
            self.ledger.set_alarm(key, status="done", reason=f"{receipt or 'accepted'}/sleep_{sleep}")
            self.status("alarm_played")
        except Exception as error:
            self.ledger.set_alarm(key, status="failed", reason=self.reason(error))
            self.status("alarm_failed")

    @staticmethod
    def reason(error):
        """失败原因只记可核对的短码，不把云端原文写进台账。"""
        text = str(error)
        if "-127" in text or "client withdraw" in text:
            return "rate_limited"
        if "401" in text or "403" in text or "Unauthorized" in text:
            return "unauthorized"
        if isinstance(error, PermissionError):
            return "denied"
        return type(error).__name__

    async def alarms(self):
        while True:
            try:
                for row in self.ledger.due_alarms(time.time()):
                    await self.fire_alarm(row)
            except Exception:
                pass
            await asyncio.sleep(ALARM_TICK)

    async def worker(self):
        while True:
            key = await self.queue.get()
            try:
                await self.execute(key)
            finally:
                self.queue.task_done()

    async def run(self):
        self.ledger.recover_alarms()
        worker = asyncio.create_task(self.worker())
        alarms = asyncio.create_task(self.alarms())
        control = await Control(self).__aenter__()
        failures = 0
        try:
            self.status("listening")
            while True:
                if worker.done():
                    worker.result()
                try:
                    records = await self.speaker.records()
                    await self.receive(records)
                    if failures:
                        self.status("listening")
                    failures = 0
                    self.status(self.phase, lastPollAt=time.time())
                except Exception:
                    failures += 1
                    self.status("speaker_unavailable", consecutiveFailures=failures)
                await asyncio.sleep(min(30, POLL_SECONDS * max(1, failures)))
        finally:
            worker.cancel(); alarms.cancel()
            await asyncio.gather(worker, alarms, return_exceptions=True)
            await control.__aexit__()
            self.status("stopped")

class Control:
    """本机回环的定时入口：只登记、取消、查询时间，不接触设备动作或音频正文。"""

    def __init__(self, bridge, state=None):
        self.bridge, self.token, self.runner, self.port = bridge, secrets.token_urlsafe(32), None, None
        self.state = Path(state) if state else STATE

    async def __aenter__(self):
        app = web.Application(client_max_size=1024)
        app.router.add_get("/alarm", self.listing)
        app.router.add_post("/alarm", self.schedule)
        app.router.add_post("/alarm/cancel", self.cancel)
        app.router.add_post("/alarm/stop", self.stop)
        self.runner = web.AppRunner(app, access_log=None)
        await self.runner.setup()
        await web.TCPSite(self.runner, "127.0.0.1", 0).start()
        self.port = self.runner.addresses[0][1]
        save_private(self.state / CONTROL_FILE, {"port": self.port, "token": self.token,
                    "pid": os.getpid(), "updatedAt": time.time()})
        return self

    async def __aexit__(self, *_):
        if self.runner:
            await self.runner.cleanup()
        try:
            (self.state / CONTROL_FILE).unlink()
        except FileNotFoundError:
            pass

    def authorized(self, request):
        # 只认回环来源和本次进程的私有token；音箱能访问的音频端口不承载这些路由。
        if request.remote not in ("127.0.0.1", "::1"):
            return False
        return secrets.compare_digest(request.headers.get("Authorization", ""), "Bearer " + self.token)

    async def body(self, request):
        if not self.authorized(request):
            raise web.HTTPForbidden()
        try:
            value = await request.json()
        except Exception:
            raise web.HTTPBadRequest()
        if not isinstance(value, dict):
            raise web.HTTPBadRequest()
        return value

    async def schedule(self, request):
        value = await self.body(request)
        if set(value) != {"id", "due"}:
            raise web.HTTPBadRequest()
        key, due = value["id"], value["due"]
        now = time.time()
        if not isinstance(key, str) or not re.fullmatch(r"[A-Za-z0-9_-]{8,64}", key):
            raise web.HTTPBadRequest()
        if type(due) is not int or not now - 60 <= due <= now + ALARM_MAX_AHEAD:
            raise web.HTTPBadRequest()
        if self.bridge.alarm_file() is None:
            return web.json_response({"error": "没有可播放的唤醒音乐"}, status=409)
        created = self.bridge.ledger.add_alarm(key, float(due), now)
        return web.json_response({"id": key, "due": due, "status": "scheduled"}, status=200 if created else 409)

    async def listing(self, request):
        if not self.authorized(request):
            raise web.HTTPForbidden()
        return web.json_response({"alarms": self.bridge.ledger.alarms()})

    async def stop(self, request):
        stopped, reply = await self.bridge.stop_alarm()
        return web.json_response({"stopped": stopped, "reply": reply})

    async def cancel(self, request):
        value = await self.body(request)
        if set(value) != {"id"} or not isinstance(value["id"], str):
            raise web.HTTPBadRequest()
        return web.json_response({"id": value["id"], "cancelled": self.bridge.ledger.cancel_alarm(value["id"])})


async def main():
    os.umask(0o077)
    config = read_private(STATE / "config.json")
    lock = open(STATE / "bridge.lock", "a")
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    ledger = Ledger(STATE / "turns.sqlite3")
    async with Speaker(config) as speaker, ClientSession(trust_env=False) as session:
        bridge = Bridge(config, speaker, Workbench(session, config["targets"]), ledger)
        await bridge.run()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
    except Exception as error:
        # 异常文本可能含cookie、完整云返回或用户原话，只输出类型。
        save_private(STATE / "status.json", {"phase": "startup_failed", "errorType": type(error).__name__,
                                           "updatedAt": time.time()})
        raise SystemExit(1)
