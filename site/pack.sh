#!/bin/bash
# 打包 macOS + Windows 两个安装包 → site/public/ (Cloudflare 用) 并同步 docs/ (GitHub Pages 用)
# 依赖: swiftc(系统) + dotnet(~/dotnet, 编译 Windows 版用)
set -euo pipefail
cd "$(dirname "$0")/.."

# ---- macOS ----
bash build.sh

# ---- Windows (交叉编译 net48, 仅 IL 无本机代码) ----
export PATH="$HOME/dotnet:$PATH"
if [ -x "$HOME/dotnet/dotnet" ]; then
    (cd windows && dotnet build -v q)
else
    echo "警告: 未安装 dotnet (~/dotnet), 跳过 Windows 版打包"
fi

# ---- 组装发布目录 ----
mkdir -p site/public
rm -f site/public/*.zip site/public/index.html

ditto -c -k --sequesterRsrc --keepParent build/BreakReminder.app site/public/BreakReminder-macOS.zip

if [ -f windows/bin/Debug/net48/BreakReminder.exe ]; then
    STAGE=$(mktemp -d)
    cp windows/bin/Debug/net48/BreakReminder.exe "$STAGE/"
    printf '\xEF\xBB\xBF' > "$STAGE/README.txt"
    printf 'BreakReminder Windows 版\n\n双击 BreakReminder.exe 运行, 托盘出现图标。\n要求 Windows 10/11 (系统自带 .NET Framework 4.8, 无需安装其他)。\nSmartScreen 拦截时: 更多信息 → 仍要运行。\n右键托盘图标可开启开机自启。\n' >> "$STAGE/README.txt"
    (cd "$STAGE" && zip -q -r "$OLDPWD/site/public/BreakReminder-Windows.zip" BreakReminder.exe README.txt)
    rm -rf "$STAGE"
fi

cp site/index.html site/public/index.html

# ---- 注入校验和 ----
inject() {  # $1=zip文件  $2=html中的class
    local SHA
    SHA=$(shasum -a 256 "site/public/$1" | awk '{print $1}')
    python3 site/_sha.py "$2" "$SHA" site/public/index.html
}
inject BreakReminder-macOS.zip sha
[ -f site/public/BreakReminder-Windows.zip ] && inject BreakReminder-Windows.zip sha-win

# ---- 同步到 docs/ (GitHub Pages) ----
rm -rf docs
mkdir docs
cp site/public/* docs/

echo "打包完成: site/public/ 与 docs/"
ls -la docs/
