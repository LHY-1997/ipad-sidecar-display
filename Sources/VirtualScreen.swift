// VirtualScreen.swift —— 进程内虚拟屏
//
// 由 iPad随航.app 直接创建并持有，不再依赖独立的 ipad-vdisplay 进程。
// 原理：CGVirtualDisplay 私有 API（在 CoreGraphics.framework 里），
//      编译期不链接私有框架，运行时用 NSClassFromString + ObjC runtime 反射调用。
//
// 关键约束：
//   1. CGVirtualDisplay 实例必须被强引用持有，一释放虚拟屏立刻消失
//   2. 注册【逻辑】分辨率 + setHiDPI(1)，系统自动派生 2x，不是注册物理分辨率
//   3. applySettings 是异步的，切 HiDPI 模式要延迟一点

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

    /// 必须强引用持有，一释放虚拟屏就消失
    private var held: AnyObject?
    private(set) var displayID: CGDirectDisplayID?

    var isOn: Bool { held != nil }

    private init() {}

    // ===== ObjC runtime 桥 =====

    private typealias AllocF   = @convention(c) (AnyClass, Selector) -> AnyObject
    private typealias InitF    = @convention(c) (AnyObject, Selector) -> AnyObject
    private typealias SetObjF  = @convention(c) (AnyObject, Selector, AnyObject) -> Void
    private typealias SetU32F  = @convention(c) (AnyObject, Selector, UInt32) -> Void
    private typealias SetSizeF = @convention(c) (AnyObject, Selector, CGSize) -> Void
    private typealias SetPtF   = @convention(c) (AnyObject, Selector, CGPoint) -> Void
    private typealias ModeF    = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> AnyObject
    private typealias VInitF   = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject
    private typealias IdF      = @convention(c) (AnyObject, Selector) -> UInt32

    private func instIMP(_ c: AnyClass, _ s: String) -> IMP? {
        guard let m = class_getInstanceMethod(c, NSSelectorFromString(s)) else { return nil }
        return method_getImplementation(m)
    }

    private func classIMP(_ c: AnyClass, _ s: String) -> IMP? {
        guard let m = class_getClassMethod(c, NSSelectorFromString(s)) else { return nil }
        return method_getImplementation(m)
    }

    private func allocOf(_ c: AnyClass) -> AnyObject? {
        guard let imp = classIMP(c, "alloc") else { return nil }
        return unsafeBitCast(imp, to: AllocF.self)(c, NSSelectorFromString("alloc"))
    }

    private func newInit(_ c: AnyClass) -> AnyObject? {
        guard let a = allocOf(c), let imp = instIMP(c, "init") else { return nil }
        return unsafeBitCast(imp, to: InitF.self)(a, NSSelectorFromString("init"))
    }

    private func setObj(_ o: AnyObject, _ c: AnyClass, _ s: String, _ v: AnyObject) {
        guard let imp = instIMP(c, s) else { return }
        unsafeBitCast(imp, to: SetObjF.self)(o, NSSelectorFromString(s), v)
    }

    private func setU32(_ o: AnyObject, _ c: AnyClass, _ s: String, _ v: UInt32) {
        guard let imp = instIMP(c, s) else { return }
        unsafeBitCast(imp, to: SetU32F.self)(o, NSSelectorFromString(s), v)
    }

    private func setSize(_ o: AnyObject, _ c: AnyClass, _ s: String, _ v: CGSize) {
        guard let imp = instIMP(c, s) else { return }
        unsafeBitCast(imp, to: SetSizeF.self)(o, NSSelectorFromString(s), v)
    }

    private func setPt(_ o: AnyObject, _ c: AnyClass, _ s: String, _ v: CGPoint) {
        guard let imp = instIMP(c, s) else { return }
        unsafeBitCast(imp, to: SetPtF.self)(o, NSSelectorFromString(s), v)
    }

    // ===== 对外接口 =====

    /// 建屏。已存在则直接返回。
    @discardableResult
    func turnOn() -> CGDirectDisplayID? {
        if let id = displayID, held != nil { return id }

        guard let DescCls = NSClassFromString("CGVirtualDisplayDescriptor"),
              let VdCls   = NSClassFromString("CGVirtualDisplay"),
              let ModeCls = NSClassFromString("CGVirtualDisplayMode"),
              let SetCls  = NSClassFromString("CGVirtualDisplaySettings") else {
            vlog("❌ 私有类缺失，CGVirtualDisplay 不可用（macOS 版本可能变了）")
            return nil
        }

        // --- Descriptor ---
        guard let d = newInit(DescCls) else { vlog("❌ descriptor 创建失败"); return nil }
        setObj(d, DescCls, "setName:", screenName as NSString)
        setU32(d, DescCls, "setMaxPixelsWide:", logicalW * 2)
        setU32(d, DescCls, "setMaxPixelsHigh:", logicalH * 2)
        setSize(d, DescCls, "setSizeInMillimeters:", CGSize(width: mmW, height: mmH))
        setU32(d, DescCls, "setVendorID:", vendorID)
        setU32(d, DescCls, "setProductID:", productID)
        setU32(d, DescCls, "setSerialNum:", serialNum)
        setPt(d, DescCls, "setRedPrimary:",   CGPoint(x: 0.680, y: 0.320))
        setPt(d, DescCls, "setGreenPrimary:", CGPoint(x: 0.265, y: 0.690))
        setPt(d, DescCls, "setBluePrimary:",  CGPoint(x: 0.150, y: 0.060))
        setPt(d, DescCls, "setWhitePoint:",   CGPoint(x: 0.3127, y: 0.3290))
        setObj(d, DescCls, "setDispatchQueue:", DispatchQueue.main as AnyObject)

        // --- CGVirtualDisplay ---
        guard let raw = allocOf(VdCls),
              let vImp = instIMP(VdCls, "initWithDescriptor:") else {
            vlog("❌ CGVirtualDisplay init 不可用"); return nil
        }
        let vd = unsafeBitCast(vImp, to: VInitF.self)(
            raw, NSSelectorFromString("initWithDescriptor:"), d)

        // --- Mode：注册【逻辑】分辨率，HiDPI 由系统派生 ---
        guard let mRaw = allocOf(ModeCls),
              let mImp = instIMP(ModeCls, "initWithWidth:height:refreshRate:") else {
            vlog("❌ Mode 创建失败"); return nil
        }
        let mode = unsafeBitCast(mImp, to: ModeF.self)(
            mRaw, NSSelectorFromString("initWithWidth:height:refreshRate:"),
            logicalW, logicalH, refresh)

        // --- Settings ---
        guard let settings = newInit(SetCls) else { vlog("❌ settings 创建失败"); return nil }
        setU32(settings, SetCls, "setHiDPI:", 1)          // 关键：开 HiDPI
        setObj(settings, SetCls, "setModes:", [mode] as NSArray)
        setU32(settings, SetCls, "setRotation:", 0)

        // --- apply ---
        setObj(vd, VdCls, "applySettings:", settings)

        guard let idImp = instIMP(VdCls, "displayID") else { vlog("❌ displayID 不可用"); return nil }
        let did = unsafeBitCast(idImp, to: IdF.self)(vd, NSSelectorFromString("displayID"))

        held = vd
        displayID = did
        vlog("✅ 虚拟屏已创建  displayID=\(did)  逻辑 \(logicalW)x\(logicalH) @\(Int(refresh))Hz")

        // applySettings 是异步的，给 WindowServer 一点时间注册，再切 HiDPI
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.held != nil else { return }
            _ = self.applyHiDPIMode(did)

            // 虚拟屏建出来常落在原点，顺手把主屏抢走。
            // 等模式切换稳定后再让回去，交给实体屏（没有实体屏就给 iPad）。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, self.held != nil else { return }
                if Displays.kickVirtualOffMain() {
                    vlog("↩️ 虚拟屏占用了主屏，已让给实体屏/iPad")
                }
            }
        }

        return did
    }

    /// 销毁虚拟屏。屏会立刻从系统消失。
    func turnOff() {
        guard held != nil else { return }
        let old = displayID
        held = nil
        displayID = nil
        vlog("── 虚拟屏已关闭（原 displayID=\(old.map(String.init) ?? "?")）")
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
