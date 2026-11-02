#!/usr/bin/env python3
"""把 resemblyzer 的 GE2E 声纹编码器导出成一张 ONNX 图。

[INPUT]: 已装 torch + librosa + onnx 的构建虚拟环境，以及 resemblyzer 包里自带的 pretrained.pt 权重。
[OUTPUT]: speaker-encoder.onnx —— 输入 float32 波形 (1, n_samples)，输出 L2 归一化后的 256 维 embedding；
          mel 计算、1.6s 切窗、均值、归一化全部烘焙进图里，运行时只要 numpy + onnxruntime。
[POS]: 构建期一次性工具，不是运行时依赖；App 不必为声纹识别装 torch（省下 ~2GB 的 venv 和几百 MB 常驻）。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md

与 resemblyzer 的逐项对应（原样搬运，不自己发明参数）：
  wav_to_mel_spectrogram: librosa.feature.melspectrogram(sr=16000, n_fft=400, hop=160, n_mels=40)
    即 resemblyzer hparams 的 mel_window_length=25ms / mel_window_step=10ms；
    fmin=0、fmax=8000、htk=False、norm=slaney、center=True + pad_mode="constant"、
    hann 周期窗、功率谱、**没有 log**（resemblyzer 这个 mel 本来就是线性的）。
    图里用"定长卷积做分帧+加窗 + DFT 矩阵"等价替换 librosa，避开 torch.stft 复数导出限制。
  embed_utterance(rate=1.3, min_coverage=0.75): 每窗 160 帧（1.6s），步长 77 帧（固定常数），
    尾部不足一窗用零补齐（补齐由调用方按 partial_wav_length() 先做，与 compute_partial_slices 同算术），
    窗数 = (T - 160) // 77 + 1 与 resemblyzer 落定后的切片数完全一致。

用法：
  /path/to/build-venv/bin/python scripts/export-voiceprint.py [--out PATH] [--verify WAV ...]
不带 --out 时默认写到 ~/Library/Application Support/VoiceDeck/voiceprint/speaker-encoder.onnx。
导出后用 --verify 传几个 wav，会打印 ONNX 与 resemblyzer 原版 embedding 的 cosine（应 ≥ 0.99）。
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import torch
from torch import nn

SAMPLE_RATE = 16000
N_FFT = 400           # mel_window_length 25ms
HOP = 160             # mel_window_step 10ms
N_MELS = 40
N_BINS = N_FFT // 2 + 1
PARTIAL_FRAMES = 160  # partials_n_frames，1.6s 一窗
PARTIAL_STEP = 77     # round((16000 / 1.3) / 160)
RATE = 1.3
MIN_COVERAGE = 0.75


def dft_basis() -> torch.Tensor:
    """把 hann 窗 + 实/虚部 DFT 基折成一个卷积核，形状 (2 * N_BINS, 1, N_FFT)。"""
    window = torch.hann_window(N_FFT, periodic=True).numpy()
    n = np.arange(N_FFT)
    k = np.arange(N_BINS)
    angle = 2.0 * np.pi * np.outer(k, n) / N_FFT
    cos = (np.cos(angle) * window).astype(np.float32)
    sin = (np.sin(angle) * window).astype(np.float32)
    return torch.from_numpy(np.concatenate([cos, sin], axis=0)).unsqueeze(1)


def mel_filterbank() -> torch.Tensor:
    import librosa

    filters = librosa.filters.mel(sr=SAMPLE_RATE, n_fft=N_FFT, n_mels=N_MELS,
                                  fmin=0.0, fmax=SAMPLE_RATE / 2, htk=False, norm="slaney")
    return torch.from_numpy(np.asarray(filters, dtype=np.float32))


class SpeakerGraph(nn.Module):
    """波形 (1, n) -> 语句级 embedding (1, 256)，等价于 VoiceEncoder.embed_utterance。"""

    def __init__(self, encoder: nn.Module):
        super().__init__()
        self.encoder = encoder                      # 只用它的 LSTM + linear，见 forward
        self.register_buffer("dft", dft_basis())
        self.register_buffer("melfb", mel_filterbank())

    def mel(self, wav: torch.Tensor) -> torch.Tensor:
        # center=True + pad_mode="constant"：两端各补 N_FFT//2 个 0，与 librosa 默认一致。
        padded = torch.nn.functional.pad(wav.unsqueeze(1), (N_FFT // 2, N_FFT // 2))
        spec = torch.nn.functional.conv1d(padded, self.dft, stride=HOP)   # (1, 402, T)
        spec = spec.transpose(1, 2)                                      # (1, T, 402)
        real, imag = spec[..., :N_BINS], spec[..., N_BINS:]
        power = real * real + imag * imag                                # (1, T, 201)
        return (power @ self.melfb.t()).squeeze(0)                       # (T, 40)

    def forward(self, wav: torch.Tensor) -> torch.Tensor:
        mel = self.mel(wav)
        n_frames = mel.shape[0]
        n_partials = (n_frames - PARTIAL_FRAMES) // PARTIAL_STEP + 1
        offsets = torch.arange(n_partials) * PARTIAL_STEP
        index = offsets.view(n_partials, 1) + torch.arange(PARTIAL_FRAMES).view(1, PARTIAL_FRAMES)
        frames = mel.index_select(0, index.reshape(-1))
        frames = frames.reshape(n_partials, PARTIAL_FRAMES, N_MELS)        # (B, 160, 40)

        _, (hidden, _) = self.encoder.lstm(frames)
        raw = self.encoder.relu(self.encoder.linear(hidden[-1]))
        embeds = raw / torch.norm(raw, dim=1, keepdim=True)               # 逐窗 L2 归一化
        pooled = embeds.mean(dim=0, keepdim=True)
        return pooled / torch.norm(pooled, dim=1, keepdim=True)


def partial_wav_length(n_samples: int) -> int:
    """复刻 VoiceEncoder.compute_partial_slices 的窗数与 min_coverage 规则，返回补齐后长度。

    voiceprint.py 运行时用的是同一套算术，两边必须一致；不一致切窗就会错位。
    """
    samples_per_frame = HOP
    n_frames = int(np.ceil((n_samples + 1) / samples_per_frame))
    frame_step = int(np.round((SAMPLE_RATE / RATE) / samples_per_frame))
    steps = max(1, n_frames - PARTIAL_FRAMES + frame_step + 1)
    starts = list(range(0, steps, frame_step))
    last_start = starts[-1]
    span = PARTIAL_FRAMES * samples_per_frame
    coverage = (n_samples - last_start * samples_per_frame) / span
    if coverage < MIN_COVERAGE and len(starts) > 1:
        starts = starts[:-1]
    return (starts[-1] + PARTIAL_FRAMES) * samples_per_frame


def pad_for_partials(wav: np.ndarray) -> np.ndarray:
    """按 compute_partial_slices 的需求补零。最后整窗被 min_coverage 丢掉时长于所需，不裁。"""
    wav = np.asarray(wav, dtype=np.float32)
    extra = partial_wav_length(len(wav)) - len(wav)
    return np.pad(wav, (0, extra)) if extra > 0 else wav


def reference_embedding(encoder: nn.Module, wav: np.ndarray) -> np.ndarray:
    """resemblyzer 原版路径：同样的补齐规则 + librosa mel + 逐窗前向 + 均值 + L2。"""
    with torch.no_grad():
        return encoder.embed_utterance(pad_for_partials(wav)).astype(np.float32)


def cosine(a: np.ndarray, b: np.ndarray) -> float:
    a = np.asarray(a, dtype=np.float64).ravel()
    b = np.asarray(b, dtype=np.float64).ravel()
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b)))


def load_wav(path: str) -> np.ndarray:
    import librosa

    wav, _ = librosa.load(path, sr=SAMPLE_RATE, mono=True)
    return np.asarray(wav, dtype=np.float32)


def main() -> int:
    parser = argparse.ArgumentParser(description="导出 PocketDesk 声纹编码器 ONNX")
    parser.add_argument("--out", default=None)
    parser.add_argument("--verify", nargs="*", default=None,
                        help="这些 wav 上比对 ONNX 与 resemblyzer 原版 embedding 的 cosine")
    parser.add_argument("--opset", type=int, default=17)
    args = parser.parse_args()

    from resemblyzer import VoiceEncoder
    import onnxruntime as ort

    out_path = Path(args.out) if args.out else (
        Path.home() / "Library/Application Support/VoiceDeck/voiceprint/speaker-encoder.onnx")
    out_path.parent.mkdir(parents=True, exist_ok=True)

    encoder = VoiceEncoder(device="cpu", verbose=False).eval()
    for parameter in encoder.parameters():
        parameter.requires_grad_(False)
    model = SpeakerGraph(encoder).eval()

    # 只给 tracer 一个具体长度（2s），真实长度由 dynamic_axes 放开。
    torch.onnx.export(
        model, (torch.zeros(1, SAMPLE_RATE * 2, dtype=torch.float32),), str(out_path),
        input_names=["wav"], output_names=["embed"],
        dynamic_axes={"wav": {1: "n_samples"}, "embed": {0: "batch"}},
        opset_version=args.opset, do_constant_folding=True,
    )
    print(f"已导出 {out_path} ({out_path.stat().st_size / 1024 / 1024:.1f} MB)")

    if not args.verify:
        return 0

    session = ort.InferenceSession(str(out_path), providers=["CPUExecutionProvider"])
    worst = 1.0
    for path in args.verify:
        wav = load_wav(path)
        ref = reference_embedding(encoder, wav)
        got = session.run(["embed"], {"wav": pad_for_partials(wav)[None, :]})[0][0]
        score = cosine(ref, got)
        worst = min(worst, score)
        print(f"  {Path(path).name:24s} {len(wav) / SAMPLE_RATE:5.2f}s  cos(ref, onnx) = {score:.6f}")
    print(f"最低一致度 {worst:.6f}")
    return 0 if worst >= 0.99 else 1


if __name__ == "__main__":
    sys.exit(main())
