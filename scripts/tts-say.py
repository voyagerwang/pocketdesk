#!/usr/bin/env python3
"""小E 的神经音色合成桥。

[INPUT]: 本机回环 HTTP 请求（短句、音色名、语速/音高微调）与随 App 打包的独立 Python 环境里的 edge-tts。
[OUTPUT]: audio/mpeg 字节流；同一句同参数只向云端要一次，之后回放磁盘缓存。
[POS]: 发声层的进程边界——Swift 侧只管把音频播出去，服务端协议变化留给 pip 升级，不把云端私有算法搬进客户端。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

CACHE = Path.home() / "Library/Caches/PocketDesk/tts"
VOICE_RE = re.compile(r"^[A-Za-z]{2}-[A-Za-z]{2,4}-[A-Za-z0-9]+Neural$")
RATE_RE = re.compile(r"^[+-]\d{1,3}%$")
PITCH_RE = re.compile(r"^[+-]\d{1,3}Hz$")
MAX_TEXT = 200
LAST_OK = {"voice": "", "text": ""}

# 控制台里给人看的名字：只说声音的性格，不暴露内部代号。
LABELS = {
    "zh-CN-XiaoxiaoNeural": ("温柔姐姐", "温暖、稳，适合日常对话", 0),
    "zh-CN-XiaoyiNeural": ("活泼少女", "轻快、动漫感", 1),
    "zh-CN-liaoning-XiaobeiNeural": ("东北小北", "俏皮、有性格", 2),
    "zh-CN-shaanxi-XiaoniNeural": ("陕西小妮", "利落、方言味", 3),
    "zh-TW-HsiaoChenNeural": ("台湾小臻", "软糯、轻", 4),
    "zh-HK-HiuMaanNeural": ("粤语小曼", "粤语女声", 5),
}
FALLBACK_VOICES = [
    {"id": voice_id, "name": name, "hint": hint}
    for voice_id, (name, hint, _) in sorted(LABELS.items(), key=lambda item: item[1][2])[:3]
]


def cache_path(text: str, voice: str, rate: str, pitch: str) -> Path:
    digest = hashlib.sha256(f"{voice}|{rate}|{pitch}|{text}".encode("utf-8")).hexdigest()[:32]
    return CACHE / f"{digest}.mp3"


def synth(text: str, voice: str, rate: str, pitch: str) -> bytes:
    import edge_tts

    async def run() -> bytes:
        communicate = edge_tts.Communicate(text, voice, rate=rate, pitch=pitch)
        chunks = bytearray()
        async for chunk in communicate.stream():
            if chunk["type"] == "audio":
                chunks += chunk["data"]
        return bytes(chunks)

    return asyncio.run(run())


def speak(text: str, voice: str, rate: str, pitch: str, use_cache: bool = True) -> bytes:
    text = " ".join(text.split())[:MAX_TEXT]
    if not text:
        return b""
    path = cache_path(text, voice, rate, pitch)
    if use_cache and path.exists() and path.stat().st_size > 0:
        return path.read_bytes()
    audio = synth(text, voice, rate, pitch)
    if audio:
        CACHE.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".part")
        tmp.write_bytes(audio)
        tmp.replace(path)
        LAST_OK.update(voice=voice, text=text)
    return audio


def voices() -> list:
    import edge_tts

    cached = CACHE / "voices.json"
    if cached.exists() and (time.time() - cached.stat().st_mtime) < 86400:
        try:
            return json.loads(cached.read_text())
        except ValueError:
            pass

    async def fetch() -> list:
        listed = await edge_tts.list_voices()
        picked = []
        for voice in listed:
            short = voice.get("ShortName", "")
            if not short.startswith("zh-") or not short.endswith("Neural"):
                continue
            name, hint, order = LABELS.get(short, (short.split("-")[-1].replace("Neural", ""), voice.get("Gender", ""), 99))
            picked.append({"id": short, "name": name, "hint": hint, "order": order, "gender": voice.get("Gender", "")})
        picked.sort(key=lambda item: (item.pop("order"), item["id"]))
        return picked

    try:
        result = asyncio.run(fetch())
    except Exception:
        return FALLBACK_VOICES
    if result:
        CACHE.mkdir(parents=True, exist_ok=True)
        cached.write_text(json.dumps(result, ensure_ascii=False))
        return result
    return FALLBACK_VOICES


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "PocketDeskTTS/1"

    def log_message(self, *args):  # 不往 stdout 写访问日志，保持安静
        pass

    def log_request_quiet(self, note: str) -> None:
        path = os.environ.get("POCKETDESK_TTS_ACCESS_LOG")
        if not path:
            return
        try:
            with open(path, "a", encoding="utf-8") as handle:
                handle.write(f"{time.time():.0f} {note} {self.path[:200]}\n")
        except OSError:
            pass

    def _send(self, code: int, body: bytes, mime: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        self.log_request_quiet("GET")
        parsed = urlparse(self.path)
        query = {key: value[0] for key, value in parse_qs(parsed.query).items()}
        if parsed.path == "/voices":
            self._send(200, json.dumps(voices(), ensure_ascii=False).encode(), "application/json")
            return
        if parsed.path == "/health":
            self._send(200, json.dumps({"ok": True, "cached": len(list(CACHE.glob("*.mp3"))) if CACHE.exists() else 0}).encode(), "application/json")
            return
        if parsed.path != "/say":
            self._send(404, b"{}", "application/json")
            return
        text = query.get("text", "")
        voice = query.get("voice", "zh-CN-XiaoxiaoNeural")
        # 查询串里未转义的「+」会被解成空格，先抹干净再交给 edge-tts，否则语速档位直接报错。
        rate = query.get("rate", "+4%").strip() or "+4%"
        pitch = query.get("pitch", "+0Hz").strip() or "+0Hz"
        if rate[0].isdigit():
            rate = "+" + rate
        if pitch[0].isdigit():
            pitch = "+" + pitch
        if not RATE_RE.match(rate) or not PITCH_RE.match(pitch):
            self._send(400, json.dumps({"error": "语速或音高参数无效"}).encode(), "application/json")
            return
        if not VOICE_RE.match(voice):
            self._send(400, json.dumps({"error": "音色名无效"}).encode(), "application/json")
            return
        try:
            audio = speak(text, voice, rate, pitch)
        except Exception as error:  # 网络或服务端问题一律回 502，Swift 侧据此退化到系统音色
            self._send(502, json.dumps({"error": str(error)[:300]}).encode(), "application/json")
            return
        if not audio:
            self._send(504, json.dumps({"error": "没有音频"}).encode(), "application/json")
            return
        self._send(200, audio, "audio/mpeg")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--port", type=int, default=46390)
    parser.add_argument("--text", default="")
    parser.add_argument("--voice", default="zh-CN-XiaoxiaoNeural")
    parser.add_argument("--rate", default="+4%")
    parser.add_argument("--pitch", default="+0Hz")
    parser.add_argument("--out", default="")
    args = parser.parse_args()

    if args.serve:
        server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
        print(f"tts bridge on 127.0.0.1:{args.port}", flush=True)
        server.serve_forever()
        return 0

    if not args.text:
        parser.error("需要 --text 或 --serve")
    audio = speak(args.text, args.voice, args.rate, args.pitch)
    if args.out:
        Path(args.out).write_bytes(audio)
        print(f"{args.out} {len(audio)}")
    else:
        sys.stdout.buffer.write(audio)
    return 0 if audio else 1


if __name__ == "__main__":
    raise SystemExit(main())
