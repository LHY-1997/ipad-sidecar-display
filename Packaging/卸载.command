#!/bin/bash
cd "$(dirname "$0")" || exit 1
clear
echo "════════════════════════════════════════"
echo "   iPad 随航工具集 —— 卸载"
echo "════════════════════════════════════════"
echo ""
bash ./uninstall.sh
echo ""
read -n 1 -s -r -p "按任意键关闭窗口..."
echo ""
