#!/bin/bash
#
# 发布 site/public 为公网网站
#
# 现状(2026-09-20): 已用 --temporary 匿名账号部署成功:
#   https://breakreminder.ringed-deltadeltadromeus.workers.dev 见下方输出
#   但 *.workers.dev 在国内被 DNS 污染/阻断, 直连不可用(代理可用)。
#
# 【正式方案: 自有域名, 国内可直连】
#   1) 注册域名(如 .com, Cloudflare Registrar 成本价 ~$10/年, 或腾讯云/阿里云)
#      并把域名 NS 托管到 Cloudflare(注册商处改 NS, Cloudflare 有引导);
#   2) 一次性登录免费 Cloudflare 账号:
#        npx wrangler login
#   3) 重新部署并绑定自有域名:
#        bash site/pack.sh && bash site/deploy.sh
#      然后在 Cloudflare 控制台 Workers & Pages → breakreminder → Domains
#      添加你的域名(NS 已托管时自动配证书与解析, 数分钟生效)。
#      自定义域名不经过 workers.dev, 国内一般可直连。
#
# 【备选: 自有云服务器】把 site/public 内容放到 web 根目录:
#        rsync -av --delete site/public/ user@your-server:/var/www/breakreminder/
#
set -euo pipefail
cd "$(dirname "$0")"

npx --yes wrangler deploy
echo
echo "部署完成。已登录正式账号时, 记得到控制台给 Worker 绑定自有域名。"
