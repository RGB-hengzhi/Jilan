#!/bin/bash
# Build and verify a shareable Apple Silicon disk image from an existing signed app.
# This script does not modify the app or any user index, preference, or system setting.
set -euo pipefail
export COPYFILE_DISABLE=1

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${JILAN_APP_PATH:-$PROJECT_DIR/交付/疾览.app}"
OUTPUT_DIR="${JILAN_DMG_OUTPUT_DIR:-$PROJECT_DIR/交付/发布}"
CACHE_DIR="${JILAN_PACKAGE_WORK_DIR:-$HOME/Library/Caches/JilanPackaging}"
INSTALL_DOC="$PROJECT_DIR/docs/安装说明.md"

test -d "$APP_PATH" || { echo "找不到应用，请先运行 scripts/build.sh。" >&2; exit 1; }
test -f "$INSTALL_DOC" || { echo "找不到 docs/安装说明.md。" >&2; exit 1; }
codesign --verify --deep --strict "$APP_PATH"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP_PATH/Contents/Info.plist")
EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$APP_PATH/Contents/Info.plist")
ARCHITECTURE=$(lipo -archs "$APP_PATH/Contents/MacOS/$EXECUTABLE")
test "$ARCHITECTURE" = arm64 || { echo "此安装包仅支持 arm64 应用。" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "无效的应用版本。" >&2; exit 1; }

mkdir -p "$CACHE_DIR" "$OUTPUT_DIR"
WORK_DIR=$(mktemp -d "$CACHE_DIR/jilan-dmg.XXXXXXXX")
MOUNT_DIR="$WORK_DIR/mounted"
MOUNTED=0
cleanup() {
  if test "$MOUNTED" = 1; then
    hdiutil detach "$MOUNT_DIR" -quiet || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

STAGING_DIR="$WORK_DIR/contents"
mkdir -p "$STAGING_DIR" "$MOUNT_DIR"
ditto --norsrc --noextattr "$APP_PATH" "$STAGING_DIR/疾览.app"
python3 - "$STAGING_DIR/疾览.app" "$EXECUTABLE" <<'PY'
# -*- coding: utf-8 -*-
from pathlib import Path
import sys

root = Path(sys.argv[1])
executable = root / "Contents/MacOS" / sys.argv[2]
root.chmod(0o755)
for item in root.rglob("*"):
    if item.is_symlink():
        continue
    if item.is_dir():
        item.chmod(0o755)
    elif item.is_file():
        item.chmod(0o755 if item == executable else 0o644)
PY
ln -s /Applications "$STAGING_DIR/Applications"
cp "$INSTALL_DOC" "$STAGING_DIR/安装说明.txt"
codesign --verify --deep --strict "$STAGING_DIR/疾览.app"

DMG_NAME="Jilan-$VERSION-macOS-arm64.dmg"
test ! -e "$OUTPUT_DIR/$DMG_NAME" || {
  echo "目标安装包已存在；请通过 JILAN_DMG_OUTPUT_DIR 指定新的输出目录。" >&2
  exit 1
}
TEMP_DMG="$WORK_DIR/$DMG_NAME"
hdiutil create -quiet -format UDZO -fs HFS+ -volname '疾览 Jilan' \
  -srcfolder "$STAGING_DIR" "$TEMP_DMG"
hdiutil verify -quiet "$TEMP_DMG"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$MOUNT_DIR" "$TEMP_DMG"
MOUNTED=1
codesign --verify --deep --strict "$MOUNT_DIR/疾览.app"

python3 - "$APP_PATH" "$MOUNT_DIR" "$VERSION" "$BUILD" "$WORK_DIR/verification.json" <<'PY'
# -*- coding: utf-8 -*-
from pathlib import Path
import datetime
import hashlib
import json
import os
import plistlib
import stat
import sys

app, mount = Path(sys.argv[1]), Path(sys.argv[2])
version, build, report = sys.argv[3], sys.argv[4], Path(sys.argv[5])
packaged = mount / "疾览.app"

def manifest(root):
    result = {}
    for item in sorted(root.rglob("*")):
        relative = str(item.relative_to(root))
        if item.name.startswith("._") or item.name == ".DS_Store":
            raise SystemExit("应用或安装包中存在不应发布的元数据文件：" + relative)
        if item.is_symlink():
            result[relative] = {"symlink": os.readlink(item)}
        elif item.is_file():
            result[relative] = {
                "sha256": hashlib.sha256(item.read_bytes()).hexdigest(),
                "mode": oct(stat.S_IMODE(item.stat().st_mode)),
            }
    return result

original_manifest = manifest(app)
packaged_manifest = manifest(packaged)
original_bytes = {name: {k: v for k, v in detail.items() if k != "mode"}
                  for name, detail in original_manifest.items()}
packaged_bytes = {name: {k: v for k, v in detail.items() if k != "mode"}
                  for name, detail in packaged_manifest.items()}
if original_bytes != packaged_bytes:
    raise SystemExit("DMG 内应用与原版应用的文件字节不一致。")
for name, detail in packaged_manifest.items():
    expected_mode = "0o755" if name == "Contents/MacOS/QuickFind" else "0o644"
    if detail.get("mode") != expected_mode:
        raise SystemExit("DMG 内应用文件权限不正确：" + name)
for item in [packaged, *packaged.rglob("*")]:
    if item.is_dir() and stat.S_IMODE(item.stat().st_mode) != 0o755:
        raise SystemExit("DMG 内应用目录权限不正确。")
expected_app_files = {
    "Contents/Info.plist", "Contents/_CodeSignature/CodeResources",
    "Contents/MacOS/QuickFind", "Contents/Resources/LICENSE",
    "Contents/Resources/QuickFind.icns", "Contents/Resources/docs/开源声明.md",
}
if set(packaged_manifest) != expected_app_files:
    raise SystemExit("应用文件不在当前发行白名单中，请审阅新增资源后更新白名单。")

expected = {"疾览.app", "Applications", "安装说明.txt"}
actual = {p.name for p in mount.iterdir()}
filesystem_metadata = {".HFS+ Private Directory Data\r", ".Trashes", ".fseventsd"}
unexpected = actual - expected - filesystem_metadata
if not expected.issubset(actual) or unexpected:
    raise SystemExit("DMG 根目录内容与发布白名单不一致：" + repr(sorted(actual)))
if not (mount / "Applications").is_symlink() or os.readlink(mount / "Applications") != "/Applications":
    raise SystemExit("Applications 快捷方式不正确。")
info = plistlib.loads((packaged / "Contents/Info.plist").read_bytes())
if info["CFBundleShortVersionString"] != version or info["CFBundleVersion"] != build:
    raise SystemExit("DMG 内应用版本不一致。")
if info["CFBundleIdentifier"] != "cn.local.quickfind":
    raise SystemExit("应用身份意外变化。")
if not (packaged / "Contents/Resources/LICENSE").is_file():
    raise SystemExit("应用中缺少许可证。")

report.write_text(json.dumps({
    "application": info["CFBundleDisplayName"],
    "version": version,
    "build": build,
    "architecture": "arm64",
    "minimumMacOS": info["LSMinimumSystemVersion"],
    "verifiedAtUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "result": "passed",
    "checks": {
        "diskImageIntegrity": True,
        "readOnlyMount": True,
        "appBytesMatch": True,
        "standardAppPermissionsAndExecutableValid": True,
        "appAdHocSignatureValid": True,
        "applicationsShortcutCorrect": True,
        "licenseIncluded": True,
        "releaseContentsWhitelisted": True,
        "userIndexAndPreferencesNotIncluded": True,
    },
    "appFiles": packaged_manifest,
    "limits": [
        "Not signed with Apple Developer ID and not notarized.",
        "First-launch Gatekeeper approval on another Mac has not been tested.",
        "Device compatibility below the current test host was not physically tested.",
    ],
}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

hdiutil detach -quiet "$MOUNT_DIR"
MOUNTED=0
cp "$TEMP_DMG" "$OUTPUT_DIR/$DMG_NAME.tmp"
mv "$OUTPUT_DIR/$DMG_NAME.tmp" "$OUTPUT_DIR/$DMG_NAME"
cp "$WORK_DIR/verification.json" "$OUTPUT_DIR/$DMG_NAME.verification.json"
(cd "$OUTPUT_DIR" && shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256")
echo "安装包：$OUTPUT_DIR/$DMG_NAME"
cat "$OUTPUT_DIR/$DMG_NAME.sha256"
