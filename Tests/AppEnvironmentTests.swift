import Foundation

@main
enum AppEnvironmentTests {
    static func main() {
        #if SIDECAR_TEST
        precondition(AppEnvironment.appName == "iPad随航 2.4.1.app")
        precondition(AppEnvironment.executableName == "iPad随航241")
        precondition(AppEnvironment.supportName == "ipad-watchdog-test")
        precondition(AppEnvironment.watchdogLabel == "com.local.ipad-watchdog-test")
        #else
        precondition(AppEnvironment.appName == "iPad随航.app")
        precondition(AppEnvironment.executableName == "iPad随航")
        precondition(AppEnvironment.supportName == "ipad-watchdog")
        precondition(AppEnvironment.watchdogLabel == "com.local.ipad-watchdog")
        #endif
        print("AppEnvironment isolation passed")
    }
}
