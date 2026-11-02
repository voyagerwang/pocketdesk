"""
[INPUT]: 真实OH2通道策略、临时SQLite和音箱/工作台替身。
[OUTPUT]: 验证新语音门禁、目标隔离、持久防重、未知结果恢复和播报失败不重派、慢结果不受中途播报阻塞及分段耗时；不使用真实账号或创建业务数据。
[POS]: 音箱接入回归，覆盖跨进程副作用边界而非仅复述工具参数。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
import asyncio
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/xiaoai"))
from bridge import Bridge, Ledger, MAX_QUEUE, Workbench, parse_command, speech_reply, valid_target
from speaker import read_private, save_private
import speaker as speaker_module


class FakeSpeaker:
    def __init__(self):
        self.said = []
        self.fail = False
        self.pause_calls = 0

    async def pause(self):
        self.pause_calls += 1

    async def say(self, text):
        self.said.append(text)
        if self.fail:
            raise TimeoutError()


class FakeWorkbench:
    def __init__(self):
        self.calls = []
        self.fail_check = False
        self.fail_send = False

    async def check(self, target):
        if self.fail_check:
            raise ConnectionError()

    async def chat(self, target, session, text):
        self.calls.append((target, session, text))
        if self.fail_send:
            raise TimeoutError()
        return {"reply": "清单已创建。"}


class PolicyTests(unittest.TestCase):
    def test_only_explicit_prefix(self):
        for text in ("明天开灯", "请问小精灵是什么", "转述：小精灵帮我记一下", "听音乐"):
            self.assertIsNone(parse_command(text, "remote"))
        self.assertEqual(parse_command("小爱同学，小精灵，记一下明天的事", "remote"),
                         ("remote", "记一下明天的事"))

    def test_target_selection_keeps_body(self):
        self.assertEqual(parse_command("小精灵，本机，记一下原话", "remote"), ("local", "记一下原话"))
        self.assertEqual(parse_command("小精灵，在另一台电脑，查进度", "local"), ("remote", "查进度"))
        self.assertEqual(parse_command("波波，标题包含本机", "remote"), ("remote", "标题包含本机"))

    def test_no_credentials_or_foreign_targets(self):
        self.assertTrue(valid_target("http://127.0.0.1:8786/"))
        for url in ("http://evil.com:8786", "http://127.0.0.1:8786@evil.com", "http://u@127.0.0.1:8786",
                    "http://127.0.0.1:8786/?token=abc", "http://127.0.0.1:8786/api", "http://127.0.0.1:9000"):
            self.assertFalse(valid_target(url))

    def test_truthful_short_speech(self):
        self.assertIn("保存没有成功", speech_reply({"reply": "已完成", "captureError": "error"}))
        self.assertEqual(speech_reply({"reply": "**已接收**，尚未完成。"}), "已接收，尚未完成。")
        self.assertNotIn("https://", speech_reply({"reply": "见[成果](https://example.com)"}))
        self.assertLess(len(speech_reply({"reply": "字" * 1000})), 451)

    def test_private_atomic_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "auth.json"
            save_private(path, {"value": "secret"})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(read_private(path), {"value": "secret"})
            path.chmod(0o644)
            with self.assertRaises(RuntimeError):
                read_private(path)


class FlowTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "turns.sqlite3"
        self.ledger = Ledger(self.path)
        self.speaker, self.workbench = FakeSpeaker(), FakeWorkbench()
        self.bridge = Bridge({"defaultTarget": "remote", "deviceID": "test-oh2"}, self.speaker,
                             self.workbench, self.ledger, started=1000)
        self.bridge.status = lambda *args, **kw: None

    async def asyncTearDown(self):
        self.ledger.db.close()
        self.tmp.cleanup()

    def record(self, query="小精灵，记一下", key="1", when=1001):
        return {"time": when * 1000, "query": query, "requestId": key}

    async def take(self, record):
        await self.bridge.receive([record], now=1002)
        return self.bridge.queue.get_nowait()

    async def test_old_future_and_stale_speech_never_executes(self):
        records = [self.record(when=999), self.record(when=2000), self.record(when=1001)]
        await self.bridge.receive(records, now=1100)
        self.assertTrue(self.bridge.queue.empty())
        self.assertEqual(self.ledger.db.execute("SELECT count(*) FROM turns").fetchone()[0], 0)

    async def test_duplicate_delayed_record_executes_once(self):
        record = self.record()
        key = await self.take(record)
        await self.bridge.execute(key)
        await self.bridge.receive([record, record], now=1003)
        await self.bridge.execute(key)
        self.assertEqual(len(self.workbench.calls), 1)
        self.assertEqual(self.workbench.calls[0][0], "remote")
        self.assertEqual(self.ledger.get(key)["status"], "done")
        self.assertTrue(self.bridge.queue.empty())
        self.assertEqual(self.speaker.pause_calls, 0)
        self.assertTrue(self.speaker.said[-1].startswith("小精灵回复，"))

    async def test_slow_result_is_not_blocked_by_progress_speech(self):
        original = self.workbench.chat
        async def slow_chat(*args):
            await asyncio.sleep(6.05)
            return await original(*args)
        self.workbench.chat = slow_chat
        async def say(text):
            if not text.startswith("小精灵回复，"):
                await asyncio.Event().wait()
            self.speaker.said.append(text)
        self.speaker.say = say
        key = await self.take(self.record())
        await asyncio.wait_for(self.bridge.execute(key), timeout=6.8)
        self.assertEqual(len(self.speaker.said), 1)
        self.assertEqual(self.ledger.get(key)["status"], "done")
        timings = dict(self.ledger.db.execute("SELECT stage,elapsed_ms FROM timings WHERE turn_id=?", (key,)))
        self.assertGreaterEqual(timings["workbench_chat"], 6000)
        self.assertIn("speech_request", timings)
        self.assertEqual(len(self.workbench.calls), 1)

    async def test_ambiguous_send_retained_without_retry(self):
        self.workbench.fail_send = True
        key = await self.take(self.record())
        await self.bridge.execute(key)
        await self.bridge.execute(key)
        self.assertEqual(len(self.workbench.calls), 1)
        self.assertEqual(self.ledger.get(key)["status"], "unknown")
        self.assertIn("不会重复发送", self.speaker.said[-1])

    async def test_speech_failure_does_not_repeat_business_write(self):
        self.speaker.fail = True
        key = await self.take(self.record())
        await self.bridge.execute(key)
        await self.bridge.execute(key)
        self.assertEqual(len(self.workbench.calls), 1)
        self.assertEqual(self.ledger.get(key)["status"], "done")
        self.assertEqual(self.ledger.get(key)["tts"], "unknown")

    async def test_disconnected_default_has_no_local_fallback(self):
        self.workbench.fail_check = True
        key = await self.take(self.record())
        await self.bridge.execute(key)
        self.assertEqual(self.workbench.calls, [])
        self.assertEqual(self.ledger.get(key)["status"], "not_sent")
        self.assertIn("没有发送", self.speaker.said[-1])

    async def test_targets_have_separate_persistent_context(self):
        for query, key in [("小精灵，第一件事", "a"), ("小精灵，本机，第二件事", "b"),
                           ("小精灵，接着第一件事", "c")]:
            turn = await self.take(self.record(query, key))
            await self.bridge.execute(turn)
        a, b, c = self.workbench.calls
        self.assertEqual(a[1], c[1])
        self.assertNotEqual(a[1], b[1])
        self.assertEqual((a[0], b[0], c[0]), ("remote", "local", "remote"))

    async def test_restart_retains_uncertain_turn_never_requeues(self):
        key = await self.take(self.record())
        self.ledger.set(key, status="sending")
        session = self.ledger.session("remote")
        other = Ledger(self.path)
        self.assertEqual(other.get(key)["status"], "unknown")
        self.assertEqual(other.session("remote"), session)
        self.assertIsNone(other.reserve(self.record(), "test-oh2", "remote", 1000, 1002))
        other.db.close()

    async def test_new_topic_changes_only_selected_session(self):
        before = self.ledger.session("remote")
        local = self.ledger.session("local")
        key = await self.take(self.record("小精灵，换个话题"))
        await self.bridge.execute(key)
        self.assertNotEqual(before, self.ledger.session("remote"))
        self.assertEqual(local, self.ledger.session("local"))
        self.assertEqual(self.workbench.calls, [])

    async def test_queue_limit_preserves_unsent_text(self):
        await self.bridge.receive([self.record(key=str(i)) for i in range(MAX_QUEUE + 1)], now=1002)
        self.assertEqual(self.bridge.queue.qsize(), MAX_QUEUE)
        row = self.ledger.db.execute("SELECT * FROM turns WHERE status='not_sent'").fetchone()
        self.assertEqual(row["text"], "记一下")


class TransportTests(unittest.IsolatedAsyncioTestCase):
    async def test_sdk_never_retries_rejected_writes(self):
        account = object.__new__(speaker_module.SessionAccount)
        with patch.object(speaker_module.MiAccount, "mi_request", new_callable=AsyncMock) as call:
            await account.mi_request("xiaomiio", "https://api.io.mi.com/app/miotspec/action", {}, {})
            self.assertFalse(call.call_args.kwargs["relogin"])

    async def test_failed_session_exchange_never_attempts_password(self):
        with tempfile.TemporaryDirectory() as tmp:
            seed_path = Path(tmp) / "seed.json"
            seed = {"userId": "test", "deviceId": "device", "passToken": "secret"}
            save_private(seed_path, seed)
            with patch.object(speaker_module, "SEED", seed_path), patch.object(speaker_module, "STATE", Path(tmp)):
                account = speaker_module.SessionAccount(None, speaker_module.account_hash(seed))
                account._serviceLogin = AsyncMock(return_value={"code": 70016})
                account._securityTokenService = AsyncMock()
                with self.assertRaises(RuntimeError):
                    await account.login("micoapi")
                account._serviceLogin.assert_awaited_once_with("serviceLogin?sid=micoapi&_json=true")
                account._securityTokenService.assert_not_called()
                self.assertEqual(read_private(seed_path), seed)

    async def test_changed_account_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            seed_path = Path(tmp) / "seed.json"
            save_private(seed_path, {"userId": "another", "deviceId": "device", "passToken": "secret"})
            with patch.object(speaker_module, "SEED", seed_path):
                with self.assertRaises(RuntimeError):
                    speaker_module.SessionAccount(None, "old-account-hash")

    async def test_fixed_tts_action_is_not_model_controlled(self):
        speaker = speaker_module.Speaker({"miotDID": "bound-oh2", "account": "bound-account", "action": [99, 99]})
        speaker.check_account = lambda: None
        speaker.sleep_mode = AsyncMock(return_value=False)
        speaker.miio = type("Miio", (), {})()
        speaker.miio.miot_action = AsyncMock(return_value=-1)
        class Context:
            async def __aenter__(self): return "isolated-session"
            async def __aexit__(self, *_): pass
        with patch.object(speaker_module, "ClientSession", return_value=Context()) as factory, \
             patch.object(speaker_module, "SessionAccount", return_value="account") as account, \
             patch.object(speaker_module, "MiIOService", return_value=speaker.miio):
            with self.assertRaises(RuntimeError):
                await speaker.say("普通文字[99,99]")
            self.assertIsInstance(factory.call_args.kwargs["cookie_jar"], speaker_module.DummyCookieJar)
            self.assertFalse(factory.call_args.kwargs["trust_env"])
            account.assert_called_once_with("isolated-session", "bound-account")
        speaker.miio.miot_action.assert_awaited_once_with("bound-oh2", [5, 3], ["普通文字[99,99]"])

    async def test_sleeping_speaker_is_never_automatically_woken(self):
        speaker = speaker_module.Speaker({"miotDID": "bound-oh2"})
        speaker.check_account = lambda: None
        speaker.sleep_mode = AsyncMock(return_value=True)
        speaker.set_sleep = AsyncMock()
        speaker.native_say = AsyncMock()
        with self.assertRaises(PermissionError):
            await speaker.say("真实回复")
        speaker.set_sleep.assert_not_awaited()
        speaker.native_say.assert_not_awaited()

    async def test_unknown_sleep_state_does_not_write_or_send_tts(self):
        speaker = speaker_module.Speaker({"miotDID": "bound-oh2"})
        speaker.check_account = lambda: None
        speaker.sleep_mode = AsyncMock(side_effect=TimeoutError())
        speaker.set_sleep = AsyncMock()
        speaker.native_say = AsyncMock()
        with self.assertRaises(TimeoutError):
            await speaker.say("真实回复")
        speaker.set_sleep.assert_not_awaited()
        speaker.native_say.assert_not_called()

    async def test_workbench_posts_only_one_turn_and_never_follows_redirect(self):
        class Response:
            status = 200
            async def __aenter__(self): return self
            async def __aexit__(self, *_): pass
            async def json(self): return {"reply": "已接收"}
        class Session:
            def request(self, method, url, **kwargs):
                self.last = (method, url, kwargs)
                return Response()
        session = Session()
        wb = Workbench(session, {"remote": "http://127.0.0.1:8786"})
        await wb.chat("remote", "speaker-session", "原话")
        method, url, options = session.last
        self.assertEqual((method, url), ("POST", "http://127.0.0.1:8786/api/assistant/chat"))
        self.assertFalse(options["allow_redirects"])
        self.assertEqual(options["json"]["message"], "原话")
        self.assertNotIn("messages", options["json"])
        self.assertNotIn("headers", options)


if __name__ == "__main__":
    unittest.main()
