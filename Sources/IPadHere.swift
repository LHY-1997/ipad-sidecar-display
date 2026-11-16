import Foundation
import CoreGraphics
import CoreAudio
import IOKit

func screenIsAwake() -> Bool { CGDisplayIsAsleep(CGMainDisplayID()) == 0 }
func screenIsLocked() -> Bool {
    guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return (d["CGSSessionScreenIsLocked"] as? Bool) ?? false
}
func audioIsPlaying() -> Bool {
    var dev = AudioDeviceID(0); var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &dev) == noErr, dev != 0 else { return false }
    var run: UInt32 = 0; var rs = UInt32(MemoryLayout<UInt32>.size)
    var ra = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(dev, &ra, 0, nil, &rs, &run) == noErr else { return false }
    return run != 0
}
func userIdleSeconds() -> Double {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"), &iter) == KERN_SUCCESS else { return 9999 }
    defer { IOObjectRelease(iter) }
    let svc = IOIteratorNext(iter); guard svc != 0 else { return 9999 }
    defer { IOObjectRelease(svc) }
    var props: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let dict = props?.takeRetainedValue() as? [String: Any],
          let idle = dict["HIDIdleTime"] as? Int64 else { return 9999 }
    return Double(idle) / 1_000_000_000
}
func userIsHere() -> Bool {
    if !screenIsAwake() { return false }
    if screenIsLocked() { return false }
    let idle = userIdleSeconds()
    if idle < 300 { return true }
    if audioIsPlaying() { return true }
    if idle < 1800 { return true }
    return false
}
let aw = screenIsAwake(), lk = screenIsLocked(), au = audioIsPlaying(), id = userIdleSeconds()
print(String(format: "屏幕亮=%@ 已锁屏=%@ 有音频=%@ 空闲=%.1f秒 → 人在=%@",
             aw ? "是":"否", lk ? "是":"否", au ? "是":"否", id, userIsHere() ? "是":"否"))
