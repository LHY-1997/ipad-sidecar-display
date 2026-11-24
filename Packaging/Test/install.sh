#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
[[ "$(uname -s)" == Darwin && "$EUID" != 0 ]] || { echo "请使用当前 macOS 用户运行。" >&2; exit 1; }
APP_NAME="iPad随航 Test.app"
DEST="/Applications/$APP_NAME"
SUPPORT="$HOME/Library/Application Support/ipad-watchdog-test"
AGENTS="$HOME/Library/LaunchAgents"
GUI="gui/$(id -u)"

[[ -d "payload/$APP_NAME" && -f payload/ipad-watchdog && -f payload/ipad-here ]] || {
    echo "安装包不完整，请保留解压后的整个文件夹。" >&2; exit 1;
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "payload/$APP_NAME/Contents/Info.plist")" == "local.ipad.sidecar.test" ]] || {
    echo "安装包中的应用标识不正确。" >&2; exit 1;
}
codesign --verify --deep --strict "payload/$APP_NAME"
codesign --verify --strict payload/ipad-watchdog
codesign --verify --strict payload/ipad-here
[[ -w /Applications ]] || { echo "当前用户无法写入“应用程序”文件夹。" >&2; exit 1; }
if [[ -e "$DEST" ]]; then
    [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$DEST/Contents/Info.plist")" == "local.ipad.sidecar.test" ]] || {
        echo "同名应用的标识不匹配，已停止。" >&2; exit 1;
    }
fi

mkdir -p "$SUPPORT" "$AGENTS"
STAGE=$(mktemp -d /Applications/.ipad-sidecar-test.XXXXXX)
cleanup() {
    local result=$?
    rm -rf -- "$STAGE"
    if [[ "$result" -ne 0 && -f "$SUPPORT/original-services.state" && -f "$SUPPORT/activate.sh" ]]; then
        echo "安装未完成，正在恢复原版服务……" >&2
        bash "$SUPPORT/activate.sh" original || true
    fi
}
trap cleanup EXIT
ditto "payload/$APP_NAME" "$STAGE/$APP_NAME"
codesign --verify --deep --strict "$STAGE/$APP_NAME"

# 只停止已有测试服务，原版应用及其文件不会被替换。
launchctl bootout "$GUI/com.local.ipad-watchdog-test" 2>/dev/null || true
launchctl bootout "$GUI/com.local.ipad-sidecar-test-ui" 2>/dev/null || true
pkill -x 'iPad随航 Test' 2>/dev/null || true
rm -rf -- "$DEST"
mv "$STAGE/$APP_NAME" "$DEST"
cp payload/ipad-watchdog "$SUPPORT/ipad-watchdog"
cp payload/ipad-here "$SUPPORT/ipad-here"
cp activate.sh '切换 Test.command' '恢复原版.command' "$SUPPORT/"
chmod +x "$SUPPORT/ipad-watchdog" "$SUPPORT/ipad-here" "$SUPPORT/activate.sh" "$SUPPORT/切换 Test.command" "$SUPPORT/恢复原版.command"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

SUPPORT_XML=$(printf '%s' "$SUPPORT" | sed -e 's/\&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
DEST_XML=$(printf '%s' "$DEST" | sed -e 's/\&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
cat > "$AGENTS/com.local.ipad-watchdog-test.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.local.ipad-watchdog-test</string>
<key>ProgramArguments</key><array><string>$SUPPORT_XML/ipad-watchdog</string></array>
<key>RunAtLoad</key><true/><key>StartInterval</key><integer>10</integer>
<key>LimitLoadToSessionType</key><string>Aqua</string>
<key>StandardErrorPath</key><string>$SUPPORT_XML/stderr.log</string>
</dict></plist>
PLIST
cat > "$AGENTS/com.local.ipad-sidecar-test-ui.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.local.ipad-sidecar-test-ui</string>
<key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-a</string><string>$DEST_XML</string><string>--args</string><string>--background</string></array>
<key>RunAtLoad</key><true/><key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
PLIST
plutil -lint "$AGENTS/com.local.ipad-watchdog-test.plist" "$AGENTS/com.local.ipad-sidecar-test-ui.plist"

echo "测试版已安装，正在切换到 Test 模式。"
bash "$SUPPORT/activate.sh" test
echo "安装完成：iPad 随航 Test。"
