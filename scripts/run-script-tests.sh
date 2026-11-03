#!/bin/bash
# [INPUT]: Node 与 Python3（xiaoai-audio 需要 aiohttp）；tests/*.test.cjs、*.test.js 与不依赖浏览器/真实账号 SDK 的 *.test.py。
# [OUTPUT]: 逐个运行网页脚本与 Python 回归并汇总，任一失败退出码非零。
# [POS]: CI 的跨平台回归入口（Linux 即可跑）；Playwright 浏览器回归、需要米家/小爱 SDK 的测试不在这里。
# [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 需要 zsh（macOS）、编好的 Swift 夹具、Playwright 浏览器或 miservice SDK 的 Python 测试不在此列。
PYTHON_TESTS=(
  tests/mijia-bridge.test.py
  tests/mijia-login.test.py
  tests/mijia-network.test.py
  tests/mijia-policy.test.py
  tests/mijia-sensor.test.py
  tests/xiaoai-intent.test.py
  tests/xiaoai-audio.test.py
)

passed=0; failed=()
run() {
  local label="$1"; shift
  echo "::group::$label"
  if "$@"; then passed=$((passed + 1)); echo "::endgroup::"
  else echo "::endgroup::"; failed+=("$label"); echo "::error::$label 未通过"; fi
}
for test in tests/*.test.cjs tests/*.test.js; do run "$(basename "$test")" node "$test"; done
for test in "${PYTHON_TESTS[@]}"; do run "$(basename "$test")" python3 "$test"; done

echo
echo "通过 $passed 项；失败 ${#failed[@]} 项：${failed[*]:-无}"
[[ ${#failed[@]} -eq 0 ]]
