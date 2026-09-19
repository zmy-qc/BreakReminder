#!/bin/bash
# 构建 BreakReminder.app (默认通用二进制 arm64 + x86_64, 便于拷贝到其他 Mac 直接使用)
set -euo pipefail
cd "$(dirname "$0")"
BUILD="$PWD/build"
APP="$BUILD/BreakReminder.app"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 图标
mkdir -p "$BUILD/icon.iconset"
swiftc -O make_icon.swift -o "$BUILD/make_icon"
"$BUILD/make_icon" "$BUILD/icon.iconset"
iconutil -c icns "$BUILD/icon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cp Info.plist "$APP/Contents/Info.plist"

BIN="$APP/Contents/MacOS/BreakReminder"
# Swift 6.3 新驱动不支持 -arch, 用 -target 分别编译两个架构再 lipo 合并
if swiftc -O -target arm64-apple-macos13.0  BreakReminderApp.swift -o "$BUILD/break_arm64" 2> "$BUILD/universal.err" && \
   swiftc -O -target x86_64-apple-macos13.0 BreakReminderApp.swift -o "$BUILD/break_x86_64" >> "$BUILD/universal.err" 2>&1 && \
   lipo -create "$BUILD/break_arm64" "$BUILD/break_x86_64" -output "$BIN"; then
    echo "二进制: 通用 (arm64 + x86_64)"
    rm -f "$BUILD/break_arm64" "$BUILD/break_x86_64"
else
    echo "警告: 通用二进制编译失败, 回退仅 arm64 (原因见 build/universal.err)"
    swiftc -O -target arm64-apple-macos13.0 BreakReminderApp.swift -o "$BIN"
fi

codesign --force --sign - "$APP"
echo "已构建: $APP"
