#!/bin/zsh
# [INPUT]: 本机 uv/Python 3.12、PyPI 的固定 mijiaAPI 5.0.0 与 mijia-bridge.py。
# [OUTPUT]: 安装用户独立 Python 环境并显式扫码登录；--no-login 只准备依赖，取消时终止并回收当前子进程。
# [POS]: 米家可选依赖的安装入口，负责 uv/登录子进程生命周期，不把上游 SDK 或账号凭证打入 PocketDesk App。
# [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
set -euo pipefail
umask 077
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MIJIA_DIR="$HOME/Library/Application Support/VoiceDeck/mijia"
MIJIA_UV="${POCKETDESK_UV_PATH:-$HOME/.local/bin/uv}"
if [[ ! -x "$MIJIA_UV" ]]; then MIJIA_UV="$(command -v uv || true)"; fi
if [[ ! -x "$MIJIA_UV" ]]; then
  print -u2 '未找到 uv，请先安装 uv 后重新运行。'
  exit 1
fi
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != '--no-login' ) ]]; then
  print -u2 '用法：scripts/setup-mijia.sh [--no-login]'
  exit 1
fi

# ---- 子进程归属：取消安装必须等 uv 退出，避免下次连接与旧安装并行 ----
MIJIA_CHILD_PID=""
cancel_mijia_setup() {
  trap '' TERM INT HUP
  if [[ -n "$MIJIA_CHILD_PID" ]]; then
    kill -TERM "$MIJIA_CHILD_PID" 2>/dev/null || true
    sleep 0.2
    kill -KILL "$MIJIA_CHILD_PID" 2>/dev/null || true
    wait "$MIJIA_CHILD_PID" 2>/dev/null || true
    MIJIA_CHILD_PID=""
  fi
  exit 130
}
trap cancel_mijia_setup TERM INT HUP
run_mijia_child() {
  local mijia_child_status=0
  "$@" &
  MIJIA_CHILD_PID=$!
  wait "$MIJIA_CHILD_PID" || mijia_child_status=$?
  MIJIA_CHILD_PID=""
  return "$mijia_child_status"
}

mkdir -p "$MIJIA_DIR"
chmod 700 "$MIJIA_DIR"
if [[ ! -x "$MIJIA_DIR/venv/bin/python" ]]; then
  run_mijia_child "$MIJIA_UV" venv --python 3.12 "$MIJIA_DIR/venv"
fi
run_mijia_child "$MIJIA_UV" pip install --python "$MIJIA_DIR/venv/bin/python" 'mijiaAPI==5.0.0'
if [[ "${1:-}" != '--no-login' ]]; then
  run_mijia_child "$MIJIA_DIR/venv/bin/python" -I -B "$ROOT_DIR/scripts/mijia-bridge.py" --auth "$MIJIA_DIR/auth.json" --login
fi
print '米家桥接依赖已安装。'
