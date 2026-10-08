#!/bin/bash
# [INPUT]: Sources（排除生产 main.swift）、耳机操作识别测试及可选原生预览测试。
# [OUTPUT]: 隔离测试退出码；二进制、编译缓存与可选预览写入临时或指定目录。
# [POS]: 耳机 UI 回归入口；不安装应用、不录音、不注入键盘或执行耳机动作。
# [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: bash tests/run-headset-ui-tests.sh [--native] [--output-dir DIRECTORY]

Default: build and run synthetic operation-recognition tests without opening UI.
--native: also open native preview windows and save PNGs; requires a macOS UI session.
--output-dir: retain binaries and compiler caches in DIRECTORY instead of a new temporary directory.
PD_HEADSET_TEST_OUTPUT_DIR can also select the output directory.
PD_HEADSET_PREVIEW_DIR can separately select the native preview destination.
USAGE
}

project_root="$(cd "$(dirname "$0")/.." && pwd)"
run_native=false
output_dir="${PD_HEADSET_TEST_OUTPUT_DIR:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --native) run_native=true; shift ;;
    --output-dir)
      [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }
      output_dir="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if [[ -z "$output_dir" ]]; then
  output_dir="$(mktemp -d "${TMPDIR:-/tmp}/pocketdesk-headset-ui-tests.XXXXXX")"
fi
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
module_cache_dir="$output_dir/module-cache"
mkdir -p "$module_cache_dir"

app_sources=()
for source_file in "$project_root"/Sources/*.swift; do
  if [[ "$source_file" != "$project_root/Sources/main.swift" ]]; then
    app_sources+=("$source_file")
  fi
done
framework_options=(-framework AppKit -framework SwiftUI -framework WebKit -framework Network -framework CoreImage -framework Carbon)

build_test() {
  local test_source="$1" test_binary="$2"
  swiftc -parse-as-library -module-cache-path "$module_cache_dir" \
    "${app_sources[@]}" "$test_source" "${framework_options[@]}" -o "$test_binary" > "$test_binary.compiler.log" 2>&1 || {
      cat "$test_binary.compiler.log" >&2
      return 1
    }
}

recognition_binary="$output_dir/headset-operation-learning-test"
build_test "$project_root/tests/headset-operation-learning.test.swift" "$recognition_binary"
"$recognition_binary"

if [[ "$run_native" == true ]]; then
  native_binary="$output_dir/headset-magpie-native-test"
  build_test "$project_root/tests/headset-magpie-native.test.swift" "$native_binary"
  PD_HEADSET_PREVIEW_DIR="${PD_HEADSET_PREVIEW_DIR:-$output_dir/previews}" "$native_binary"
fi

printf 'Headset test outputs: %s\n' "$output_dir"
