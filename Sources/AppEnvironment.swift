import Foundation

/// The test build keeps its application, preferences and login services separate.
enum AppEnvironment {
    #if SIDECAR_TEST
    static let supportName = "ipad-watchdog-test"
    static let appName = "iPad随航 2.4.1.app"
    static let executableName = "iPad随航241"
    static let displayName = "iPad 随航 2.4.1"
    static let watchdogLabel = "com.local.ipad-watchdog-test"
    #else
    static let supportName = "ipad-watchdog"
    static let appName = "iPad随航.app"
    static let executableName = "iPad随航"
    static let displayName = "iPad 随航"
    static let watchdogLabel = "com.local.ipad-watchdog"
    #endif

    static let supportPath = NSHomeDirectory() + "/Library/Application Support/" + supportName
    static let appPath = "/Applications/" + appName
    static let watchdogPlist = NSHomeDirectory() + "/Library/LaunchAgents/" + watchdogLabel + ".plist"
}
