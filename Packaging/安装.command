#!/bin/bash
cd "$(dirname "$0")" || exit 1
clear
echo "════════════════════════════════════════"
echo "   iPad 随航工具集 —— 安装"
echo "════════════════════════════════════════"
echo ""
# 去掉下载隔离标记，否则脚本内部调用会被拦
xattr -dr com.apple.quarantine . 2>/dev/null || true
bash ./install.sh
echo ""
echo "════════════════════════════════════════"
read -n 1 -s -r -p "按任意键关闭窗口..."
echo ""
