import AppKit
import Combine

/// Owns one overlay window per display and keeps them in sync with settings + display changes.
final class OverlayController {
    private struct Slot {
        let window = OverlayWindow()
        let view = OverlayView()
        init() { window.contentView = view }
    }

    private var slots: [Slot] = []
    private(set) var targets: [OverlayTarget] = []
    private var statsSubscription: AnyCancellable?
    private var weatherSubscription: AnyCancellable?
    private var clickMonitor: Any?
    private var moveMonitor: Any?
    private var debugTabOpened = false

    init() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(relayout), name: SettingsStore.didChange, object: nil)
        nc.addObserver(self, selector: #selector(relayout), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // New readings only repaint the stats circles / panel; no need for a full relayout.
        // `history` is published after `snapshot` on every tick, so both are current here.
        let monitor = SystemStatsMonitor.shared
        statsSubscription = monitor.$history.sink { [weak self] history in
            guard let self else { return }
            let settings = SettingsStore.shared.settings
            guard settings.stats.enabled else { return }
            self.slots.forEach { $0.view.update(snapshot: monitor.snapshot, history: history, settings: settings) }
        }
        // Weather readings arrive every few minutes; repaint just the right circle.
        let weather = WeatherService.shared
        weatherSubscription = weather.$reading.combineLatest(weather.$status).sink { [weak self] reading, status in
            guard let self else { return }
            let settings = SettingsStore.shared.settings
            guard settings.weather.enabled else { return }
            let shown = (reading?.isStale ?? true) ? nil : reading
            self.slots.forEach { $0.view.updateWeather(reading: shown, status: status, settings: settings) }
        }
        // The overlay windows are click-through except while the pointer is over a drawn
        // part of the overlay. Follow the mouse to flip that per window, so clicks on the
        // notch, island, circles or panel are swallowed instead of reaching what's behind.
        // The windows are only as large as the overlay needs, so most moves are rejected
        // by a bounds check.
        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] _ in
            self?.updateMouseTransparency(at: NSEvent.mouseLocation)
        }
        // Clicks that land elsewhere still matter: they collapse an expanded panel.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.handleGlobalClick(at: NSEvent.mouseLocation)
        }
        relayout()
    }

    deinit {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let moveMonitor { NSEvent.removeMonitor(moveMonitor) }
    }

    private func updateMouseTransparency(at point: CGPoint) {
        for slot in slots where slot.window.isVisible {
            slot.view.updateMouseTransparency(at: point)
        }
    }

    private func handleGlobalClick(at point: CGPoint) {
        for slot in slots where slot.window.isVisible {
            if slot.view.handleGlobalClick(at: point) {
                if Debug.enabled { debugLog("[debug] circle clicked at", point, slot.view.debugSummary()) }
                return
            }
        }
    }

    @objc func relayout() {
        let settings = SettingsStore.shared.settings
        targets = OverlayTarget.detect(settings: settings)

        let monitor = SystemStatsMonitor.shared
        monitor.interval = settings.stats.refreshInterval
        monitor.wanted = settings.stats.enabled && settings.overlayVisible

        // Runs whenever weather mode is on (even with the overlay hidden) so the
        // settings preview stays live; it is one small request every few minutes.
        let weather = WeatherService.shared
        weather.settings = settings.weather
        weather.wanted = settings.weather.enabled

        guard settings.overlayVisible else {
            slots.forEach { $0.window.orderOut(nil) }
            return
        }

        while slots.count < targets.count { slots.append(Slot()) }

        for (index, slot) in slots.enumerated() {
            guard index < targets.count else { slot.window.orderOut(nil); continue }
            let target = targets[index]
            let screen = target.screen.frame

            // The window covers only what the overlay can draw: a strip around the notch
            // or island, grown to the panel's size while it is expanded. (It used to span
            // the whole display width at the panel's full height; the window server keeps
            // a backing surface for every window, so the size costs memory.)
            let top = CGRect(x: 0, y: screen.maxY - target.rect.maxY, width: target.rect.width, height: target.rect.height)
            let width = min(screen.width, OverlayView.requiredWidth(settings: settings, rect: top))
            let height = min(screen.height, slot.view.isExpanded ? OverlayView.expandedHeight
                                                                 : OverlayView.collapsedHeight(settings: settings, rect: top))
            let x = min(max(screen.minX, target.rect.midX - width / 2), screen.maxX - width).rounded()
            let frame = CGRect(x: x, y: screen.maxY - height, width: width, height: height)
            slot.window.setFrame(frame, display: false)

            // Target rect in the view's flipped coordinates (y = 0 is the top of the screen).
            let local = CGRect(x: target.rect.minX - frame.minX, y: top.minY, width: target.rect.width, height: target.rect.height)
            slot.view.needsLayout = true
            slot.view.apply(settings: settings, rect: local, kind: target.kind)
            slot.window.orderFrontRegardless()
            slot.view.updateMouseTransparency(at: NSEvent.mouseLocation)

            if Debug.enabled {
                slot.view.layoutSubtreeIfNeeded()
                debugLog("[debug] target:", target.description, "rect(global):", target.rect)
                debugLog("[debug] window frame:", slot.window.frame, "level:", slot.window.level.rawValue)
                debugLog("[debug]", slot.view.debugSummary())
            }
        }
        // NOTCHORBIT_DEBUG_TAB=mic opens the panel on that tab right after launch.
        if !debugTabOpened, settings.stats.enabled, let tab = Debug.tab, let first = slots.first, !targets.isEmpty {
            debugTabOpened = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { first.view.debugExpand(tab: tab) }
        }
    }
}
