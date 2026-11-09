import AppKit

/// Right circle in weather mode: the current condition as an emoji or a multicolour
/// SF Symbol. With the temperature on, the circle stretches into a capsule with the
/// temperature on the left and the icon on the right.
final class WeatherBadgeView: CircleBadgeView {
    var reading: WeatherReading? { didSet { if reading != oldValue { needsDisplay = true } } }
    var settings = WeatherSettings() { didSet { if settings != oldValue { needsDisplay = true } } }
    var status: WeatherService.Status = .idle { didSet { if status != oldValue { needsDisplay = true } } }

    // Proportions of the capsule, relative to its height.
    private static let leadingPad: CGFloat = 0.30
    private static let gap: CGFloat = 0.10
    private static let iconWidth: CGFloat = 0.70
    private static let trailingPad: CGFloat = 0.22
    private static let temperatureFont: CGFloat = 0.42

    /// Width the badge needs for `height`: a circle, or a capsule when a temperature is shown.
    static func preferredWidth(height: CGFloat, reading: WeatherReading?, settings: WeatherSettings) -> CGFloat {
        guard settings.showTemperature, let reading else { return height }
        let text = temperatureString(reading, settings: settings)
        let width = text.size().width
        let total = height * (leadingPad + gap + iconWidth + trailingPad) + width
        return max(height, total.rounded())
    }

    private static func temperatureString(_ reading: WeatherReading, settings: WeatherSettings,
                                          height: CGFloat = 30) -> NSAttributedString {
        NSAttributedString(string: reading.temperature(in: settings.unit),
                           attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: height * temperatureFont, weight: .semibold),
                                        .foregroundColor: NSColor.white])
    }

    override func draw(_ dirtyRect: NSRect) {
        let height = bounds.height
        guard height > 0 else { return }
        let inner = height - 2 * borderWidth
        guard inner > 4 else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        guard let reading else {
            drawPlaceholder(center: center, inner: inner)
            return
        }

        let capsule = settings.showTemperature && bounds.width > height + 1
        if capsule {
            // Temperature on the left, icon on the right.
            let text = Self.temperatureString(reading, settings: settings, height: height)
            let m = text.size()
            let textX = height * Self.leadingPad
            text.draw(at: CGPoint(x: textX, y: center.y - m.height / 2))
            let iconCenterX = textX + m.width + height * Self.gap + height * Self.iconWidth / 2
            drawIcon(reading, at: CGPoint(x: iconCenterX, y: center.y), pointSize: inner * 0.58)
        } else {
            drawIcon(reading, at: center, pointSize: inner * 0.58)
        }
    }

    private func drawIcon(_ reading: WeatherReading, at center: CGPoint, pointSize: CGFloat) {
        switch settings.iconStyle {
        case .emoji:
            let attributed = NSAttributedString(string: reading.emoji(),
                                                attributes: [.font: NSFont.systemFont(ofSize: pointSize)])
            let measured = attributed.size()
            attributed.draw(at: CGPoint(x: center.x - measured.width / 2, y: center.y - measured.height / 2))
        case .symbol:
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
                .applying(.preferringMulticolor())
            guard let image = NSImage(systemSymbolName: reading.symbolName(), accessibilityDescription: reading.condition.title)?
                    .withSymbolConfiguration(config) else { return }
            let s = image.size
            image.draw(in: CGRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height),
                       from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    /// No reading yet: a dim cloud, or a crossed-out signal when the last fetch failed.
    private func drawPlaceholder(center: CGPoint, inner: CGFloat) {
        let failed: Bool
        if case .failed = status { failed = true } else { failed = false }
        let name = failed ? "wifi.slash" : "cloud"
        let config = NSImage.SymbolConfiguration(pointSize: inner * 0.5, weight: .regular)
            .applying(.init(paletteColors: [NSColor.white.withAlphaComponent(failed ? 0.55 : 0.4)]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let s = image.size
        image.draw(in: CGRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height),
                   from: .zero, operation: .sourceOver, fraction: 1)
    }

    /// Quick "pop" of the badge as click feedback.
    func pulse() {
        guard let layer else { return }
        let anchorPos = CGPoint(x: bounds.width * layer.anchorPoint.x, y: bounds.height * layer.anchorPoint.y)
        let d = CGPoint(x: bounds.midX - anchorPos.x, y: bounds.midY - anchorPos.y)
        func scaled(_ s: CGFloat) -> CATransform3D {
            var t = CATransform3DMakeTranslation(d.x, d.y, 0)
            t = CATransform3DScale(t, s, s, 1)
            return CATransform3DTranslate(t, -d.x, -d.y, 0)
        }
        let pop = CAKeyframeAnimation(keyPath: "transform")
        pop.values = [CATransform3DIdentity, scaled(1.2), scaled(0.96), CATransform3DIdentity]
        pop.duration = 0.45
        pop.calculationMode = .cubic
        layer.add(pop, forKey: "notchorbit.pop")
    }
}
