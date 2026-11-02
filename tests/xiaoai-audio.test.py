"""
[INPUT]: 临时音频、真实回环HTTP、aiohttp客户端及生成/播放替身。
[OUTPUT]: 验证临时URL权限边界、过期、范围读取、HEAD不冒充下载、实际GET才给回执，以及唤醒音乐只读播放与目录边界。
[POS]: OH2备用声音出口的传输验收；不调用真实音箱、系统合成器或工作台。
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
from audio import AudioOutput, audio_range


class AudioTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.output = await AudioOutput(self.temp.name, None, host="127.0.0.1").__aenter__()
        self.url = f"http://127.0.0.1:{self.output.port}"
        self.path = Path(self.temp.name) / "test.mp3"
        self.path.write_bytes(b"0123456789")
        self.event = asyncio.Event()
        self.output.clips["test-token"] = {"folder": self.temp.name, "path": self.path,
                         "expires": time.time() + 60, "requested": self.event}
        self.session = ClientSession()

    async def asyncTearDown(self):
        await self.session.close()
        await self.output.__aexit__()
        self.temp.cleanup()

    async def test_only_random_known_clip_is_served(self):
        for path in ("/", "/audio/auth.json", "/audio/unknown.mp3", "/audio/../config.json"):
            async with self.session.get(self.url + path) as response:
                self.assertEqual(response.status, 404)
        self.assertFalse(self.event.is_set())

    async def test_head_is_not_playback_proof(self):
        async with self.session.head(self.url + "/audio/test-token.mp3") as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(response.headers["Content-Type"], "audio/mpeg")
        self.assertFalse(self.event.is_set())

    async def test_range_download_and_no_cache(self):
        async with self.session.get(self.url + "/audio/test-token.mp3", headers={"Range": "bytes=2-5"}) as response:
            self.assertEqual(response.status, 206)
            self.assertEqual(await response.read(), b"2345")
            self.assertEqual(response.headers["Cache-Control"], "no-store")
        self.assertTrue(self.event.is_set())

    async def test_expired_clip_is_unavailable(self):
        self.output.clips["test-token"]["expires"] = time.time() - 1
        async with self.session.get(self.url + "/audio/test-token.mp3") as response:
            self.assertEqual(response.status, 404)

    async def test_invalid_range_never_counts_as_download(self):
        async with self.session.get(self.url + "/audio/test-token.mp3", headers={"Range": "bytes=99-100"}) as response:
            self.assertEqual(response.status, 416)
        self.assertFalse(self.event.is_set())

    async def test_audio_receipt_requires_get_not_cloud_acceptance(self):
        async def render(text, folder):
            p = Path(folder) / "voice.mp3"
            p.write_bytes(b"fake-mp3")
            return p
        async def play(url):
            async with self.session.get(url) as response:
                self.assertEqual(await response.read(), b"fake-mp3")
            return True
        self.output.render = render
        self.output.play = play
        self.assertEqual(await self.output.say("测试"), "audio_requested")

    async def test_alarm_music_plays_from_allowed_dir_and_is_not_deleted(self):
        alarm_dir = Path(self.temp.name) / "alarm"
        alarm_dir.mkdir()
        music = alarm_dir / "wake.mp3"
        music.write_bytes(b"ID3" + b"0" * 300)
        async def play(url):
            async with self.session.get(url) as response:
                self.assertEqual(await response.read(), b"ID3" + b"0" * 300)
            return True
        self.output.play = play
        self.assertEqual(await self.output.play_alarm(music), "audio_requested")
        self.assertTrue(music.is_file(), "用户自己的唤醒音乐不能被删除或搬走")

    async def test_alarm_music_outside_dir_is_refused(self):
        async def play(url):
            self.fail("目录外文件不应发起播放")
        self.output.play = play
        for path in (self.path, Path(self.temp.name) / "alarm/../test.mp3"):
            with self.assertRaises(RuntimeError):
                await self.output.play_alarm(path)

    async def test_alarm_music_size_limit(self):
        alarm_dir = Path(self.temp.name) / "alarm"
        alarm_dir.mkdir()
        music = alarm_dir / "huge.mp3"
        music.write_bytes(b"0" * (8 * 1024 * 1024 + 1))
        with self.assertRaises(RuntimeError):
            await self.output.play_alarm(music)

    def test_range_boundaries(self):
        self.assertEqual(audio_range("bytes=-3", 10), (7, 9))
        self.assertEqual(audio_range("bytes=0-999", 10), (0, 9))
        for value in ("bytes=", "bytes=-0", "bytes=5-2", "bytes=1-2,4-5"):
            with self.assertRaises(ValueError):
                audio_range(value, 10)


if __name__ == "__main__":
    unittest.main()
