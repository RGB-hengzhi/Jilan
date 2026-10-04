#!/bin/bash
set -euo pipefail
export COPYFILE_DISABLE=1
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${QUICKFIND_BUILD_DIR:-$HOME/Library/Caches/QuickFind-dev/build}"
DELIVERY_APP="$PROJECT_DIR/交付/疾览.app"
APP_DIR="$BUILD_DIR/package/疾览.app"
mkdir -p "$BUILD_DIR" "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources/docs"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 \
  "$PROJECT_DIR"/Sources/*.swift "$PROJECT_DIR"/Tests/*.swift \
  -framework AppKit -framework Quartz -framework Carbon -framework CoreServices \
  -o "$BUILD_DIR/QuickFind"
cp "$BUILD_DIR/QuickFind" "$APP_DIR/Contents/MacOS/QuickFind"
cp "$PROJECT_DIR/LICENSE" "$APP_DIR/Contents/Resources/LICENSE"
if test -f "$PROJECT_DIR/docs/开源声明.md"; then
  cp "$PROJECT_DIR/docs/开源声明.md" "$APP_DIR/Contents/Resources/docs/开源声明.md"
fi
if test -f "$PROJECT_DIR/scripts/make-icon.swift"; then
  swift "$PROJECT_DIR/scripts/make-icon.swift" "$BUILD_DIR"
  iconutil -c icns "$BUILD_DIR/QuickFind.iconset" -o "$APP_DIR/Contents/Resources/QuickFind.icns"
fi
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>疾览</string>
<key>CFBundleDisplayName</key><string>疾览 · Jilan</string>
<key>CFBundleIdentifier</key><string>cn.local.quickfind</string>
<key>CFBundleExecutable</key><string>QuickFind</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.2.3</string>
<key>CFBundleVersion</key><string>10</string>
<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
<key>CFBundleLocalizations</key><array><string>zh-Hans</string></array>
<key>CFBundleIconFile</key><string>QuickFind</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSDesktopFolderUsageDescription</key><string>用于搜索、浏览和整理您选择的桌面文件。</string>
<key>NSDocumentsFolderUsageDescription</key><string>用于搜索、浏览和整理您选择的文稿文件。</string>
<key>NSDownloadsFolderUsageDescription</key><string>用于搜索、浏览和整理您选择的下载文件。</string>
<key>NSRemovableVolumesUsageDescription</key><string>用于搜索、浏览和整理您选择的外置磁盘文件。</string>
<key>NSNetworkVolumesUsageDescription</key><string>用于读取您添加的网络位置中的文件与文件夹名称，建立本地搜索索引。</string>
<key>NSAppleMusicUsageDescription</key><string>用于索引本机媒体库中音乐文件的名称和所在目录，不分析音乐内容。</string>
<key>NSHumanReadableCopyright</key><string>© 2026 塔贰舅；GPL-3.0；包含 FuzzyIdeas/Cling 开源索引核心</string>
</dict></plist>
PLIST
codesign --force --sign - --identifier cn.local.quickfind "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
mkdir -p "$PROJECT_DIR/交付/历史版本"
for PREVIOUS_APP in "$DELIVERY_APP" "$PROJECT_DIR/交付/疾速查找.app"; do
  if test -d "$PREVIOUS_APP"; then
    PREVIOUS_NAME="$(basename "$PREVIOUS_APP" .app)"
    mv "$PREVIOUS_APP" "$PROJECT_DIR/交付/历史版本/${PREVIOUS_NAME}_$(date +%Y%m%d_%H%M%S).app"
  fi
done
ditto --norsrc --noextattr "$APP_DIR" "$DELIVERY_APP"
python3 "$PROJECT_DIR/scripts/clean_sidecars.py" "$DELIVERY_APP"
codesign --verify --deep --strict "$DELIVERY_APP"
echo "已构建：$DELIVERY_APP"
