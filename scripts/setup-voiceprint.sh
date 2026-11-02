#!/bin/zsh
# [INPUT]: 系统 python3、PyPI 可达的网络、scripts/export-voiceprint.py 与（仅首次导出时）一次性 torch 构建环境。
# [OUTPUT]: ~/Library/Application Support/VoiceDeck/voiceprint 下的运行环境（numpy + onnxruntime）与 speaker-encoder.onnx，目录 0700、模型 0600。
# [POS]: 声纹桥的一次性安装入口；可重复执行，已有环境与模型不重建，不碰 App 安装、不启动服务。
# [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$HOME/Library/Application Support/VoiceDeck/voiceprint"
VENV="$STATE/venv"
BUILD_VENV="$STATE/build-venv"
MODEL="$STATE/speaker-encoder.onnx"

umask 077
mkdir -p "$STATE"

# 运行环境只要 numpy + onnxruntime：模型把 mel、切窗、归一化全烘焙进图里，不需要 torch 常驻。
if [[ ! -x "$VENV/bin/python" ]]; then
  echo "创建声纹运行环境 ${VENV}…"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" -q install --upgrade pip >/dev/null
  "$VENV/bin/pip" -q install onnxruntime numpy
else
  echo "运行环境已存在，跳过。"
fi
"$VENV/bin/python" -c "import numpy, onnxruntime" || { echo "运行环境不可用，请删除 ${VENV} 后重试" >&2; exit 1; }

# 模型只在这里生成一次；重装 App 不会带走它（它不在 App 包里）。
if [[ ! -s "$MODEL" ]]; then
  echo "导出 speaker-encoder.onnx（需要 torch + librosa + resemblyzer，仅这一次）…"
  if [[ ! -x "$BUILD_VENV/bin/python" ]]; then
    python3 -m venv "$BUILD_VENV"
    "$BUILD_VENV/bin/pip" -q install --upgrade pip >/dev/null
    "$BUILD_VENV/bin/pip" -q install torch librosa resemblyzer onnx
  fi
  "$BUILD_VENV/bin/python" "$ROOT_DIR/scripts/export-voiceprint.py" --out "$MODEL"
else
  echo "模型已存在：$MODEL"
fi

[[ -s "$MODEL" ]] || { echo "没有生成模型，声纹不可用" >&2; exit 1; }
chmod 600 "$MODEL" 2>/dev/null || true
chmod 700 "$STATE" 2>/dev/null || true

echo "声纹环境就绪：$STATE"
echo "启动方式由 App 负责（本机回环 46391）。想手动自检："
echo "  \"$VENV/bin/python\" \"$ROOT_DIR/scripts/voiceprint.py\" --serve --port 46391 &"
echo "  curl -s http://127.0.0.1:46391/health"
