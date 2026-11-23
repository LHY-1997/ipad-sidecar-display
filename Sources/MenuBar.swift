import SwiftUI
import AppKit
import CoreGraphics
import ObjectiveC

let IPAD_MODEL: UInt32 = 0x69506164
let baseDir = NSHomeDirectory() + "/Library/Application Support/ipad-watchdog"
let pauseFile = baseDir + "/pause"
let logFile = baseDir + "/watchdog.log"
let targetFile = baseDir + "/target"
let intervalFile = baseDir + "/interval"
/// watchdog 连接失败时留下的信号文件，面板看到就弹一次说明
let notifyFile = baseDir + "/notify-disconnect"
/// watchdog 用来记「本次断开已经提示过」，避免每 10 秒弹一次
let notifiedFile = baseDir + "/notified"
/// 开机后待应用：把 iPad 顶成主屏，内容是这一轮开机的 boot time
let mainIpadFile = baseDir + "/main-ipad"
/// watchdog 应用过之后写下的 boot time，用来区分系统重启和面板自己重启
let mainIpadDoneFile = baseDir + "/main-ipad.done"
/// 这个文件存在 = 用户主动关掉了虚拟屏；不存在 = 默认开启
let vOffFile = baseDir + "/vdisplay.off"
/// 这个文件存在 = 当前这块虚拟屏是程序自动建的（不是用户手动开的）。
/// 有实体屏时据此回收，用户手动开的则保留。
let vAutoFile = baseDir + "/vdisplay.auto"
/// 用户主动退出面板时创建，watchdog 看到就不再把面板拉起来
let panelOffFile = baseDir + "/panel.off"
let watchdogPlist = NSHomeDirectory() + "/Library/LaunchAgents/com.local.ipad-watchdog.plist"
/// 已经引导过一次辅助功能授权。存在就不再自动弹，避免每次开机都烦人。

struct DeviceInfo: Identifiable, Equatable {
    let id: String
    let name: String
}

// MARK: - 失败弹窗

/// 连接失败时系统会弹「无法连接 "xxx" 发生了其他错误 (-1010)」，卡在屏幕上等人点「好」。
/// 弹窗进程是 UserNotificationCenter，不是 SidecarDisplayAgent。
/// 实测（11-23 21:43）：AX 路线走不通——即使进程已有辅助功能权限，
/// UserNotificationCenter 也不暴露元素树（连 AXRole 都读不到），按钮点不了。
/// 只剩 killall：杀掉后弹窗 0.5 秒内消失，且不会自己回来。
/// 副作用：连带清掉当前通知横幅；该进程按需启动，下次有通知会自己回来。
enum Popup {
    static func hasWindow() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return false }
        for w in list {
            guard let owner = w[kCGWindowOwnerName as String] as? String,
                  owner.contains("UserNotificationCenter") else { continue }
            guard let b = w[kCGWindowBounds as String] as? [String: Any],
                  let width = b["Width"] as? Double,
                  let height = b["Height"] as? Double else { continue }
            guard width >= 200, width <= 500, height >= 120, height <= 400 else { continue }
            let ratio = width / height
            if ratio >= 0.8, ratio <= 1.8 { return true }
        }
        return false
    }

    static func kill() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["UserNotificationCenter"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    private static var busy = false

    /// 后台清理，不阻塞界面。
    static func squash() {
        if busy { return }
        busy = true
        DispatchQueue.global().async {
            kill()
            // 补一刀：万一第一次没退干净
            for _ in 0..<3 {
                Thread.sleep(forTimeInterval: 0.3)
                if hasWindow() { kill() } else { break }
            }
            busy = false
        }
    }
}

// MARK: - Sidecar 控制

enum Sidecar {
    static func manager() -> NSObject? {
        guard dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore", RTLD_NOW) != nil,
              let cls = NSClassFromString("SidecarDisplayManager") as? NSObject.Type else { return nil }
        return cls.init()
    }

    static func devices() -> [AnyObject] {
        (manager()?.value(forKey: "devices") as? [AnyObject]) ?? []
    }

    static func connectedDevices() -> [AnyObject] {
        (manager()?.value(forKey: "connectedDevices") as? [AnyObject]) ?? []
    }

    static func name(_ d: AnyObject) -> String {
        (d.value(forKey: "name") as? String) ?? "iPad"
    }

    static func identifier(_ d: AnyObject) -> String {
        (d.value(forKey: "identifier") as? String) ?? ""
    }

    /// 历史设备（含当前不在附近的）
    static func recentDevices() -> [AnyObject] {
        (manager()?.value(forKey: "recentDevices") as? [AnyObject]) ?? []
    }

    /// 从系统「最近设备」里移除一台，走 cfprefsd，不直接改文件
    static func removeRecent(_ identifier: String) -> Bool {
        let appID = "com.apple.sidecar.display" as CFString
        guard let recents = CFPreferencesCopyAppValue("recents" as CFString, appID) as? [String] else {
            return false
        }
        let filtered = recents.filter { $0 != identifier }
        guard filtered.count != recents.count else { return false }
        CFPreferencesSetAppValue("recents" as CFString, filtered as CFArray, appID)
        CFPreferencesAppSynchronize(appID)
        // 通知 Sidecar 重新读偏好
        if let mgr = manager() {
            let sel = NSSelectorFromString("preferencesChanged")
            if mgr.responds(to: sel) {
                _ = mgr.perform(sel)
            }
        }
        return true
    }

    static func call(_ selName: String, on device: AnyObject, done: @escaping (String?) -> Void) {
        guard let mgr = manager() else { done("SidecarCore 加载失败"); return }
        let sel = NSSelectorFromString(selName)
        guard mgr.responds(to: sel) else { done("接口不存在"); return }

        typealias C = @convention(block) (NSError?) -> Void
        let block: C = { err in
            let msg = err?.localizedDescription
            DispatchQueue.main.async { done(msg) }
        }
        let imp = mgr.method(for: sel)
        typealias F = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Void
        unsafeBitCast(imp, to: F.self)(mgr, sel, device, unsafeBitCast(block, to: AnyObject.self))
    }
}

// MARK: - 显示器

enum Displays {
    static func ids() -> [CGDirectDisplayID] {
        var n: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &n)
        var a = [CGDirectDisplayID](repeating: 0, count: Int(n))
        CGGetActiveDisplayList(n, &a, &n)
        return a
    }

    static func ipad() -> CGDirectDisplayID? {
        ids().first { CGDisplayModelNumber($0) == IPAD_MODEL }
    }

    static func isMain(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayIsMain(id) != 0 && CGDisplayBounds(id).origin == .zero
    }

    @discardableResult
    static func makeMain(_ id: CGDirectDisplayID) -> Bool {
        if isMain(id) { return true }
        let b = CGDisplayBounds(id)
        var ref: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&ref) == .success, let cfg = ref else { return false }
        let dx = -b.origin.x, dy = -b.origin.y
        for d in ids() {
            let bb = CGDisplayBounds(d)
            _ = CGConfigureDisplayOrigin(cfg, d, Int32(bb.origin.x + dx), Int32(bb.origin.y + dy))
        }
        return CGCompleteDisplayConfiguration(cfg, .permanently) == .success
    }

    // MARK: 虚拟屏 / 实体屏

    /// 虚拟屏的 vendorID，和 VirtualScreen.swift 里注册的一致
    static let VIRTUAL_VENDOR: UInt32 = 0x1A2B

    static func isVirtual(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == VIRTUAL_VENDOR
    }

    static func isIPad(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayModelNumber(id) == IPAD_MODEL
    }

    /// 实体屏：既不是虚拟屏，也不是 iPad 随航屏
    static func physical() -> CGDirectDisplayID? {
        ids().first { !isVirtual($0) && !isIPad($0) }
    }

    /// 在线屏（含休眠中的）。判断「有没有实体屏」必须用这个：
    /// 显示器休眠时会被从活动列表里摘掉，拿活动列表判断会把休眠当成
    /// 无头机器，凭空多建一块虚拟屏——12:26 那次就是这么来的。
    static func onlineIDs() -> [CGDirectDisplayID] {
        var n: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &n)
        var a = [CGDirectDisplayID](repeating: 0, count: Int(n))
        CGGetOnlineDisplayList(n, &a, &n)
        return a
    }

    /// 在线的实体屏（含休眠中的）
    static func physicalOnline() -> CGDirectDisplayID? {
        onlineIDs().first { !isVirtual($0) && !isIPad($0) }
    }

    /// 虚拟屏要不要自动建：只给没有实体屏的机器当落脚点。
    /// 有实体屏还建一块，等于凭空多出一块屏，会打乱主屏归属和 Dock 位置。
    static func needsVirtualScreen() -> Bool {
        physicalOnline() == nil
    }

    /// 主屏的合法候选：实体屏优先，其次 iPad。虚拟屏永远不在候选里。
    static func mainCandidate() -> CGDirectDisplayID? {
        if let p = physical() { return p }
        return ids().first { isIPad($0) }
    }

    /// 当前主屏是不是虚拟屏
    static func mainIsVirtual() -> Bool {
        guard let m = ids().first(where: { CGDisplayIsMain($0) != 0 }) else { return false }
        return isVirtual(m)
    }

    /// 确立主屏归属，返回是否真的动过。规则分两种：
    /// - 有实体屏：只在主屏落到虚拟屏上时纠正，实体屏和 iPad 之间由用户自己选
    /// - 没有实体屏：iPad 存在就必须当主屏（虚拟屏永远不能占）
    /// 只剩虚拟屏一块时无解，返回 false 不动。
    @discardableResult
    static func enforceMain() -> Bool {
        guard let target = mainCandidate() else { return false }
        if physical() != nil {
            guard mainIsVirtual() else { return false }
        } else {
            // 没实体屏，iPad 是唯一合法主屏，只要不在它身上就切过去
            guard !isMain(target) else { return false }
        }
        return makeMain(target)
    }
}

// MARK: - 状态

/// 本次开机的时刻（秒）。用来区分「系统重启」和「面板自己重启」——
/// 只有系统重启才需要重新把 iPad 顶成主屏。
func bootTimeSeconds() -> Int {
    var tv = timeval()
    var size = MemoryLayout<timeval>.size
    guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return 0 }
    return Int(tv.tv_sec)
}

/// 说明面板上两个按钮的回调桥。AppState 不是 NSObject，不能直接当 target。
private final class NoticeBridge: NSObject {
    var onPause: (() -> Void)?
    var onClose: (() -> Void)?
    @objc func pauseTapped() { onPause?() }
    @objc func closeTapped() { onClose?() }
}

final class AppState: ObservableObject {
    private var noticePanel: NSPanel?
    private var noticeBridge: NoticeBridge?

    @Published var connected = false
    @Published var isMain = false
    @Published var mainOnVirtual = false
    @Published var deviceVisible = false
    @Published var deviceName = ""
    @Published var devices: [DeviceInfo] = []
    @Published var recents: [DeviceInfo] = []
    @Published var targetId: String = ""
    @Published var watchdogPaused = false
    @Published var busy = false
    @Published var message = ""
    @Published var logs: [String] = []
    @Published var interval: Int = 30
    @Published var virtualScreenOn = true
    /// 连续多少次 refresh 看到实体屏 / 看不到实体屏。给建屏和回收加滞后，
    /// 免得显示器休眠、唤醒的瞬间状态抖动导致建了又拆。
    private var physicalTicks = 0
    private var noPhysicalTicks = 0

    /// 上一次把主屏从虚拟屏抢回来的时间，用于防抖（系统自己也会重排显示器，别打架）
    private var lastKickAt = Date.distantPast

    private var timer: Timer?

    var currentDeviceName: String {
        if let t = devices.first(where: { $0.id == targetId }) { return t.name }
        return devices.first?.name ?? ""
    }

    init() {
        interval = Self.readInterval()

        // 虚拟屏状态以进程实际持有为准。这里不建屏——建屏统一在
        // applicationDidFinishLaunching 里按「有没有实体屏」决定。
        // 两个入口各建一块，正是随航每分钟断开的元凶。
        virtualScreenOn = VirtualScreen.shared.displayID != nil

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func loadTargetId() -> String {
        ((try? String(contentsOfFile: targetFile, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func selectDevice(_ id: String) {
        try? id.write(toFile: targetFile, atomically: true, encoding: .utf8)
        targetId = id
        let nm = devices.first(where: { $0.id == id })?.name ?? "设备"
        message = "默认设备：\(nm)"
        refresh()
    }

    /// 从系统「最近设备」里删掉一台（卖掉的、不用的）
    func removeDevice(_ id: String) {
        let nm = recents.first(where: { $0.id == id })?.name ?? "设备"
        if Sidecar.removeRecent(id) {
            if loadTargetId() == id {
                try? FileManager.default.removeItem(atPath: targetFile)
                targetId = ""
            }
            message = "已从历史移除：\(nm)"
        } else {
            message = "移除失败，系统没认这条记录"
        }
        refresh()
    }

    /// 优先返回用户指定的那台，找不到就退回第一台
    func targetDevice() -> AnyObject? {
        let list = Sidecar.devices()
        let t = loadTargetId()
        if !t.isEmpty, let d = list.first(where: { Sidecar.identifier($0) == t }) {
            return d
        }
        return list.first
    }

    func refresh() {
        // 虚拟屏状态跟随进程实际持有情况：建屏是延迟做的，UI 不能一直显示"关"。
        let vOn = VirtualScreen.shared.displayID != nil
        if vOn != virtualScreenOn { virtualScreenOn = vOn }

        // 用在线屏判断有没有实体屏：显示器休眠时活动列表里会没有它，
        // 拿活动列表判断会把休眠当成无头机器，凭空多建一块虚拟屏。
        let hasPhysical = Displays.physicalOnline() != nil
        if hasPhysical {
            physicalTicks += 1
            noPhysicalTicks = 0
        } else {
            noPhysicalTicks += 1
            physicalTicks = 0
        }

        // 有实体屏就不该有虚拟屏。连续 3 次（约 6 秒）确认实体屏在位才回收，
        // 只回收自动建的那块，用户手动开的不动。
        if vOn, hasPhysical, physicalTicks >= 3,
           !FileManager.default.fileExists(atPath: vOffFile),
           FileManager.default.fileExists(atPath: vAutoFile) {
            VirtualScreen.shared.turnOff()
            try? FileManager.default.removeItem(atPath: vAutoFile)
            virtualScreenOn = false
            vlog("🧹 实体屏在位，回收自动创建的虚拟屏")
        }

        // 没有实体屏才补建，且要连续 2 次（约 4 秒）都读不到，避免状态抖动。
        if !vOn, !hasPhysical, noPhysicalTicks >= 2,
           !FileManager.default.fileExists(atPath: vOffFile),
           VirtualScreen.shared.turnOn() != nil {
            virtualScreenOn = true
            try? "auto".write(toFile: vAutoFile, atomically: true, encoding: .utf8)
            vlog("🖥️ 没有实体屏，已自动创建虚拟屏作为落脚点")
        }

        let ipad = Displays.ipad()
        let nowConnected = ipad != nil
        let nowMain = ipad.map { Displays.isMain($0) } ?? false
        if nowConnected != connected { connected = nowConnected }
        if nowMain != isMain { isMain = nowMain }

        // 主屏归属：有实体屏就守住不让虚拟屏占；没实体屏则 iPad 必须在主屏位
        let onVirtual = Displays.mainIsVirtual()
        if onVirtual != mainOnVirtual { mainOnVirtual = onVirtual }
        if Date().timeIntervalSince(lastKickAt) > 3, Displays.enforceMain() {
            lastKickAt = Date()
            vlog("↩️ 主屏已归位（有实体屏给实体屏，没有则给 iPad）")
        }

        let devs = Sidecar.devices()
        let vis = !devs.isEmpty
        if vis != deviceVisible { deviceVisible = vis }
        let nm = devs.first.map { Sidecar.name($0) } ?? ""
        if nm != deviceName { deviceName = nm }

        let list = devs.map { DeviceInfo(id: Sidecar.identifier($0), name: Sidecar.name($0)) }
        if list != devices { devices = list }

        // 历史设备里，去掉当前在线的（在线的不能删）
        let onlineIds = Set(list.map { $0.id })
        let rec = Sidecar.recentDevices()
            .map { DeviceInfo(id: Sidecar.identifier($0), name: Sidecar.name($0)) }
            .filter { !onlineIds.contains($0.id) && !$0.id.isEmpty }
        if rec != recents { recents = rec }

        let t = loadTargetId()
        if t != targetId { targetId = t }

        let paused = FileManager.default.fileExists(atPath: pauseFile)
        if paused != watchdogPaused { watchdogPaused = paused }

        if let s = try? String(contentsOfFile: logFile, encoding: .utf8) {
            let lines = s.components(separatedBy: "\n").filter { !$0.isEmpty }
            let tail = Array(lines.suffix(3))
            if tail != logs { logs = tail }
        } else if !logs.isEmpty {
            logs = []
        }

        // 每 2 秒顺手看一眼有没有系统警告弹窗。有就压掉——不等到手动连接失败才处理，
        // 这样 watchdog 自动重连撞出来的弹窗也能在两秒内消失。
        if Popup.hasWindow() { Popup.squash() }

        // watchdog 连接失败时会留个信号：系统警告被压掉了，用户只看到一闪，
        // 得补一句说明，告诉他可以暂停自动重连。每次断开只提示一次。
        if FileManager.default.fileExists(atPath: notifyFile) {
            try? FileManager.default.removeItem(atPath: notifyFile)
            showDisconnectNotice()
        }
    }

    /// iPad 连不上时给一次说明。watchdog 每次断开周期只发一次信号，不会反复弹。
    ///
    /// 不用 NSAlert.runModal()：一是它会阻塞 refresh 循环，用户不点面板就卡死；
    /// 二是实测在 --background 启动的场景下 runModal 会立刻返回第二按钮，
    /// 等于没问就把守护停了（11-23 21:56 踩到）。改用非模态浮动面板。
    func showDisconnectNotice() {
        if let p = noticePanel, p.isVisible {
            p.makeKeyAndOrderFront(nil)
            return
        }

        let w: CGFloat = 400, h: CGFloat = 200
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                            styleMask: [.titled, .closable],
                            backing: .buffered,
                            defer: false)
        panel.title = "iPad 随航断开"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let box = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        let text = NSTextField(wrappingLabelWithString:
            "正在尝试自动重连。\n\n如果暂时不需要 iPad 随航，可以暂停自动重连，免得被反复打扰。软件重启后会自动恢复开启。")
        text.frame = NSRect(x: 20, y: 66, width: w - 40, height: 116)
        text.font = .systemFont(ofSize: 13)
        text.isSelectable = false
        text.isEditable = false
        text.isBordered = false
        text.drawsBackground = false
        text.lineBreakMode = .byWordWrapping
        text.maximumNumberOfLines = 0
        text.preferredMaxLayoutWidth = w - 40
        box.addSubview(text)

        let bridge = NoticeBridge()
        bridge.onPause = { [weak self] in
            guard let self else { return }
            _ = FileManager.default.createFile(atPath: pauseFile, contents: nil)
            // 清掉「本轮已提示」，用户恢复自动重连后要是还连不上，重新提示一次
            try? FileManager.default.removeItem(atPath: notifiedFile)
            self.watchdogPaused = true
            self.message = "自动重连已暂停"
            self.noticePanel?.close()
            self.noticePanel = nil
        }
        bridge.onClose = { [weak self] in
            self?.noticePanel?.close()
            self?.noticePanel = nil
        }
        noticeBridge = bridge

        let okBtn = NSButton(title: "知道了", target: bridge, action: #selector(NoticeBridge.closeTapped))
        okBtn.frame = NSRect(x: w - 20 - 90, y: 18, width: 90, height: 32)
        okBtn.bezelStyle = .rounded
        okBtn.keyEquivalent = "\r"
        box.addSubview(okBtn)

        let pauseBtn = NSButton(title: "暂停自动重连", target: bridge, action: #selector(NoticeBridge.pauseTapped))
        pauseBtn.frame = NSRect(x: w - 20 - 90 - 8 - 130, y: 18, width: 130, height: 32)
        pauseBtn.bezelStyle = .rounded
        box.addSubview(pauseBtn)

        panel.contentView = box
        // 显式钉死内容尺寸：只给 contentRect 的话窗口会被 contentView 的
        // 自动布局压窄，文字就会溢出到面板外面
        panel.setContentSize(NSSize(width: w, height: h))
        panel.minSize = NSSize(width: w, height: h)
        panel.maxSize = NSSize(width: w, height: h)
        // 放屏幕上方偏中，避开居中的主面板，两个窗口别叠在一起
        if let scr = NSScreen.main {
            let vf = scr.visibleFrame
            panel.setFrameOrigin(NSPoint(x: vf.midX - w / 2, y: vf.maxY - h - 90))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        noticePanel = panel
    }

    func connect() {
        busy = true
        message = "正在连接…"
        guard let d = targetDevice() else {
            message = "没搜到 iPad：确认解锁、同 Wi-Fi、蓝牙开、在旁边"
            busy = false
            return
        }
        Sidecar.call("connectToDevice:completion:", on: d) { [weak self] err in
            guard let self else { return }
            if let e = err {
                self.message = "连接失败：\(e)"
                // 系统警告比回调晚一步出来，等一下再收
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { Popup.squash() }
            } else {
                self.message = "已连接"
                // 手动连上了，说明想要连接状态，自动重连恢复
                self.resumeWatchdogSilently()
                self.watchdogPaused = false
            }
            self.busy = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.refresh() }
        }
    }

    func disconnect() {
        busy = true
        // 先暂停自动重连，否则 30 秒后又被拉回来
        if !watchdogPaused {
            FileManager.default.createFile(atPath: pauseFile, contents: nil)
            watchdogPaused = true
        }
        guard let d = Sidecar.connectedDevices().first else {
            message = "本来就没连"
            busy = false
            refresh()
            return
        }
        Sidecar.call("disconnectFromDevice:completion:", on: d) { [weak self] err in
            guard let self else { return }
            self.message = err == nil ? "已断开（自动重连已暂停）" : "断开失败：\(err!)"
            self.busy = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refresh() }
        }
    }

    func setMain() {
        guard let ipad = Displays.ipad() else {
            message = "iPad 不在"
            return
        }
        message = Displays.makeMain(ipad) ? "已把 iPad 设为主屏" : "设置失败"
        refresh()
    }

    /// 把主屏还给实体屏。没有实体屏时退回 iPad，两者都没有就不动。
    func setMainToPhysical() {
        guard let target = Displays.mainCandidate() else {
            message = "没有可用的实体屏或 iPad"
            return
        }
        if Displays.makeMain(target) {
            message = Displays.isIPad(target) ? "已把 iPad 设为主屏" : "已把主屏切回实体屏"
        } else {
            message = "设置失败"
        }
        refresh()
    }

    func toggleWatchdog() {
        if watchdogPaused {
            try? FileManager.default.removeItem(atPath: pauseFile)
            message = "自动重连已恢复"
        } else {
            FileManager.default.createFile(atPath: pauseFile, contents: nil)
            message = "自动重连已暂停"
        }
        refresh()
    }

    private func resumeWatchdogSilently() {
        try? FileManager.default.removeItem(atPath: pauseFile)
    }

    // MARK: 退出

    /// 退出面板。虚拟屏由本进程持有，退出会连虚拟屏一起关掉，所以先问一句。
    func quitApp() {
        if virtualScreenOn {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "退出面板？"
            alert.informativeText = """
            虚拟屏由面板进程持有，退出面板会一并关掉虚拟屏：

            • 系统会退到 1920×1080 兜底屏，随航随之断开
            • 后台守护不会再把面板拉起来，要等下次登录或手动打开
            • 只是不想看窗口的话，关掉窗口就行，不会退出

            确定要退出吗？
            """
            alert.addButton(withTitle: "退出")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        FileManager.default.createFile(atPath: panelOffFile, contents: nil)
        NSApplication.shared.terminate(nil)
    }

    // MARK: 虚拟屏

    /// 真正执行开关。关闭前必须由调用方确认过（走 requestVirtualScreenToggle）
    func setVirtualScreen(_ on: Bool) {
        if on {
            try? FileManager.default.removeItem(atPath: vOffFile)
            // 用户主动开的，别让 refresh 当成"自动建的"回收掉
            try? FileManager.default.removeItem(atPath: vAutoFile)
            if VirtualScreen.shared.turnOn() != nil {
                virtualScreenOn = true
                message = "虚拟屏已开启"
            } else {
                virtualScreenOn = false
                message = "虚拟屏创建失败，看 vdisplay.log"
            }
        } else {
            try? "off".write(toFile: vOffFile, atomically: true, encoding: .utf8)
            VirtualScreen.shared.turnOff()
            virtualScreenOn = false
            message = "虚拟屏已关闭（重启后自动恢复）"
        }
        refresh()
    }

    /// 界面开关入口：关的时候先弹警告
    func requestVirtualScreenToggle(_ on: Bool) {
        if on {
            setVirtualScreen(true)
            return
        }
        guard virtualScreenOn else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "关闭虚拟屏？"
        alert.informativeText = """
        虚拟屏是随航的落脚点。关掉之后：

        • 系统会退到一块 1920×1080 的兜底屏，分辨率掉一半，HiDPI 没了
        • 随航大概率当场断开（实测会断），要等自动重连或手动点「连接随航」
        • 没有实体屏时，画面会退到兜底屏
        • 恢复办法：重新打开这个开关；软件重启后也会自动恢复开启

        确定要关闭吗？
        """
        alert.addButton(withTitle: "关闭虚拟屏")
        alert.addButton(withTitle: "取消")

        if alert.runModal() == .alertFirstButtonReturn {
            setVirtualScreen(false)
        }
    }

    // MARK: 重连间隔

    /// 读用户选的间隔，默认 30 秒
    private static func readInterval() -> Int {
        if let s = try? String(contentsOfFile: intervalFile, encoding: .utf8),
           let v = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)), v > 0 {
            return v
        }
        return 30
    }

    func setInterval(_ v: Int) {
        guard v != interval else { return }
        try? String(v).write(toFile: intervalFile, atomically: true, encoding: .utf8)
        interval = v
        message = applyInterval(v) ? "重连间隔已改为 \(v) 秒" : "间隔已存，但重启服务失败"
    }

    /// 改 LaunchAgent 的 StartInterval，然后重载服务
    private func applyInterval(_ v: Int) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: watchdogPlist)),
              var dict = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
        else { return false }

        dict["StartInterval"] = v
        guard let out = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0),
              (try? out.write(to: URL(fileURLWithPath: watchdogPlist))) != nil
        else { return false }

        let uid = getuid()
        run("/bin/launchctl", ["bootout", "gui/\(uid)/com.local.ipad-watchdog"])
        return run("/bin/launchctl", ["bootstrap", "gui/\(uid)", watchdogPlist]) == 0
    }

    @discardableResult
    private func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }
}

// MARK: - 界面

struct ContentView: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "ipad.landscape")
                    .foregroundColor(.accentColor)
                Text("iPad 随航")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Circle()
                    .fill(s.connected ? Color.green : (s.deviceVisible ? Color.orange : Color.gray))
                    .frame(width: 7, height: 7)
            }

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                infoRow("连接", s.connected ? "已连接" : (s.deviceVisible ? "可连接" : "未发现"),
                        s.connected ? .green : .secondary)

                if s.devices.count > 1 || !s.recents.isEmpty {
                    // 多台设备，或有历史设备可清理
                    HStack(spacing: 4) {
                        Text("设备").foregroundColor(.secondary)
                        Spacer()
                        Menu {
                            ForEach(s.devices) { d in
                                Button {
                                    s.selectDevice(d.id)
                                } label: {
                                    if d.id == s.targetId {
                                        Label(d.name, systemImage: "checkmark")
                                    } else {
                                        Text(d.name)
                                    }
                                }
                            }

                            if !s.recents.isEmpty {
                                Divider()
                                Menu("清理历史设备") {
                                    ForEach(s.recents) { r in
                                        Button("删除 \(r.name)") {
                                            s.removeDevice(r.id)
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 2) {
                                Text(s.currentDeviceName).lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 7))
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                } else if !s.deviceName.isEmpty {
                    infoRow("设备", s.deviceName, .secondary)
                }

                if s.isMain {
                    infoRow("主屏", "iPad Pro", .green)
                } else if s.mainOnVirtual {
                    infoRow("主屏", "虚拟屏 ⚠️", .orange)
                } else {
                    infoRow("主屏", "实体屏", .green)
                }

                HStack(spacing: 4) {
                    Text("虚拟屏").foregroundColor(.secondary)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { s.virtualScreenOn },
                        set: { s.requestVirtualScreenToggle($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }

                HStack(spacing: 4) {
                    Text("自动重连").foregroundColor(.secondary)
                    Spacer()
                    if s.watchdogPaused {
                        Text("已暂停").foregroundColor(.orange)
                    } else {
                        Text("开启").foregroundColor(.green)
                        Menu {
                            ForEach([10, 30, 60], id: \.self) { v in
                                Button {
                                    s.setInterval(v)
                                } label: {
                                    if v == s.interval {
                                        Label("\(v) 秒", systemImage: "checkmark")
                                    } else {
                                        Text("\(v) 秒")
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 2) {
                                Text("\(s.interval) 秒").foregroundColor(.green)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 7))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                }
            }
            .font(.system(size: 11))

            Divider()

            if s.connected {
                HStack(spacing: 8) {
                    Button {
                        s.disconnect()
                    } label: {
                        Text("断开").frame(maxWidth: .infinity)
                    }
                    .disabled(s.busy)

                    Button {
                        s.setMain()
                    } label: {
                        Text("设 iPad 为主屏").frame(maxWidth: .infinity)
                    }
                    .disabled(s.isMain)
                }
            } else {
                Button {
                    s.connect()
                } label: {
                    HStack(spacing: 4) {
                        if s.busy { ProgressView().controlSize(.small) }
                        Text(s.busy ? "连接中…" : "连接随航")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(s.busy || !s.deviceVisible)
            }

            // 主屏在虚拟屏上（异常），或者用户把 iPad 设成了主屏时，给一条切回实体屏的路
            if s.mainOnVirtual || s.isMain {
                Button {
                    s.setMainToPhysical()
                } label: {
                    Text("主屏切回实体屏").frame(maxWidth: .infinity)
                }
                .disabled(s.busy)
            }

            Button {
                s.toggleWatchdog()
            } label: {
                Text(s.watchdogPaused ? "恢复自动重连" : "暂停自动重连")
                    .frame(maxWidth: .infinity)
            }

            if !s.message.isEmpty {
                Text(s.message)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !s.logs.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(s.logs.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Divider()

            HStack {
                // 版本号从 Info.plist 读，build.sh 改一处这里自动跟上
                Text("v" + appVersion)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                Spacer()

                Button("退出") {
                    s.quitApp()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .frame(width: 250)
    }

    /// 从 Info.plist 读版本号
    var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }

    func infoRow(_ k: String, _ v: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text(k).foregroundColor(.secondary)
            Spacer()
            Text(v).foregroundColor(color)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 关窗不退出，常驻后台，点 Dock 图标随时唤回
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// 点 Dock 图标时，如果窗口都不见了就重新显示
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showPanel() }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    /// 把主面板窗口提到前面。
    /// 加了菜单栏图标之后 NSApp.windows 里会混进图标的附属窗口，必须按标题筛。
    private func showPanel() {
        let w = NSApp.windows.first { $0.title == "iPad 随航" && $0.canBecomeMain }
            ?? NSApp.windows.first { $0.title == "iPad 随航" }
        guard let w = w else { return }
        positionOnMouseScreen(w)
        w.makeKeyAndOrderFront(nil)
    }

    private func positionOnMouseScreen(_ w: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let s = screen else { return }
        let vf = s.visibleFrame
        let ws = w.frame
        w.setFrameOrigin(NSPoint(x: vf.midX - ws.width / 2,
                                 y: vf.midY - ws.height / 2))
    }

    /// 没有实体屏才建虚拟屏。
    ///
    /// 开机瞬间显示器可能还没枚举完，这时候 physical() 读不到实体屏，会被
    /// 误判成"无头机器"而多建一块屏——所以判断为"没有实体屏"时先等 2 秒
    /// 复核，确认还是没有才建。有实体屏的情况直接返回，不建。
    private func tryAutoVirtualScreen() {
        if !Displays.needsVirtualScreen() { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard !FileManager.default.fileExists(atPath: vOffFile) else { return }
            guard VirtualScreen.shared.displayID == nil else { return }
            guard Displays.needsVirtualScreen() else { return }
            if VirtualScreen.shared.turnOn() != nil {
                try? "auto".write(toFile: vAutoFile, atomically: true, encoding: .utf8)
                vlog("🖥️ 没有实体屏，已自动创建虚拟屏作为落脚点")
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 面板起来了，清掉上次的主动退出标记，让 watchdog 恢复守护
        try? FileManager.default.removeItem(atPath: panelOffFile)

        // 虚拟屏的「关闭」和暂停自动重连一样，只对当次运行有效：重启后回到
        // 自动判断（有实体屏不建，没实体屏才建，实体屏回来再回收）。
        // 只清标记不够——refresh 的建屏/回收两条路都看这个文件。
        try? FileManager.default.removeItem(atPath: vOffFile)
        tryAutoVirtualScreen()

        // 开机自启也把面板弹出来。之前这里是 orderOut 藏窗口，
        // 但那时菜单栏没有图标，藏完就彻底没入口了，只剩 Dock 里一个图标。
        //
        // 手动断开 / 暂停自动重连只对当次有效：面板每次启动都回到默认开启状态，
        // 不管是不是 --background 拉起。用户手动关掉随航后重启，守护照常工作。
        try? FileManager.default.removeItem(atPath: pauseFile)
        try? FileManager.default.removeItem(atPath: notifiedFile)

        // 开机后第一次：让 watchdog 把 iPad 顶成主屏。
        // 用户要求（11-23 22:37）：重启后除了恢复自动重连，还要默认 iPad 主屏；
        // 不然没接实体屏的场合主屏会停在不存在的那块屏上。
        // 用 boot time 认「系统重启」，面板自己重启时 .done 已经是同一个值，不会重复抢主屏。
        let bt = "\(bootTimeSeconds())"
        let done = (try? String(contentsOfFile: mainIpadDoneFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if bt != "0", done != bt {
            try? bt.write(toFile: mainIpadFile, atomically: true, encoding: .utf8)
        }

        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            self?.showPanel()
        }
    }
}

@main
struct SidecarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("iPad 随航") {
            ContentView()
                .environmentObject(state)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // 菜单栏图标：点一下弹出面板。v2.0 只有 Dock 图标，菜单栏上是空的。
        MenuBarExtra("iPad 随航", systemImage: "ipad.landscape") {
            ContentView()
                .environmentObject(state)
        }
        .menuBarExtraStyle(.window)
    }
}
