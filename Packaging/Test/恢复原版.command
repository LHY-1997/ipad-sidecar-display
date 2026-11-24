#!/bin/bash
support="$HOME/Library/Application Support/ipad-watchdog-test"
bash "$support/activate.sh" original
result=$?
echo ""
read -n 1 -s -r -p "按任意键关闭窗口..."
echo ""
exit "$result"
