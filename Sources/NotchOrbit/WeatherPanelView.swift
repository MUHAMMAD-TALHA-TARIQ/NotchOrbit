import AppKit
import QuartzCore

/// Weather tab of the expanded panel: an animated scene of the current conditions
/// (the same particle effects as the full-screen burst, scaled down) under a card
/// with the big temperature, condition, feels-like / humidity / wind chips and an
/// hourly strip with a temperature curve. Flipped (y down) like the panel.
final class WeatherPanelView: NSView {
    private let sky = CAGradientLayer()
    private let backdrop = ScreenEffectView()
    private let scrim = CAGradientLayer()
    private let content = WeatherPanelContentView(frame: .zero)

    private var reading: WeatherReading?
    private var activeKind: ScreenEffectKind?
    private var isActive = false
    private var startedSize: CGSize = .zero
    private var agoTimer: Timer?

    static let cornerRadius: CGFloat = 14

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = Self.cornerRadius
        sky.startPoint = CGPoint(x: 0.5, y: 1)
        sky.endPoint = CGPoint(x: 0.5, y: 0)
        scrim.colors = [CGColor(gray: 0, alpha: 0.42), CGColor(gray: 0, alpha: 0.0)]
        scrim.startPoint = CGPoint(x: 0.5, y: 1)   // layer space: top → bottom
        scrim.endPoint = CGPoint(x: 0.5, y: 0.45)
        layer?.addSublayer(sky)
        addSubview(backdrop)
        layer?.addSublayer(scrim)
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sky.frame = bounds
        scrim.frame = bounds
        backdrop.frame = bounds
        content.frame = bounds
        CATransaction.commit()
        // Emitter rates and speeds depend on the size; restart if it changed while active.
        if isActive, bounds.size != startedSize { restartEffect() }
    }

    func update(reading: WeatherReading?, status: WeatherService.Status, settings: WeatherSettings) {
        self.reading = reading
        content.reading = reading
        content.status = status
        content.settings = settings
        let kind = reading.map { ScreenEffectKind(condition: $0.condition, isDay: $0.isDay) }
        if kind != activeKind { restartEffect() }
    }

    /// Particles (and the "updated … ago" ticker) only run while the tab is on screen.
    func setActive(_ on: Bool) {
        guard on != isActive else { return }
        isActive = on
        agoTimer?.invalidate(); agoTimer = nil
        if on {
            restartEffect()
            agoTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.content.needsDisplay = true }
        } else {
            backdrop.stopEmitting()
            activeKind = nil
        }
    }

    deinit { agoTimer?.invalidate() }

    private func restartEffect() {
        guard isActive, bounds.width > 0, bounds.height > 0 else { return }
        guard let reading else {
            backdrop.stopEmitting()
            activeKind = nil
            setSky(for: nil)
            return
        }
        let kind = ScreenEffectKind(condition: reading.condition, isDay: reading.isDay)
        activeKind = kind
        startedSize = bounds.size
        setSky(for: kind)
        backdrop.layoutSubtreeIfNeeded()
        backdrop.start(kind, emoji: reading.emoji(), emojiPointSize: 18)
    }

    /// Background gradient matching the scene (top colour first).
    private func setSky(for kind: ScreenEffectKind?) {
        func c(_ r: Double, _ g: Double, _ b: Double) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
        let colors: [CGColor]
        switch kind {
        case .sun:        colors = [c(0.16, 0.45, 0.85), c(0.99, 0.70, 0.30)]
        case .night:      colors = [c(0.03, 0.05, 0.16), c(0.14, 0.18, 0.40)]
        case .clouds:     colors = [c(0.25, 0.30, 0.40), c(0.48, 0.55, 0.66)]
        case .fog:        colors = [c(0.40, 0.44, 0.52), c(0.66, 0.70, 0.76)]
        case .rain:       colors = [c(0.14, 0.21, 0.33), c(0.28, 0.44, 0.66)]
        case .heavyRain:  colors = [c(0.10, 0.14, 0.22), c(0.20, 0.30, 0.45)]
        case .thunder:    colors = [c(0.07, 0.08, 0.15), c(0.20, 0.22, 0.38)]
        case .snow:       colors = [c(0.26, 0.38, 0.55), c(0.62, 0.76, 0.92)]
        case .fire:       colors = [c(0.20, 0.08, 0.04), c(0.60, 0.25, 0.08)]
        case nil:         colors = [c(0.12, 0.13, 0.17), c(0.20, 0.22, 0.28)]
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sky.colors = colors
        CATransaction.commit()
    }
}

/// The text and chart layer of the Weather tab (transparent; drawn over the scene).
final class WeatherPanelContentView: NSView {
    var reading: WeatherReading? { didSet { if reading != oldValue { needsDisplay = true } } }
    var status: WeatherService.Status = .idle { didSet { if status != oldValue { needsDisplay = true } } }
    var settings = WeatherSettings() { didSet { if settings != oldValue { needsDisplay = true } } }

    private let accent = NSColor(srgbRed: 1.0, green: 0.85, blue: 0.45, alpha: 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width, h = bounds.height
        guard w > 120, h > 80 else { return }
        guard let reading else { drawEmpty(); return }
        let unit = settings.unit

        // Header: icon, big temperature, condition + feels like; place / high-low / updated on the right.
        let iconSize: CGFloat = 46
        drawConditionIcon(reading, in: CGRect(x: 14, y: 10, width: iconSize, height: iconSize))
        let tempX: CGFloat = 14 + iconSize + 10
        let temp = PanelDrawing.text(reading.temperature(in: unit), size: 38, weight: .bold, color: .white)
        temp.draw(at: CGPoint(x: tempX, y: 8))
        let afterTemp = tempX + temp.size().width + 12
        PanelDrawing.draw(reading.condition.title, at: CGPoint(x: afterTemp, y: 14), size: 13, weight: .semibold, color: .white, align: .left)
        if let feels = reading.apparent(in: unit) {
            PanelDrawing.draw("Feels like \(feels)", at: CGPoint(x: afterTemp, y: 33), size: 11, weight: .medium,
                 color: NSColor.white.withAlphaComponent(0.75), align: .left)
        }
        let right = w - 14
        if let place = reading.placeName {
            let maxWidth = max(60, w - afterTemp - 120)
            PanelDrawing.draw(place, at: CGPoint(x: right, y: 12), size: 12, weight: .semibold, color: .white, align: .right, maxWidth: maxWidth)
        }
        if let hi = reading.highC, let lo = reading.lowC {
            let hiText = "H \(WeatherReading.format(celsius: hi, unit: unit))"
            let loText = "L \(WeatherReading.format(celsius: lo, unit: unit))"
            PanelDrawing.draw("\(hiText)   \(loText)", at: CGPoint(x: right, y: 30), size: 11, weight: .medium,
                 color: NSColor.white.withAlphaComponent(0.85), align: .right)
        }
        PanelDrawing.draw("Updated \(agoText(reading.fetchedAt))", at: CGPoint(x: right, y: 47), size: 9, weight: .medium,
             color: NSColor.white.withAlphaComponent(0.55), align: .right)

        // Chips
        var chips: [(String, String)] = []
        if let humidity = reading.humidity { chips.append(("humidity.fill", "\(Int(humidity.rounded()))%")) }
        if let wind = reading.windKmh {
            chips.append(("wind", unit.usesFahrenheit ? "\(Int((wind * 0.621371).rounded())) mph" : "\(Int(wind.rounded())) km/h"))
        }
        chips.append((reading.isDay ? "sun.max" : "moon", reading.isDay ? "Day" : "Night"))
        var cx: CGFloat = 14
        for (symbol, text) in chips {
            cx = drawChip(symbol: symbol, text: text, at: CGPoint(x: cx, y: 66)) + 8
        }

        // Hourly strip with a temperature curve.
        let stripTop: CGFloat = 98
        guard let hours = reading.hourly, hours.count >= 2, h - stripTop > 60 else {
            if h - stripTop > 24 {
                PanelDrawing.draw("Hourly forecast arrives with the next refresh.", at: CGPoint(x: w / 2, y: stripTop + 20),
                     size: 10, weight: .medium, color: NSColor.white.withAlphaComponent(0.6), align: .center)
            }
            return
        }
        drawHourly(Array(hours.prefix(8)), unit: unit, in: CGRect(x: 10, y: stripTop, width: w - 20, height: h - stripTop - 8))
    }

    private func drawEmpty() {
        let message: String
        switch status {
        case .idle:     message = "Weather is off."
        case .locating: message = "Finding your location…"
        case .loading:  message = "Fetching the forecast…"
        case .ready:    message = "No reading yet."
        case .failed(let why): message = why
        }
        PanelDrawing.draw(message, at: CGPoint(x: bounds.midX, y: bounds.midY - 16), size: 12, weight: .semibold,
             color: .white, align: .center, maxWidth: bounds.width - 40)
        PanelDrawing.draw("Click the weather circle to refresh.", at: CGPoint(x: bounds.midX, y: bounds.midY + 4), size: 10,
             weight: .medium, color: NSColor.white.withAlphaComponent(0.6), align: .center)
    }

    // MARK: Pieces

    private func drawConditionIcon(_ reading: WeatherReading, in rect: CGRect) {
        switch settings.iconStyle {
        case .emoji:
            let a = NSAttributedString(string: reading.emoji(), attributes: [.font: NSFont.systemFont(ofSize: rect.height * 0.78)])
            let m = a.size()
            a.draw(at: CGPoint(x: rect.midX - m.width / 2, y: rect.midY - m.height / 2))
        case .symbol:
            let config = NSImage.SymbolConfiguration(pointSize: rect.height * 0.7, weight: .medium).applying(.preferringMulticolor())
            guard let image = NSImage(systemSymbolName: reading.symbolName(), accessibilityDescription: nil)?
                    .withSymbolConfiguration(config) else { return }
            let s = image.size
            image.draw(in: CGRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    /// Small translucent pill with a symbol and a value. Returns its right edge.
    @discardableResult
    private func drawChip(symbol: String, text: String, at origin: CGPoint) -> CGFloat {
        let label = PanelDrawing.text(text, size: 10.5, weight: .semibold, color: .white)
        let width = 10 + 14 + 5 + label.size().width + 10
        let rect = CGRect(x: origin.x, y: origin.y, width: width, height: 22)
        NSColor.black.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11).fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 10.5, yRadius: 10.5)
        outline.lineWidth = 1; outline.stroke()
        PanelDrawing.drawSymbol(symbol, in: CGRect(x: rect.minX + 10, y: rect.minY, width: 14, height: rect.height), pointSize: 10,
                   color: NSColor.white.withAlphaComponent(0.9))
        label.draw(at: CGPoint(x: rect.minX + 29, y: rect.midY - label.size().height / 2))
        return rect.maxX
    }

    private func drawHourly(_ hours: [HourForecast], unit: TemperatureUnit, in area: CGRect) {
        let n = hours.count
        let columnWidth = area.width / CGFloat(n)
        let centers = (0..<n).map { area.minX + columnWidth * (CGFloat($0) + 0.5) }

        // Labels and icons
        for (i, hour) in hours.enumerated() {
            let label = i == 0 ? "Now" : hour.label
            PanelDrawing.draw(label, at: CGPoint(x: centers[i], y: area.minY), size: 9, weight: i == 0 ? .bold : .medium,
                 color: NSColor.white.withAlphaComponent(i == 0 ? 0.95 : 0.65), align: .center)
            let iconRect = CGRect(x: centers[i] - 10, y: area.minY + 13, width: 20, height: 18)
            switch settings.iconStyle {
            case .emoji:
                let a = NSAttributedString(string: hour.condition.emoji(isDay: hour.isDay), attributes: [.font: NSFont.systemFont(ofSize: 13)])
                let m = a.size()
                a.draw(at: CGPoint(x: iconRect.midX - m.width / 2, y: iconRect.midY - m.height / 2))
            case .symbol:
                let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium).applying(.preferringMulticolor())
                if let image = NSImage(systemSymbolName: hour.condition.symbolName(isDay: hour.isDay), accessibilityDescription: nil)?
                    .withSymbolConfiguration(config) {
                    let s = image.size
                    image.draw(in: CGRect(x: iconRect.midX - s.width / 2, y: iconRect.midY - s.height / 2, width: s.width, height: s.height),
                               from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
            }
        }

        // Curve band
        let bandTop = area.minY + 48
        let bandBottom = area.maxY - 2
        guard bandBottom - bandTop > 18 else { return }
        let temps = hours.map(\.temperatureC)
        let lo = (temps.min() ?? 0) - 1, hi = (temps.max() ?? 0) + 1
        func y(_ t: Double) -> CGFloat { bandBottom - CGFloat((t - lo) / max(0.5, hi - lo)) * (bandBottom - bandTop) }
        let points = temps.enumerated().map { CGPoint(x: centers[$0.offset], y: y($0.element)) }

        // Smooth path through the points (quadratic through midpoints).
        let line = NSBezierPath()
        line.move(to: points[0])
        if points.count == 2 {
            line.line(to: points[1])
        } else {
            for i in 1..<points.count - 1 {
                let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
                line.curve(to: mid, controlPoint1: points[i], controlPoint2: points[i])
            }
            line.line(to: points[points.count - 1])
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: CGRect(x: area.minX, y: bandTop - 20, width: area.width, height: bandBottom - bandTop + 22)).addClip()
        let fill = line.copy() as! NSBezierPath
        fill.line(to: CGPoint(x: points[points.count - 1].x, y: bandBottom))
        fill.line(to: CGPoint(x: points[0].x, y: bandBottom))
        fill.close()
        // Fade from the curve down to the baseline, in view coordinates (y grows downward here).
        if let cg = NSGraphicsContext.current?.cgContext,
           let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                     colors: [accent.withAlphaComponent(0.38).cgColor, accent.withAlphaComponent(0.02).cgColor] as CFArray,
                                     locations: [0, 1]) {
            cg.saveGState()
            fill.addClip()
            let top = points.map(\.y).min() ?? bandTop
            cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bandBottom), options: [])
            cg.restoreGState()
        }
        line.lineWidth = 2
        line.lineJoinStyle = .round
        line.lineCapStyle = .round
        accent.setStroke()
        line.stroke()
        NSGraphicsContext.restoreGraphicsState()

        for (i, p) in points.enumerated() {
            let dot = NSBezierPath(ovalIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
            (i == 0 ? NSColor.white : accent).setFill(); dot.fill()
            NSColor.black.withAlphaComponent(0.35).setStroke(); dot.lineWidth = 1; dot.stroke()
            PanelDrawing.draw(WeatherReading.format(celsius: temps[i], unit: unit), at: CGPoint(x: p.x, y: p.y - 17),
                 size: 10, weight: .semibold, color: .white, align: .center)
        }
    }

    // MARK: Helpers

    private func agoText(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60) min ago" }
        return "\(s / 3600) h ago"
    }

}
