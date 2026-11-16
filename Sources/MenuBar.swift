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

    private var timer: Timer?

    var currentDeviceName: String {
        if let t = devices.first(where: { $0.id == targetId }) { return t.name }
        return devices.first?.name ?? ""
    }

    init() {
        interval = Self.readInterval()
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
                Button("打开工具目录") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Coze/Drive/杂事问答/tools/set-ipad-main"))
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundColor(.secondary)

                Spacer()

                Button("退出") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .frame(width: 250)
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
        if !flag {
            if let w = NSApp.windows.first {
                positionOnMouseScreen(w)
                w.makeKeyAndOrderFront(nil)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
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
        let background = CommandLine.arguments.contains("--background")

        if background {
            // 开机自启：恢复自动重连（清掉上次可能残留的暂停标记），窗口不弹出来
            try? FileManager.default.removeItem(atPath: pauseFile)
            DispatchQueue.main.async {
                NSApp.windows.forEach { $0.orderOut(nil) }
            }
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            guard let w = NSApp.windows.first else { return }
            self?.positionOnMouseScreen(w)
            w.makeKeyAndOrderFront(nil)
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
    }
}
