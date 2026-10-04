#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$PROJECT_DIR/验证记录"
export FASTFIND_TEST_VOLUME_ROOT="$PROJECT_DIR/Tests"
"$PROJECT_DIR/交付/疾览.app/Contents/MacOS/QuickFind" --self-test \
  --output "$PROJECT_DIR/验证记录/自动与实际文件测试.json"
