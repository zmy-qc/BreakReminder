//
//  BreakReminderApp.swift
//  菜单栏常驻应用: 连续工作满 1 小时 → 弹窗提示 → 播放系统屏保 5 分钟 → 恢复
//
//  构建: bash build.sh   (通用二进制 arm64 + x86_64, 组装 BreakReminder.app)
//

import AppKit
import CoreGraphics
import ServiceManagement

// MARK: - 日志 (追加写入 ~/Library/Logs/BreakReminder.log)

private let logLock = NSLock()
private let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm:ss"
    return f
}()
private let logFileURL = URL(fileURLWithPath:
    NSString(string: "~/Library/Logs/BreakReminder.log").expandingTildeInPath)

func log(_ msg: String) {
    logLock.lock()
    defer { logLock.unlock() }
    let data = "[\(logFormatter.string(from: Date()))] \(msg)\n".data(using: .utf8)!
    if let h = try? FileHandle(forWritingTo: logFileURL) {
        defer { try? h.close() }
        h.seekToEndOfFile()
        h.write(data)
    } else {
        try? data.write(to: logFileURL)
    }
}

// MARK: - 配置 (UserDefaults, 域 = bundle id com.zmy.breakreminder)

struct Config {
    var workSeconds: Double
    var breakSeconds: Double
    var idleResetSeconds: Double
    var dialogTimeout: Double
    var maxDismisses: Int
    var sound: Bool

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "workMin": 60.0,
            "breakMin": 5.0,
            "idleResetMin": 5.0,
            "dialogTimeoutSec": 30.0,
            "dismissSkip": 3,
            "soundOn": true,
        ])
    }

    static func load() -> Config {
        let d = UserDefaults.standard
        func minutes(_ key: String) -> Double { d.double(forKey: key) * 60 }
        return Config(
            workSeconds: minutes("workMin"),
            breakSeconds: minutes("breakMin"),
            idleResetSeconds: minutes("idleResetMin"),
            dialogTimeout: max(3, d.double(forKey: "dialogTimeoutSec")),
            maxDismisses: max(1, d.integer(forKey: "dismissSkip")),
            sound: d.bool(forKey: "soundOn")
        )
    }
}

// MARK: - 系统空闲与屏保 (无需任何权限)

func systemIdleSeconds() -> Double {
    // kCGAnyInputEventType(~0): 距最近一次任意键鼠事件的秒数
    guard let anyEvent = CGEventType(rawValue: ~0) else { return 0 }
    return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
}

let screensaverBundleCandidates = [
    "/System/Library/CoreServices/ScreenSaverEngine.app",                               // macOS 26+
    "/System/Library/Frameworks/ScreenSaver.framework/Resources/ScreenSaverEngine.app", // 旧版本位置
]

func startScreensaver() {
    // macOS 26 (Tahoe) 实测: 引擎二进制是 arm64e 触发器, 直接 exec 会被 SIGKILL,
    // 必须经 LaunchServices 用 open 启动; 屏保已在运行时 open 为空操作;
    // 屏保动画由会话层托管, 无法编程关闭, 只能被真实键鼠输入关掉。
    guard let bundle = screensaverBundleCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
        log("未找到 ScreenSaverEngine")
        return
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = [bundle]
    do { try p.run() } catch { log("open 屏保失败: \(error.localizedDescription)") }
}

// MARK: - 设置窗口 (纯代码构建)

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let onSave: () -> Void
    var onClose: () -> Void = {}
    private var numberFields: [String: NSTextField] = [:]
    private var soundCheck: NSButton!

    init(config: Config, onSave: @escaping () -> Void) {
        self.onSave = onSave
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        win.title = "BreakReminder 设置"
        super.init(window: win)
        win.delegate = self

        func lbl(_ s: String) -> NSTextField {
            let t = NSTextField(labelWithString: s)
            t.font = .systemFont(ofSize: 13)
            return t
        }
        func num(_ key: String, _ v: Double) -> NSTextField {
            let f = NSTextField(string: String(format: "%g", v))
            f.font = .systemFont(ofSize: 13)
            f.alignment = .right
            numberFields[key] = f
            return f
        }
        func unit(_ s: String) -> NSTextField {
            let t = NSTextField(labelWithString: s)
            t.font = .systemFont(ofSize: 12)
            t.textColor = .secondaryLabelColor
            return t
        }

        let grid = NSGridView(views: [
            [lbl("连续工作时长"),        num("workMin", config.workSeconds / 60),        unit("分钟")],
            [lbl("休息(屏保)时长"),      num("breakMin", config.breakSeconds / 60),      unit("分钟")],
            [lbl("空闲多久算已休息过"),  num("idleResetMin", config.idleResetSeconds / 60), unit("分钟")],
            [lbl("提示框超时"),          num("dialogTimeoutSec", config.dialogTimeout),  unit("秒")],
            [lbl("键鼠打断几次后放行"),  num("dismissSkip", Double(config.maxDismisses)), unit("次")],
        ])
        grid.column(at: 0).xPlacement = .leading
        grid.rowSpacing = 10
        grid.columnSpacing = 12

        soundCheck = NSButton(checkboxWithTitle: "触发时播放提示音", target: nil, action: nil)
        soundCheck.state = config.sound ? .on : .off

        let save = NSButton(title: "保存", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"

        let box = NSStackView(views: [grid, soundCheck, save])
        box.orientation = .vertical
        box.spacing = 18
        box.translatesAutoresizingMaskIntoConstraints = false
        win.contentView = box
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: win.contentView!.topAnchor, constant: 24),
            box.bottomAnchor.constraint(equalTo: win.contentView!.bottomAnchor, constant: -24),
            box.leadingAnchor.constraint(equalTo: win.contentView!.leadingAnchor, constant: 24),
            box.trailingAnchor.constraint(equalTo: win.contentView!.trailingAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    @objc private func save() {
        let d = UserDefaults.standard
        func clamp(_ key: String, _ lo: Double, _ hi: Double) {
            let raw = Double(numberFields[key]!.stringValue.trimmingCharacters(in: .whitespaces)) ?? lo
            d.set(min(hi, max(lo, raw)), forKey: key)
        }
        clamp("workMin", 1, 480)
        clamp("breakMin", 0.5, 60)
        clamp("idleResetMin", 1, 120)
        clamp("dialogTimeoutSec", 3, 300)
        let skip = Int(numberFields["dismissSkip"]!.stringValue) ?? 3
        d.set(min(10, max(1, skip)), forKey: "dismissSkip")
        d.set(soundCheck.state == .on, forKey: "soundOn")
        onSave()
        log("设置已保存")
        window?.close()
    }

    func windowWillClose(_ notification: Notification) { onClose() }
}

// MARK: - 应用主体

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = Config.load()
    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var remainLine: NSMenuItem!
    private var pauseItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var settingsWC: SettingsWindowController?

    private var accumulated: Double = 0     // 本轮"连续工作"累计秒数
    private var lastTick = Date()
    private var paused = false
    private var inBreak = false
    private var activityToken: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 禁用 App Nap, 保证计时/补拉屏保的节奏稳定(仍允许系统空闲睡眠)
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "BreakReminder 工作时长监控")
        buildMenu()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.onTick() }
        RunLoop.main.add(t, forMode: .common)
        autoRegisterLoginItemIfNeeded()
        log(String(format: "BreakReminder 启动 | 工作 %.0f 分钟 | 屏保 %.0f 分钟 | 空闲清零 %.0f 分钟",
                   config.workSeconds / 60, config.breakSeconds / 60, config.idleResetSeconds / 60))
        updateMenu()
    }

    // ---------------- 主计时循环

    private func onTick() {
        guard !inBreak && !paused else { updateMenu(); return }
        let now = Date()
        let dt = min(now.timeIntervalSince(lastTick), 2)   // 防跳变
        lastTick = now
        let idle = systemIdleSeconds()

        if idle >= config.idleResetSeconds {
            if accumulated > 60 {
                log(String(format: "键鼠空闲 %.0f 分钟, 视为已休息过, 累计 %.0f 分钟清零",
                           idle / 60, accumulated / 60))
            }
            accumulated = 0
        } else {
            accumulated += dt
        }
        updateMenu()
        if accumulated >= config.workSeconds {
            triggerAutoBreak()
        }
    }

    // ---------------- 菜单栏

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "BreakReminder 休息提醒"

        let m = NSMenu()
        statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        remainLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        m.addItem(statusLine)
        m.addItem(remainLine)
        m.addItem(.separator())

        let rest = m.addItem(withTitle: "立即休息", action: #selector(restNow), keyEquivalent: "r")
        rest.target = self
        let reset = m.addItem(withTitle: "重新计时", action: #selector(resetTimer), keyEquivalent: "")
        reset.target = self
        pauseItem = m.addItem(withTitle: "暂停监控", action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        m.addItem(.separator())

        let prefs = m.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        loginItem = m.addItem(withTitle: "开机自启", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        m.addItem(.separator())

        let quit = NSMenuItem(title: "退出 BreakReminder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.addItem(quit)

        statusItem.menu = m
    }

    private func updateMenu() {
        let totalMin = Int(config.workSeconds / 60)
        if inBreak {
            statusLine.title = "☕ 休息中…"
            remainLine.isHidden = true
        } else if paused {
            statusLine.title = "监控已暂停"
            remainLine.isHidden = true
        } else {
            let m = Int(accumulated / 60)
            statusLine.title = "已连续工作 \(m) / \(totalMin) 分钟"
            remainLine.title = "距下次休息还有 \(max(0, totalMin - m)) 分钟"
            remainLine.isHidden = false
        }
        pauseItem.title = paused ? "恢复监控" : "暂停监控"
        let symbol = inBreak ? "moon.zzz.fill" : (paused ? "pause.circle" : "cup.and.saucer")
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "BreakReminder")
    }

    // ---------------- 菜单动作

    @objc private func restNow() {
        guard !inBreak else { return }
        log("手动开始休息")
        inBreak = true
        accumulated = 0
        lastTick = Date()
        updateMenu()
        startBreakLoop()
    }

    @objc private func resetTimer() {
        accumulated = 0
        lastTick = Date()
        log("手动重新计时")
        updateMenu()
    }

    @objc private func togglePause() {
        paused.toggle()
        lastTick = Date()
        log(paused ? "监控已暂停" : "监控已恢复")
        updateMenu()
    }

    @objc private func openSettings() {
        if settingsWC == nil {
            settingsWC = SettingsWindowController(config: config) { [weak self] in
                guard let self else { return }
                self.config = Config.load()
                self.updateMenu()
            }
            settingsWC!.onClose = { [weak self] in self?.settingsWC = nil }
        }
        settingsWC?.windowCenterAndShow()
    }

    // ---------------- 开机自启 (SMAppService, macOS 13+)

    private func loginItemEnabled() -> Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    @objc private func toggleLoginItem() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if loginItemEnabled() {
                try SMAppService.mainApp.unregister()
                log("已取消开机自启")
            } else {
                try SMAppService.mainApp.register()
                log("已开启开机自启")
            }
        } catch {
            log("登录项切换失败: \(error.localizedDescription)")
        }
        loginItem.state = loginItemEnabled() ? .on : .off
    }

    /// 首次成功启动时自动注册开机自启(仅当 app 位于 /Applications 等正规位置才会成功)
    private func autoRegisterLoginItemIfNeeded() {
        if UserDefaults.standard.bool(forKey: "didAutoRegisterLogin") {
            loginItem.state = loginItemEnabled() ? .on : .off
            return
        }
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: "didAutoRegisterLogin")
                log("已自动注册开机自启 (菜单中可关闭)")
            } catch {
                // 不在 /Applications 等位置时注册失败, 不记 flag, 装到正式位置后首启会再试
                log("开机自启注册暂不可用: \(error.localizedDescription)")
            }
        }
        loginItem.state = loginItemEnabled() ? .on : .off
    }

    // ---------------- 休息流程

    private func triggerAutoBreak() {
        guard !inBreak else { return }
        inBreak = true
        accumulated = 0
        updateMenu()
        if config.sound { NSSound(named: "Glass")?.play() }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "连续工作一小时，请休息一下 ☕"
        alert.informativeText = String(
            format: "接下来播放系统屏保 %.0f 分钟；休息期间键鼠活动 %d 次后放行。",
            config.breakSeconds / 60, config.maxDismisses)
        alert.addButton(withTitle: "马上休息")
        alert.addButton(withTitle: "跳过本次")

        var timedOut = false
        let timeoutTimer = Timer(timeInterval: config.dialogTimeout, repeats: false) { _ in
            timedOut = true
            NSApp.stopModal(withCode: .alertFirstButtonReturn)   // 超时未响应 → 视为开始休息
        }
        RunLoop.main.add(timeoutTimer, forMode: .common)
        let resp = alert.runModal()
        timeoutTimer.invalidate()

        if resp == .alertFirstButtonReturn {
            log(timedOut ? "提示框超时, 自动开始休息" : "用户选择马上休息")
            startBreakLoop()
        } else {
            log("用户跳过本次休息")
            inBreak = false
            lastTick = Date()
            updateMenu()
        }
    }

    /// 休息主体(后台线程): 周期补拉屏保保持时长; 键鼠活动累计 N 次放行
    private func startBreakLoop() {
        log("开始休息: 系统屏保 \(Int(config.breakSeconds)) 秒 (被关掉会自动重新拉起)")
        startScreensaver()
        let cfg = config
        Thread.detachNewThread {
            let breakStart = Date()
            var strikes = 0
            while true {
                let remaining = cfg.breakSeconds - Date().timeIntervalSince(breakStart)
                if remaining <= 0 { break }
                Thread.sleep(forTimeInterval: min(5, remaining))
                if Date().timeIntervalSince(breakStart) >= cfg.breakSeconds { break }
                // 屏保只能被键鼠输入关掉 → 休息期间的键鼠活动 = 用户在打断休息
                if systemIdleSeconds() < 5 {
                    strikes += 1
                    if strikes >= cfg.maxDismisses {
                        log("休息期间检测到 \(strikes) 次键鼠活动, 放行")
                        break
                    }
                    log("休息期间检测到键鼠活动 (\(strikes)/\(cfg.maxDismisses)), 重新拉起屏保")
                }
                startScreensaver()   // 已在运行时为空操作
            }
            DispatchQueue.main.async { self.breakEnded() }
        }
    }

    private func breakEnded() {
        inBreak = false
        accumulated = 0
        lastTick = Date()
        log("休息结束, 已恢复正常 (若人不在座, 屏保会在下次触碰键鼠时消失)")
        updateMenu()
    }
}

extension SettingsWindowController {
    func windowCenterAndShow() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - main

Config.registerDefaults()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
