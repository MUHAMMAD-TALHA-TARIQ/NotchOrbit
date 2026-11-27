import AppKit
import Carbon.HIToolbox
import MetalKit

/// The Screen Ripple feature: a shockwave that bends what is on screen, set
/// off by a shortcut, an AirDrop arriving or the Mac locking and unlocking,
/// and effects that follow the beat of whatever the Mac is playing.
///
/// Everything here is created on first use and only while the feature is on:
/// with it off, NotchOrbit holds no Metal device, capture stream or hotkey.
final class ScreenRipple {
    static let shared = ScreenRipple()

    enum Source { case top, cursor, center }

    private lazy var device = MTLCreateSystemDefaultDevice()
    private var overlays: [RippleOverlay] = []   // one per attached screen, made on demand
    private var generation = 0
    private var observing = false
    private var hotkeysOn = false
    private var askedForScreenRecording = false

    private lazy var previewPanel = AirDropPreviewPanel()
    private lazy var airDropWatcher = AirDropWatcher { [weak self] urls in
        // The ripple spreads from the middle of the screen and the received
        // content appears at its centre.
        guard let self else { return }
        if LockScreen.isLocked {
            // Ripple now, but keep what arrived off the lock screen: the
            // card appears once the Mac is unlocked.
            self.receivedWhileLocked += urls
            self.ripple(from: .center)
        } else {
            self.ripple(from: .center) { point, screen in
                self.previewPanel.show(urls, centeredAt: point, on: screen)
            }
        }
    }
    private var receivedWhileLocked: [URL] = []

    private lazy var musicListener = MusicListener { [weak self] beat in self?.pulse(for: beat) }
    private var hue: Float = 0.52
    private var shuffled = RippleMusicEffect.glass   // what Shuffle is showing now
    private var bassBeats = 0
    private var feeds: [CGDirectDisplayID: LiveScreen] = [:]
    private var feedStop: DispatchWorkItem?
    private var musicChecked = false

    private init() {}

    /// What the feature should be doing right now. `NOTCHORBIT_DEBUG_RIPPLE`
    /// switches everything on for a run without touching the stored settings.
    private var settings: RippleSettings {
        guard !Debug.ripple else {
            var all = SettingsStore.shared.settings.ripple
            all.enabled = true
            all.hotkeys = true
            all.onAirDrop = true
            all.onLock = true
            all.withMusic = true
            return all
        }
        return SettingsStore.shared.settings.ripple
    }

    /// Called once at launch; follows the settings from then on.
    func start() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(
            forName: SettingsStore.didChange, object: nil, queue: .main) { [weak self] _ in self?.apply() }
        apply()
        if Debug.ripple {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.ripple(from: .top) }
        }
    }

    /// Starts and stops the triggers to match the settings.
    private func apply() {
        let settings = settings
        let on = settings.enabled

        if on && settings.hotkeys {
            if !hotkeysOn {
                hotkeysOn = true
                HotKey.register(keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey) { [weak self] in
                    self?.ripple(from: .top)
                }
                HotKey.register(keyCode: kVK_ANSI_R, modifiers: controlKey | optionKey) { [weak self] in
                    self?.ripple(from: .cursor)
                }
            }
        } else if hotkeysOn {
            hotkeysOn = false
            HotKey.unregisterAll()
        }

        if on && settings.onAirDrop {
            hasAirDropWatcher = true
            airDropWatcher.start()
        } else if hasAirDropWatcher {
            airDropWatcher.stop()
        }
        // The sound comes through Screen Recording; without it there is nothing to hear.
        if on && settings.withMusic && ScreenStill.hasPermission {
            hasMusicListener = true
            musicListener.start()
        } else if hasMusicListener {
            musicListener.stop()
            stopFeeds()
        }
        if on {
            LockScreen.observe(
                onLock: { [weak self] in self?.screenDidLock() },
                onUnlock: { [weak self] in self?.screenDidUnlock() })
            // Bending the screen needs to see it. Ask once, when the feature is first switched on.
            if !ScreenStill.hasPermission && !askedForScreenRecording {
                askedForScreenRecording = true
                ScreenStill.requestPermission()
            }
        } else {
            overlays.forEach { $0.hide() }
        }
    }

    // Lazy properties are created by their first use, so "stop" must not be that use.
    private var hasAirDropWatcher = false
    private var hasMusicListener = false

    func shutdown() {
        if hasMusicListener { musicListener.stop() }
        stopFeeds()
    }

    // MARK: Lock screen

    private func screenDidLock() {
        debugLog("ripple: screen locked")
        stopFeeds()
        guard settings.enabled, settings.onLock else { return }
        // Give the lock screen a moment to finish appearing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard LockScreen.isLocked else { return }
            self?.ripple(from: .top)
        }
    }

    private func screenDidUnlock() {
        debugLog("ripple: screen unlocked")
        let urls = receivedWhileLocked
        receivedWhileLocked = []
        guard settings.enabled, settings.onLock || !urls.isEmpty else { return }
        // Wait for the desktop to be back so the screenshot is of it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !LockScreen.isLocked else { return }
            self.ripple(from: .center) { point, screen in
                if !urls.isEmpty { self.previewPanel.show(urls, centeredAt: point, on: screen) }
            }
        }
    }

    // MARK: Shockwave

    func ripple(from source: Source, onStart: ((CGPoint, NSScreen) -> Void)? = nil) {
        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens
        guard device != nil,
              let home = screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        else { return }

        // One source point in global screen coordinates; every screen draws
        // its part of the same wave, so it crosses from one display to the next.
        let point: CGPoint
        switch source {
        case .top: point = CGPoint(x: home.frame.midX, y: home.frame.maxY)
        case .cursor: point = mouse
        case .center: point = CGPoint(x: home.frame.midX, y: home.frame.midY)
        }

        generation += 1
        let current = generation
        // A capture taken while locked could hold the desktop behind the lock
        // screen, and the wave would then show pieces of it to anyone looking.
        // The lock screen gets the light-only wave instead.
        let locked = LockScreen.isLocked
        Task { @MainActor in
            debugLog("ripple: requested, permission=\(ScreenStill.hasPermission), screens=\(screens.count), locked=\(locked)")
            let shots = await withTaskGroup(of: (Int, CGImage?).self) { group in
                for (index, screen) in screens.enumerated() {
                    group.addTask { (index, locked ? nil : await ScreenStill.capture(screen)) }
                }
                var result = [CGImage?](repeating: nil, count: screens.count)
                for await (index, image) in group { result[index] = image }
                return result
            }
            guard current == self.generation else { return }  // a newer ripple took over
            self.play(on: screens, from: point, screenshots: shots)
            onStart?(point, home)
        }
    }

    private func ensureOverlays(_ count: Int) -> Bool {
        guard let device else { return false }
        while overlays.count < count {
            guard let overlay = RippleOverlay(device: device) else { return false }
            overlays.append(overlay)
        }
        return true
    }

    private func play(on screens: [NSScreen], from point: CGPoint, screenshots: [CGImage?]) {
        guard ensureOverlays(screens.count) else { return }
        for overlay in overlays.dropFirst(screens.count) { overlay.hide() }

        // The wave runs until it has passed the farthest corner of any screen.
        let farthest = screens.flatMap { screen -> [CGPoint] in
            let f = screen.frame
            return [CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.maxX, y: f.minY),
                    CGPoint(x: f.minX, y: f.maxY), CGPoint(x: f.maxX, y: f.maxY)]
        }.map { hypot($0.x - point.x, $0.y - point.y) }.max() ?? 1
        let duration = Float(0.9 + farthest / 1300)
        let startTime = CACurrentMediaTime()

        for (index, screen) in screens.enumerated() {
            let overlay = overlays[index]
            let renderer = overlay.renderer
            let frame = screen.frame
            let scale = screen.backingScaleFactor
            let screenshot = screenshots[index]

            // Origin in this screen's pixels from its top-left, like the
            // screenshot; it lies outside the screen when the wave starts elsewhere.
            renderer.origin = SIMD2(Float((point.x - frame.minX) * scale), Float((frame.maxY - point.y) * scale))
            renderer.maxRadius = Float(farthest * scale)
            renderer.scale = Float(scale)
            renderer.screenFrame = frame
            renderer.duration = duration
            renderer.screenTexture = screenshot.flatMap(renderer.makeTexture(from:))
            overlay.show(on: screen, colorSpace: screenshot?.colorSpace, startTime: startTime)

            if Debug.ripple {
                // Self-check: how much of the screen did the overlay actually change?
                // Only the percentage is logged; no image leaves the process.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    Task { @MainActor in
                        guard let during = await ScreenStill.capture(screen, includeSelf: true) else { return debugLog("ripple: self-check capture failed") }
                        var reference = screenshot
                        if reference == nil {
                            // Locked: there is no "before", so compare with the screen once the wave has gone.
                            try? await Task.sleep(nanoseconds: UInt64((Double(duration) + 0.5) * 1_000_000_000))
                            reference = await ScreenStill.capture(screen, includeSelf: true)
                        }
                        guard let reference else { return debugLog("ripple: self-check capture failed") }
                        debugLog("ripple: self-check [\(screen.localizedName)] locked=\(LockScreen.isLocked): \(changedFraction(reference, during))% of screen pixels differ mid-ripple")
                    }
                }
            }
        }
    }

    // MARK: Music

    /// Turns one beat into pieces of the current effect. Bass hits make the
    /// big gesture and move the colour on round the wheel; snares and hi-hats
    /// answer with something smaller in the opposite colour. Harder hits are
    /// larger and stronger.
    private func pulse(for beat: Beat) {
        let settings = settings
        let screens = NSScreen.screens
        guard settings.enabled, settings.withMusic, let anyScreen = screens.randomElement(),
              let home = screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main,
              ensureOverlays(screens.count)
        else { return }

        let low = beat.kind == .low
        let hit = CGFloat(beat.strength)
        if low {
            hue = (hue + 0.13).truncatingRemainder(dividingBy: 1)
            bassBeats += 1
            if bassBeats % 24 == 0 {
                let choices = RippleMusicEffect.allCases.filter { $0 != .shuffle && $0 != shuffled }
                shuffled = choices.randomElement() ?? .glass
            }
        }
        let effect = settings.musicEffect == .shuffle ? shuffled : settings.musicEffect
        let tint = NSColor(hue: CGFloat(low ? hue : (hue + 0.5).truncatingRemainder(dividingBy: 1)),
                           saturation: 0.85, brightness: 1, alpha: 1).usingColorSpace(.sRGB) ?? .cyan
        let color = SIMD3(Float(tint.redComponent), Float(tint.greenComponent), Float(tint.blueComponent))
        let now = CACurrentMediaTime()

        var elements: [RippleElement] = []
        switch effect {
        case .glass, .shuffle:
            // One wave for all screens: down from the top on the bass,
            // back up from the bottom on the snare.
            let span = hypot(home.frame.width / 2, home.frame.height)
            elements.append(RippleElement(
                kind: .ring,
                origin: CGPoint(x: home.frame.midX, y: low ? home.frame.maxY : home.frame.minY),
                startTime: now, duration: low ? 1.5 : 0.9, color: color,
                strength: low ? 0.55 + 0.45 * beat.strength : 0.4 + 0.35 * beat.strength,
                size: span * (low ? 0.75 + 0.45 * hit : 0.35 + 0.3 * hit),
                width: low ? 1 : 0.55))

        case .bubbles:
            // A big bubble on the bass, a couple of small ones on the snare.
            // They open where they are and drift upward until they pop.
            for _ in 0..<(low ? 1 : 2) {
                let radius = low ? 42 + 70 * hit : CGFloat.random(in: 10...24) + 8 * hit
                let frame = anyScreen.frame
                elements.append(RippleElement(
                    kind: .bubble,
                    origin: CGPoint(x: .random(in: frame.minX + radius...frame.maxX - radius),
                                    y: .random(in: frame.minY + radius...frame.minY + frame.height * 0.72)),
                    velocity: CGVector(dx: .random(in: -14...14), dy: (low ? 26 : 48) + .random(in: 0...26)),
                    startTime: now, duration: low ? .random(in: 3.2...4.6) : .random(in: 2.2...3.4),
                    color: color, strength: 0.75 + 0.25 * beat.strength, size: radius))
            }

        case .rain:
            // A drop lands somewhere and its rings spread across the surface.
            let frame = anyScreen.frame.insetBy(dx: 60, dy: 60)
            elements.append(RippleElement(
                kind: .ring,
                origin: CGPoint(x: .random(in: frame.minX...frame.maxX), y: .random(in: frame.minY...frame.maxY)),
                startTime: now, duration: low ? 1.6 : 1.0, color: color,
                strength: low ? 0.6 + 0.4 * beat.strength : 0.45 + 0.35 * beat.strength,
                size: low ? 240 + 260 * hit : 90 + 100 * hit,
                width: low ? 0.5 : 0.3))

        case .aurora:
            // Colour wells up from the bottom on the bass and flickers in
            // from alternate sides on the snare.
            elements.append(RippleElement(
                kind: .glow, origin: .zero, startTime: now, duration: low ? 1.1 : 0.7, color: color,
                strength: 0.55 + 0.45 * beat.strength,
                size: low ? home.frame.height * (0.1 + 0.14 * hit) : home.frame.width * (0.04 + 0.05 * hit),
                edge: low ? 0 : (bassBeats % 2 == 0 ? 2 : 3)))
        }

        // Bending needs a live picture of the screen. Not while locked: that
        // picture could be the desktop behind the lock screen.
        let bends = effect != .aurora && !LockScreen.isLocked && ScreenStill.hasPermission
        for (index, screen) in screens.enumerated() {
            let overlay = overlays[index]
            overlay.renderer.screenFrame = screen.frame
            overlay.renderer.scale = Float(screen.backingScaleFactor)
            overlay.renderer.liveScreen = bends ? feed(for: screen) : nil
            if low { overlay.renderer.lastBeat = now }
            elements.forEach(overlay.renderer.add)
            overlay.present(on: screen, forEffects: true)
        }

        // The feeds cost something to run, so they stop once the music does.
        feedStop?.cancel()
        let stop = DispatchWorkItem { [weak self] in self?.stopFeeds() }
        feedStop = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: stop)

        if Debug.ripple, !musicChecked {
            // Self-check, once: the screen mid-effect against the screen ten seconds on.
            musicChecked = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                let during = await ScreenStill.capture(home, includeSelf: true)
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let during, let after = await ScreenStill.capture(home, includeSelf: true) else { return debugLog("ripple: music self-check capture failed") }
                debugLog("ripple: music self-check [\(home.localizedName)]: \(changedFraction(after, during))% of screen pixels differ mid-effect")
            }
        }
    }

    private func feed(for screen: NSScreen) -> LiveScreen? {
        guard let device, let id = screen.displayID else { return nil }
        if let feed = feeds[id] {
            feed.start()   // no-op while running; restarts one the system stopped
            return feed
        }
        let feed = LiveScreen(device: device, screen: screen, displayID: id)
        feeds[id] = feed
        feed.start()
        return feed
    }

    private func stopFeeds() {
        feedStop?.cancel()
        feedStop = nil
        feeds.values.forEach { $0.stop() }
        feeds.removeAll()
        overlays.forEach { $0.renderer.liveScreen = nil }
    }
}

/// A transparent, click-through, always-on-top window covering one screen.
private final class RippleOverlay {
    let renderer: RippleRenderer
    private let window: NSWindow
    private let view: MTKView

    init?(device: MTLDevice) {
        guard let renderer = RippleRenderer(device: device) else {
            debugLog("ripple: Metal is unavailable")
            return nil
        }
        self.renderer = renderer

        window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none

        view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = RippleRenderer.pixelFormat
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.delegate = renderer
        window.contentView = view

        renderer.onFinish = { [weak self] in self?.hide() }
    }

    /// Starts the main shockwave.
    func show(on screen: NSScreen, colorSpace: CGColorSpace?, startTime: CFTimeInterval) {
        (view.layer as? CAMetalLayer)?.colorspace = colorSpace
        renderer.start(at: startTime)
        present(on: screen)
    }

    /// Puts the window up on `screen` and keeps it drawing until the renderer
    /// has nothing left to show. Cheap to call again while it is already up.
    func present(on screen: NSScreen, forEffects: Bool = false) {
        // The effects bend the live feed, so the layer speaks its colour
        // space, unless the main shockwave is using its screenshot's.
        if forEffects && !renderer.isPlaying {
            (view.layer as? CAMetalLayer)?.colorspace = LiveScreen.colorSpace
        }
        if window.frame != screen.frame { window.setFrame(screen.frame, display: false) }
        // The layer starts life in a zero-sized window with a scale of 0,
        // which draws nothing, so both of these must be set explicitly.
        view.layer?.isOpaque = false
        view.layer?.contentsScale = screen.backingScaleFactor
        view.preferredFramesPerSecond = screen.maximumFramesPerSecond
        view.isPaused = false
        guard !window.isVisible else { return }
        window.orderFrontRegardless()
        LockScreen.raise(window)
    }

    func hide() {
        renderer.stop()
        view.isPaused = true
        window.orderOut(nil)
    }
}

/// Share of pixels that differ between two captures, as a percentage. Used by
/// the `NOTCHORBIT_DEBUG_RIPPLE` self-checks.
private func changedFraction(_ a: CGImage, _ b: CGImage) -> String {
    let w = 432, h = 280
    func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return data
    }
    let pa = pixels(a), pb = pixels(b)
    var changed = 0
    for i in 0..<(w * h) {
        let o = i * 4
        if abs(Int(pa[o]) - Int(pb[o])) > 12 || abs(Int(pa[o+1]) - Int(pb[o+1])) > 12 || abs(Int(pa[o+2]) - Int(pb[o+2])) > 12 { changed += 1 }
    }
    return String(format: "%.1f", Double(changed) * 100 / Double(w * h))
}
