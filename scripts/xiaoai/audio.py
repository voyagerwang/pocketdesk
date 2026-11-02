"""
[INPUT]: macOS本地Tingting语音、固定ffmpeg程序、绑定OH2的音频播放回调，以及用户显式安装的唤醒音乐文件。
[OUTPUT]: 临时MP3与随机单文件URL；只有音箱实际GET音频后才确认已请求，不把云端接受等同出声。
[POS]: 音箱声音出口；不提供目录或任意路径接口，音频三分钟过期，临时片段停止即销毁、用户音乐只读不删。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
import asyncio
import ipaddress
from pathlib import Path
import re
import secrets
import shutil
import tempfile
import time

from aiohttp import web

MAX_AUDIO_BYTES = 2 * 1024 * 1024
ALARM_MAX_BYTES = 8 * 1024 * 1024
CLIP_TTL = 180


def audio_range(header, size):
    if not header:
        return 0, size - 1
    match = re.fullmatch(r"bytes=(\d*)-(\d*)", header)
    if not match or not any(match.groups()):
        raise ValueError("无效音频范围")
    first, last = match.groups()
    start = int(first) if first else max(0, size - int(last))
    end = min(size - 1, int(last)) if first and last else size - 1
    if start > end or start >= size:
        raise ValueError("无效音频范围")
    return start, end


class AudioOutput:
    def __init__(self, directory, play, host=None):
        self.directory, self.play, self.host = Path(directory), play, host
        self.clips = {}
        self.runner = None

    async def __aenter__(self):
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.directory.chmod(0o700)
        app = web.Application(client_max_size=1024)
        app.router.add_get("/audio/{token}.mp3", self.serve)
        self.runner = web.AppRunner(app, access_log=None)
        await self.runner.setup()
        server = web.TCPSite(self.runner, "0.0.0.0", 0)
        await server.start()
        self.port = self.runner.addresses[0][1]
        return self

    async def __aexit__(self, *_):
        if self.runner:
            await self.runner.cleanup()
        for token in list(self.clips):
            self.drop(token)

    async def run_tool(self, arguments, body=None):
        process = await asyncio.create_subprocess_exec(*arguments, stdin=asyncio.subprocess.PIPE,
                    stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE)
        try:
            await asyncio.wait_for(process.communicate(body), timeout=30)
            if process.returncode != 0:
                raise RuntimeError("本地语音生成失败")
        finally:
            if process.returncode is None:
                process.kill()
                await process.wait()

    async def lan_host(self):
        if self.host:
            return self.host
        for interface in ("en0", "en1"):
            process = await asyncio.create_subprocess_exec("/usr/sbin/ipconfig", "getifaddr", interface,
                         stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
            data, _ = await process.communicate()
            try:
                address = ipaddress.ip_address(data.decode().strip())
                if address.version == 4 and address.is_private and not address.is_loopback and not address.is_link_local:
                    return str(address)
            except ValueError:
                pass
        raise RuntimeError("没有可供音箱读取音频的局域网地址")

    async def render(self, text, folder):
        aiff, mp3 = Path(folder) / "voice.aiff", Path(folder) / "voice.mp3"
        ffmpeg = Path.home() / ".local/bin/ffmpeg"
        if not ffmpeg.is_file():
            ffmpeg = Path("/opt/homebrew/bin/ffmpeg")
        await self.run_tool(["/usr/bin/say", "-v", "Tingting", "-r", "190", "-o", str(aiff)], text.encode())
        await self.run_tool([str(ffmpeg), "-hide_banner", "-loglevel", "error", "-y", "-i", str(aiff),
                             "-codec:a", "libmp3lame", "-q:a", "4", str(mp3)])
        aiff.unlink(missing_ok=True)
        if not 0 < mp3.stat().st_size <= MAX_AUDIO_BYTES:
            raise RuntimeError("生成音频大小不符合限制")
        return mp3

    def drop(self, token):
        clip = self.clips.pop(token, None)
        # 只有本次生成的临时目录才删；用户自己装的唤醒音乐不碰。
        if clip and clip.get("folder"):
            shutil.rmtree(clip["folder"], ignore_errors=True)

    def expire(self):
        for token, clip in list(self.clips.items()):
            if clip["expires"] <= time.time():
                self.drop(token)

    async def publish(self, path, folder=None):
        """发布一个可播放片段并等音箱真的来取；只认实际GET，不把云端接受当出声。"""
        self.expire()
        if len(self.clips) >= 16:
            raise RuntimeError("音频队列已满")
        token = secrets.token_urlsafe(24)
        clip = {"folder": folder, "path": Path(path), "expires": time.time() + CLIP_TTL,
                "requested": asyncio.Event()}
        self.clips[token] = clip
        url = f"http://{await self.lan_host()}:{self.port}/audio/{token}.mp3"
        if not await self.play(url):
            raise RuntimeError("音箱未接受音频播放")
        await asyncio.wait_for(clip["requested"].wait(), timeout=15)
        return "audio_requested"

    async def say(self, text):
        folder = tempfile.mkdtemp(prefix="reply-", dir=self.directory)
        try:
            return await self.publish(await self.render(text, folder), folder)
        except BaseException:
            # 已发布的音频保留到TTL，防止迟到请求读到半文件；业务请求绝不重发。
            if not any(c.get("folder") == folder for c in self.clips.values()):
                shutil.rmtree(folder, ignore_errors=True)
            raise

    async def play_alarm(self, path):
        """到点播一段本地唤醒音乐；文件只读，不复制、不删除、不接受任意路径。"""
        path = Path(path)
        if path.is_symlink() or not path.is_file() or path.resolve().parent != self.alarm_dir():
            raise RuntimeError("唤醒音乐不在允许目录内")
        size = path.stat().st_size
        if not 0 < size <= ALARM_MAX_BYTES:
            raise RuntimeError("唤醒音乐超出大小限制")
        return await self.publish(path)

    def alarm_dir(self):
        return (self.directory / "alarm").resolve()

    async def serve(self, request):
        self.expire()
        clip = self.clips.get(request.match_info["token"])
        if not clip:
            raise web.HTTPNotFound()
        data = clip["path"].read_bytes()
        try:
            start, end = audio_range(request.headers.get("Range"), len(data))
        except ValueError:
            raise web.HTTPRequestRangeNotSatisfiable()
        headers = {"Cache-Control": "no-store", "Accept-Ranges": "bytes"}
        partial = "Range" in request.headers
        if partial:
            headers["Content-Range"] = f"bytes {start}-{end}/{len(data)}"
        if request.method == "GET":
            clip["requested"].set()
        return web.Response(status=206 if partial else 200, body=data[start:end + 1],
                            content_type="audio/mpeg", headers=headers)
