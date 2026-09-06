#!/bin/zsh
# [INPUT]: 依赖 Sources、Web 和 Resources/Info.plist、AppIcon.icns。 [OUTPUT]: 安装并启动 ~/Applications/PocketDesk.app。 [POS]: scripts 的本机打包入口。 [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
BUILD_APP="$TEMP_DIR/PocketDesk.app"
INSTALL_DIR="$HOME/Applications"
INSTALL_APP="$INSTALL_DIR/PocketDesk.app"
trap 'rm -rf "$TEMP_DIR"' EXIT

mkdir -p "$BUILD_APP/Contents/MacOS" "$BUILD_APP/Contents/Resources" "$INSTALL_DIR"
swiftc "$ROOT_DIR/Sources/main.swift" -o "$BUILD_APP/Contents/MacOS/VoiceDeck" -framework AppKit -framework Network -framework CoreImage
cp "$ROOT_DIR/Resources/Info.plist" "$BUILD_APP/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$BUILD_APP/Contents/Resources/AppIcon.icns"
ditto "$ROOT_DIR/Web" "$BUILD_APP/Contents/Resources/Web"
# 固定 designated requirement，避免每次本地重编译都因 CDHash 改变而丢失辅助功能授权。
# 这是本机开发签名策略；正式分发时应替换为 Apple Developer ID 签名。
codesign --force --sign - --requirements '=designated => identifier "dev.voicedeck.app"' "$BUILD_APP"
rm -rf "$INSTALL_APP"
ditto "$BUILD_APP" "$INSTALL_APP"
# 清理历史更名遗留的安装目录（Voice Deck / Pocket Deck）。
if [ "$INSTALL_DIR/Voice Deck.app" != "$INSTALL_APP" ]; then rm -rf "$INSTALL_DIR/Voice Deck.app"; fi
if [ "$INSTALL_DIR/Pocket Deck.app" != "$INSTALL_APP" ]; then rm -rf "$INSTALL_DIR/Pocket Deck.app"; fi
open "$INSTALL_APP"
echo "Installed and started: $INSTALL_APP"
