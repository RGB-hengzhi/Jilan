#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$PROJECT_DIR/验证记录"

# Cross-volume mutation tests need a different device from macOS's temporary
# directory. A clone on the internal APFS disk must not masquerade as one.
LOCAL_TEST_BASE="${TMPDIR:-/tmp}"
LOCAL_TEST_DEVICE=$(stat -f '%d' "$LOCAL_TEST_BASE")
if test -z "${FASTFIND_TEST_VOLUME_ROOT:-}"; then
  if test "$(stat -f '%d' "$PROJECT_DIR/Tests")" != "$LOCAL_TEST_DEVICE"; then
    export FASTFIND_TEST_VOLUME_ROOT="$PROJECT_DIR/Tests"
  else
    unset FASTFIND_TEST_VOLUME_ROOT
    echo "本次仅运行本机卷检查；跨卷/ExFAT 检查可设置 FASTFIND_TEST_VOLUME_ROOT 指向自有不同卷目录。"
  fi
else
  test -d "$FASTFIND_TEST_VOLUME_ROOT" || { echo "测试卷目录不存在。" >&2; exit 1; }
  test "$(stat -f '%d' "$FASTFIND_TEST_VOLUME_ROOT")" != "$LOCAL_TEST_DEVICE" || {
    echo "FASTFIND_TEST_VOLUME_ROOT 必须指向与系统临时目录不同的卷；请取消此变量运行本机检查。" >&2
    exit 1
  }
  export FASTFIND_TEST_VOLUME_ROOT
fi
"$PROJECT_DIR/交付/疾览.app/Contents/MacOS/QuickFind" --self-test \
  --output "$PROJECT_DIR/验证记录/自动与实际文件测试.json"
