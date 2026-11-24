#!/bin/bash
set -euo pipefail

SUPPORT="$HOME/Library/Application Support/ipad-watchdog-test"
DEST="/Applications/iPad随航 2.4.1.app"
AGENTS="$HOME/Library/LaunchAgents"
if [[ -e "$DEST" ]]; then
    [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$DEST/Contents/Info.plist")" == "local.ipad.sidecar.test" ]] || {
        echo "同名应用的标识不匹配，已停止。" >&2; exit 1;
    }
fi
if [[ -f "$SUPPORT/activate.sh" ]]; then
    bash "$SUPPORT/activate.sh" original
fi
rm -f -- "$AGENTS/com.local.ipad-watchdog-test.plist" "$AGENTS/com.local.ipad-sidecar-test-ui.plist"
rm -rf -- "$DEST" "$SUPPORT"
defaults delete local.ipad.sidecar.test >/dev/null 2>&1 || true
echo "已卸载 2.4.1 版。"
