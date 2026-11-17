#!/bin/bash
# 编译通用二进制并打包成可分发的 zip
set -e

cd "$(dirname "$0")"
ROOT="$(pwd)"
BUILD="$ROOT/build"
DIST="$BUILD/dist"
APP_NAME="iPad随航.app"
# ===== 版本号唯一来源：改这里，zip 名和 Info.plist 一起变 =====
VERSION="2.0"
BUILD_NUM="${VERSION//./}"      # 2.0 → 20，CFBundleVersion 要纯数字
# zip 名必须是纯 ASCII：GitHub 上传 Release 附件时会剥掉中文字符
# （实测 "iPad随航工具集-2.0.zip" 会被存成 "iPad.-2.0.zip"）
ZIP_NAME="iPad-Sidecar-Display-${VERSION}.zip"
MIN_MACOS="13.0"

say() { printf "\033[1;34m▸\033[0m %s\n" "$1"; }
ok()  { printf "\033[1;32m✓\033[0m %s\n" "$1"; }
err() { printf "\033[1;31m✗\033[0m %s\n" "$1" >&2; }

command -v swiftc >/dev/null || { err "需要 Xcode 命令行工具：xcode-select --install"; exit 1; }

rm -rf "$BUILD"
mkdir -p "$DIST/payload"

# ---------- 1. 后台守护 ----------
say "编译 watchdog（arm64 + x86_64）"
swiftc -O -target "arm64-apple-macos$MIN_MACOS" Sources/Watchdog.swift \
    -framework IOKit -framework CoreAudio -o "$BUILD/w-arm"
swiftc -O -target "x86_64-apple-macos$MIN_MACOS" Sources/Watchdog.swift \
    -framework IOKit -framework CoreAudio -o "$BUILD/w-x86"
lipo -create "$BUILD/w-arm" "$BUILD/w-x86" -output "$DIST/payload/ipad-watchdog"
chmod +x "$DIST/payload/ipad-watchdog"
ok "ipad-watchdog"

# ---------- 2. 自检工具 ----------
say "编译 ipad-here（arm64 + x86_64）"
swiftc -O -target "arm64-apple-macos$MIN_MACOS" Sources/IPadHere.swift \
    -framework IOKit -framework CoreAudio -o "$BUILD/h-arm"
swiftc -O -target "x86_64-apple-macos$MIN_MACOS" Sources/IPadHere.swift \
    -framework IOKit -framework CoreAudio -o "$BUILD/h-x86"
lipo -create "$BUILD/h-arm" "$BUILD/h-x86" -output "$DIST/payload/ipad-here"
chmod +x "$DIST/payload/ipad-here"
ok "ipad-here"

# ---------- 3. 菜单栏 app（内含虚拟屏）----------
say "编译菜单栏面板（arm64 + x86_64）"
swiftc -O -parse-as-library -target "arm64-apple-macos$MIN_MACOS" \
    Sources/MenuBar.swift Sources/VirtualScreen.swift \
    -framework SwiftUI -framework AppKit -o "$BUILD/m-arm"
swiftc -O -parse-as-library -target "x86_64-apple-macos$MIN_MACOS" \
    Sources/MenuBar.swift Sources/VirtualScreen.swift \
    -framework SwiftUI -framework AppKit -o "$BUILD/m-x86"
lipo -create "$BUILD/m-arm" "$BUILD/m-x86" -output "$BUILD/menu-bar"
ok "菜单栏面板（含虚拟屏）"

# 虚拟屏已合并进菜单栏 app（Sources/VirtualScreen.swift），不再单独编译进程。

# ---------- 4. 组装 .app ----------
say "组装 $APP_NAME"
APP="$DIST/payload/$APP_NAME"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/menu-bar" "$APP/Contents/MacOS/iPad随航"
chmod +x "$APP/Contents/MacOS/iPad随航"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDisplayName</key><string>iPad 随航</string>
	<key>CFBundleExecutable</key><string>iPad随航</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>local.ipad.sidecar</string>
	<key>CFBundleName</key><string>iPad随航</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>${VERSION}</string>
	<key>CFBundleVersion</key><string>${BUILD_NUM}</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST_EOF
codesign --force --deep -s - "$APP" 2>/dev/null || true
ok "$APP_NAME"

# ---------- 5. 附上安装脚本 ----------
say "打包安装脚本"
cp Packaging/install.sh Packaging/uninstall.sh "$DIST/"
cp Packaging/安装.command Packaging/卸载.command "$DIST/"
cp Packaging/README.md "$DIST/README.md"
chmod +x "$DIST/install.sh" "$DIST/uninstall.sh" "$DIST/安装.command" "$DIST/卸载.command"
ok "安装脚本"

# ---------- 6. 生成 zip ----------
say "生成 $ZIP_NAME"
cd "$DIST"
ditto -c -k --sequesterRsrc . "$ROOT/$ZIP_NAME"
cd "$ROOT"
# 去掉 ditto 附带的 __MACOSX 资源分叉目录，别人解压不会看到一堆垃圾文件
zip -q -d "$ZIP_NAME" "__MACOSX/*" 2>/dev/null || true
ok "$ROOT/$ZIP_NAME"

echo ""
echo "──────────────────────────────────────"
ls -lh "$ZIP_NAME"
echo ""
echo "验证架构："
lipo -archs "$DIST/payload/ipad-watchdog" | sed 's/^/  ipad-watchdog:  /'
lipo -archs "$DIST/payload/ipad-here" | sed 's/^/  ipad-here:      /'
lipo -archs "$APP/Contents/MacOS/iPad随航" | sed 's/^/  菜单栏面板:     /'
echo "──────────────────────────────────────"
