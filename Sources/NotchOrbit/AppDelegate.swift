import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var overlay: OverlayController!
    /// Built when Settings is opened and released again when the window closes, so the
    /// SwiftUI hierarchy doesn't stay resident for the life of the app.
    private var settingsWindow: SettingsWindowController?
    private var showOverlayItem: NSMenuItem!
    private var stopRecordingItem: NSMenuItem!
    private var virtualMicItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyFirstLaunchDefaultsIfNeeded()
        overlay = OverlayController()
        setupStatusItem()
        NotificationCenter.default.addObserver(self, selector: #selector(openSettings),
                                               name: StatsPanelView.openSettingsRequested, object: nil)

        if SettingsStore.shared.isFirstLaunch {
            openSettings()
        }
        VirtualMicrophone.resumeAtLaunch()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    // MARK: Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "NotchOrbit")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "NotchOrbit"
        }

        let menu = NSMenu()
        menu.delegate = self
        showOverlayItem = NSMenuItem(title: "Show Overlay", action: #selector(toggleOverlay), keyEquivalent: "")
        showOverlayItem.target = self
        menu.addItem(showOverlayItem)
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        stopRecordingItem = NSMenuItem(title: "Stop Screen Recording", action: #selector(stopRecording), keyEquivalent: "")
        stopRecordingItem.target = self
        menu.addItem(stopRecordingItem)
        virtualMicItem = NSMenuItem(title: "Use Voice Effect as Microphone", action: #selector(toggleVirtualMic), keyEquivalent: "")
        virtualMicItem.target = self
        menu.addItem(virtualMicItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit NotchOrbit", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu

        if Debug.enabled {
            debugLog("[debug] status item window:", statusItem.button?.window?.frame as Any, "visible:", statusItem.isVisible)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        showOverlayItem.state = SettingsStore.shared.settings.overlayVisible ? .on : .off
        stopRecordingItem.isHidden = !ScreenCaptureService.shared.isRecording
        let mic = SettingsStore.shared.settings.stats.mic
        virtualMicItem.state = mic.useAsMicrophone ? .on : .off
        virtualMicItem.title = mic.useAsMicrophone ? "Use Voice Effect as Microphone (\(mic.effect.title))" : "Use Voice Effect as Microphone"
    }

    func applicationWillTerminate(_ notification: Notification) {
        ScreenCaptureService.shared.finishForTermination()
        VoiceChanger.current?.stop()   // finishes any voice recording
        VirtualMicrophone.restoreForQuit()
        SettingsStore.shared.flush()
    }

    // MARK: Actions

    @objc private func toggleOverlay() {
        SettingsStore.shared.settings.overlayVisible.toggle()
    }

    @objc private func stopRecording() {
        ScreenCaptureService.shared.stopRecording { result in
            if case .success(let url) = result { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    @objc private func toggleVirtualMic() {
        if VirtualMicrophone.isOn {
            VirtualMicrophone.disable()
            return
        }
        do {
            try VirtualMicrophone.enable()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't use the voice effect as a microphone"
            alert.informativeText = error.localizedDescription
            if case VirtualMicrophone.Failure.noLoopbackDevice = error {
                alert.addButton(withTitle: "Open Settings")
                alert.addButton(withTitle: "Cancel")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn { openSettings() }
            } else {
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let controller = SettingsWindowController(overlay: overlay)
            controller.onClose = { [weak self] in
                // Let the close finish before the controller (and its window) go away.
                DispatchQueue.main.async { self?.settingsWindow = nil }
            }
            settingsWindow = controller
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: First launch

    /// On first launch, start with the rounded overlay so the user sees something immediately.
    private func applyFirstLaunchDefaultsIfNeeded() {
        let store = SettingsStore.shared
        guard store.isFirstLaunch else { return }
        store.settings.preset = .rounded
        store.settings.shape = NotchPreset.rounded.params ?? NotchShapeParams()
    }
}
