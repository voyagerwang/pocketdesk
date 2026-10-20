#!/bin/zsh
# [INPUT]: 环境变量 GITHUB_TOKEN（需 contents: read/write）与已由 scripts/package-macos.sh 产出的 dist/ 工件；版本号取自 Resources/Info.plist，仓库默认 voyagerwang/pocketdesk（可用 GITHUB_REPO 覆盖）。 [OUTPUT]: GitHub Release v<版本>，附 DMG、ZIP 与 SHA256SUMS，并打印发布页与资产下载地址。 [POS]: scripts 的对外发布入口；只上传 dist/ 中已构建的工件，不重新编译。 [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
REPO="${GITHUB_REPO:-voyagerwang/pocketdesk}"
TOKEN="${GITHUB_TOKEN:-}"

if [[ -z "$TOKEN" ]]; then
  echo "GITHUB_TOKEN is required (contents: read/write)." >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Resources/Info.plist")"
TAG="v${VERSION}"
DMG="$DIST_DIR/PocketDesk-${VERSION}-macOS-arm64.dmg"
ZIP="$DIST_DIR/PocketDesk-macOS-arm64.zip"

for f in "$DMG" "$ZIP" "$DIST_DIR/SHA256SUMS"; do
  [[ -f "$f" ]] || { echo "Missing artifact: $f (run scripts/package-macos.sh first)" >&2; exit 1; }
done

API="https://api.github.com/repos/$REPO"
AUTH=(-H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")

# 先确保 tag 已推到远端：Release 挂在 tag 上，缺 tag 会退化成 GitHub 自动建的分支指针。
git -C "$ROOT_DIR" tag -f "$TAG" >/dev/null
git -C "$ROOT_DIR" push -f origin "refs/tags/$TAG" >/dev/null

# 已存在同名 Release 则复用它（重跑只补传缺失资产），否则新建。
RELEASE_JSON="$(curl -sS -m 30 "${AUTH[@]}" "$API/releases/tags/$TAG" || true)"
if [[ "$(printf '%s' "$RELEASE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null)" == "" ]]; then
  echo "Creating release $TAG…"
  RELEASE_JSON="$(python3 - "$TAG" <<'PY' | curl -sS -m 60 -X POST "${AUTH[@]}" -d @- "$API/releases"
import json, sys
tag = sys.argv[1]
print(json.dumps({
    "tag_name": tag,
    "name": f"PocketDesk {tag}",
    "generate_release_notes": True,
    "body": "\n".join([
        "## macOS 安装（Apple Silicon）",
        "",
        f"1. 下载 `PocketDesk-{tag.lstrip('v')}-macOS-arm64.dmg`，双击挂载后把 PocketDesk 拖进「应用程序」；",
        "2. 首次打开：**右键点击应用 → 打开 → 再点「打开」**（本项目使用本机开发签名，未经 Apple 公证，直接双击会被 Gatekeeper 拦截）；",
        "3. 按电脑端控制台引导授予辅助功能权限 → 手机扫码连接。",
        "",
        "ZIP 包内容相同，供脚本或旧链接使用；`SHA256SUMS` 可用于校验下载完整性。",
    ]),
}))
PY
)"
fi

RELEASE_ID="$(printf '%s' "$RELEASE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
RELEASE_URL="$(printf '%s' "$RELEASE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["html_url"])')"
UPLOAD_URL="$(printf '%s' "$RELEASE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["upload_url"].split("{")[0])')"

existing_names="$(printf '%s' "$RELEASE_JSON" | python3 -c 'import json,sys; print("\n".join(a["name"] for a in json.load(sys.stdin).get("assets",[])))')"

for f in "$DMG" "$ZIP" "$DIST_DIR/SHA256SUMS"; do
  name="$(basename "$f")"
  if printf '%s\n' "$existing_names" | grep -qx "$name"; then
    echo "Asset already present, replacing: $name"
    asset_id="$(printf '%s' "$RELEASE_JSON" | python3 -c "import json,sys;print([a['id'] for a in json.load(sys.stdin)['assets'] if a['name']=='$name'][0])")"
    curl -sS -m 60 -X DELETE "${AUTH[@]}" "https://api.github.com/repos/$REPO/releases/assets/$asset_id" >/dev/null
  fi
  echo "Uploading $name ($(du -h "$f" | cut -f1))…"
  curl -sS -m 600 -X POST "${AUTH[@]}" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @"$f" \
    "$UPLOAD_URL?name=$name" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  ->", d.get("browser_download_url", d))'
done

echo
echo "Release page: $RELEASE_URL"
