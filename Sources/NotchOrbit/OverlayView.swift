import AppKit

/// Strip pinned to the top of a display around the notch / island. Flipped so that
/// y = 0 is the very top of the screen, matching `NotchShapeBuilder`.
///
/// In stats mode the left circle is a gauge and the right one an animated emoji.
/// Clicking the gauge expands the notch downward into a panel with every stat
/// in tabs and a history graph; clicking the emoji plays a full-screen burst.
/// In weather mode the right circle shows the current condition instead
/// (with or without stats mode); clicking it plays a full-screen scene of that
/// weather and refreshes the forecast.
///
/// The window is only as large as the overlay needs (see `collapsedHeight` and
/// `requiredWidth`) and grows to `expandedHeight` while the panel is open.
final class OverlayView: NSView {
    private let notchLayer = CAShapeLayer()
    private let leftCircle = CircleDiscView(frame: .zero)
    private let rightCircle = CircleDiscView(frame: .zero)
    /// Stats mode replaces the plain discs: gauge on the left, animated hot/cold emoji on the right.
    private let leftGauge = StatGaugeView(frame: .zero)
    private let rightBadge = EmojiBadgeView(frame: .zero)
    /// Weather mode replaces whatever the right circle would otherwise show.
    private let rightWeather = WeatherBadgeView(frame: .zero)
    /// Built the first time the gauge is clicked; it owns the camera, mic and weather tabs.
    private var panel: StatsPanelView?
    private var statsHot = false

    /// Expanded panel below the notch.
    private(set) var isExpanded = false
    private var last: (settings: AppSettings, rect: CGRect, kind: OverlayKind)?
    private var shapeGeneration = 0
    /// The overlay shape in view coordinates (nil while it is hidden), for hit testing.
    private var shapePath: CGPath?
    /// Everything drawn, as one rect; the mouse-move monitor rejects most points with it.
    private var solidBounds = CGRect.zero

    static let panelWidth: CGFloat = 500
    static let panelCornerRadius: CGFloat = 24
    /// Window height while the panel is expanded: its tallest layout plus the notch.
    static let expandedHeight: CGFloat = 360

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        notchLayer.fillColor = NSColor.black.cgColor
        notchLayer.contentsScale = 2
        layer?.addSublayer(notchLayer)
        for view in [leftCircle, rightCircle, leftGauge, rightBadge, rightWeather] as [NSView] { addSubview(view) }
        leftGauge.isHidden = true
        rightBadge.isHidden = true
        rightWeather.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        notchLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    func debugSummary() -> String {
        let flipped = layer?.isGeometryFlipped ?? false
        let box = shapePath?.boundingBoxOfPath ?? .zero
        return "layer flipped=\(flipped) bounds=\(bounds) pathBox=\(box) pathHidden=\(notchLayer.isHidden) layerFrame=\(notchLayer.frame) left=\(leftCircle.frame) right=\(rightCircle.frame) leftHidden=\(leftCircle.isHidden) gaugeHidden=\(leftGauge.isHidden) weatherHidden=\(rightWeather.isHidden) expanded=\(isExpanded) panel=\(panel != nil)"
    }

    // MARK: - Window size

    /// Height the collapsed overlay needs for `settings` when the notch / island is
    /// `rect` (flipped coordinates): the shape, the circles and room for the click
    /// "pop" animation.
    static func collapsedHeight(settings: AppSettings, rect: CGRect) -> CGFloat {
        let c = settings.circles
        var bottom = rect.maxY + CGFloat(settings.effectiveShape?.extraHeight ?? 0)
        if c.enabled, c.showLeft || c.showRight {
            let circles = rect.midY + CGFloat(c.size) / 2 + CGFloat(c.verticalOffset) + (c.attachToNotch ? CGFloat(c.attachPadding) : 0)
            bottom = max(bottom, circles)
        }
        return (bottom + 16).rounded(.up)
    }

    /// Width the overlay needs: the shape with its ears and extra width, the circles
    /// (a weather capsule can be about 2.5× the circle size) and the expanded panel.
    static func requiredWidth(settings: AppSettings, rect: CGRect) -> CGFloat {
        let c = settings.circles
        let shape = settings.effectiveShape
        let reach = CGFloat(shape?.extraWidth ?? 0) + CGFloat(shape?.earRadius ?? 0) + CGFloat(c.gap)
            + 2.6 * CGFloat(c.size) + CGFloat(c.attachPadding) + 24
        return max(rect.width + 2 * reach, panelWidth + 48).rounded(.up)
    }

    /// Resizes the window downward, keeping its top edge on the top of the screen.
    private func resizeWindow(height: CGFloat) {
        guard let window else { return }
        var frame = window.frame
        guard abs(frame.height - height) > 0.5 else { return }
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        window.setFrame(frame, display: false)
    }

    // MARK: - Layout

    /// - Parameters:
    ///   - rect: hardware notch or virtual island in this view's flipped coordinates.
    ///   - kind: whether `rect` is a real notch or a floating island.
    ///   - animated: morph the overlay shape from its current form (used when expanding/collapsing).
    func apply(settings: AppSettings, rect: CGRect, kind: OverlayKind, animated: Bool = false) {
        last = (settings, rect, kind)
        let statsMode = settings.stats.enabled
        let weatherMode = settings.weather.enabled
        if !statsMode { isExpanded = false }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Circle frames first: the overlay may need to wrap around them.
        let c = settings.circles
        let size = CGFloat(c.size)
        let extraWidth = kind == .notch ? CGFloat(settings.effectiveShape?.extraWidth ?? 0) : 0
        let y = rect.midY - size / 2 + CGFloat(c.verticalOffset)

        let showLeft = c.enabled && c.showLeft
        let showRight = c.enabled && c.showRight
        let leftFrame = CGRect(x: rect.minX - extraWidth - CGFloat(c.gap) - size, y: y, width: size, height: size)
        let rightFrame = CGRect(x: rect.maxX + extraWidth + CGFloat(c.gap), y: y, width: size, height: size)
        // Weather badge: a capsule when it carries the temperature.
        let weatherWidth = weatherMode
            ? WeatherBadgeView.preferredWidth(height: size, reading: WeatherService.shared.currentReading, settings: settings.weather)
            : size
        let weatherFrame = CGRect(x: rightFrame.minX, y: y, width: weatherWidth, height: size)

        leftCircle.isHidden = !(showLeft && !statsMode)
        rightCircle.isHidden = !(showRight && !statsMode && !weatherMode)
        leftGauge.isHidden = !(showLeft && statsMode)
        rightBadge.isHidden = !(showRight && statsMode && !weatherMode)
        rightWeather.isHidden = !(showRight && weatherMode)
        leftCircle.frame = leftFrame
        leftGauge.frame = leftFrame
        rightCircle.frame = rightFrame
        rightBadge.frame = rightFrame
        rightWeather.frame = weatherFrame

        let embraced: [CGRect] = c.enabled && c.attachToNotch
            ? [(showLeft, leftFrame), (showRight, weatherMode ? weatherFrame : rightFrame)].filter { $0.0 }.map { $0.1 } : []
        let padding = CGFloat(c.attachPadding)

        // Expanded geometry: a wide rounded block hanging from the notch with the panel inside.
        let circlesBottom = (showLeft || showRight) ? y + size : rect.maxY
        let contentTop = max(rect.maxY, circlesBottom) + 10
        let panelHeight = panel?.preferredHeight ?? StatsPanelView.baseHeight
        let availableBottom = bounds.height > 100 ? bounds.height - 4 : contentTop + panelHeight
        let expandedBottom = min(availableBottom, contentTop + panelHeight)
        let halfWidth = max(rect.width / 2 + extraWidth, Self.panelWidth / 2)
        let expandedRect = CGRect(x: rect.midX - halfWidth, y: rect.minY, width: 2 * halfWidth, height: expandedBottom - rect.minY)

        if let panel {
            panel.frame = CGRect(x: expandedRect.minX + 16, y: contentTop,
                                 width: expandedRect.width - 32, height: max(0, expandedBottom - contentTop - 10))
            panel.isHidden = !isExpanded
        }

        // Overlay shape
        var newPath: CGPath?
        switch kind {
        case .notch:
            if isExpanded {
                var p = settings.effectiveShape ?? NotchShapeParams()
                p.extraWidth = 0; p.extraHeight = 0; p.bottomRadius = Self.panelCornerRadius
                newPath = NotchShapeBuilder.path(notch: expandedRect, params: p, embracing: embraced, padding: padding)
            } else if let shape = settings.effectiveShape {
                newPath = NotchShapeBuilder.path(notch: rect, params: shape, embracing: embraced, padding: padding)
            }
        case .island:
            if isExpanded {
                newPath = NotchShapeBuilder.islandPath(rect: expandedRect, cornerRadius: Self.panelCornerRadius,
                                                       shape: settings.shape, embracing: embraced, padding: padding)
            } else {
                newPath = NotchShapeBuilder.islandPath(rect: rect,
                                                       cornerRadius: CGFloat(settings.island.cornerRadius),
                                                       shape: settings.shape,
                                                       embracing: embraced, padding: padding)
            }
        }
        notchLayer.fillColor = settings.notchColor.cgColor
        setShape(newPath, fallback: NotchShapeBuilder.hardwarePath(notch: rect), animated: animated)

        for circle in [leftCircle, rightCircle] {
            circle.configure(borderWidth: CGFloat(c.borderWidth), borderColor: c.borderColor.cgColor)
            circle.needsLayout = true
        }
        for badge in [leftGauge, rightBadge, rightWeather] as [CircleBadgeView] {
            badge.configure(borderWidth: CGFloat(c.borderWidth), borderColor: c.borderColor.cgColor)
            badge.needsLayout = true
        }

        // One rect around everything that takes clicks.
        var solid = rect
        if let shapePath { solid = solid.union(shapePath.boundingBoxOfPath) }
        for view in [leftCircle, rightCircle, leftGauge, rightBadge, rightWeather] as [NSView] where !view.isHidden {
            solid = solid.union(view.frame)
        }
        if isExpanded, let panel { solid = solid.union(panel.frame) }
        solidBounds = solid

        // Take clicks only while the pointer is over a drawn part of the overlay
        // (the controller keeps this up to date as the mouse moves).
        updateMouseTransparency(at: NSEvent.mouseLocation)

        let monitor = SystemStatsMonitor.shared
        update(snapshot: monitor.snapshot, history: monitor.history, settings: settings)
        let weather = WeatherService.shared
        updateWeather(reading: weather.currentReading, status: weather.status, settings: settings)
    }

    /// Sets the overlay path, optionally morphing from the current one. `nil` hides
    /// the overlay (after morphing to `fallback`, the bare notch, when animated).
    ///
    /// The shape layer is kept just as large as the shape itself (plus the start of a
    /// morph) rather than the whole window: a shape layer is rasterised at its full
    /// frame size, so a window-sized one cost a few megabytes per display.
    private func setShape(_ path: CGPath?, fallback: CGPath, animated: Bool) {
        shapeGeneration += 1
        let generation = shapeGeneration
        let target = path ?? fallback

        // Where a morph starts, in view coordinates (the layer's path is relative to its frame).
        var from = fallback
        if !notchLayer.isHidden, let current = notchLayer.presentation()?.path ?? notchLayer.path {
            var toView = CGAffineTransform(translationX: notchLayer.frame.minX, y: notchLayer.frame.minY)
            from = current.copy(using: &toView) ?? fallback
        }
        var region = target.boundingBoxOfPath
        if animated { region = region.union(from.boundingBoxOfPath) }
        region = region.isNull ? .zero : region.insetBy(dx: -2, dy: -2).integral
        var toLayer = CGAffineTransform(translationX: -region.minX, y: -region.minY)
        let localTarget = target.copy(using: &toLayer) ?? target
        let localFrom = from.copy(using: &toLayer) ?? from

        notchLayer.removeAnimation(forKey: "path")
        notchLayer.frame = region
        notchLayer.path = localTarget
        shapePath = path
        guard animated else { notchLayer.isHidden = path == nil; return }

        notchLayer.isHidden = false
        let morph = CABasicAnimation(keyPath: "path")
        morph.fromValue = localFrom
        morph.toValue = localTarget
        morph.duration = 0.32
        morph.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.shapeGeneration == generation, path == nil else { return }
            self.notchLayer.isHidden = true
        }
        notchLayer.add(morph, forKey: "path")
        CATransaction.commit()
    }

    // MARK: - Expansion

    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded, let last else { return }
        guard !expanded || last.settings.stats.enabled else { return }
        isExpanded = expanded
        if Debug.enabled { debugLog("[debug] stats panel", expanded ? "expanded" : "collapsed") }
        if expanded {
            resizeWindow(height: Self.expandedHeight)
            let panel = ensurePanel(settings: last.settings)
            panel.show(metric: last.settings.stats.metric)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0; fade.toValue = 1
            fade.duration = 0.25
            fade.beginTime = CACurrentMediaTime() + 0.12
            fade.fillMode = .backwards
            panel.layer?.add(fade, forKey: "fade")
        }
        apply(settings: last.settings, rect: last.rect, kind: last.kind, animated: true)
        if !expanded {
            // Shrink the window back once the collapse morph has played out.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, !self.isExpanded, let last = self.last else { return }
                self.resizeWindow(height: Self.collapsedHeight(settings: last.settings, rect: last.rect))
            }
        }
    }

    private func ensurePanel(settings: AppSettings) -> StatsPanelView {
        if let panel { return panel }
        let panel = StatsPanelView(frame: .zero)
        panel.isHidden = true
        panel.onPreferredHeightChange = { [weak self] in
            guard let self, self.isExpanded, let last = self.last else { return }
            self.apply(settings: last.settings, rect: last.rect, kind: last.kind, animated: true)
        }
        panel.settings = settings.stats
        panel.interval = settings.stats.refreshInterval
        let weather = WeatherService.shared
        panel.weather = (weather.currentReading, weather.status, settings.weather)
        addSubview(panel)
        self.panel = panel
        return panel
    }

    /// Debug aid: expand the panel on the named tab without a click.
    func debugExpand(tab: String) {
        setExpanded(true)
        panel?.debugSelectTab(named: tab)
    }

    // MARK: - Clicks

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// True when `screenPoint` is over something the overlay draws: the notch / island
    /// shape, a circle, or the expanded panel. Clicks there must not fall through to
    /// whatever sits behind the overlay.
    func isSolid(at screenPoint: CGPoint) -> Bool {
        guard let window, window.isVisible else { return false }
        let p = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        guard solidBounds.contains(p) else { return false }
        if let shapePath, shapePath.contains(p) { return true }
        if let last, last.rect.contains(p) { return true }   // the hardware notch / island itself
        for view in [leftCircle, rightCircle, leftGauge, rightBadge, rightWeather] as [NSView] where !view.isHidden {
            if view.frame.contains(p) { return true }
        }
        if isExpanded, let panel, panel.frame.contains(p) { return true }
        return false
    }

    /// Makes the window click-through unless the pointer is over the overlay.
    func updateMouseTransparency(at screenPoint: CGPoint) {
        guard let window else { return }
        let solid = isSolid(at: screenPoint)
        if window.ignoresMouseEvents == solid {
            window.ignoresMouseEvents = !solid
            if Debug.enabled { debugLog("[debug] overlay", solid ? "takes clicks" : "click-through", "at", screenPoint) }
        }
    }

    /// Clicks arrive here while the pointer is over the overlay. Anything that isn't a
    /// circle is simply swallowed (or collapses the panel), never passed on.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if Debug.enabled { debugLog("[debug] overlay mouseDown at", p, "expanded:", isExpanded) }
        if handleClick(at: p) { return }
        if isExpanded, !(panel?.frame.contains(p) ?? false) { setExpanded(false) }
    }

    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}

    /// Called by the controller's global monitor for clicks that bypassed the window.
    /// Returns true when the click landed on one of the circles.
    @discardableResult
    func handleGlobalClick(at screenPoint: CGPoint) -> Bool {
        guard let window else { return false }
        if isExpanded {
            // The window takes clicks while expanded, so a global click was outside it.
            if Debug.enabled { debugLog("[debug] global click at", screenPoint, "collapses the panel") }
            setExpanded(false)
            return false
        }
        let p = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        return handleClick(at: p)
    }

    private func handleClick(at p: CGPoint) -> Bool {
        if !leftGauge.isHidden, leftGauge.frame.contains(p) {
            setExpanded(!isExpanded)
            return true
        }
        if !rightWeather.isHidden, rightWeather.frame.contains(p) {
            rightWeather.pulse()
            let service = WeatherService.shared
            if let last, last.settings.weather.animateOnClick,
               let reading = service.currentReading, let screen = window?.screen {
                ScreenEffectPlayer.shared.play(ScreenEffectKind(condition: reading.condition, isDay: reading.isDay),
                                               emoji: reading.emoji(), on: screen,
                                               duration: last.settings.weather.burstDuration)
            }
            service.refresh(force: true)
            return true
        }
        if !rightBadge.isHidden, rightBadge.frame.contains(p) {
            rightBadge.pulse()
            if let screen = window?.screen, let last {
                ScreenEffectPlayer.shared.play(statsHot ? .fire : .snow, emoji: rightBadge.emoji, on: screen,
                                               duration: last.settings.stats.burstDuration)
            }
            return true
        }
        return false
    }

    // MARK: - Data

    /// Pushes fresh readings into the gauge, emoji badge and (while open) the panel.
    func update(snapshot: StatSnapshot, history: [StatSnapshot], settings: AppSettings) {
        let stats = settings.stats
        let value = snapshot.value(for: stats.metric)
        let hot = stats.isHot(value)
        statsHot = hot
        leftGauge.metric = stats.metric
        leftGauge.showLabel = stats.showLabel
        leftGauge.value = value
        leftGauge.isHot = hot
        rightBadge.emoji = stats.emoji(for: value)
        rightBadge.effect = stats.animateEmoji ? (hot ? .fire : .snow) : .none
        guard isExpanded, let panel else { return }
        if panel.settings != stats { panel.settings = stats }
        panel.interval = stats.refreshInterval
        panel.snapshot = snapshot
        panel.history = history
    }

    /// Pushes the latest forecast into the weather badge and the panel's Weather tab.
    /// Re-lays out only when the badge needs a different width (new temperature digits).
    func updateWeather(reading: WeatherReading?, status: WeatherService.Status, settings: AppSettings) {
        rightWeather.settings = settings.weather
        rightWeather.reading = reading
        rightWeather.status = status
        panel?.weather = (reading, status, settings.weather)
        if !rightWeather.isHidden, let last {
            let wanted = WeatherBadgeView.preferredWidth(height: rightWeather.frame.height, reading: reading, settings: settings.weather)
            if abs(wanted - rightWeather.frame.width) > 0.5 {
                apply(settings: last.settings, rect: last.rect, kind: last.kind)
            }
        }
    }
}
