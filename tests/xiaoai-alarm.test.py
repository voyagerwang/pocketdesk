"""
[INPUT]: 真实Ledger/Control回环服务与音箱、音频出口替身；临时目录承载私有配置。
[OUTPUT]: 验证定时只登记时间、重复登记不覆盖、取消只对未播生效、到点只放已安装音乐、睡眠状态只记账不拦闹钟、缺音乐/迟到如实记原因且不重复播放，以及回环token门禁。
[POS]: 唤醒音乐闹钟的隔离验收；不调用真实音箱、不触发系统合成，不写正式配置目录。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
import asyncio
from pathlib import Path
import sys
import tempfile
import time
import unittest

from aiohttp import ClientSession

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/xiaoai"))
from bridge import Bridge, Control, Ledger


class FakeAudio:
    def __init__(self, fail=None):
        self.played, self.fail = [], fail

    async def play_alarm(self, path):
        if self.fail:
            raise self.fail
        self.played.append(Path(path).name)
        return "audio_requested"


class FakeWorkbench:
    def __init__(self):
        self.calls = []

    async def check(self, target):
        self.calls.append("check")

    async def chat(self, target, session, text):
        self.calls.append("chat")
        return {"reply": "远端不该被叫到"}


class FakeSpeaker:
    def __init__(self, audio=None, sleep=False, failures=0):
        self.audio, self.sleep, self.failures = audio, sleep, failures

    async def say(self, text):
        self.said = getattr(self, "said", [])
        self.said.append(text)
        return "accepted"

    async def sleep_mode(self):
        if self.failures:
            self.failures -= 1
            raise RuntimeError("Error: rate limit -127")
        return self.sleep


def build(root, speaker, alarm="wake.mp3"):
    ledger = Ledger(Path(root) / "turns.sqlite3")
    config = {"deviceID": "d", "defaultTarget": "remote", "targets": {}}
    if alarm:
        folder = Path(root) / "audio" / "alarm"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / alarm).write_bytes(b"ID3" + b"0" * 64)
        config["alarmFile"] = alarm
    return Bridge(config, speaker, None, ledger, root=root), ledger


class AlarmTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = self.temp.name

    async def asyncTearDown(self):
        self.temp.cleanup()

    async def test_due_alarm_plays_music_once(self):
        audio = FakeAudio()
        bridge, ledger = build(self.root, FakeSpeaker(audio))
        now = time.time()
        self.assertTrue(ledger.add_alarm("abc12345", now - 1, now))
        self.assertFalse(ledger.add_alarm("abc12345", now - 1, now), "同一 id 不覆盖已有时刻")
        rows = ledger.due_alarms(now)
        self.assertEqual([row["id"] for row in rows], ["abc12345"])
        await bridge.fire_alarm(rows[0])
        self.assertEqual(audio.played, ["wake.mp3"], "到点播的就是已安装的那段音乐")
        self.assertEqual(ledger.due_alarms(now), [], "播过的不再重复触发")

    async def test_sleep_mode_does_not_silence_alarm(self):
        audio = FakeAudio()
        bridge, ledger = build(self.root, FakeSpeaker(audio, sleep=True))
        now = time.time()
        ledger.add_alarm("abc12345", now - 1, now)
        await bridge.fire_alarm(ledger.due_alarms(now)[0])
        self.assertEqual(audio.played, ["wake.mp3"], "睡着的音箱也得响，这正是闹钟的用途")
        alarm = ledger.alarms()[0]
        self.assertEqual((alarm["status"], alarm["reason"]), ("done", "audio_requested/sleep_on"))

    async def test_sleep_state_is_recorded_when_off(self):
        audio = FakeAudio()
        bridge, ledger = build(self.root, FakeSpeaker(audio))
        now = time.time()
        ledger.add_alarm("abc12345", now - 1, now)
        await bridge.fire_alarm(ledger.due_alarms(now)[0])
        self.assertEqual(ledger.alarms()[0]["reason"], "audio_requested/sleep_off")

    async def test_missing_music_fails_with_reason(self):
        bridge, ledger = build(self.root, FakeSpeaker(FakeAudio()), alarm=None)
        now = time.time()
        ledger.add_alarm("abc12345", now - 1, now)
        await bridge.fire_alarm(ledger.due_alarms(now)[0])
        alarm = ledger.alarms()[0]
        self.assertEqual((alarm["status"], alarm["reason"]), ("failed", "no_music"))

    async def test_late_alarm_is_missed_not_played(self):
        audio = FakeAudio()
        bridge, ledger = build(self.root, FakeSpeaker(audio))
        now = time.time()
        ledger.add_alarm("abc12345", now - 601, now)
        await bridge.fire_alarm(ledger.due_alarms(now)[0])
        self.assertEqual(audio.played, [], "迟到太久不补播，别在九点响八点的铃")
        self.assertEqual(ledger.alarms()[0]["status"], "missed")

    async def test_sleep_read_failure_still_rings(self):
        audio = FakeAudio()
        bridge, ledger = build(self.root, FakeSpeaker(audio, failures=3))
        now = time.time()
        ledger.add_alarm("abc12345", now - 1, now)
        await bridge.fire_alarm(ledger.due_alarms(now)[0])
        self.assertEqual(audio.played, ["wake.mp3"], "读不到睡眠状态不该让闹钟安静地消失")
        self.assertEqual(ledger.alarms()[0]["reason"], "audio_requested/sleep_unknown")

    async def test_spoken_alarm_is_handled_locally(self):
        speaker, workbench = FakeSpeaker(FakeAudio()), FakeWorkbench()
        ledger = Ledger(Path(self.root) / "turns.sqlite3")
        folder = Path(self.root) / "audio" / "alarm"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "wake.mp3").write_bytes(b"ID3" + b"0" * 64)
        config = {"deviceID": "d", "defaultTarget": "remote", "targets": {}, "alarmFile": "wake.mp3"}
        now = time.time()
        bridge = Bridge(config, speaker, workbench, ledger, started=now - 60, root=self.root)
        key = ledger.reserve({"time": int(now * 1000), "query": "小精灵，五分钟后用音乐叫我", "requestId": "r1"},
                             "d", "remote", now - 60, now)
        self.assertIsNotNone(key, "带唤醒词的句子要能进台账")
        await bridge.execute(key)
        self.assertEqual(workbench.calls, [], "到点叫醒不交给远端工作台，远端只会口头答应")
        alarms = ledger.alarms()
        self.assertEqual(len(alarms), 1, "要真的登记一条闹钟")
        self.assertEqual(alarms[0]["status"], "scheduled")
        self.assertAlmostEqual(alarms[0]["due"] - now, 300, delta=5)
        self.assertIn("用音乐叫你", ledger.get(key)["reply"])
        self.assertTrue(getattr(speaker, "said", []), "要有播报回执")

    async def test_stop_only_touches_a_ringing_alarm(self):
        class LoudSpeaker(FakeSpeaker):
            def __init__(self, audio):
                super().__init__(audio)
                self.stopped = 0

            async def stop_playback(self):
                self.stopped += 1

        speaker = LoudSpeaker(FakeAudio())
        bridge, ledger = build(self.root, speaker)
        now = time.time()
        stopped, reply = await bridge.stop_alarm()
        self.assertFalse(stopped, "没有闹钟在响就不能动播放器")
        self.assertIn("没有闹钟在响", reply)
        self.assertEqual(speaker.stopped, 0)

        ledger.add_alarm("abc12345", now - 5, now)
        ledger.set_alarm("abc12345", status="ringing", fired=now - 5)
        stopped, _ = await bridge.stop_alarm()
        self.assertTrue(stopped)
        self.assertEqual(speaker.stopped, 1)
        self.assertEqual((ledger.alarms()[0]["status"], ledger.alarms()[0]["reason"]), ("stopped", "user_stopped"))

    async def test_stop_cancels_the_pending_one_instead(self):
        speaker = FakeSpeaker(FakeAudio())
        bridge, ledger = build(self.root, speaker)
        now = time.time()
        ledger.add_alarm("abc12345", now + 600, now)
        stopped, reply = await bridge.stop_alarm()
        self.assertTrue(stopped)
        self.assertIn("取消了", reply)
        self.assertEqual(ledger.alarms()[0]["status"], "cancelled")

    async def test_interrupted_ring_is_marked_not_faked(self):
        ledger = Ledger(Path(self.root) / "turns.sqlite3")
        now = time.time()
        ledger.add_alarm("abc12345", now - 1, now)
        ledger.set_alarm("abc12345", status="ringing", fired=now)
        self.assertEqual(ledger.recover_alarms(), 1, "重启要把响铃中途的记录收干净")
        alarm = ledger.alarms()[0]
        self.assertEqual((alarm["status"], alarm["reason"]), ("failed", "interrupted"))
        self.assertEqual(ledger.recover_alarms(), 0, "已经收过的不再重复处理")

    async def test_cancel_only_hits_pending(self):
        audio = FakeAudio()
        bridge, ledger = build(self.root, FakeSpeaker(audio))
        now = time.time()
        ledger.add_alarm("abc12345", now + 3600, now)
        self.assertTrue(ledger.cancel_alarm("abc12345"))
        self.assertFalse(ledger.cancel_alarm("abc12345"), "已取消的不再重复取消")

    async def test_control_requires_loopback_token_and_bounded_time(self):
        bridge, ledger = build(self.root, FakeSpeaker(FakeAudio()))
        control = await Control(bridge, state=self.root).__aenter__()
        url = f"http://127.0.0.1:{control.port}/alarm"
        now = int(time.time())
        try:
            async with ClientSession() as session:
                async with session.post(url, json={"id": "abc12345", "due": now + 60}) as response:
                    self.assertEqual(response.status, 403, "没有 token 不登记")
                headers = {"Authorization": "Bearer " + control.token}
                async with session.post(url, json={"id": "abc12345", "due": now + 60}, headers=headers) as response:
                    self.assertEqual(response.status, 200)
                async with session.post(url, json={"id": "abc12345", "due": now + 60}, headers=headers) as response:
                    self.assertEqual(response.status, 409, "重复登记明确冲突")
                for bad in ({"id": "短", "due": now + 60}, {"id": "abc12345", "due": now + 40 * 86400},
                            {"id": "abc12345", "due": now - 600}, {"id": "abc12345", "due": True},
                            {"id": "abc12345", "due": now + 60, "text": "多说一句"}):
                    async with session.post(url, json=bad) as response:
                        self.assertIn(response.status, (400, 403), bad)
                async with session.get(url) as response:
                    self.assertEqual(response.status, 403)
                async with session.get(url, headers=headers) as response:
                    self.assertEqual(response.status, 200)
                    self.assertEqual(len((await response.json())["alarms"]), 1)
                async with session.post(url + "/cancel", json={"id": "abc12345"}, headers=headers) as response:
                    self.assertTrue((await response.json())["cancelled"])
        finally:
            await control.__aexit__()
        self.assertFalse((Path(self.root) / "control.json").exists(), "停服务即撤掉端口与token文件")


if __name__ == "__main__":
    unittest.main()
