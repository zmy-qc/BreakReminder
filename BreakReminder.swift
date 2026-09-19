//
//  BreakReminder.swift
//  连续工作满 1 小时 → 弹窗提示 → 播放系统屏保 5 分钟 → 恢复正常
//
//  手动运行: ./BreakReminder [--work-min 60 --break-min 5 ...]
//  编译:     swiftc -O BreakReminder.swift -o BreakReminder
//

import Foundation
import CoreGraphics

// ---------------------------------------------------------------- 全局状态

var stopRequested = false   // 收到 SIGINT/SIGTERM 后置位, 主循环检测到即退出

let logTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm:ss"
    return f
}()

func log(_ msg: String) {
    print("[\(logTimeFormatter.string(from: Date()))] \(msg)")
    fflush(stdout)
}

/// 分步睡眠, 便于及时响应退出请求
func interruptibleSleep(_ seconds: Double) {
    var left = seconds
    while left > 0 && !stopRequested {
        Thread.sleep(forTimeInterval: min(0.3, left))
        left -= 0.3
    }
}

// ---------------------------------------------------------------- 配置

struct Config {
    var workSeconds          = 60.0 * 60   // 连续工作多久触发休息
    var breakSeconds         = 5.0  * 60   // 屏保保持多久
    var idleResetSeconds     = 5.0  * 60   // 键鼠空闲达到该时长 → 视为已主动休息, 累计清零
    var dialogTimeoutSeconds = 30.0        // 提示框等待超时, 超时视为"马上休息"
    var maxDismisses         = 3           // 屏保被手动关掉达到此次数 → 提前结束休息
    var pollSeconds          = 5.0
    var sound                = true
    var verbose              = false
}

func usage() {
    print("""
    BreakReminder — 连续工作满 1 小时提醒休息, 播放系统屏保 5 分钟后恢复

    用法: BreakReminder [选项]
      --work-min <分钟>       连续工作时长(触发休息), 默认 60
      --break-min <分钟>      休息(屏保)时长, 默认 5
      --idle-reset-min <分钟> 键鼠空闲多久算"已休息过"并清零累计, 默认 5
      --dialog-timeout <秒>   提示框等待超时, 超时直接开始休息, 默认 30
      --dismiss-skip <次>     屏保被手动关闭达到此次数后放行, 默认 3
      --poll-sec <秒>         检测周期, 默认 5
      --no-sound              不播放提示音
      --verbose               每个周期都打印状态(调试用)
      --help                  显示本帮助

    示例:
      ./BreakReminder                              # 60 分钟工作 / 5 分钟屏保
      ./BreakReminder --work-min 45 --break-min 3  # 45 分钟工作 / 3 分钟屏保
    """)
}

func exitUsage(_ msg: String) -> Never {
    FileHandle.standardError.write(("参数错误: \(msg)\n").data(using: .utf8)!)
    usage()
    exit(2)
}

func parseArgs() -> Config {
    var cfg = Config()
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    func value(_ flag: String) -> String {
        i += 1
        guard i < args.count else { exitUsage("\(flag) 缺少参数值") }
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "--work-min":
            guard let v = Double(value("--work-min")), v > 0 else { exitUsage("--work-min 需为正数") }
            cfg.workSeconds = v * 60
        case "--break-min":
            guard let v = Double(value("--break-min")), v > 0 else { exitUsage("--break-min 需为正数") }
            cfg.breakSeconds = v * 60
        case "--idle-reset-min":
            guard let v = Double(value("--idle-reset-min")), v > 0 else { exitUsage("--idle-reset-min 需为正数") }
            cfg.idleResetSeconds = v * 60
        case "--dialog-timeout":
            guard let v = Double(value("--dialog-timeout")), v >= 3 else { exitUsage("--dialog-timeout 需为不小于 3 的秒数") }
            cfg.dialogTimeoutSeconds = v
        case "--dismiss-skip":
            guard let v = Int(value("--dismiss-skip")), v >= 1 else { exitUsage("--dismiss-skip 需为正整数") }
            cfg.maxDismisses = v
        case "--poll-sec":
            guard let v = Double(value("--poll-sec")), 0.5...60 ~= v else { exitUsage("--poll-sec 需在 0.5~60 之间") }
            cfg.pollSeconds = v
        case "--no-sound":
            cfg.sound = false
        case "--verbose":
            cfg.verbose = true
        case "--help", "-h":
            usage(); exit(0)
        default:
            exitUsage("未知选项 \(args[i])")
        }
        i += 1
    }
    return cfg
}

// ---------------------------------------------------------------- 系统空闲检测

func systemIdleSeconds() -> Double {
    // kCGAnyInputEventType(~0): 距最近一次任意键鼠事件的秒数, 无需任何系统权限
    guard let anyEvent = CGEventType(rawValue: ~0) else { return 0 }
    return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
}

// ---------------------------------------------------------------- 外部命令

func runOSA(_ script: String) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do {
        try p.run()
    } catch {
        return (-1, "启动 osascript 失败: \(error)")
    }
    p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (p.terminationStatus, out.trimmingCharacters(in: .whitespacesAndNewlines))
}

func playSound() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    p.arguments = ["/System/Library/Sounds/Glass.aiff"]
    Thread.detachNewThread {
        do { try p.run(); p.waitUntilExit() } catch { }
    }
}

// ---------------------------------------------------------------- 屏保控制
// macOS 26 (Tahoe) 的实测结论:
//   - ScreenSaverEngine 二进制只是"触发器", 直接 exec 会被系统 SIGKILL(arm64e 保护),
//     必须经 LaunchServices 用 open 启动; 屏保已在运行时 open 为空操作;
//   - 屏保动画由会话层(loginwindow)托管, 杀掉引擎进程、caffeinate -u 都无法关闭它,
//     只有真实的键鼠输入能让它消失。
// 因此休息流程的设计: 休息期间周期性 open 补拉屏保(被关掉会立刻回来, 实现"保持 N 分钟");
// 屏保只能被键鼠输入关掉, 休息期间检测到键鼠活动即视为"打断", 累计 maxDismisses 次放行。

func screensaverBundlePath() -> String? {
    let candidates = [
        "/System/Library/CoreServices/ScreenSaverEngine.app",                               // macOS 26+
        "/System/Library/Frameworks/ScreenSaver.framework/Resources/ScreenSaverEngine.app", // 旧版本位置
    ]
    return candidates.first { FileManager.default.fileExists(atPath: $0) }
}

@discardableResult
func startScreensaver() -> Bool {
    guard let bundle = screensaverBundlePath() else { return false }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = [bundle]
    do {
        try p.run()
        return true
    } catch {
        log("open 屏保失败: \(error.localizedDescription)")
        return false
    }
}

// ---------------------------------------------------------------- 休息流程

enum DialogChoice { case takeBreak, skip }

func askUser(_ cfg: Config) -> DialogChoice {
    let script = "display dialog \"连续工作一小时，请休息一下 ☕\" with title \"BreakReminder 休息提醒\" buttons {\"跳过本次\", \"马上休息\"} default button \"马上休息\" cancel button \"跳过本次\" with icon note giving up after \(Int(cfg.dialogTimeoutSeconds))"
    let (status, out) = runOSA(script)
    if status == 0 { return .takeBreak }   // 点了"马上休息", 或超时未响应
    if out.contains("canceled") || out.contains("cancel") || out.contains("取消") {
        log("用户选择: 跳过本次休息")
        return .skip
    }
    log("提示框异常 (status \(status): \(out)), 按开始休息处理")
    return .takeBreak
}

/// 执行一次完整休息流程, 返回 true 表示流程结束(正常完成或提前放行)
@discardableResult
func runBreak(cfg: Config) -> Bool {
    if cfg.sound { playSound() }

    if askUser(cfg) == .skip { return false }

    guard screensaverBundlePath() != nil else {
        log("找不到 ScreenSaverEngine, 改为静置等待 \(Int(cfg.breakSeconds)) 秒")
        interruptibleSleep(cfg.breakSeconds)
        return true
    }

    log("开始休息: 系统屏保 \(Int(cfg.breakSeconds)) 秒 (被关掉会自动重新拉起)")
    startScreensaver()

    let breakStart = Date()
    var strikes = 0

    while !stopRequested {
        interruptibleSleep(cfg.pollSeconds)
        if stopRequested { break }
        if Date().timeIntervalSince(breakStart) >= cfg.breakSeconds { break }

        // 屏保只能被键鼠输入关掉 → 休息期间的键鼠活动 = 用户在打断休息
        if systemIdleSeconds() < cfg.pollSeconds {
            strikes += 1
            if strikes >= cfg.maxDismisses {
                log("休息期间检测到 \(strikes) 次键鼠活动, 放行")
                break
            }
            log(String(format: "休息期间检测到键鼠活动 (%d/%d), 重新拉起屏保", strikes, cfg.maxDismisses))
        }

        startScreensaver()   // 屏保仍在运行时为空操作
    }

    log("休息结束, 已恢复正常 (若人不在座, 屏保会在下次触碰键鼠时消失)")
    return true
}

// ---------------------------------------------------------------- 主循环

let cfg = parseArgs()

signal(SIGINT) { _ in stopRequested = true }
signal(SIGTERM) { _ in stopRequested = true }

log(String(format: "BreakReminder 启动 | 工作 %.0f 分钟 | 屏保 %.0f 分钟 | 空闲清零 %.0f 分钟",
           cfg.workSeconds / 60, cfg.breakSeconds / 60, cfg.idleResetSeconds / 60))
if screensaverBundlePath() == nil {
    log("警告: 未找到 ScreenSaverEngine, 触发时将只静置等待")
}

var accumulated: Double = 0   // 本轮"连续工作"累计秒数
var lastTick = Date()
var lastStatus = Date()

while !stopRequested {
    interruptibleSleep(cfg.pollSeconds)
    if stopRequested { break }

    let now = Date()
    let dt = min(now.timeIntervalSince(lastTick), cfg.pollSeconds * 2)   // 进程被挂起时防跳变
    lastTick = now
    let idle = systemIdleSeconds()

    if idle >= cfg.idleResetSeconds {
        if accumulated > 60 {
            log(String(format: "键鼠空闲 %.0f 分钟, 视为已休息过, 累计 %.0f 分钟清零",
                       idle / 60, accumulated / 60))
        }
        accumulated = 0
        continue
    }

    accumulated += dt

    if cfg.verbose {
        log(String(format: "工作中: %.1f / %.0f 分钟 (idle %.0fs)",
                   accumulated / 60, cfg.workSeconds / 60, idle))
    } else if now.timeIntervalSince(lastStatus) >= 300 {
        log(String(format: "工作中: %.0f / %.0f 分钟 (idle %.0fs)",
                   accumulated / 60, cfg.workSeconds / 60, idle))
        lastStatus = now
    }

    if accumulated >= cfg.workSeconds {
        let completed = runBreak(cfg: cfg)
        log(completed ? "本轮休息完成, 重新累计" : "本轮休息被跳过, 重新累计")
        accumulated = 0
        lastTick = Date()
        lastStatus = Date()
    }
}

log("BreakReminder 退出")
