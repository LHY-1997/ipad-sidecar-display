#!/bin/bash
# iPad 随航工具集 —— 安装脚本
set -e

BIN_NAME="ipad-watchdog"
APP_NAME="iPad随航.app"
SUPPORT="$HOME/Library/Application Support/ipad-watchdog"
PLIST="$HOME/Library/LaunchAgents/com.local.ipad-watchdog.plist"
UI_PLIST="$HOME/Library/LaunchAgents/com.local.ipad-sidecar-ui.plist"
OLD_VD_PLIST="$HOME/Library/LaunchAgents/com.local.ipad-vdisplay.plist"
DEST_APP="/Applications/$APP_NAME"

say() { printf "\033[1;34m▸\033[0m %s\n" "$1"; }
ok()  { printf "\033[1;32m✓\033[0m %s\n" "$1"; }
err() { printf "\033[1;31m✗\033[0m %s\n" "$1" >&2; }

cd "$(dirname "$0")"

# ---------- 1. 环境检查 ----------
say "检查环境"

OS_VER=$(sw_vers -productVersion)
OS_MAJOR=${OS_VER%%.*}
if [ "$OS_MAJOR" -lt 13 ]; then
    err "需要 macOS 13 或更新版本，当前 $OS_VER"
    exit 1
fi
ok "macOS $OS_VER"

ARCH=$(uname -m)
ok "架构 ${ARCH}（安装包同时支持 Apple Silicon 和 Intel）"

if [ ! -f "payload/$BIN_NAME" ] || [ ! -d "payload/$APP_NAME" ]; then
    err "安装包不完整，缺少 payload"
    echo ""
    printf "  如果你是从 GitHub 首页点绿色 Code → Download ZIP，或者在 Release 页面\n"
    printf "  底部点 Source code (zip)，那是源码包——里面只有代码，没有编译好的程序，装不了。\n"
    printf "  请到 Releases 下载真正的安装包：\n"
    printf "    https://github.com/nishtica/ipad-sidecar-display/releases/latest\n"
    echo ""
    printf "  如果你只把「安装.command」单独拷了出来，请放回解压出来的整个文件夹再运行。\n"
    exit 1
fi
ok "安装包完整"

# ---------- 2. 停掉旧版本 ----------
say "清理旧版本"
launchctl bootout "gui/$(id -u)/com.local.ipad-watchdog" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.local.ipad-sidecar-ui" 2>/dev/null || true

# 虚拟屏已合并进菜单栏 app。清掉 2.0 之前的独立守护，避免建出两块假屏
launchctl bootout "gui/$(id -u)/com.local.ipad-vdisplay" 2>/dev/null || true
if [ -f "$OLD_VD_PLIST" ] || [ -f "$SUPPORT/ipad-vdisplay" ]; then
    rm -f "$OLD_VD_PLIST" "$SUPPORT/ipad-vdisplay"
    ok "已移除旧的独立虚拟屏守护（功能已并入 app）"
fi

pkill -f "iPad随航" 2>/dev/null || true
ok "已停止旧进程"

# ---------- 3. 部署二进制 ----------
say "部署后台守护"
mkdir -p "$SUPPORT"
cp "payload/$BIN_NAME" "$SUPPORT/$BIN_NAME"
cp "payload/ipad-here" "$SUPPORT/ipad-here"
chmod +x "$SUPPORT/$BIN_NAME" "$SUPPORT/ipad-here"
ok "$SUPPORT/$BIN_NAME"
ok "$SUPPORT/ipad-here（自检工具）"

# ---------- 4. 部署 app ----------
say "部署面板程序"
if [ -d "$DEST_APP" ]; then
    rm -rf "$DEST_APP"
fi
if cp -R "payload/$APP_NAME" "$DEST_APP" 2>/dev/null; then
    ok "$DEST_APP"
else
    err "写入 /Applications 失败，请用 sudo 重跑"
    exit 1
fi

# 去掉隔离标记，否则 Gatekeeper 会拦
xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true
xattr -d com.apple.quarantine "$SUPPORT/$BIN_NAME" 2>/dev/null || true

# ---------- 5. 注册 LaunchAgent ----------
say "注册开机自启"

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.local.ipad-watchdog</string>
	<key>ProgramArguments</key>
	<array>
		<string>$SUPPORT/$BIN_NAME</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StartInterval</key>
	<integer>10</integer>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>StandardErrorPath</key>
	<string>$SUPPORT/stderr.log</string>
</dict>
</plist>
PLIST_EOF

cat > "$UI_PLIST" <<UI_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.local.ipad-sidecar-ui</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/bin/open</string>
		<string>-a</string>
		<string>$DEST_APP</string>
		<string>--args</string>
		<string>--background</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
</dict>
</plist>
UI_EOF

launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl bootstrap "gui/$(id -u)" "$UI_PLIST" 2>/dev/null || true
ok "已注册并启动"

# ---------- 6. 收尾 ----------
sleep 2
echo ""
echo "──────────────────────────────────────"
ok "安装完成"
echo ""
echo "接下来："
echo "  1. 屏幕顶部菜单栏会出现 iPad 图标"
echo "  2. 点开它可以手动连接 / 断开 / 暂停守护"
echo "  3. 后台守护每 10 秒检查一次，人在电脑前就会自动连"
echo "  4. 虚拟屏在面板里开关，默认开启，不依赖 BetterDisplay"
echo ""
echo "常用命令："
echo "  查看状态   $SUPPORT/ipad-here"
echo "  查看日志   tail -f \"$SUPPORT/watchdog.log\""
echo "  虚拟屏日志 tail -f \"$SUPPORT/vdisplay.log\""
echo "  暂停守护   touch \"$SUPPORT/pause\""
echo "  恢复守护   rm \"$SUPPORT/pause\""
echo "  卸载       ./uninstall.sh"
echo "──────────────────────────────────────"
