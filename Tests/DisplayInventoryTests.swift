import Foundation

@main
enum DisplayInventoryTests {
    static func main() {
        let real = DisplayInventory.Display(vendor: 0x1234, model: 0x5678)
        let otherReal = DisplayInventory.Display(vendor: 0x4321, model: 0x8765)
        let virtual = DisplayInventory.Display(vendor: DisplayInventory.virtualVendor, model: 0x3C4D)
        let fallback = DisplayInventory.Display(vendor: DisplayInventory.dummyVendor, model: DisplayInventory.dummyModel)
        let ipad = DisplayInventory.Display(vendor: 0x610, model: DisplayInventory.ipadModel)

        let cases: [(String, [DisplayInventory.Display], DisplayInventory.Mode)] = [
            ("empty", [], .waitingForVirtual),
            ("fallback only", [fallback], .waitingForVirtual),
            ("iPad without virtual screen", [ipad], .waitingForVirtual),
            ("headless with virtual screen", [virtual], .headlessReady),
            ("headless with fallback and iPad", [fallback, virtual, ipad], .headlessReady),
            ("physical screen", [real], .physical),
            ("physical screen wins over virtual and iPad", [virtual, ipad, real], .physical),
            ("several physical screens", [real, otherReal], .physical)
        ]
        for (name, screens, expected) in cases {
            let result = DisplayInventory.mode(for: screens)
            guard result == expected else {
                fatalError("\(name): expected \(expected), got \(result)")
            }
        }
        print("DisplayInventory: \(cases.count) cases passed")
    }
}
