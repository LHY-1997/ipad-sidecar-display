#!/bin/bash
# iPad 随航工具集 —— 卸载脚本
set -e

SUPPORT="$HOME/Library/Application Support/ipad-watchdog"
PLIST="$HOME/Library/LaunchAgents/com.local.ipad-watchdog.plist"
UI_PLIST="$HOME/Library/LaunchAgents/com.local.ipad-sidecar-ui.plist"
OLD_VD_PLIST="$HOME/Library/LaunchAgents/com.local.ipad-vdisplay.plist"  # 旧版遗留，2.0 起已并入 app
DEST_APP="/Applications/iPad随航.app"

say() { printf "\033[1;34m▸\033[0m %s\n" "$1"; }
ok()  { printf "\033[1;32m✓\033[0m %s\n" "$1"; }

echo "将要删除："
echo "  $PLIST"
echo "  $UI_PLIST"
echo "  $OLD_VD_PLIST  （旧版遗留，如存在）"
echo "  $SUPPORT/  （含日志和配置）"
echo "  $DEST_APP"
echo ""
read -p "确认卸载？[y/N] " ans
case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "已取消"; exit 0 ;;
esac

say "停止服务"
launchctl bootout "gui/$(id -u)/com.local.ipad-watchdog" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.local.ipad-sidecar-ui" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.local.ipad-vdisplay" 2>/dev/null || true
pkill -f "iPad随航" 2>/dev/null || true
ok "已停止"

say "删除文件"
rm -f "$PLIST" "$UI_PLIST" "$OLD_VD_PLIST"
rm -rf "$SUPPORT"
rm -rf "$DEST_APP"
ok "已清理"

echo ""
echo "──────────────────────────────────────"
ok "卸载完成"
echo "注意：随航本身是 macOS 系统功能，不受影响，"
echo "      仍可在「系统设置 → 显示器」里手动添加 iPad。"
echo "──────────────────────────────────────"
