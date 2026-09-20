//
//  BreakReminderApp.swift
//  菜单栏常驻应用: 连续工作满 1 小时 → 弹窗提示 → 播放系统屏保 5 分钟 → 恢复
//
//  构建: bash build.sh   (通用二进制 arm64 + x86_64, 组装 BreakReminder.app)
//

import AppKit
import CoreGraphics
import UserNotifications
import ServiceManagement

// MARK: - 休息倒计时通知 (macOS 26 会话屏保渲染在特权合成层, 窗口无法盖在其上,
//        通知是唯一能显示在屏保之上的通道; 休息开始一条 + 每分钟"还剩 X 分钟")

final class BreakNotifier {
    static let shared = BreakNotifier()
    private var ids: [String] = []

    func requestIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    func begin(breakSeconds: Double) {
        cancel()
        let total = Int(breakSeconds)
        add(1, "☕ 休息开始 · \(total / 60) 分钟", "触碰键鼠随时结束休息")
        if total >= 120 {
            for m in stride(from: total / 60 - 1, through: 1, by: -1) {
                add(TimeInterval(total - m * 60), "还剩 \(m) 分钟", "触碰键鼠随时结束休息")
            }
        }
    }

    func cancel() {
        guard !ids.isEmpty else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        ids.removeAll()
    }

    private func add(_ after: TimeInterval, _ title: String, _ body: String) {
        let id = "breakreminder.\(Int(after))"
        ids.append(id)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .none   // 提示音已在触发时播放过
        let req = UNNotificationRequest(
            identifier: id, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: after, repeats: false))
        UNUserNotificationCenter.current().add(req)
    }
}

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
    var sound: Bool

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "workMin": 60.0,
            "breakMin": 5.0,
            "idleResetMin": 5.0,
            "dialogTimeoutSec": 5.0,
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
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
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
        d.set(soundCheck.state == .on, forKey: "soundOn")
        onSave()
        log("设置已保存")
        window?.close()
    }

    func windowWillClose(_ notification: Notification) { onClose() }
}

// MARK: - 居中倒计时弹窗 (大数字倒数 N 秒自动进入屏保)

final class BreakCountdownPanel: NSPanel {
    var onChoice: ((Bool) -> Void)?   // true = 进入休息
    private var numberLabel: NSTextField!
    private var timer: Timer?
    private var secondsLeft: Int

    init(timeout: Double, breakMinutes: Double) {
        secondsLeft = max(1, Int(timeout.rounded(.up)))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 216),
                   styleMask: [.nonactivatingPanel], backing: .buffered, defer: false)

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false

        let card = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 216))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(calibratedRed: 0.11, green: 0.14, blue: 0.20, alpha: 0.97).cgColor
        card.layer?.cornerRadius = 20

        let title = NSTextField(labelWithString: "☕ 连续工作一小时，请休息一下")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .white
        title.alignment = .center
        title.frame = NSRect(x: 24, y: 156, width: 332, height: 24)
        card.addSubview(title)

        numberLabel = NSTextField(labelWithString: "\(secondsLeft)")
        numberLabel.font = .monospacedDigitSystemFont(ofSize: 44, weight: .bold)
        numberLabel.textColor = NSColor(calibratedRed: 0.42, green: 0.66, blue: 1.0, alpha: 1)
        numberLabel.alignment = .center
        numberLabel.frame = NSRect(x: 24, y: 88, width: 332, height: 56)
        card.addSubview(numberLabel)

        let caption = NSTextField(labelWithString: String(format: "秒后自动进入屏保 · 本次休息 %.0f 分钟", breakMinutes))
        caption.font = .systemFont(ofSize: 11.5)
        caption.textColor = NSColor(calibratedWhite: 0.66, alpha: 1)
        caption.alignment = .center
        caption.frame = NSRect(x: 24, y: 62, width: 332, height: 20)
        card.addSubview(caption)

        let skip = makeButton("本次跳过", bg: NSColor(calibratedWhite: 0.20, alpha: 1),
                              fg: NSColor(calibratedWhite: 0.85, alpha: 1),
                              action: #selector(skipTapped))
        skip.frame = NSRect(x: 32, y: 18, width: 150, height: 34)
        card.addSubview(skip)

        let go = makeButton("进入休息", bg: NSColor(calibratedRed: 0.23, green: 0.55, blue: 0.97, alpha: 1),
                            fg: .white, action: #selector(goTapped))
        go.frame = NSRect(x: 198, y: 18, width: 150, height: 34)
        card.addSubview(go)

        contentView = card
    }

    private func makeButton(_ title: String, bg: NSColor, fg: NSColor, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.backgroundColor = bg.cgColor
        b.layer?.cornerRadius = 10
        b.layer?.masksToBounds = true
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: fg,
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
        ])
        return b
    }

    func startCountdown() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func tick() {
        secondsLeft -= 1
        if secondsLeft <= 0 {
            finish(true)   // 倒计时结束 → 自动进入休息
            return
        }
        numberLabel.stringValue = "\(secondsLeft)"
    }

    @objc private func goTapped()   { finish(true) }
    @objc private func skipTapped() { finish(false) }

    private func finish(_ take: Bool) {
        timer?.invalidate()
        timer = nil
        let cb = onChoice
        onChoice = nil
        close()
        cb?(take)
    }

    override var canBecomeKey: Bool { true }
}

// MARK: - 休息期间剩余时间浮层 (半透明, 点击完全穿透, 不遮挡屏保)

final class BreakOverlayPanel: NSPanel {
    private var label: NSTextField!
    private var timer: Timer?
    private let endTime: Date
    private var adaptTicks = 0

    init(breakSeconds: Double) {
        endTime = Date().addingTimeInterval(breakSeconds)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 50),
                   styleMask: [.nonactivatingPanel], backing: .buffered, defer: false)

        isFloatingPanel = true
        // 实测 macOS 26: loginwindow 托管的屏保窗口在 layer 2001~2004, 常规 screenSaver 层(1000)会被盖住
        level = NSWindow.Level(rawValue: 2100)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true   // 鼠标事件全部穿透给屏保
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        hidesOnDeactivate = false

        let card = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 50))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 0.72).cgColor
        card.layer?.cornerRadius = 25

        label = NSTextField(labelWithString: "休息中 · 还剩 0:00")
        label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.frame = card.bounds
        card.addSubview(label)
        contentView = card

        if let visible = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: visible.midX - 160, y: visible.minY + 48))
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        tick()
        orderFrontRegardless()
    }

    private func tick() {
        let left = max(0, endTime.timeIntervalSinceNow)
        let m = Int(left) / 60, s = Int(left) % 60
        label.stringValue = String(format: "休息中 · 还剩 %d:%02d", m, s)
        if adaptTicks < 10 { adaptTicks += 1; adaptLevel() }
        if left <= 0 { dismiss() }
    }

    /// 兜底自适应: 若探测到比 2100 更高的外部窗口层级(如系统升级后), 再往上压
    private var loggedDiag = false
    private func adaptLevel() {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return }
        let myPid = Int32(getpid())
        var maxLayer = 0
        for w in list {
            if let pid = w[kCGWindowOwnerPID as String] as? Int32, pid == myPid { continue }
            if let layer = w[kCGWindowLayer as String] as? Int, layer > maxLayer { maxLayer = layer }
        }
        if !loggedDiag {
            loggedDiag = true
            log("倒计时浮层层级诊断: 可见窗口 \(list.count) 个, 最高外部层级 \(maxLayer), 浮层层级 \(level.rawValue)")
        }
        let target = min(maxLayer + 1, 10_000)
        if level.rawValue < target {
            level = NSWindow.Level(rawValue: target)
            orderFrontRegardless()
            log("倒计时浮层: 探测到更高层级 \(maxLayer), 浮层已调至 \(target)")
        }
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        orderOut(nil)
    }

    override var canBecomeKey: Bool { false }
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
    private var breakOverlay: BreakOverlayPanel?
    private var activityToken: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 禁用 App Nap, 保证计时/补拉屏保的节奏稳定(仍允许系统空闲睡眠)
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "BreakReminder 工作时长监控")
        buildMenu()
        BreakNotifier.shared.requestIfNeeded()
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
        presentBreakDialog()
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
        presentBreakDialog()
    }

    /// 弹出居中倒计时确认卡 (自动触发与"立即休息"共用)
    private func presentBreakDialog() {
        if config.sound { NSSound(named: "Glass")?.play() }
        NSApp.activate(ignoringOtherApps: true)
        let panel = BreakCountdownPanel(timeout: config.dialogTimeout,
                                        breakMinutes: config.breakSeconds / 60)
        panel.onChoice = { [weak self] take in
            guard let self else { return }
            if take {
                log("开始休息 (倒计时结束/用户确认)")
                self.startBreakLoop()
            } else {
                log("用户选择: 本次跳过")
                self.inBreak = false
                self.lastTick = Date()
                self.updateMenu()
            }
        }
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.startCountdown()
    }

    /// 休息主体(后台线程): 拉起屏保保持到时长; 检测到键鼠活动立即结束
    private func startBreakLoop() {
        log("开始休息: 系统屏保 \(Int(config.breakSeconds)) 秒 (触碰键鼠立即结束)")
        startScreensaver()
        breakOverlay = BreakOverlayPanel(breakSeconds: config.breakSeconds)
        BreakNotifier.shared.begin(breakSeconds: config.breakSeconds)
        let cfg = config
        Thread.detachNewThread {
            let breakStart = Date()
            let grace: Double = 3   // 宽限期: 忽略点"进入休息"后手还没离开鼠标的余动
            var earlyExit = false
            while true {
                Thread.sleep(forTimeInterval: 0.5)
                let elapsed = Date().timeIntervalSince(breakStart)
                if elapsed >= cfg.breakSeconds { break }
                // 屏保只能被键鼠输入关掉 → 空闲时长很短 = 用户在动键鼠
                if systemIdleSeconds() < 1 {
                    if elapsed >= grace {
                        earlyExit = true
                        break
                    }
                    startScreensaver()   // 宽限期内被余动关掉, 重新拉起
                }
            }
            if earlyExit { log("检测到键鼠活动, 提前结束休息") }
            DispatchQueue.main.async { self.breakEnded() }
        }
    }

    private func breakEnded() {
        BreakNotifier.shared.cancel()
        breakOverlay?.dismiss()
        breakOverlay = nil
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
