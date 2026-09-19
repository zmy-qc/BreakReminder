#!/bin/bash
# 打包最新 App → site/public/ (Cloudflare 用) 并同步到 docs/ (GitHub Pages 用)
set -euo pipefail
cd "$(dirname "$0")/.."

bash build.sh

mkdir -p site/public
rm -f site/public/BreakReminder.zip site/public/index.html

ditto -c -k --sequesterRsrc --keepParent build/BreakReminder.app site/public/BreakReminder.zip
cp site/index.html site/public/index.html

SHA=$(shasum -a 256 site/public/BreakReminder.zip | awk '{print $1}')
python3 - "$SHA" <<'PY'
import sys, re
sha = sys.argv[1]
p = "site/public/index.html"
s = open(p, encoding="utf-8").read()
s = re.sub(r'(<code class="sha">)[0-9a-f]{64}(</code>)', r'\g<1>' + sha + r'\g<2>', s)
open(p, "w", encoding="utf-8").write(s)
PY

rm -rf docs
mkdir docs
cp site/public/index.html site/public/BreakReminder.zip docs/

echo "打包完成: site/public/ 与 docs/"
echo "  大小: $(du -h docs/BreakReminder.zip | awk '{print $1}')  SHA-256: $SHA"
