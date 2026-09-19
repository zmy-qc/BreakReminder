#!/bin/bash
# 卸载 BreakReminder.app
set -euo pipefail
pkill -x BreakReminder 2>/dev/null || true
rm -rf "/Applications/BreakReminder.app" "$HOME/Applications/BreakReminder.app"
echo "已卸载 (登录项由系统自动清理, 也可在 系统设置→通用→登录项 手动删除)"
echo "日志 ~/Library/Logs/BreakReminder.log 可手动删除"
