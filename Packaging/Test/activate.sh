#!/bin/bash
set -euo pipefail

[[ "$(uname -s)" == Darwin && "$EUID" != 0 ]] || { echo "请使用当前 macOS 用户运行。" >&2; exit 1; }
MODE="${1:-}"
[[ "$MODE" == test || "$MODE" == original ]] || { echo "用法：activate.sh test|original" >&2; exit 1; }
SUPPORT="$HOME/Library/Application Support/ipad-watchdog-test"
AGENTS="$HOME/Library/LaunchAgents"
STATE="$SUPPORT/original-services.state"
GUI="gui/$(id -u)"
ORIGINAL_APP="/Applications/iPad随航.app"
TEST_APP="/Applications/iPad随航 Test.app"
TEST_LABELS=(com.local.ipad-watchdog-test com.local.ipad-sidecar-test-ui)
ORIGINAL_LABELS=(com.local.ipad-watchdog com.local.ipad-sidecar-ui)
mkdir -p "$SUPPORT"
LOCK="$SUPPORT/.switch-lock"
mkdir "$LOCK" 2>/dev/null || { echo "另一项版本切换正在进行。" >&2; exit 1; }
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

stop_app() {
    local name="$1"
    pkill -x "$name" 2>/dev/null || true
    for attempt in 1 2 3 4 5; do
        pgrep -x "$name" >/dev/null 2>&1 || return 0
        sleep 1
    done
    echo "$name 尚未退出，请关闭后重试。" >&2
    return 1
}

stop_test() {
    local label
    for label in "${TEST_LABELS[@]}"; do
        launchctl disable "$GUI/$label" || return 1
        if launchctl print "$GUI/$label" >/dev/null 2>&1; then
            launchctl bootout "$GUI/$label" || return 1
        fi
    done
    stop_app 'iPad随航 Test' || return 1
    rm -f -- "$SUPPORT/test-active"
}

restore_original() {
    [[ -f "$STATE" ]] || return 0
    local label enabled loaded running
    while IFS=' ' read -r label enabled loaded; do
        case "$label" in
            com.local.ipad-watchdog|com.local.ipad-sidecar-ui)
                if [[ "$enabled" == enabled ]]; then
                    launchctl enable "$GUI/$label" || return 1
                fi
                if [[ "$loaded" == loaded && -f "$AGENTS/$label.plist" ]] && ! launchctl print "$GUI/$label" >/dev/null 2>&1; then
                    launchctl enable "$GUI/$label" || return 1
                    launchctl bootstrap "$GUI" "$AGENTS/$label.plist" || return 1
                fi
                if [[ "$enabled" == disabled ]]; then
                    launchctl disable "$GUI/$label" || return 1
                fi
                ;;
            app)
                running="$enabled"
                if [[ "$running" == running && -d "$ORIGINAL_APP" ]] && ! pgrep -x 'iPad随航' >/dev/null 2>&1; then
                    open -a "$ORIGINAL_APP" --args --background || return 1
                fi
                ;;
            *) echo "保存的原版状态无效，请检查 $STATE" >&2; return 1 ;;
        esac
    done < "$STATE"
    rm -f -- "$STATE"
}

if [[ "$MODE" == original ]]; then
    stop_test
    restore_original
    echo "已切换回原版 2.4，测试版仍保留在应用程序中。"
    exit 0
fi

[[ -d "$TEST_APP" && -x "$SUPPORT/ipad-watchdog" ]] || { echo "请先安装 Test 版。" >&2; exit 1; }
[[ -f "$AGENTS/com.local.ipad-watchdog-test.plist" && -f "$AGENTS/com.local.ipad-sidecar-test-ui.plist" ]] || {
    echo "测试版后台服务缺失，请重新运行安装。" >&2; exit 1;
}
disabled_services=$(launchctl print-disabled "$GUI") || { echo "无法读取后台服务状态。" >&2; exit 1; }
if [[ ! -f "$STATE" ]]; then
    state_tmp=$(mktemp "$SUPPORT/.original-services.XXXXXX")
    for label in "${ORIGINAL_LABELS[@]}"; do
        enabled=enabled
        loaded=unloaded
        if printf '%s\n' "$disabled_services" | grep -Fq "\"$label\" => disabled"; then enabled=disabled; fi
        if launchctl print "$GUI/$label" >/dev/null 2>&1; then loaded=loaded; fi
        printf '%s %s %s\n' "$label" "$enabled" "$loaded" >> "$state_tmp"
    done
    if pgrep -x 'iPad随航' >/dev/null 2>&1; then
        echo 'app running -' >> "$state_tmp"
    else
        echo 'app stopped -' >> "$state_tmp"
    fi
    mv "$state_tmp" "$STATE"
fi

# 切换失败时尝试恢复原来的服务，避免留下没有可用界面的状态。
activation_complete=false
rollback() {
    if [[ "$activation_complete" != true ]]; then
        echo "切换未完成，正在恢复原版服务……" >&2
        stop_test || true
        restore_original || true
    fi
}
trap 'rollback; rmdir "$LOCK" 2>/dev/null || true' EXIT
for label in "${ORIGINAL_LABELS[@]}"; do
    launchctl disable "$GUI/$label"
    if launchctl print "$GUI/$label" >/dev/null 2>&1; then
        launchctl bootout "$GUI/$label"
    fi
done
stop_app 'iPad随航'
touch "$SUPPORT/test-active"
for label in "${TEST_LABELS[@]}"; do
    launchctl enable "$GUI/$label"
    if ! launchctl print "$GUI/$label" >/dev/null 2>&1; then
        launchctl bootstrap "$GUI" "$AGENTS/$label.plist"
    fi
    launchctl print "$GUI/$label" >/dev/null
done
activation_complete=true
echo "已切换到 Test 版。原版后台服务已暂停，使用「恢复原版.command」可切回。"
