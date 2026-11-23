// VirtualScreen.swift —— 虚拟屏（独立 helper 进程持有）
//
// 原理：CGVirtualDisplay 私有 API（在 CoreGraphics.framework 里），
//      编译期不链接私有框架，运行时用 NSClassFromString + ObjC runtime 反射调用。
//
// 为什么必须用独立进程（11-23 22:56 实测）：
//   在面板进程里建屏，把 CGVirtualDisplay 对象释放掉、再提交显示配置变更，
//   屏都不会消失——weak 引用已经变 nil（对象确实 dealloc 了），
//   但 CGDisplayIsOnline 一直是 true，最长观察到 20 秒仍在。
//   只有持有它的进程退出，屏才从系统消失（pkill 面板后立刻没了）。
//   所以改成：每次建屏 spawn 一个 helper 子进程，拆屏就结束这个进程。
//
// 关键约束：
//   1. 建屏只在 helper 进程里做，面板进程只管 spawn / kill
//   2. 注册【逻辑】分辨率 + setHiDPI(1)，系统自动派生 2x，不是注册物理分辨率
//   3. applySettings 是异步的，切 HiDPI 模式要延迟一点
//   4. helper 用 stdin EOF 感知父进程死亡，面板崩了也不会留孤儿屏

import Foundation
import CoreGraphics
import AppKit

// MARK: - 日志

let vBaseDir = NSHomeDirectory() + "/Library/Application Support/ipad-watchdog"
let vLogFile = vBaseDir + "/vdisplay.log"

func vlog(_ msg: String) {
    let df = DateFormatter(); df.dateFormat = "MM-dd HH:mm:ss"
    let line = "[\(df.string(from: Date()))] \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let h = FileHandle(forWritingAtPath: vLogFile) {
        h.seekToEndOfFile(); h.write(data); h.closeFile()
    } else {
        try? data.write(to: URL(fileURLWithPath: vLogFile))
    }
}

// MARK: - 虚拟屏

final class VirtualScreen {
    static let shared = VirtualScreen()

    // ===== 配置（对齐 BetterDisplay 那块「虚拟 16:9」）=====
    /// 逻辑宽（HiDPI 的一半，物理 = 逻辑 × 2）
    private let logicalW: UInt32 = 2560
    private let logicalH: UInt32 = 1440
    private let refresh: Double = 60
    private let screenName = "虚拟 16:9"
    private let mmW: Double = 530.81
    private let mmH: Double = 298.58
    private let vendorID: UInt32 = 0x1A2B
    private let productID: UInt32 = 0x3C4D
    private let serialNum: UInt32 = 0x5E6F

    /// 持有虚拟屏的 helper 子进程。屏的生命周期跟着它走。
    private var helper: Process?
    /// helper 的 stdout（读 displayID）和 stdin（父进程死了变 EOF，helper 自己退出）
    private var helperOut: Pipe?
    private var helperIn: Pipe?
    private(set) var displayID: CGDirectDisplayID?

    var isOn: Bool { helper?.isRunning == true && displayID != nil }

    private init() {}

    // ===== 对外接口 =====

    /// 建屏：spawn 一个 helper 子进程，由它创建并持有虚拟屏。
    /// 已存在则直接返回。
    @discardableResult
    func turnOn() -> CGDirectDisplayID? {
        if let id = displayID, helper?.isRunning == true { return id }
        cleanup()

        guard let exe = Bundle.main.executableURL else {
            vlog("❌ 拿不到自身可执行文件路径，无法起 helper")
            return nil
        }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--vdisplay-helper"]
        let out = Pipe()
        let inp = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = FileHandle.nullDevice

        do { try p.run() } catch {
            vlog("❌ helper 启动失败：\(error.localizedDescription)")
            return nil
        }

        // helper 建好屏后把 displayID 打在第一行
        let fh = out.fileHandleForReading
        var buf = Data()
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            let chunk = fh.availableData
            if chunk.isEmpty { break }
            buf.append(chunk)
            if buf.contains(UInt8(ascii: "\n")) { break }
        }
        let line = (String(data: buf, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let did = CGDirectDisplayID(line), did != 0 else {
            vlog("❌ helper 没给出 displayID（收到：\(line.isEmpty ? "空" : line)）")
            p.terminate()
            return nil
        }

        helper = p
        helperOut = out
        helperIn = inp
        displayID = did
        vlog("✅ 虚拟屏已创建  displayID=\(did)  逻辑 \(logicalW)x\(logicalH) @\(Int(refresh))Hz  helper pid=\(p.processIdentifier)")

        // applySettings 是异步的，给 WindowServer 一点时间注册，再切 HiDPI
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.isOn else { return }
            _ = self.applyHiDPIMode(did)

            // 虚拟屏建出来常落在原点，顺手把主屏抢走。
            // 等模式切换稳定后按规则归位：有实体屏给实体屏，没有实体屏给 iPad。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, self.isOn else { return }
                if Displays.enforceMain() {
                    vlog("↩️ 虚拟屏建好后主屏已归位（实体屏优先，没有则 iPad）")
                }
            }
        }

        return did
    }

    /// 拆屏：结束 helper 进程。屏随进程退出从系统消失。
    func turnOff() {
        guard helper != nil || displayID != nil else { return }
        let old = displayID
        cleanup()
        vlog("── 虚拟屏已关闭（原 displayID=\(old.map(String.init) ?? "?")）")

        guard let old else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if CGDisplayIsOnline(old) != 0 {
                vlog("⚠️ 虚拟屏 \(old) 仍在系统里")
            } else {
                vlog("✅ 虚拟屏 \(old) 已从系统移除")
            }
        }
    }

    private func cleanup() {
        if let h = helper, h.isRunning { h.terminate() }
        helper = nil
        helperOut = nil
        helperIn = nil
        displayID = nil
    }

    /// 切到 HiDPI 模式（物理 = 逻辑 × 2）
    @discardableResult
    private func applyHiDPIMode(_ did: CGDirectDisplayID) -> Bool {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let list = CGDisplayCopyAllDisplayModes(did, opts) as? [CGDisplayMode] else { return false }
        let targetW = Int(logicalW * 2), targetH = Int(logicalH * 2)
        guard let hi = list.first(where: { $0.pixelWidth == targetW && $0.pixelHeight == targetH }) else {
            vlog("⚠️ 未找到 \(targetW)x\(targetH) 的 HiDPI 模式")
            return false
        }
        if let cur = CGDisplayCopyDisplayMode(did),
           cur.width == hi.width, cur.pixelWidth == hi.pixelWidth {
            vlog("ℹ️ 已是目标模式 逻辑 \(hi.width)x\(hi.height) / 物理 \(hi.pixelWidth)x\(hi.pixelHeight)")
            return true
        }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg = cfg else {
            vlog("❌ CGBeginDisplayConfiguration 失败"); return false
        }
        CGConfigureDisplayWithDisplayMode(cfg, did, hi, nil)
        let r = CGCompleteDisplayConfiguration(cfg, .forSession)
        if r == .success {
            vlog("✅ 已切 HiDPI  逻辑 \(hi.width)x\(hi.height) / 物理 \(hi.pixelWidth)x\(hi.pixelHeight)")
            return true
        } else {
            vlog("❌ 切模式失败 err=\(r.rawValue)")
            return false
        }
    }
}


// MARK: - ObjC runtime 桥（顶层，helper 用）

typealias VAllocF   = @convention(c) (AnyClass, Selector) -> AnyObject
typealias VInit0F   = @convention(c) (AnyObject, Selector) -> AnyObject
typealias VSetObjF  = @convention(c) (AnyObject, Selector, AnyObject) -> Void
typealias VSetU32F  = @convention(c) (AnyObject, Selector, UInt32) -> Void
typealias VSetSizeF = @convention(c) (AnyObject, Selector, CGSize) -> Void
typealias VSetPtF   = @convention(c) (AnyObject, Selector, CGPoint) -> Void
typealias VModeF    = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> AnyObject
typealias VIdF      = @convention(c) (AnyObject, Selector) -> UInt32
/// alloc/init 走 IMP 直接调用，返回的是 +1 引用。声明成 AnyObject 会被 Swift
/// 按 +0 桥接，所有权对不上，对象永远不释放。用 Unmanaged 由调用方接管。
typealias VInitF    = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>

func VInstIMP(_ c: AnyClass, _ s: String) -> IMP? {
    guard let m = class_getInstanceMethod(c, NSSelectorFromString(s)) else { return nil }
    return method_getImplementation(m)
}
func VClassIMP(_ c: AnyClass, _ s: String) -> IMP? {
    guard let m = class_getClassMethod(c, NSSelectorFromString(s)) else { return nil }
    return method_getImplementation(m)
}
func VAllocOf(_ c: AnyClass) -> AnyObject? {
    guard let imp = VClassIMP(c, "alloc") else { return nil }
    return unsafeBitCast(imp, to: VAllocF.self)(c, NSSelectorFromString("alloc"))
}
func VNewInit(_ c: AnyClass) -> AnyObject? {
    guard let a = VAllocOf(c), let imp = VInstIMP(c, "init") else { return nil }
    return unsafeBitCast(imp, to: VInit0F.self)(a, NSSelectorFromString("init"))
}
func VSetObj(_ o: AnyObject, _ c: AnyClass, _ s: String, _ v: AnyObject) {
    guard let imp = VInstIMP(c, s) else { return }
    unsafeBitCast(imp, to: VSetObjF.self)(o, NSSelectorFromString(s), v)
}
func VSetU32(_ o: AnyObject, _ c: AnyClass, _ s: String, _ v: UInt32) {
    guard let imp = VInstIMP(c, s) else { return }
    unsafeBitCast(imp, to: VSetU32F.self)(o, NSSelectorFromString(s), v)
}
func VSetSize(_ o: AnyObject, _ c: AnyClass, _ s: String, _ v: CGSize) {
    guard let imp = VInstIMP(c, s) else { return }
    unsafeBitCast(imp, to: VSetSizeF.self)(o, NSSelectorFromString(s), v)
}
func VSetPt(_ o: AnyObject, _ c: AnyClass, _ s: String, _ v: CGPoint) {
    guard let imp = VInstIMP(c, s) else { return }
    unsafeBitCast(imp, to: VSetPtF.self)(o, NSSelectorFromString(s), v)
}

// MARK: - helper 进程

/// helper 进程里强引用持有虚拟屏对象。进程活着它就活着，进程退出屏才消失。
private var helperHeld: AnyObject?

/// helper 进程入口：建一块虚拟屏并一直持有，直到父进程断开或自己被结束。
func runVirtualScreenHelper() -> Never {
    guard let (vd, did) = createDisplayObject() else {
        print("0"); fflush(stdout)
        vlog("❌ helper 建屏失败")
        exit(1)
    }
    helperHeld = vd
    print(did); fflush(stdout)
    vlog("🖥️ helper 持有虚拟屏  displayID=\(did)  pid=\(getpid())")

    // 父进程退出时 stdin 管道关闭，read 立刻返回 0，跟着退出。
    // 这样面板崩了也不会留一块孤儿屏在系统里。
    DispatchQueue.global().async {
        var b = [UInt8](repeating: 0, count: 1)
        _ = read(STDIN_FILENO, &b, 1)
        vlog("── helper 收到父进程断开，退出")
        exit(0)
    }
    dispatchMain()
}

/// 真正建屏。只在 helper 进程里调用。
private func createDisplayObject() -> (AnyObject, CGDirectDisplayID)? {
    guard let DescCls = NSClassFromString("CGVirtualDisplayDescriptor"),
          let VdCls   = NSClassFromString("CGVirtualDisplay"),
          let ModeCls = NSClassFromString("CGVirtualDisplayMode"),
          let SetCls  = NSClassFromString("CGVirtualDisplaySettings") else {
        vlog("❌ 私有类缺失，CGVirtualDisplay 不可用（macOS 版本可能变了）")
        return nil
    }

    let logicalW: UInt32 = 2560
    let logicalH: UInt32 = 1440
    let refresh: Double = 60
    let screenName = "虚拟 16:9"
    let mmW: Double = 530.81
    let mmH: Double = 298.58

    guard let d = VNewInit(DescCls) else { vlog("❌ descriptor 创建失败"); return nil }
    VSetObj(d, DescCls, "setName:", screenName as NSString)
    VSetU32(d, DescCls, "setMaxPixelsWide:", logicalW * 2)
    VSetU32(d, DescCls, "setMaxPixelsHigh:", logicalH * 2)
    VSetSize(d, DescCls, "setSizeInMillimeters:", CGSize(width: mmW, height: mmH))
    VSetU32(d, DescCls, "setVendorID:", 0x1A2B)
    VSetU32(d, DescCls, "setProductID:", 0x3C4D)
    VSetU32(d, DescCls, "setSerialNum:", 0x5E6F)
    VSetPt(d, DescCls, "setRedPrimary:",   CGPoint(x: 0.680, y: 0.320))
    VSetPt(d, DescCls, "setGreenPrimary:", CGPoint(x: 0.265, y: 0.690))
    VSetPt(d, DescCls, "setBluePrimary:",  CGPoint(x: 0.150, y: 0.060))
    VSetPt(d, DescCls, "setWhitePoint:",   CGPoint(x: 0.3127, y: 0.3290))
    VSetObj(d, DescCls, "setDispatchQueue:", DispatchQueue.main as AnyObject)

    guard let raw = VAllocOf(VdCls), let vImp = VInstIMP(VdCls, "initWithDescriptor:") else {
        vlog("❌ CGVirtualDisplay init 不可用"); return nil
    }
    let vd = unsafeBitCast(vImp, to: VInitF.self)(
        raw, NSSelectorFromString("initWithDescriptor:"), d).takeRetainedValue()

    guard let mRaw = VAllocOf(ModeCls), let mImp = VInstIMP(ModeCls, "initWithWidth:height:refreshRate:") else {
        vlog("❌ Mode 创建失败"); return nil
    }
    let mode = unsafeBitCast(mImp, to: VModeF.self)(
        mRaw, NSSelectorFromString("initWithWidth:height:refreshRate:"), logicalW, logicalH, refresh)

    guard let settings = VNewInit(SetCls) else { vlog("❌ settings 创建失败"); return nil }
    VSetU32(settings, SetCls, "setHiDPI:", 1)
    VSetObj(settings, SetCls, "setModes:", [mode] as NSArray)
    VSetU32(settings, SetCls, "setRotation:", 0)

    VSetObj(vd, VdCls, "applySettings:", settings)

    guard let idImp = VInstIMP(VdCls, "displayID") else { vlog("❌ displayID 不可用"); return nil }
    let did = unsafeBitCast(idImp, to: VIdF.self)(vd, NSSelectorFromString("displayID"))
    guard did != 0 else { vlog("❌ displayID 为 0"); return nil }
    return (vd, did)
}
