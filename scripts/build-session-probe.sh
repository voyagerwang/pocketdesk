#!/bin/zsh
# [INPUT]: SessionProbe/main.swift、macOS SDK 与 codesign；可选 baseline 禁用预登录标记。
# [OUTPUT]: 在新建临时目录生成独立验证 App、用户级 LaunchAgent 配置与运行说明，不自动安装或启动。
# [POS]: scripts 的会话原型构建入口；默认加与 UU/RustDesk 相同的 Mach-O 标记，不修改正式应用。
# [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
set -euo pipefail
variant="${1:-prelogin}"
[[ "$variant" == prelogin || "$variant" == baseline ]] || { echo 'usage: build-session-probe.sh [prelogin|baseline]' >&2; exit 2; }
root_dir="$(cd "$(dirname "$0")/.." && pwd)"
probe_dir="$(mktemp -d /private/tmp/pocketdesk-session-probe.XXXXXX)"
trap 'build_status=$?; if (( build_status != 0 )); then /bin/rm -rf -- "$probe_dir"; fi' EXIT
probe_app="$probe_dir/PocketDeskSessionProbe.app"
mkdir -p "$probe_app/Contents/MacOS" "$probe_app/Contents/Resources"
linker_flags=()
if [[ "$variant" == prelogin ]]; then
  linker_flags=(-Xlinker -sectcreate -Xlinker __CGPreLoginApp -Xlinker __cgpreloginapp -Xlinker /dev/null)
fi
swiftc "$root_dir/SessionProbe/main.swift" -o "$probe_app/Contents/MacOS/PocketDeskSessionProbe" \
  -module-cache-path "$probe_dir/module-cache" -target "$(uname -m)-apple-macos14.0" \
  -framework AppKit -framework ScreenCaptureKit -framework Carbon "${linker_flags[@]}"
/bin/rm -rf -- "$probe_dir/module-cache"
python3 - "$probe_dir" "$variant" "$(id -u)" <<'PY'
import pathlib, plistlib, sys
folder, variant, uid = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
app = folder / 'PocketDeskSessionProbe.app'
identity = 'dev.voicedeck.session-probe'
info = {'CFBundleIdentifier': identity, 'CFBundleExecutable': 'PocketDeskSessionProbe',
        'CFBundleName': 'PocketDeskSessionProbe', 'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': '0.1', 'CFBundleVersion': '1', 'LSMinimumSystemVersion': '14.0',
        'NSScreenCaptureUsageDescription': '只统计锁屏前后的画面帧状态，不保存画面。'}
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
agent = {'Label': identity, 'ProgramArguments': [str(app / 'Contents/MacOS/PocketDeskSessionProbe'), str(folder / 'report.json'), variant],
         'LimitLoadToSessionType': ['Aqua'], 'RunAtLoad': True, 'ProcessType': 'Interactive'}
(folder / 'agent.plist').write_bytes(plistlib.dumps(agent))
(folder / 'RUN.txt').write_text(f'''本机验证，不是已完成的解锁功能。只在当前用户 Aqua 会话运行，不安装 root 服务。
启动前注册应用（否则 TCC 可能无法显示此应用的权限请求）：/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f {app}
启动：launchctl bootstrap gui/{uid} {folder}/agent.plist
停止并移除临时服务：launchctl bootout gui/{uid}/dev.voicedeck.session-probe
报告：{folder}/report.json
先授权，再点击应用中的“开始 45 秒验证”。锁屏与解锁由用户现场操作。
输入试验默认关闭；明确勾选后仅发一次 q 和删除，不按回车、不传密码。
对照测试可构建 baseline；必须先 bootout 当前实例，再启动对照实例，不能同时运行。
验证后先 bootout，再从系统隐私权限中移除本验证应用，最后删除本临时目录。
''')
PY
codesign --force --sign - --requirements '=designated => identifier "dev.voicedeck.session-probe"' "$probe_app"
printf '%s\n' "$probe_dir"
