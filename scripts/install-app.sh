#!/bin/zsh
# [INPUT]: 依赖 Sources、Web 和 Resources/Info.plist、AppIcon.icns。 [OUTPUT]: 安装并启动 ~/Applications/PocketDesk.app。 [POS]: scripts 的本机打包入口。 [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
BUILD_APP="$TEMP_DIR/PocketDesk.app"
INSTALL_DIR="$HOME/Applications"
INSTALL_APP="$INSTALL_DIR/PocketDesk.app"
trap 'rm -rf "$TEMP_DIR"' EXIT

# TLS 材料迁移：SecureTransport 现在直接从 DER 装配内存身份（不进钥匙串），需要派生副本。
# 已有身份只派生、绝不重新签发——重签会让手机已信任的 CA 与已授权的传感器权限全部作废。
TLS_DIR="$HOME/Library/Application Support/VoiceDeck/tls"
if [[ -e "$TLS_DIR/server.p12" && ( ! -e "$TLS_DIR/server-key.der" || ! -e "$TLS_DIR/server-cert.der" ) ]]; then
  echo 'Deriving TLS DER material from the existing identity…'
  umask 077
  openssl pkcs12 -in "$TLS_DIR/server.p12" -nocerts -nodes -passin "file:$TLS_DIR/password" 2>/dev/null \
    | openssl rsa -outform DER -out "$TLS_DIR/server-key.der" 2>/dev/null
  openssl pkcs12 -in "$TLS_DIR/server.p12" -clcerts -nokeys -passin "file:$TLS_DIR/password" 2>/dev/null \
    | openssl x509 -outform DER -out "$TLS_DIR/server-cert.der" 2>/dev/null
fi

mkdir -p "$BUILD_APP/Contents/MacOS" "$BUILD_APP/Contents/Resources" "$INSTALL_DIR"
swiftc "$ROOT_DIR"/Sources/*.swift -o "$BUILD_APP/Contents/MacOS/VoiceDeck" -framework AppKit -framework Network -framework CoreImage -framework Carbon -Xlinker -sectcreate -Xlinker __CGPreLoginApp -Xlinker __cgpreloginapp -Xlinker /dev/null
cp "$ROOT_DIR/Resources/Info.plist" "$BUILD_APP/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$BUILD_APP/Contents/Resources/AppIcon.icns"
# 复制目录：优先 ditto（保留扩展属性与资源分支）；受限/沙箱环境下 ditto 会在写自己的
# .BC.T_* 临时文件时被拒（Operation not permitted），退回 cp -R，否则本地打包永远装不成。
copy_tree() {
  local src="$1" dst="$2"
  if ditto "$src" "$dst" 2>/dev/null; then return 0; fi
  rm -rf "$dst"
  cp -R "$src" "$dst"
}
copy_tree "$ROOT_DIR/Web" "$BUILD_APP/Contents/Resources/Web"
# 固定 designated requirement，避免每次本地重编译都因 CDHash 改变而丢失辅助功能授权。
# 这是本机开发签名策略；正式分发时应替换为 Apple Developer ID 签名。
codesign --force --sign - --requirements '=designated => identifier "dev.voicedeck.app"' "$BUILD_APP"
rm -rf "$INSTALL_APP"
copy_tree "$BUILD_APP" "$INSTALL_APP"
# 清理历史更名遗留的安装目录（Voice Deck / Pocket Deck）。
if [ "$INSTALL_DIR/Voice Deck.app" != "$INSTALL_APP" ]; then rm -rf "$INSTALL_DIR/Voice Deck.app"; fi
if [ "$INSTALL_DIR/Pocket Deck.app" != "$INSTALL_APP" ]; then rm -rf "$INSTALL_DIR/Pocket Deck.app"; fi
# open 对已经在运行的应用只会把它激活，不会换成刚装进去的新二进制——
# 不先退出旧实例，改完的代码永远跑不起来（"我改了却没变化"的根源就在这）。
# 进程名取可执行文件 VoiceDeck（与 app 名 PocketDesk 不同，历史遗留）。
if pgrep -x VoiceDeck >/dev/null 2>&1; then
  echo "Quitting running VoiceDeck…"
  pkill -x VoiceDeck || true
  # 等端口释放：退得不够干净时新进程会绑不上 46387，白装一次。
  sleep 1.5
fi
open "$INSTALL_APP"
echo "Installed and started: $INSTALL_APP"
