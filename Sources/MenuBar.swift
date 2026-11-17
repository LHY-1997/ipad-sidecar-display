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
/// 这个文件存在 = 用户主动关掉了虚拟屏；不存在 = 默认开启
let vOffFile = baseDir + "/vdisplay.off"
/// 用户主动退出面板时创建，watchdog 看到就不再把面板拉起来
let panelOffFile = baseDir + "/panel.off"
let watchdogPlist = NSHomeDirectory() + "/Library/LaunchAgents/com.local.ipad-watchdog.plist"

struct DeviceInfo: Identifiable, Equatable {
    let id: String
    let name: String
}

// MARK: - 失败弹窗

/// 连接失败时系统会弹「无法连接 "xxx" 发生了其他错误 (-1010)」，卡在屏幕上等人点「好」。
/// 弹窗进程是 UserNotificationCenter，不是 SidecarDisplayAgent。
/// 点按钮需要 AppleScript / Accessibility 权限，GUI app 不一定有，所以直接杀进程。
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

    /// 后台清理，不阻塞界面
    static func squash() {
        DispatchQueue.global().async {
            kill()
            for _ in 0..<3 {
                Thread.sleep(forTimeInterval: 0.3)
                if hasWindow() { kill() } else { break }
            }
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
}

// MARK: - 状态

final class AppState: ObservableObject {
    @Published var connected = false
    @Published var isMain = false
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

    private var timer: Timer?

    var currentDeviceName: String {
        if let t = devices.first(where: { $0.id == targetId }) { return t.name }
        return devices.first?.name ?? ""
    }

    init() {
        interval = Self.readInterval()

        // 虚拟屏：默认开启，只有 vdisplay.off 存在才算用户关过
        let vOff = FileManager.default.fileExists(atPath: vOffFile)
        virtualScreenOn = !vOff
        if !vOff {
            // AppDelegate 已经建过就幂等返回；这里兜底（比如窗口先于 delegate 求值）
            _ = VirtualScreen.shared.turnOn()
        }

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
        let ipad = Displays.ipad()
        let nowConnected = ipad != nil
        let nowMain = ipad.map { Displays.isMain($0) } ?? false
        if nowConnected != connected { connected = nowConnected }
        if nowMain != isMain { isMain = nowMain }

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
            message = "虚拟屏已关闭"
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
        • 没有实体屏、也没接 HDMI 欺骗器时，重启后可能连兜底屏都没有，画面彻底消失
        • 恢复办法：重新打开这个开关，或删掉 vdisplay.off 后重启

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

                infoRow("主屏", s.isMain ? "iPad Pro" : "其他屏幕", s.isMain ? .green : .secondary)

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
                        Text("设为主屏").frame(maxWidth: .infinity)
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 面板起来了，清掉上次的主动退出标记，让 watchdog 恢复守护
        try? FileManager.default.removeItem(atPath: panelOffFile)

        // 最早时机建虚拟屏：无头 Mac 开机时系统可能一块屏都没有，
        // 越早建出落脚点，WindowServer 和随航越早有着落
        if !FileManager.default.fileExists(atPath: vOffFile) {
            _ = VirtualScreen.shared.turnOn()
        }

        // 开机自启也把面板弹出来。之前这里是 orderOut 藏窗口，
        // 但那时菜单栏没有图标，藏完就彻底没入口了，只剩 Dock 里一个图标。
        if CommandLine.arguments.contains("--background") {
            // 恢复自动重连（清掉上次可能残留的暂停标记）
            try? FileManager.default.removeItem(atPath: pauseFile)
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
