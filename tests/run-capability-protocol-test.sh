#!/bin/bash
# [INPUT]: 两个 Sources 协议文件与隔离测试/冻结包。
# [OUTPUT]: 编译和验证退出码，临时二进制自动清理。
# [POS]: G0 无副作用测试入口。
# [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
# 编译并运行统一小精灵能力协议 v1 的 Swift 隔离测试（G0 纯协议）。
# 只读冻结包 fixtures/schema（默认
# /Users/yz/.codex/zcode-night-20260919/frozen/A-protocol-v1-r2/protocols/unified-assistant/v1，
# 可用 PD_UNIFIED_ASSISTANT_PROTOCOL_DIR 覆盖）；无网络、无桌面副作用、无真实模型调用。
# 用法：bash tests/run-capability-protocol-test.sh
set -euo pipefail
root_dir="$(cd "$(dirname "$0")/.." && pwd)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT
out_bin="$temp_dir/capability-protocol-test"
swiftc -parse-as-library \
  "$root_dir/Sources/CapabilityModels.swift" \
  "$root_dir/Sources/CapabilityDateTime.swift" \
  "$root_dir/tests/CapabilityFixtureSupport.swift" \
  "$root_dir/tests/capability-protocol.test.swift" \
  -o "$out_bin"
"$out_bin"
