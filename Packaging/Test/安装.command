#!/bin/bash
cd "$(dirname "$0")" || exit 1
echo "安装 iPad 随航 Test"
bash ./install.sh
result=$?
echo ""
if [ "$result" -ne 0 ]; then echo "安装未完成，请保留上面的错误信息。"; fi
read -n 1 -s -r -p "按任意键关闭窗口..."
echo ""
exit "$result"
