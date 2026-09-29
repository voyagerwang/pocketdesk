#!/bin/zsh
# [INPUT]: 依赖 Swift/AppKit/WebKit、Sources、Web 和 Resources/Info.plist、AppIcon.icns。 [OUTPUT]: 重装并启动 ~/Applications/PocketDesk.app。
# [POS]: scripts 的本机安全重装入口（替代 install-app.sh 中触发 safe-delete 的 rm -rf 整目录删除）。
# [PROTOCOL]: 与原 install-app.sh 编译/codesign 逻辑一致，仅删除旧安装改为移到废纸篓。
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
BUILD_APP="$TEMP_DIR/PocketDesk.app"
INSTALL_DIR="$HOME/Applications"
INSTALL_APP="$INSTALL_DIR/PocketDesk.app"
trap 'rm -rf "$TEMP_DIR" 2>/dev/null || true' EXIT

# TLS 材料迁移：从现有 p12 派生 DER（仅当缺失时）
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
swiftc "$ROOT_DIR"/Sources/*.swift -o "$BUILD_APP/Contents/MacOS/VoiceDeck" -framework AppKit -framework WebKit -framework Network -framework CoreImage -framework Carbon -Xlinker -sectcreate -Xlinker __CGPreLoginApp -Xlinker __cgpreloginapp -Xlinker /dev/null
cp "$ROOT_DIR/Resources/Info.plist" "$BUILD_APP/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$BUILD_APP/Contents/Resources/AppIcon.icns"
copy_tree() {
  local src="$1" dst="$2"
  if ditto "$src" "$dst" 2>/dev/null; then return 0; fi
  rm -rf "$dst"
  cp -R "$src" "$dst"
}
copy_tree "$ROOT_DIR/Web" "$BUILD_APP/Contents/Resources/Web"
mkdir -p "$BUILD_APP/Contents/Helpers"
xcrun clang -fobjc-arc -Wall -Wextra -framework Foundation -framework IOKit "$ROOT_DIR/Helpers/HeadsetOptionMapping/main.m" -o "$BUILD_APP/Contents/Helpers/HeadsetOptionMapping"
"$BUILD_APP/Contents/Helpers/HeadsetOptionMapping" --self-test
codesign --force --sign - --identifier dev.voicedeck.headset-option-mapping "$BUILD_APP/Contents/Helpers/HeadsetOptionMapping"
codesign --force --sign - --requirements '=designated => identifier "dev.voicedeck.app"' "$BUILD_APP"

# Stop launchd ownership before replacing the bundle to prevent respawn during installation.
launchctl bootout "gui/$(id -u)/dev.voicedeck.app" 2>/dev/null || true
# 退出旧实例（进程名是 VoiceDeck，与 app 名不同）
if pgrep -x VoiceDeck >/dev/null 2>&1; then
  echo "Quitting running VoiceDeck…"
  pkill -x VoiceDeck || true
  sleep 1.5
fi

# 旧安装移到废纸篓，而非 rm -rf 整目录（避免触发本机 safe-delete 批量删除确认）
if [ -e "$INSTALL_APP" ]; then
  echo "Moving old install to Trash…"
  mv "$INSTALL_APP" "$HOME/.Trash/PocketDesk-$(date +%s).app" 2>/dev/null || true
fi
copy_tree "$BUILD_APP" "$INSTALL_APP"

# 清理历史更名遗留（同样移到废纸篓）
if [ -e "$INSTALL_DIR/Voice Deck.app" ]; then mv "$INSTALL_DIR/Voice Deck.app" "$HOME/.Trash/Voice Deck-$(date +%s).app" 2>/dev/null || true; fi
if [ -e "$INSTALL_DIR/Pocket Deck.app" ]; then mv "$INSTALL_DIR/Pocket Deck.app" "$HOME/.Trash/Pocket Deck-$(date +%s).app" 2>/dev/null || true; fi

python3 "$ROOT_DIR/scripts/install-headset-services.py"
# launchd starts the app; do not race it with a second LaunchServices launch.
echo "Installed and started: $INSTALL_APP"
