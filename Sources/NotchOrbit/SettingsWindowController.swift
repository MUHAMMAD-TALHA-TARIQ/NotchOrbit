import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    /// Called when the window closes; the app delegate drops the controller then.
    var onClose: (() -> Void)?

    init(overlay: OverlayController) {
        let root = SettingsView(overlay: overlay).environmentObject(SettingsStore.shared)
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.title = "NotchOrbit Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 820, height: 600))
        window.minSize = NSSize(width: 720, height: 520)
        window.setFrameAutosaveName("NotchOrbitSettings")
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Keep live readings flowing into the Stats tab while the window is open,
    // even when stats mode itself is switched off.
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        SystemStatsMonitor.shared.previewWanted = true
    }

    func windowWillClose(_ notification: Notification) {
        SystemStatsMonitor.shared.previewWanted = false
        onClose?()
    }
}
