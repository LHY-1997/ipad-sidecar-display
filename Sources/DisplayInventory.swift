import CoreGraphics

/// Both the panel and the watchdog must make the same decision about displays.
enum DisplayInventory {
    static let ipadModel: UInt32 = 0x69506164
    static let virtualVendor: UInt32 = 0x1A2B
    static let dummyVendor: UInt32 = 0x756E6B6E
    static let dummyModel: UInt32 = 0x76697274

    struct Display {
        let vendor: UInt32
        let model: UInt32

        var isPhysical: Bool {
            vendor != DisplayInventory.virtualVendor && model != DisplayInventory.ipadModel &&
                vendor != DisplayInventory.dummyVendor && model != DisplayInventory.dummyModel
        }

        var isVirtual: Bool { vendor == DisplayInventory.virtualVendor }
    }

    enum Mode: Equatable {
        case physical
        case waitingForVirtual
        case headlessReady
    }

    static func mode(for displays: [Display]) -> Mode {
        if displays.contains(where: { $0.isPhysical }) { return .physical }
        if displays.contains(where: { $0.isVirtual }) { return .headlessReady }
        return .waitingForVirtual
    }

    /// Online displays include sleeping monitors, avoiding reconnection on sleep.
    /// A failed query is unknown, not evidence that there is no physical screen.
    static func onlineIDs() -> [CGDirectDisplayID]? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        return Array(ids.prefix(Int(count)))
    }

    static func describe(_ id: CGDirectDisplayID) -> Display {
        Display(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id))
    }

    static func currentMode() -> Mode? {
        onlineIDs().map { mode(for: $0.map(describe)) }
    }
}
