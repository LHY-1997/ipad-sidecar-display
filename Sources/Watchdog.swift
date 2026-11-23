import Foundation
import ObjectiveC
import CoreGraphics
import CoreAudio
import IOKit
import Darwin

let IPAD_MODEL: UInt32 = 0x69506164
/// 虚拟屏的 vendorID，和 VirtualScreen.swift 里注册的一致
let VIRTUAL_VENDOR: UInt32 = 0x1A2B
/// 系统在没有任何可用屏时自己塞的兜底屏：1920×1080，vendor/model 是
/// ASCII 的 "unkn"/"virt"。拔掉实体屏后它会立刻顶上主屏位置，不能当实体屏。
let DUMMY_VENDOR: UInt32 = 0x756E6B6E
let DUMMY_MODEL: UInt32 = 0x76697274

func isDummy(_ id: CGDirectDisplayID) -> Bool {
    CGDisplayVendorNumber(id) == DUMMY_VENDOR || CGDisplayModelNumber(id) == DUMMY_MODEL
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
/// 开机后待应用：把 iPad 顶成主屏。内容是本轮开机的 boot time。
let mainIpadFile = base + "/main-ipad"
/// 已应用过的 boot time，用来区分「系统重启」和「面板自己重启」
let mainIpadDoneFile = base + "/main-ipad.done"

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

// MARK: - 屏幕状态

func screenIsAwake() -> Bool {
    CGDisplayIsAsleep(CGMainDisplayID()) == 0
}

/// 屏幕是否锁定。key 只在锁屏时存在，未锁屏时读不到，所以默认 false。
func screenIsLocked() -> Bool {
    guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return (d["CGSSessionScreenIsLocked"] as? Bool) ?? false
}

/// 默认输出设备当前是否在出声——看视频、听音乐时人在，但键鼠可以几十分钟不动
func audioIsPlaying() -> Bool {
    var dev = AudioDeviceID(0)
    var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &dev) == noErr,
          dev != 0 else { return false }
    var run: UInt32 = 0
    var rs = UInt32(MemoryLayout<UInt32>.size)
    var ra = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                        mScope: kAudioObjectPropertyScopeGlobal,
                                        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(dev, &ra, 0, nil, &rs, &run) == noErr else { return false }
    return run != 0
}

/// 键鼠空闲秒数
func userIdleSeconds() -> Double {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"), &iter) == KERN_SUCCESS else { return 9999 }
    defer { IOObjectRelease(iter) }
    let svc = IOIteratorNext(iter)
    guard svc != 0 else { return 9999 }
    defer { IOObjectRelease(svc) }
    var props: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let dict = props?.takeRetainedValue() as? [String: Any],
          let idle = dict["HIDIdleTime"] as? Int64 else { return 9999 }
    return Double(idle) / 1_000_000_000
}

/// 人是否还在电脑前。
///
/// 只看"屏幕熄没熄"是不够的——显示器设成永不关闭时，这个判据永远为真，
/// 人走了照样每 10 秒发起一次连接，弹窗又回来了。
/// 所以按可靠性从高到低叠加判断：
///   1. 熄屏 / 锁屏     → 明确离开
///   2. 键鼠 5 分钟内有动 → 明确在用
///   3. 正在出声        → 看视频听歌，鼠标不动也算在
///   4. 键鼠 30 分钟内动过 → 宽容期
///   5. 全不满足        → 人走了
func userIsHere() -> Bool {
    if !screenIsAwake() { return false }
    if screenIsLocked() { return false }
    let idle = userIdleSeconds()
    if idle < 300 { return true }
    if audioIsPlaying() { return true }
    if idle < 1800 { return true }
    return false
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
    return ids.first {
        CGDisplayVendorNumber($0) != VIRTUAL_VENDOR && CGDisplayModelNumber($0) != IPAD_MODEL && !isDummy($0)
    }
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

/// 开机后第一次连上 iPad：按用户要求默认把它顶成主屏，不管有没有实体屏。
/// 用户场景（11-23 22:37）：重启后自动重连开了，但主屏还留在实体屏上；
/// 没接实体屏的场合主屏就会指向一块不存在的屏，什么都看不到。
/// 应用一次就把 boot time 记进 .done，之后用户手动改主屏不会被抢回来。
func applyBootMainPreference() -> Bool {
    guard FileManager.default.fileExists(atPath: mainIpadFile) else { return false }
    guard let ipad = findIPad() else { return false }
    let stamp = (try? String(contentsOfFile: mainIpadFile, encoding: .utf8)) ?? ""
    try? stamp.write(toFile: mainIpadDoneFile, atomically: true, encoding: .utf8)
    try? FileManager.default.removeItem(atPath: mainIpadFile)
    return makeMain(ipad)
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

// 面板是虚拟屏的持有者，先确保它活着（暂停自动重连不影响这一步）
ensurePanelRunning()

if FileManager.default.fileExists(atPath: pauseFile) { exit(0) }

// 0) 先把残留弹窗收掉
// 手动从菜单栏点连接失败时也会弹这个窗，那时 watchdog 不在 connect 流程里，
// 没人管它就会一直挂在屏幕上。每 10 秒扫一次，顺手清掉。
if hasPopupWindow() { squashPopup() }

// 1) 人不在 → 不需要连
// 熄屏、锁屏、或长时间无操作且无音频，都算不在。
if !userIsHere() { exit(0) }

// 2) 屏已经在 → 按规则校正主屏归属
// 有实体屏时实体屏/iPad 由用户决定；没有实体屏时 iPad 必须在主屏位
if findIPad() != nil {
    // iPad 在线了，说明这一轮断开结束了，下次断开重新提示一次
    try? FileManager.default.removeItem(atPath: notifiedFile)
    if applyBootMainPreference() {
        log("开机默认：iPad 已设为主屏")
        exit(0)
    }
    if enforceMain() { log("主屏已归位") }
    exit(0)
}

// 3) 屏不在，看设备
let p = probeDevices()
if p.state <= 0 { exit(0) }   // 设备不可见：静默退出

// 4) 单实例锁：拿到锁才继续
if !acquireLock() { exit(0) }

// 5) 发起连接
let r = connect(p.device!)

if !r.ok {
    squashPopup()
    log("连接失败: \(r.msg)")
    // 系统警告弹窗已经被压掉了，用户只会看到一闪。所以补一个说明：
    // 告诉他可以暂停自动重连，免得被反复打扰。本次断开只提示一次。
    if !FileManager.default.fileExists(atPath: notifiedFile) {
        try? "1".write(toFile: notifiedFile, atomically: true, encoding: .utf8)
        try? "\(Date())".write(toFile: notifyFile, atomically: true, encoding: .utf8)
    }
    exit(0)
}

// 6) 等屏出现，期间继续盯弹窗
let dl = Date().addingTimeInterval(15)
while Date() < dl {
    if findIPad() != nil {
        try? FileManager.default.removeItem(atPath: notifiedFile)
        // 开机后第一次连上：无条件顶成主屏
        if applyBootMainPreference() {
            log("开机默认：iPad 已设为主屏")
            exit(0)
        }
        // 之后按规则定主屏：有实体屏时由用户选，没有实体屏则 iPad 必须在主屏位
        if enforceMain() {
            log("随航已就绪，主屏已归位")
        } else {
            log("随航已就绪，保持当前主屏")
        }
        exit(0)
    }
    if hasPopupWindow() {
        squashPopup()
        log("连接期间弹窗已拦截")
        exit(0)
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
}

log("连接后 15 秒内未见显示器")
squashPopup()
