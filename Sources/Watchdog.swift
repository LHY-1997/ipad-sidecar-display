import Foundation
import ObjectiveC
import CoreGraphics
import Darwin

let IPAD_MODEL = DisplayInventory.ipadModel
/// 虚拟屏的 vendorID，和 VirtualScreen.swift 里注册的一致
let VIRTUAL_VENDOR = DisplayInventory.virtualVendor
/// 系统在没有任何可用屏时自己塞的兜底屏：1920×1080，vendor/model 是
/// ASCII 的 "unkn"/"virt"。拔掉实体屏后它会立刻顶上主屏位置，不能当实体屏。
let DUMMY_VENDOR = DisplayInventory.dummyVendor
let DUMMY_MODEL = DisplayInventory.dummyModel

func isDummy(_ id: CGDirectDisplayID) -> Bool {
    CGDisplayVendorNumber(id) == DUMMY_VENDOR || CGDisplayModelNumber(id) == DUMMY_MODEL
}

/// 给面板发一次「iPad 断了」的提示信号。同一个断开周期内只发一次。
func postNotifyOnce() {
    if !FileManager.default.fileExists(atPath: notifiedFile) {
        try? "1".write(toFile: notifiedFile, atomically: true, encoding: .utf8)
        try? "\(Date())".write(toFile: notifyFile, atomically: true, encoding: .utf8)
    }
}
let base = NSHomeDirectory() + "/Library/Application Support/ipad-watchdog"
let pauseFile = base + "/pause"
let logFile = base + "/watchdog.log"
let targetFile = base + "/target"
let lockFile = base + "/.lock"
/// 连接失败时写给面板的信号：让它弹一次说明，告诉用户可以暂停自动重连
let notifyFile = base + "/notify-disconnect"
/// 本次断开周期内已经提示过，避免每 10 秒弹一次
let notifiedFile = base + "/notified"
// MARK: - 基础 IO

func log(_ m: String) {
    let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"
    let line = "[\(f.string(from: Date()))] \(m)\n"
    if let h = FileHandle(forWritingAtPath: logFile) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    } else {
        try? line.write(toFile: logFile, atomically: true, encoding: .utf8)
    }
    if let s = try? String(contentsOfFile: logFile, encoding: .utf8) {
        let lines = s.components(separatedBy: "\n")
        if lines.count > 600 {
            try? lines.suffix(300).joined(separator: "\n").write(toFile: logFile, atomically: true, encoding: .utf8)
        }
    }
}

func loadTargetId() -> String {
    ((try? String(contentsOfFile: targetFile, encoding: .utf8)) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - 面板守护
// 虚拟屏由菜单栏面板在进程内持有，面板一挂虚拟屏就没了，系统退到 1080p 兜底屏。
// 这里每 10 秒兜一次：面板不在就拉起来，虚拟屏随之重建。
// 用户主动关掉虚拟屏（vdisplay.off）或主动退出面板（panel.off）时不干预。

let panelOffFile = base + "/panel.off"
let panelApp = "/Applications/iPad随航.app"
let panelBin = panelApp + "/Contents/MacOS/iPad随航"

func panelRunning() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-f", panelBin]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return true }   // 探测失败就当它在跑，别乱拉
    p.waitUntilExit()
    return p.terminationStatus == 0
}

func ensurePanelRunning() {
    if FileManager.default.fileExists(atPath: panelOffFile) { return }
    if panelRunning() { return }
    guard FileManager.default.fileExists(atPath: panelApp) else { return }
    log("面板进程不在，拉起（虚拟屏随之重建）")
    let o = Process()
    o.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    o.arguments = ["-a", panelApp, "--args", "--background"]
    o.standardOutput = FileHandle.nullDevice
    o.standardError = FileHandle.nullDevice
    try? o.run()
    o.waitUntilExit()
}

// MARK: - 单实例锁
// 一次连接流程最长要 35 秒（等回调 20 秒 + 等屏出现 15 秒），
// 而 LaunchAgent 每 10 秒就拉一个新进程。不加锁的话会有 3-4 个实例
// 同时对着同一台 iPad 发起连接，互相干扰还成倍制造弹窗。

func acquireLock() -> Bool {
    let fd = open(lockFile, O_CREAT | O_RDWR, 0o644)
    if fd < 0 { return false }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 { return false }
    return true   // fd 不关，进程退出时自动释放
}

// MARK: - 弹窗拦截
// 连接失败时系统会弹一个模态警告「无法连接 "xxx" 发生了其他错误 (-1010)」。
//
// 注意弹窗的进程：不是 SidecarDisplayAgent，而是 UserNotificationCenter。
// 早期的版本一直盯着 SidecarDisplayAgent 杀，所以从来没生效过。
// （另有一个叫 NotificationCenter 的进程是桌面小组件，别搞混。）
//
// 为什么只能杀不能点：点「好」按钮需要 AppleScript 或 Accessibility API。
// 实测在 LaunchAgent 环境下两者都没有权限（AXIsProcessTrusted = false，
// 读窗口返回 -25211），只有从终端直接跑才有。
//
// 杀掉的副作用：会连带清掉当前所有通知横幅。但 UserNotificationCenter 是按需
// 启动的，不会立刻自拉起，下次真有通知时 launchd 会重新拉它，系统不受影响。

/// Sidecar 弹窗的窗口特征：约 260x218，标题为空，只有一个「好」按钮。
/// 按尺寸过滤，避免误判成别的通知横幅（普通横幅更扁更宽）。
func hasPopupWindow() -> Bool {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] else { return false }
    for w in list {
        guard let owner = w[kCGWindowOwnerName as String] as? String,
              owner.contains("UserNotificationCenter") else { continue }
        guard let b = w[kCGWindowBounds as String] as? [String: Any],
              let width = b["Width"] as? Double,
              let height = b["Height"] as? Double else { continue }
        // 实测 Sidecar 弹窗是 260x218，接近方形。普通通知横幅是扁的（宽高比 3 以上），
        // 桌面层窗口（通知中心小组件）是全屏尺寸，都会被下面的条件排除。
        guard width >= 200, width <= 500, height >= 120, height <= 400 else { continue }
        let ratio = width / height
        if ratio >= 0.8, ratio <= 1.8 { return true }
    }
    return false
}

@discardableResult
func killPopupAgent() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    p.arguments = ["UserNotificationCenter"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
}

/// 发现弹窗就杀，确认窗口真的没了才收手。
/// 实测（11-23 21:43）：AX 点按钮这条路走不通——UserNotificationCenter 不暴露元素树，
/// 进程有辅助功能权限也读不到 AXRole，按钮点不了。只剩 killall：
/// 杀掉后弹窗 0.5 秒内消失，且不会自己回来。
func squashPopup() {
    killPopupAgent()
    for _ in 0..<3 {
        Thread.sleep(forTimeInterval: 0.3)
        if hasPopupWindow() { killPopupAgent() } else { break }
    }
}

// MARK: - Sidecar

func findIPad() -> CGDirectDisplayID? {
    var n: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &n)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    CGGetActiveDisplayList(n, &ids, &n)
    return ids.first { CGDisplayModelNumber($0) == IPAD_MODEL }
}

func makeMain(_ ipad: CGDirectDisplayID) -> Bool {
    let b = CGDisplayBounds(ipad)
    if CGDisplayIsMain(ipad) != 0 && b.origin == .zero { return true }
    var n: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &n)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    CGGetActiveDisplayList(n, &ids, &n)
    let dx = -b.origin.x, dy = -b.origin.y
    var ref: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&ref) == .success, let cfg = ref else { return false }
    for d in ids {
        let bb = CGDisplayBounds(d)
        _ = CGConfigureDisplayOrigin(cfg, d, Int32(bb.origin.x + dx), Int32(bb.origin.y + dy))
    }
    return CGCompleteDisplayConfiguration(cfg, .permanently) == .success
}

/// 当前主屏是不是虚拟屏
func mainIsVirtual() -> Bool {
    var n: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &n)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    CGGetActiveDisplayList(n, &ids, &n)
    guard let m = ids.first(where: { CGDisplayIsMain($0) != 0 }) else { return false }
    // 系统兜底屏也算"虚拟"：它同样不能占主屏位
    return CGDisplayVendorNumber(m) == VIRTUAL_VENDOR || isDummy(m)
}

/// 实体屏：既不是虚拟屏，也不是 iPad 随航屏
func physicalDisplay() -> CGDirectDisplayID? {
    var n: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &n)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    CGGetActiveDisplayList(n, &ids, &n)
    return ids.first { DisplayInventory.describe($0).isPhysical }
}

/// 确立主屏归属，返回是否真的动过。规则分两种：
/// - 有实体屏：只在主屏落到虚拟屏上时纠正，实体屏和 iPad 之间由用户自己选
/// - 没有实体屏：iPad 存在就必须当主屏（虚拟屏永远不能占）
@discardableResult
func enforceMain() -> Bool {
    let phys = physicalDisplay()
    guard let target = phys ?? findIPad() else { return false }
    if phys != nil {
        guard mainIsVirtual() else { return false }
    } else {
        // 没实体屏，iPad 是唯一合法主屏，只要不在它身上就切过去
        let alreadyMain = CGDisplayIsMain(target) != 0 && CGDisplayBounds(target).origin == .zero
        guard !alreadyMain else { return false }
    }
    return makeMain(target)
}

/// 返回：-1 组件加载失败，0 设备不可见，1 有设备
func probeDevices() -> (state: Int, device: AnyObject?, msg: String) {
    guard dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore", RTLD_NOW) != nil,
          let cls = NSClassFromString("SidecarDisplayManager") as? NSObject.Type else {
        return (-1, nil, "SidecarCore 加载失败")
    }
    let mgr = cls.init()
    if let c = mgr.value(forKey: "connectedDevices") as? [AnyObject], !c.isEmpty {
        return (1, c.first, "已有连接")
    }
    guard let devs = mgr.value(forKey: "devices") as? [AnyObject], !devs.isEmpty else {
        return (0, nil, "设备不可见")
    }

    let t = loadTargetId()
    if !t.isEmpty {
        if let d = devs.first(where: {
            let raw = $0.value(forKey: "identifier")
            let id = (raw as? NSUUID)?.uuidString ?? (raw as? String) ?? ""
            return id == t
        }) {
            return (1, d, "目标设备可见")
        }
        if let d = devs.first { return (1, d, "目标不在，改连其他") }
    }
    return (1, devs.first, "设备可见")
}

/// 当前活跃连接数。0 = 没有活跃连接，说明 iPad 处于休眠 / 合盖 / 关机。
/// iPad 打开时系统会自己重建连接（con 回到 1），不需要我们主动连。
func connectedDeviceCount() -> Int {
    guard dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore", RTLD_NOW) != nil,
          let cls = NSClassFromString("SidecarDisplayManager") as? NSObject.Type else {
        return -1
    }
    let mgr = cls.init()
    return (mgr.value(forKey: "connectedDevices") as? [AnyObject])?.count ?? 0
}

func connect(_ device: AnyObject) -> (ok: Bool, msg: String) {
    guard let cls = NSClassFromString("SidecarDisplayManager") as? NSObject.Type else {
        return (false, "no class")
    }
    let mgr = cls.init()
    var done = false, errMsg: String?
    typealias C = @convention(block) (NSError?) -> Void
    let block: C = { e in errMsg = e?.localizedDescription; done = true }
    let sel = NSSelectorFromString("connectToDevice:completion:")
    let imp = mgr.method(for: sel)
    typealias F = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Void
    unsafeBitCast(imp, to: F.self)(mgr, sel, device, unsafeBitCast(block, to: AnyObject.self))

    // 等回调的同时盯弹窗：系统警告往往比回调更早出现
    let dl = Date().addingTimeInterval(20)
    while !done && Date() < dl {
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        if hasPopupWindow() {
            squashPopup()
            return (false, "系统弹窗已拦截")
        }
    }
    if let e = errMsg { return (false, e) }
    return (true, "连接请求完成")
}

// ===== 主流程 =====

@main
enum WatchdogMain {
    static func main() {
        // 先保证面板可以创建和维护虚拟屏，即使用户暂停了重连。
        ensurePanelRunning()
        if FileManager.default.fileExists(atPath: pauseFile) { return }

        if hasPopupWindow() { squashPopup() }

        // 用和面板相同的在线屏判断，包含休眠中的实体屏。
        // 查询失败时等待下一轮，避免误发起连接。
        guard let mode = DisplayInventory.currentMode() else { return }

        if let ipad = findIPad() {
            try? FileManager.default.removeItem(atPath: notifiedFile)
            if mode != .physical {
                if CGDisplayIsMain(ipad) == 0 || CGDisplayBounds(ipad).origin != .zero {
                    if makeMain(ipad) { log("无实体屏：iPad 已设为主屏") }
                }
            } else if enforceMain() {
                log("主屏已归位")
            }
            return
        }

        // 虚拟屏上线后才自动连接，避免启动时屏幕还在枚举就抢先连接。
        guard mode == .headlessReady else { return }
        let probe = probeDevices()
        guard probe.state > 0, let device = probe.device else { return }
        guard acquireLock() else { return }

        // 给刚登录时的显示器枚举一点时间，再复核实体屏是否已接入。
        Thread.sleep(forTimeInterval: 2)
        guard DisplayInventory.currentMode() == .headlessReady else { return }
        let result = connect(device)
        if !result.ok {
            squashPopup()
            log("连接失败: \(result.msg)")
            if physicalDisplay() != nil { postNotifyOnce() }
            return
        }

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            guard let currentMode = DisplayInventory.currentMode() else { return }
            if currentMode == .physical {
                log("实体屏已接入，停止本轮自动连接检查")
                return
            }
            if let ipad = findIPad() {
                try? FileManager.default.removeItem(atPath: notifiedFile)
                if makeMain(ipad) {
                    log("无实体屏：随航已就绪，iPad 已设为主屏")
                } else {
                    log("随航已连接，设置 iPad 主屏失败，将在下一轮重试")
                }
                return
            }
            if hasPopupWindow() {
                squashPopup()
                log("连接期间弹窗已拦截")
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }

        log("连接后 15 秒内未见显示器")
        squashPopup()
    }
}
