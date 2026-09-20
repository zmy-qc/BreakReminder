# BreakReminder — 每小时强制休息 5 分钟（macOS + Windows）

**在线下载：https://zmy-qc.github.io/BreakReminder/** （仓库 https://github.com/zmy-qc/BreakReminder）

连续工作满 1 小时 → 弹窗提示「连续工作一小时，请休息一下」→ 播放系统自带屏保
5 分钟 → 结束休息、重新计时。macOS 版为菜单栏 App（通用二进制，拷到其他 Mac
直接用）；Windows 版为单文件 exe（约 20 KB，Win10/11 自带运行时，零依赖）。

## 更新发布流程

改完代码执行 `bash site/pack.sh`（重新打包双平台并同步 docs/），然后提交推送
`git push`，GitHub Pages（main 分支 /docs）约 1 分钟后自动更新。

## Windows 版

见 `windows/`：`Program.cs`（C# WinForms，.NET Framework 4.8）+ `build.bat`。
在 Windows 上双击 `build.bat` 用系统自带编译器即可重新生成 exe；或直接使用
发布包里的 `BreakReminder-Windows.zip`。行为与 macOS 版一致，差异：Windows
上屏保是普通进程，休息到点程序直接关闭屏保恢复桌面（不必等键鼠输入）。

## 日常使用

本机已装在 `/Applications/BreakReminder.app`，开机自启，菜单栏有一个 ☕ 图标：

- 点开可看「已连续工作 X / 60 分钟」「距下次休息还有 Y 分钟」
- **立即休息** / **重新计时** / **暂停监控**
- **设置…**：工作时长、休息时长、空闲重置阈值、提示框超时、放行次数、提示音
- **开机自启**：开关（SMAppService 登录项）
- 退出后重新启动：`open /Applications/BreakReminder.app`

日志：`~/Library/Logs/BreakReminder.log`

## 工作规则（默认值，设置中可改）

- **连续工作** = 键鼠有活动的时间（`CGEventSource` 查空闲，无需任何权限）。
  空闲 ≥ 5 分钟视为已休息过，累计清零，回来重新计。
- 满 60 分钟弹提示框：点「马上休息」或超时（默认 30 秒）→ 开始休息；
  点「跳过本次」/ Esc → 跳过当次重新计时。
- **休息**：`open` 拉起系统屏保（即「系统设置 → 屏幕保护程序」选中的动画），
  期间每 5 秒补拉——被关掉立刻回来，保持满 5 分钟。
- **放行**：屏保只能被键鼠输入关掉，休息期间检测到键鼠活动记一次"打断"，
  累计 3 次放行，防止有急事被锁死。
- **恢复**：时间到不再拉屏保。人在座动一下即恢复；不在座屏保保持，
  回来一碰即消失（与系统空闲屏保一致）。

> macOS 26 (Tahoe) 实测：ScreenSaverEngine 二进制只是触发器（直接 exec 会被
> SIGKILL），屏保由会话层托管、无编程关闭接口（杀进程/caffeinate/DO 通道均无效），
> 以上"补拉 + 打断计数"即为据此设计的等价实现。旧版 macOS 行为相同。

## 在其他 Mac 上使用

1. 拷贝 `/Applications/BreakReminder.app`（U 盘/AirDrop 均可）到目标 Mac；
2. 要求 macOS 13+（Ventura），Intel / Apple Silicon 都行；
3. 因无开发者证书，首次打开：**右键 App → 打开 → 打开**（绕过 Gatekeeper，
   只需一次）；或系统设置 → 隐私与安全性里点"仍要打开"；
4. 打开后同样自动注册开机自启，设置各自独立存储。

源码构建（目标机装了 Xcode Command Line Tools 即可）：

```bash
bash build.sh        # 产出 build/BreakReminder.app
bash install.sh      # 构建并装到 /Applications, 启动
bash uninstall.sh    # 卸载
```



## 发布到自有网站（可选）

`site/` 是一个完整的静态下载站（首页 + 安装包 + 校验和）：

```bash
bash site/pack.sh      # 构建 App → site/public/ (index.html + BreakReminder.zip + SHA-256)
bash site/deploy.sh    # 部署到 Cloudflare (首次先 npx wrangler login)
```

- 2026-09-20 已用临时账号部署验证过流程：
  `https://breakreminder.ringed-deltadromeus.workers.dev`（全球可访问；
  但 `*.workers.dev` 国内被 DNS 污染，直连不通，代理可用）
- **正式使用**：注册一个域名（~¥70/年）+ 免费 Cloudflare 账号，NS 托管后
  在 Worker 的 Domains 里绑定自己的域名——自定义域名国内一般可直连；
- 备选：自有服务器 `rsync -av site/public/ user@server:/var/www/...` + DNS 指向；
- 下载的 App 无开发者签名，目标 Mac 首次打开：右键 → 打开；若提示"已损坏"
  执行 `xattr -cr /Applications/BreakReminder.app`（页面上有说明）；
- 本地预览：`python3 -m http.server 8000 -d site/public` → http://127.0.0.1:8000

## 文件

- `BreakReminderApp.swift` — 菜单栏应用源码（单文件，swiftc 直接编译）
- `make_icon.swift` — App 图标生成（iconset → icns）
- `Info.plist` / `build.sh` / `install.sh` / `uninstall.sh`
- `BreakReminder.swift` — 旧版命令行守护进程（保留备用，无菜单栏）
