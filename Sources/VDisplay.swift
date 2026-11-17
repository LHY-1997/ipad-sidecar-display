// ipad-vdisplay —— 常驻进程，创建并持有虚拟屏
// 替代 BetterDisplay 的「虚拟屏」功能，为无头 Mac mini 提供一块假屏
import Foundation
import CoreGraphics
import AppKit

// ============ 配置（对齐 BetterDisplay 那块「虚拟 16:9」） ============
let LOGICAL_W: UInt32 = 2560      // 逻辑宽（HiDPI 的一半）
let LOGICAL_H: UInt32 = 1440      // 逻辑高
let REFRESH: Double = 60
var SCREEN_NAME = "虚拟 16:9"
let MM_W: Double = 530.81
let MM_H: Double = 298.58
let VENDOR_ID: UInt32 = 0x1A2B
let PRODUCT_ID: UInt32 = 0x3C4D
let SERIAL: UInt32 = 0x5E6F

let SUPPORT_DIR = NSHomeDirectory() + "/Library/Application Support/ipad-watchdog"
let LOG_FILE = SUPPORT_DIR + "/vdisplay.log"

func log(_ msg: String) {
    let df = DateFormatter(); df.dateFormat = "MM-dd HH:mm:ss"
    let line = "[\(df.string(from: Date()))] \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let h = FileHandle(forWritingAtPath: LOG_FILE) {
        h.seekToEndOfFile(); h.write(data); h.closeFile()
    } else {
        try? data.write(to: URL(fileURLWithPath: LOG_FILE))
    }
}

// ============ ObjC runtime 桥（不链接私有框架，运行时反射） ============
func cls(_ n: String) -> AnyClass? { NSClassFromString(n) }
func instIMP(_ c: AnyClass, _ s: String) -> IMP? {
    guard let m = class_getInstanceMethod(c, NSSelectorFromString(s)) else { return nil }
    return method_getImplementation(m)
}
func classIMP(_ c: AnyClass, _ s: String) -> IMP? {
    guard let m = class_getClassMethod(c, NSSelectorFromString(s)) else { return nil }
    return method_getImplementation(m)
}
let ALLOC_SEL = NSSelectorFromString("alloc")
let INIT_SEL  = NSSelectorFromString("init")

typealias AllocF   = @convention(c) (AnyClass, Selector) -> AnyObject
typealias InitF    = @convention(c) (AnyObject, Selector) -> AnyObject
typealias SetObjF  = @convention(c) (AnyObject, Selector, AnyObject) -> Void
typealias SetU32F  = @convention(c) (AnyObject, Selector, UInt32) -> Void
typealias SetSizeF = @convention(c) (AnyObject, Selector, CGSize) -> Void
typealias SetPtF   = @convention(c) (AnyObject, Selector, CGPoint) -> Void
typealias ModeF    = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> AnyObject
typealias IdF      = @convention(c) (AnyObject, Selector) -> UInt32

func allocOf(_ c: AnyClass) -> AnyObject? {
    guard let imp = classIMP(c, "alloc") else { return nil }
    return unsafeBitCast(imp, to: AllocF.self)(c, ALLOC_SEL)
}
func newInit(_ c: AnyClass) -> AnyObject? {
    guard let a = allocOf(c), let imp = instIMP(c, "init") else { return nil }
    return unsafeBitCast(imp, to: InitF.self)(a, INIT_SEL)
}
func setObj(_ o: AnyObject, _ c: AnyClass, _ s: String, _ v: AnyObject) {
    guard let imp = instIMP(c, s) else { return }
    unsafeBitCast(imp, to: SetObjF.self)(o, NSSelectorFromString(s), v)
}
func setU32(_ o: AnyObject, _ c: AnyClass, _ s: String, _ v: UInt32) {
    guard let imp = instIMP(c, s) else { return }
    unsafeBitCast(imp, to: SetU32F.self)(o, NSSelectorFromString(s), v)
}
func setSize(_ o: AnyObject, _ c: AnyClass, _ s: String, _ v: CGSize) {
    guard let imp = instIMP(c, s) else { return }
    unsafeBitCast(imp, to: SetSizeF.self)(o, NSSelectorFromString(s), v)
}
func setPt(_ o: AnyObject, _ c: AnyClass, _ s: String, _ v: CGPoint) {
    guard let imp = instIMP(c, s) else { return }
    unsafeBitCast(imp, to: SetPtF.self)(o, NSSelectorFromString(s), v)
}

// ============ 建屏 ============
var heldDisplay: AnyObject?   // 全局持有，绝不能释放

func createVirtualDisplay() -> CGDirectDisplayID? {
    guard let DescCls = cls("CGVirtualDisplayDescriptor"),
          let VdCls   = cls("CGVirtualDisplay"),
          let ModeCls = cls("CGVirtualDisplayMode"),
          let SetCls  = cls("CGVirtualDisplaySettings") else {
        log("❌ 私有类缺失，CGVirtualDisplay 不可用")
        return nil
    }

    // --- Descriptor ---
    guard let d = newInit(DescCls) else { log("❌ descriptor 创建失败"); return nil }
    setObj(d, DescCls, "setName:", SCREEN_NAME as NSString)
    setU32(d, DescCls, "setMaxPixelsWide:", LOGICAL_W * 2)
    setU32(d, DescCls, "setMaxPixelsHigh:", LOGICAL_H * 2)
    setSize(d, DescCls, "setSizeInMillimeters:", CGSize(width: MM_W, height: MM_H))
    setU32(d, DescCls, "setVendorID:", VENDOR_ID)
    setU32(d, DescCls, "setProductID:", PRODUCT_ID)
    setU32(d, DescCls, "setSerialNum:", SERIAL)
    setPt(d, DescCls, "setRedPrimary:",   CGPoint(x: 0.680, y: 0.320))
    setPt(d, DescCls, "setGreenPrimary:", CGPoint(x: 0.265, y: 0.690))
    setPt(d, DescCls, "setBluePrimary:",  CGPoint(x: 0.150, y: 0.060))
    setPt(d, DescCls, "setWhitePoint:",   CGPoint(x: 0.3127, y: 0.3290))
    setObj(d, DescCls, "setDispatchQueue:", DispatchQueue.main as AnyObject)

    // --- CGVirtualDisplay ---
    guard let raw = allocOf(VdCls),
          let vImp = instIMP(VdCls, "initWithDescriptor:") else {
        log("❌ CGVirtualDisplay init 不可用"); return nil
    }
    typealias VInitF = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject
    let vInit = unsafeBitCast(vImp, to: VInitF.self)
    let vd = vInit(raw, NSSelectorFromString("initWithDescriptor:"), d)

    // --- Mode：注册【逻辑】分辨率，HiDPI 由系统派生 ---
    guard let mRaw = allocOf(ModeCls),
          let mImp = instIMP(ModeCls, "initWithWidth:height:refreshRate:") else {
        log("❌ Mode 创建失败"); return nil
    }
    let mode = unsafeBitCast(mImp, to: ModeF.self)(
        mRaw, NSSelectorFromString("initWithWidth:height:refreshRate:"),
        LOGICAL_W, LOGICAL_H, REFRESH)

    // --- Settings ---
    guard let settings = newInit(SetCls) else { log("❌ settings 创建失败"); return nil }
    setU32(settings, SetCls, "setHiDPI:", 1)          // 关键：开 HiDPI
    setObj(settings, SetCls, "setModes:", [mode] as NSArray)
    setU32(settings, SetCls, "setRotation:", 0)

    // --- apply ---
    setObj(vd, VdCls, "applySettings:", settings)

    guard let idImp = instIMP(VdCls, "displayID") else { log("❌ displayID 不可用"); return nil }
    let did = unsafeBitCast(idImp, to: IdF.self)(vd, NSSelectorFromString("displayID"))
    heldDisplay = vd
    log("✅ 虚拟屏已创建  displayID=\(did)  逻辑 \(LOGICAL_W)x\(LOGICAL_H) @\(Int(REFRESH))Hz")
    return did
}

// 切到 HiDPI 模式（物理 = 逻辑×2）
func applyHiDPIMode(_ did: CGDirectDisplayID) -> Bool {
    let opts = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
    guard let list = CGDisplayCopyAllDisplayModes(did, opts) as? [CGDisplayMode] else { return false }
    let targetW = Int(LOGICAL_W * 2), targetH = Int(LOGICAL_H * 2)
    guard let hi = list.first(where: { $0.pixelWidth == targetW && $0.pixelHeight == targetH }) else {
        log("⚠️ 未找到 \(targetW)x\(targetH) 的 HiDPI 模式")
        return false
    }
    if let cur = CGDisplayCopyDisplayMode(did),
       cur.width == hi.width, cur.pixelWidth == hi.pixelWidth {
        log("ℹ️ 已是目标模式 逻辑 \(hi.width)x\(hi.height) / 物理 \(hi.pixelWidth)x\(hi.pixelHeight)")
        return true
    }
    var cfg: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg = cfg else {
        log("❌ CGBeginDisplayConfiguration 失败"); return false
    }
    CGConfigureDisplayWithDisplayMode(cfg, did, hi, nil)
    let r = CGCompleteDisplayConfiguration(cfg, .forSession)
    if r == .success {
        log("✅ 已切 HiDPI  逻辑 \(hi.width)x\(hi.height) / 物理 \(hi.pixelWidth)x\(hi.pixelHeight)")
        return true
    } else {
        log("❌ 切模式失败 err=\(r.rawValue)")
        return false
    }
}

// ============ 主流程 ============
let args = CommandLine.arguments
let testMode = args.contains("--test")
if testMode { SCREEN_NAME = "虚拟 16:9 (Test)" }

log("── ipad-vdisplay 启动 ──")

guard let did = createVirtualDisplay() else {
    log("❌ 虚拟屏创建失败，5 秒后退出交由 launchd 重试")
    Thread.sleep(forTimeInterval: 5)
    exit(1)
}

// applySettings 是异步的，给 WindowServer 一点时间注册
Thread.sleep(forTimeInterval: 1.0)
_ = applyHiDPIMode(did)

if testMode {
    Thread.sleep(forTimeInterval: 6.0)
    log("── 测试模式结束，虚拟屏随进程退出消失 ──")
    exit(0)
}

// 常驻：跑 RunLoop，持有 heldDisplay
log("── 进入常驻，持有虚拟屏 ──")
let sigtrap: @convention(c) (Int32) -> Void = { sig in
    log("收到信号 \(sig)，进程退出（虚拟屏将消失）")
    // 用非零退出码，让 launchd 的 KeepAlive(SuccessfulExit=false) 判定为异常并重启
    exit(1)
}
signal(SIGTERM, sigtrap)
signal(SIGINT, sigtrap)
RunLoop.main.run()
