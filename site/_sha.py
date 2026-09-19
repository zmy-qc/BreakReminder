import sys, re

cls, sha, p = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding="utf-8").read()
s = re.sub(r'(<code class="' + cls + r'">)[0-9a-f]{64}(</code>)', r'\g<1>' + sha + r'\g<2>', s)
open(p, "w", encoding="utf-8").write(s)
