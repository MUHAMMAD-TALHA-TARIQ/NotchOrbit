import AppKit
import ScreenCaptureKit

/// One still of a display for the ripple shockwave to bend. Separate from
/// `ScreenCaptureService`, which saves screenshots and recordings to disk.
enum ScreenStill {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system Screen Recording prompt the first time it is called.
    static func requestPermission() { CGRequestScreenCaptureAccess() }

    /// A full-resolution still of `screen` without the cursor or this app's
    /// own windows. Returns nil when Screen Recording is not granted, and on
    /// macOS 13, which has no one-shot capture; the shockwave is then light only.
    static func capture(_ screen: NSScreen, includeSelf: Bool = false) async -> CGImage? {
        guard #available(macOS 14.0, *), hasPermission, let displayID = screen.displayID else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                return nil
            }
            let pid = ProcessInfo.processInfo.processIdentifier
            let ownApps = includeSelf ? [] : content.applications.filter { $0.processID == pid }
            let filter = SCContentFilter(
                display: display, excludingApplications: ownApps, exceptingWindows: [])

            let config = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            config.showsCursor = false
            config.captureResolution = .best
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
        } catch {
            debugLog("ripple: capture failed: \(error.localizedDescription)")
            return nil
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
