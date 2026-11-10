import Foundation

enum BackgroundRuntimeRole {
    #if WAIFUX_HELPER
    static let isHelper = true
    #else
    static let isHelper = false
    #endif

    static var isRemoteUI: Bool { !isHelper }
    static var isIsolatedTest: Bool {
        ProcessInfo.processInfo.environment["WAIFUX_HELPER_TEST_SUITE"] != nil
    }

    /// Configuration/process isolation does not isolate WindowServer output.
    /// Real desktop rendering requires an explicit opt-in from the test runner.
    static var allowsDesktopRendering: Bool {
        !isIsolatedTest || ProcessInfo.processInfo.environment["WAIFUX_HELPER_TEST_ALLOW_DESKTOP_RENDERING"] == "1"
    }

    static func permitsOperation(_ operation: String) -> Bool {
        guard !allowsDesktopRendering else { return true }
        return !["wallpaper.", "desktop."].contains { operation.hasPrefix($0) }
    }
}
