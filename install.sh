#!/bin/bash
# 安装 BreakReminder.app 到 /Applications (无权限则装到 ~/Applications), 并启动
set -euo pipefail
cd "$(dirname "$0")"
./build.sh

# 清理旧版 CLI 的 LaunchAgent (如装过)
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.zmy.breakreminder.plist" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.zmy.breakreminder.plist"
rm -rf "$HOME/Applications/BreakReminder"   # 旧版 CLI 二进制目录

DEST="/Applications"
if [ ! -w "/Applications" ]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
fi

pkill -x BreakReminder 2>/dev/null || true
sleep 1
rm -rf "$DEST/BreakReminder.app"
cp -R "build/BreakReminder.app" "$DEST/BreakReminder.app"
open "$DEST/BreakReminder.app"

echo "已安装并启动: $DEST/BreakReminder.app"
echo "菜单栏会出现 ☕ 图标; 首次启动自动注册开机自启(菜单中可关闭)"
echo "日志: ~/Library/Logs/BreakReminder.log"
