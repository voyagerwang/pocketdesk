#!/usr/bin/env python3
"""本机离线声纹桥：注册机主声音 / 校验是不是机主。

[INPUT]: 本机回环 HTTP 的 raw float32 16kHz 单声道 PCM（无 wav 头），以及导出好的 speaker-encoder.onnx。
[OUTPUT]: JSON 相似度与判决；画像只把 L2 归一化后的 256 维 embedding 落在本机私有目录，绝不存音频、不写日志、不出网。
[POS]: 锁屏身份校验的进程边界——Swift 侧只管录音和按 match 放行，模型格式、切窗规则和阈值都留在 Python 侧，换模型不必改客户端。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md

接口（Swift 侧按这个写，别改形状）：
  GET    /health   -> {"ok": true, "enrolled": bool, "samples": int, "threshold": float}
  POST   /enroll   -> {"ok": true, "samples": int, "score": float?}   body: PCM，header: X-Voiceprint-Label
  POST   /verify   -> {"ok": true, "score": float, "match": bool, "threshold": float}
  DELETE /profile  -> {"ok": true, "samples": 0}

切窗算术与 scripts/export-voiceprint.py 里的 partial_wav_length() 是同一份契约：改一处必须改另一处，
否则 mel 帧网格和模型内部假设错位，分数会悄悄变差而不报错。
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import numpy as np

SAMPLE_RATE = 16000
HOP = 160
PARTIAL_FRAMES = 160      # 1.6s 一窗（resemblyzer partials_n_frames）
PARTIAL_STEP = 77         # round((16000 / 1.3) / 160)
RATE = 1.3
MIN_COVERAGE = 0.75
MIN_SECONDS = 1.0         # 短于此值的片段不接受，声纹统计上不可靠
MAX_SAMPLES = 12          # 画像只留最近 12 段：既够稳，又不会让旧声音永远压着新声音
MAX_SECONDS = 30.0        # 超出取前 30 秒
AUDIO_NORM_TARGET_DBFS = -30.0  # 与 resemblyzer audio_norm_target_dBFS 一致
MAX_BODY = 8 * 1024 * 1024
DEFAULT_PORT = 46391
# 默认阈值 0.78：实测（3 条注册 + 2s 片段，见交付说明）同人最差 0.86、异人质心均值 0.57，
# 留出 0.08 的余量给真实麦克风/距离/情绪波动——日常用宁可多放行几次，也不要机主自己被锁在外面。
DEFAULT_THRESHOLD = 0.78
EMBED_DIM = 256
PROFILE_VERSION = 1

STATE_DIR = Path(os.environ.get("POCKETDESK_VOICEPRINT_DIR")
                 or Path.home() / "Library/Application Support/VoiceDeck/voiceprint")
PROFILE_PATH = STATE_DIR / "profile.json"
MODEL_PATH = Path(os.environ.get("POCKETDESK_VOICEPRINT_MODEL")
                  or STATE_DIR / "speaker-encoder.onnx")


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def partial_wav_length(n_samples: int) -> int:
    """复刻 VoiceEncoder.compute_partial_slices 的窗数与 min_coverage 规则。

    与 scripts/export-voiceprint.py 的同名函数必须逐字一致。
    """
    samples_per_frame = HOP
    n_frames = int(math.ceil((n_samples + 1) / samples_per_frame))
    frame_step = int(round((SAMPLE_RATE / RATE) / samples_per_frame))
    steps = max(1, n_frames - PARTIAL_FRAMES + frame_step + 1)
    starts = list(range(0, steps, frame_step))
    span = PARTIAL_FRAMES * samples_per_frame
    coverage = (n_samples - starts[-1] * samples_per_frame) / span
    if coverage < MIN_COVERAGE and len(starts) > 1:
        starts = starts[:-1]
    return (starts[-1] + PARTIAL_FRAMES) * samples_per_frame


def pad_for_partials(wav: np.ndarray) -> np.ndarray:
    extra = partial_wav_length(len(wav)) - len(wav)
    return np.pad(wav, (0, extra)) if extra > 0 else wav


def normalize_gain(wav: np.ndarray) -> np.ndarray:
    """把 RMS 统一拉平到 -30 dBFS（resemblyzer 的 audio_norm_target_dBFS），上调下调都做。

    resemblyzer 的 preprocess_wav 只增不减；这里故意双向拉平——锁屏注册和校验的录音距离本来就不一样，
    实测同一句话音量 −12dB 时 cosine 从 0.94 掉到 0.86，拉平后同一句话不同音量得到完全相同的 embedding。
    """
    rms = float(np.sqrt(np.mean(wav.astype(np.float64) ** 2)))
    if not math.isfinite(rms) or rms <= 0.0:
        return wav
    change_db = AUDIO_NORM_TARGET_DBFS - 20.0 * math.log10(rms)
    return wav * np.float32(10.0 ** (change_db / 20.0))


def cosine(a: np.ndarray, b: np.ndarray) -> float:
    a = np.asarray(a, dtype=np.float64).ravel()
    b = np.asarray(b, dtype=np.float64).ravel()
    na, nb = np.linalg.norm(a), np.linalg.norm(b)
    if na == 0.0 or nb == 0.0:
        return 0.0
    return float(a @ b / (na * nb))


def centroid(embeddings: list[list[float]]) -> np.ndarray:
    """画像中心：归一化 embedding 的均值再归一化，和 resemblyzer 的 embed_speaker 同口径。"""
    matrix = np.asarray(embeddings, dtype=np.float64)
    mean = matrix.mean(axis=0)
    norm = np.linalg.norm(mean)
    return mean / norm if norm else mean


class VoiceprintEngine:
    """加载 ONNX 编码器并维护画像；所有磁盘写入都收敛在 profile.json 一处。"""

    def __init__(self, model_path: Path = MODEL_PATH, profile_path: Path = PROFILE_PATH,
                 threshold: float = DEFAULT_THRESHOLD):
        self.model_path = Path(model_path)
        self.profile_path = Path(profile_path)
        self.threshold = float(threshold)
        self._lock = threading.Lock()
        self._session = None
        self._load_error = ""
        self._profile = self._read_profile()
        self._load_model()

    # ---- 模型 ----
    def _load_model(self) -> None:
        if not self.model_path.exists():
            self._load_error = f"missing model: {self.model_path}"
            return
        try:
            import onnxruntime as ort

            options = ort.SessionOptions()
            options.intra_op_num_threads = 1
            options.inter_op_num_threads = 1
            options.log_severity_level = 3
            self._session = ort.InferenceSession(str(self.model_path), options,
                                                 providers=["CPUExecutionProvider"])
        except Exception as error:  # 模型坏了要让 /health 说清楚，而不是每次请求 500
            self._load_error = f"{type(error).__name__}: {error}"

    @property
    def ready(self) -> bool:
        return self._session is not None

    def embed(self, pcm: np.ndarray) -> np.ndarray:
        wav = np.asarray(pcm, dtype=np.float32)[: int(MAX_SECONDS * SAMPLE_RATE)]
        padded = pad_for_partials(normalize_gain(wav))
        outputs = self._session.run(["embed"], {"wav": padded[None, :].astype(np.float32)})
        return np.asarray(outputs[0][0], dtype=np.float32)

    # ---- 画像 ----
    def _read_profile(self) -> dict:
        empty = {"version": PROFILE_VERSION, "label": "", "created": "", "updated": "",
                 "embeddings": []}
        try:
            raw = json.loads(self.profile_path.read_text("utf-8"))
        except (OSError, ValueError):
            return empty
        embeddings = raw.get("embeddings")
        if not isinstance(embeddings, list):
            return empty
        cleaned = [vec for vec in embeddings
                   if isinstance(vec, list) and len(vec) == EMBED_DIM
                   and all(isinstance(x, (int, float)) and math.isfinite(x) for x in vec)]
        return {
            "version": PROFILE_VERSION,
            "label": str(raw.get("label") or "")[:200],
            "created": str(raw.get("created") or ""),
            "updated": str(raw.get("updated") or ""),
            "embeddings": cleaned,
        }

    def _write_profile(self) -> None:
        payload = dict(self._profile, version=PROFILE_VERSION, updated=now_iso())
        self.profile_path.parent.mkdir(parents=True, exist_ok=True)
        os.chmod(self.profile_path.parent, 0o700)
        temp = self.profile_path.with_suffix(".json.tmp")
        descriptor = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, separators=(",", ":"))
        os.replace(temp, self.profile_path)
        os.chmod(self.profile_path, 0o600)
        self._profile = payload

    @property
    def samples(self) -> int:
        return len(self._profile["embeddings"])

    @property
    def enrolled(self) -> bool:
        return self.samples > 0

    def enroll(self, embedding: np.ndarray, label: str) -> dict:
        with self._lock:
            previous = self._profile["embeddings"]
            score = cosine(embedding, centroid(previous)) if previous else None
            if not self._profile["created"]:
                self._profile["created"] = now_iso()
            if label:
                self._profile["label"] = label[:200]
            kept = (previous + [embedding.tolist()])[-MAX_SAMPLES:]
            self._profile["embeddings"] = kept
            self._write_profile()
            result = {"ok": True, "samples": self.samples}
            if score is not None:
                result["score"] = round(score, 4)
            return result

    def verify(self, embedding: np.ndarray) -> dict:
        with self._lock:
            score = cosine(embedding, centroid(self._profile["embeddings"]))
            return {"ok": True, "score": round(score, 4),
                    "match": bool(score >= self.threshold), "threshold": self.threshold}

    def reset(self) -> dict:
        with self._lock:
            self._profile = {"version": PROFILE_VERSION, "label": "", "created": "",
                             "updated": "", "embeddings": []}
            try:
                self.profile_path.unlink()
            except FileNotFoundError:
                pass
            return {"ok": True, "samples": 0}

    def health(self) -> dict:
        payload = {"ok": self.ready, "enrolled": self.enrolled, "samples": self.samples,
                   "threshold": self.threshold}
        if not self.ready:
            payload["error"] = self._load_error or "model not loaded"
        return payload


def decode_pcm(body: bytes) -> np.ndarray:
    """raw little-endian float32 单声道 PCM；非有限值、非 4 字节对齐都算坏请求。"""
    if not body or len(body) % 4 != 0:
        raise ValueError("body must be raw little-endian float32 PCM")
    pcm = np.frombuffer(body, dtype="<f4").astype(np.float32, copy=False)
    if not np.all(np.isfinite(pcm)):
        raise ValueError("pcm contains NaN or Inf")
    return pcm


def build_handler(engine: VoiceprintEngine):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args) -> None:  # 不落盘、不打日志，避免声音内容经由日志泄漏
            return

        def _send(self, status: int, payload: dict) -> None:
            data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def _body(self) -> bytes:
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                return b""
            if length <= 0 or length > MAX_BODY:
                return b""
            return self.rfile.read(length)

        def _pcm(self) -> np.ndarray:
            pcm = decode_pcm(self._body())
            seconds = len(pcm) / SAMPLE_RATE
            if seconds < MIN_SECONDS:
                raise ValueError(f"audio too short: {seconds:.2f}s < {MIN_SECONDS:.1f}s")
            return pcm

        def do_GET(self) -> None:
            if self.path.split("?")[0] != "/health":
                self._send(404, {"ok": False, "error": "not found"})
                return
            self._send(200 if engine.ready else 503, engine.health())

        def do_POST(self) -> None:
            route = self.path.split("?")[0]
            if route not in ("/enroll", "/verify"):
                self._send(404, {"ok": False, "error": "not found"})
                return
            if not engine.ready:
                self._send(503, {"ok": False, "error": engine.health().get("error", "")})
                return
            if route == "/verify" and not engine.enrolled:
                self._send(404, {"ok": False, "error": "no enrolled profile"})
                return
            try:
                pcm = self._pcm()
            except ValueError as error:
                self._send(400, {"ok": False, "error": str(error)})
                return
            try:
                embedding = engine.embed(pcm)
            except Exception as error:
                self._send(500, {"ok": False, "error": f"{type(error).__name__}: {error}"})
                return
            if route == "/enroll":
                self._send(200, engine.enroll(embedding, self._label()))
            else:
                self._send(200, engine.verify(embedding))

        def _label(self) -> str:
            """HTTP 头在 Python 里是按 latin-1 解出来的，这里还原成客户端真正发送的 UTF-8 文本。"""
            raw = self.headers.get("X-Voiceprint-Label") or ""
            try:
                return raw.encode("latin-1").decode("utf-8")
            except (UnicodeEncodeError, UnicodeDecodeError):
                return raw

        def do_DELETE(self) -> None:
            if self.path.split("?")[0] != "/profile":
                self._send(404, {"ok": False, "error": "not found"})
                return
            self._send(200, engine.reset())

    return Handler


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main() -> int:
    parser = argparse.ArgumentParser(description="PocketDesk 本机离线声纹桥")
    parser.add_argument("--serve", action="store_true", help="起本机回环 HTTP 服务")
    parser.add_argument("--port", type=int,
                        default=int(os.environ.get("POCKETDESK_VOICEPRINT_PORT", DEFAULT_PORT)))
    parser.add_argument("--threshold", type=float,
                        default=float(os.environ.get("POCKETDESK_VOICEPRINT_THRESHOLD",
                                                     DEFAULT_THRESHOLD)))
    parser.add_argument("--model", default=str(MODEL_PATH))
    parser.add_argument("--profile", default=str(PROFILE_PATH))
    args = parser.parse_args()

    engine = VoiceprintEngine(model_path=Path(args.model), profile_path=Path(args.profile),
                              threshold=args.threshold)
    if not args.serve:
        print(json.dumps(engine.health(), ensure_ascii=False))
        return 0 if engine.ready else 1
    if not engine.ready:
        print(json.dumps(engine.health(), ensure_ascii=False), file=sys.stderr)
        return 1

    httpd = Server(("127.0.0.1", args.port), build_handler(engine))
    print(json.dumps({"ok": True, "port": args.port, "pid": os.getpid()}, ensure_ascii=False),
          flush=True)
    try:
        httpd.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
