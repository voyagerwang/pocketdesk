#!/bin/zsh
# [INPUT]: 依赖 Swift/AppKit/WebKit、Sources、Web、Resources/Info.plist 与 AppIcon.icns、Helpers/HeadsetOptionMapping 与米家 JSON 桥接脚本；版本号取自 Resources/Info.plist。 [OUTPUT]: dist/PocketDesk-<版本>-macOS-arm64.dmg、dist/PocketDesk-macOS-arm64.zip 与对应 .sha256。 [POS]: scripts 的对外分发打包入口（本机开发签名，非 Developer ID 公证）；本机安装仍走 install-app.sh / rebuild-safe.sh。 [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
WORK_DIR="$(mktemp -d)"
BUILD_APP="$WORK_DIR/PocketDesk.app"
STAGE_DIR="$WORK_DIR/dmg"
trap 'rm -rf "$WORK_DIR"' EXIT

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Resources/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT_DIR/Resources/Info.plist")"
DMG_NAME="PocketDesk-${VERSION}-macOS-arm64.dmg"
ZIP_NAME="PocketDesk-macOS-arm64.zip"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "This packaging script builds an arm64 bundle; run it on Apple Silicon." >&2
  exit 1
fi

echo "Packaging PocketDesk ${VERSION} (build ${BUILD_NUMBER})…"
mkdir -p "$BUILD_APP/Contents/MacOS" "$BUILD_APP/Contents/Resources" "$DIST_DIR"

swiftc "$ROOT_DIR"/Sources/*.swift -o "$BUILD_APP/Contents/MacOS/VoiceDeck" \
  -framework AppKit -framework WebKit -framework Network -framework CoreImage -framework Carbon \
  -Xlinker -sectcreate -Xlinker __CGPreLoginApp -Xlinker __cgpreloginapp -Xlinker /dev/null

cp "$ROOT_DIR/Resources/Info.plist" "$BUILD_APP/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$BUILD_APP/Contents/Resources/AppIcon.icns"

# 复制目录：优先 ditto（保留扩展属性）；受限环境下退回 cp -R。
copy_tree() {
  local src="$1" dst="$2"
  if ditto "$src" "$dst" 2>/dev/null; then return 0; fi
  rm -rf "$dst"
  cp -R "$src" "$dst"
}
copy_tree "$ROOT_DIR/Web" "$BUILD_APP/Contents/Resources/Web"

mkdir -p "$BUILD_APP/Contents/Resources/Mijia"
cp "$ROOT_DIR/scripts/mijia-bridge.py" "$BUILD_APP/Contents/Resources/Mijia/mijia-bridge.py"
cp "$ROOT_DIR/scripts/mijia-network.py" "$BUILD_APP/Contents/Resources/Mijia/mijia-network.py"
cp "$ROOT_DIR/scripts/mijia-policy.py" "$BUILD_APP/Contents/Resources/Mijia/mijia-policy.py"
cp "$ROOT_DIR/scripts/mijia-sensor.py" "$BUILD_APP/Contents/Resources/Mijia/mijia-sensor.py"
cp "$ROOT_DIR/scripts/setup-mijia.sh" "$BUILD_APP/Contents/Resources/Mijia/setup-mijia.sh"

mkdir -p "$BUILD_APP/Contents/Helpers"
xcrun clang -fobjc-arc -Wall -Wextra -framework Foundation -framework IOKit \
  "$ROOT_DIR/Helpers/HeadsetOptionMapping/main.m" -o "$BUILD_APP/Contents/Helpers/HeadsetOptionMapping"
"$BUILD_APP/Contents/Helpers/HeadsetOptionMapping" --self-test

# 开发签名：ad-hoc + 固定 designated requirement，与本地安装一致，
# 使辅助功能授权在两次打包之间不至于因 CDHash 变化而反复重授。
# 正式对外分发仍应替换为 Apple Developer ID 签名并公证，否则首次打开需右键「打开」绕过 Gatekeeper。
codesign --force --sign - --identifier dev.voicedeck.headset-option-mapping "$BUILD_APP/Contents/Helpers/HeadsetOptionMapping"
codesign --force --sign - --requirements '=designated => identifier "dev.voicedeck.app"' "$BUILD_APP"
codesign --verify --strict --verbose=2 "$BUILD_APP"

# DMG：应用 + 「应用程序」快捷方式，符合拖拽安装习惯。
mkdir -p "$STAGE_DIR"
copy_tree "$BUILD_APP" "$STAGE_DIR/PocketDesk.app"
ln -s /Applications "$STAGE_DIR/Applications"
rm -f "$DIST_DIR/$DMG_NAME"
hdiutil create -volname "PocketDesk ${VERSION}" -srcfolder "$STAGE_DIR" -fs HFS+ -format UDZO -ov "$DIST_DIR/$DMG_NAME" >/dev/null

# ZIP：沿用 README 中既有下载文件名，方便老链接与自动化继续使用。
rm -f "$DIST_DIR/$ZIP_NAME"
ditto -c -k --sequesterRsrc --keepParent "$BUILD_APP" "$DIST_DIR/$ZIP_NAME"

(cd "$DIST_DIR" && shasum -a 256 "$DMG_NAME" "$ZIP_NAME" > SHA256SUMS)

echo "Artifacts in $DIST_DIR:"
ls -lh "$DIST_DIR/$DMG_NAME" "$DIST_DIR/$ZIP_NAME"
cat "$DIST_DIR/SHA256SUMS"
