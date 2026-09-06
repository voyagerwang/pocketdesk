#!/bin/zsh
# [INPUT]: 依赖 Sources、Web 和 Resources/Info.plist。 [OUTPUT]: 安装并启动 ~/Applications/Voice Deck.app。 [POS]: scripts 的本机打包入口。 [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
BUILD_APP="$TEMP_DIR/Voice Deck.app"
INSTALL_DIR="$HOME/Applications"
INSTALL_APP="$INSTALL_DIR/Voice Deck.app"
trap 'rm -rf "$TEMP_DIR"' EXIT

mkdir -p "$BUILD_APP/Contents/MacOS" "$BUILD_APP/Contents/Resources" "$INSTALL_DIR"
swiftc "$ROOT_DIR/Sources/main.swift" -o "$BUILD_APP/Contents/MacOS/VoiceDeck" -framework AppKit -framework Network
cp "$ROOT_DIR/Resources/Info.plist" "$BUILD_APP/Contents/Info.plist"
ditto "$ROOT_DIR/Web" "$BUILD_APP/Contents/Resources/Web"
codesign --force --sign - "$BUILD_APP"
rm -rf "$INSTALL_APP"
ditto "$BUILD_APP" "$INSTALL_APP"
open "$INSTALL_APP"
echo "Installed and started: $INSTALL_APP"
