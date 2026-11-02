#!/bin/bash
# [INPUT]: macOS + swiftc；Sources/*.swift 与 tests/*.test.swift；scripts/swift-test-deps.py 现算每个测试的编译方式。
# [OUTPUT]: 先把 Sources（不含 main.swift）编成一个可测试静态库，不自带替身的测试 @testable 链接它（只编一次全量，省掉几十次重编）；
#           自带替身的测试按依赖闭包单独编译。逐个运行并汇总，阻塞项失败则退出码非零。
# [POS]: CI（.github/workflows/tests.yml）与本机共用的 Swift 回归入口；不安装应用、不写正式配置、不调用真实模型或设备。
# [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
#
# 用法：scripts/run-swift-tests.sh [测试名过滤，例如 desktop-voice]
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${SWIFT_TEST_BUILD_DIR:-$(mktemp -d)}"
FILTER="${1:-}"
TIMEOUT="${SWIFT_TEST_TIMEOUT:-240}"
mkdir -p "$BUILD/bin" "$BUILD/src" "$BUILD/logs"
cd "$ROOT"

FRAMEWORKS=(-framework AppKit -framework WebKit -framework Network -framework CoreImage -framework Carbon)
FLAGS=(-parse-as-library -Onone -D DESKTOP_VOICE_TEST -module-cache-path "$BUILD/module-cache")

# 需要真实图形会话、辅助功能授权、冻结协议包或真实硬件的测试：照跑、照报，但不挡 CI。
# 等它们在 CI 上稳定通过后再从这里移走。
NONBLOCKING=(
  capability-protocol      # 依赖本机冻结协议包目录
  headset-magpie-native    # 原生窗口与主题像素，需要图形会话
  sprite-panel             # 原生面板/WKWebView，需要图形会话
  sprite-voice-interaction # 原生 field editor 焦点
  lock-screen-input        # Carbon/TIS 键盘布局
  pointer-geometry         # 读取真实显示器与窗口服务器
  headset-voice-focus      # AX 句柄
)
is_nonblocking() { local name="$1"; for item in "${NONBLOCKING[@]}"; do [[ "$item" == "$name" ]] && return 0; done; return 1; }

run_with_timeout() { perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$@"; }

SOURCES=()
for file in Sources/*.swift; do [[ "$(basename "$file")" == main.swift ]] || SOURCES+=("$file"); done

echo "::group::Build PocketDeskCore (testable static library)"
start=$(date +%s)
if ! swiftc "${FLAGS[@]}" -enable-testing -module-name PocketDeskCore \
    -emit-module -emit-module-path "$BUILD/PocketDeskCore.swiftmodule" \
    -emit-library -static -o "$BUILD/libPocketDeskCore.a" "${SOURCES[@]}"; then
  echo "::endgroup::"; echo "::error::PocketDeskCore 编译失败"; exit 1
fi
echo "built in $(( $(date +%s) - start ))s"
echo "::endgroup::"

passed=(); failed=(); soft=()
for test in tests/*.test.swift; do
  name="$(basename "$test" .test.swift)"
  [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && continue
  mode="$(python3 scripts/swift-test-deps.py "$test" "$ROOT")"
  extra=()
  # 共享夹具：用到哪个就带哪个。
  grep -q "CapabilityFixture" "$test" && extra+=(tests/CapabilityFixtureSupport.swift)
  binary="$BUILD/bin/$name"
  log="$BUILD/logs/$name.log"
  echo "::group::$name (${mode%% *})"
  if [[ "$mode" == FULL ]]; then
    wrapped="$BUILD/src/$name.swift"
    { echo "@testable import PocketDeskCore"; cat "$test"; } > "$wrapped"
    swiftc "${FLAGS[@]}" -I "$BUILD" -L "$BUILD" -lPocketDeskCore "${FRAMEWORKS[@]}" \
      "$wrapped" "${extra[@]}" -o "$binary" > "$log" 2>&1
  else
    subset=()
    for file in ${mode#SUBSET}; do subset+=("Sources/$file"); done
    swiftc "${FLAGS[@]}" "${FRAMEWORKS[@]}" "${subset[@]}" "$test" "${extra[@]}" -o "$binary" > "$log" 2>&1
  fi
  status=$?
  if [[ $status -eq 0 ]]; then
    run_with_timeout "$binary" >> "$log" 2>&1
    status=$?
  else
    echo "(compile failed)" >> "$log"
  fi
  tail -n 40 "$log"
  echo "::endgroup::"
  if [[ $status -eq 0 ]]; then passed+=("$name")
  elif is_nonblocking "$name"; then soft+=("$name"); echo "::warning::$name 未通过（非阻塞）"
  else failed+=("$name"); echo "::error::$name 未通过"
  fi
done

echo
echo "通过 ${#passed[@]} 项；非阻塞未通过 ${#soft[@]} 项：${soft[*]:-无}；阻塞失败 ${#failed[@]} 项：${failed[*]:-无}"
[[ ${#failed[@]} -eq 0 ]]
