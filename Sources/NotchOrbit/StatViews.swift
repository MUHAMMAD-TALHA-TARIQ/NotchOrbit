import AppKit

/// Shared look for the stats circles: dark disc, optional border, clipped to a circle.
/// Subclasses draw their content in `draw(_:)`.
class CircleBadgeView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2   // circle, or capsule when wider
        CATransaction.commit()
        needsDisplay = true
    }

    func configure(borderWidth: CGFloat, borderColor: CGColor) {
        layer?.borderWidth = borderWidth
        layer?.borderColor = borderColor
        needsDisplay = true
    }

    var borderWidth: CGFloat { layer?.borderWidth ?? 0 }

    /// Draws `text` centred on `center`, shrinking the font so it fits in `maxWidth`.
    func drawCentered(_ text: String, at center: CGPoint, fontSize: CGFloat, weight: NSFont.Weight,
                      color: NSColor, maxWidth: CGFloat) {
        var size = fontSize
        var attributed = NSAttributedString(string: text, attributes: Self.attributes(size: size, weight: weight, color: color))
        var measured = attributed.size()
        if measured.width > maxWidth, measured.width > 0 {
            size = max(4, fontSize * maxWidth / measured.width)
            attributed = NSAttributedString(string: text, attributes: Self.attributes(size: size, weight: weight, color: color))
            measured = attributed.size()
        }
        attributed.draw(at: CGPoint(x: center.x - measured.width / 2, y: center.y - measured.height / 2))
    }

    private static func attributes(size: CGFloat, weight: NSFont.Weight, color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight), .foregroundColor: color]
    }
}

/// Left circle in stats mode: a progress ring with the reading in the middle.
final class StatGaugeView: CircleBadgeView {
    var metric: StatMetric = .cpu { didSet { if metric != oldValue { needsDisplay = true } } }
    var value: Double? { didSet { if value != oldValue { needsDisplay = true } } }
    var isHot = false { didSet { if isHot != oldValue { needsDisplay = true } } }
    var showLabel = true { didSet { if showLabel != oldValue { needsDisplay = true } } }

    private let hotColor = NSColor(srgbRed: 1.0, green: 0.36, blue: 0.22, alpha: 1)
    private let coldColor = NSColor(srgbRed: 0.40, green: 0.78, blue: 1.0, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        let size = bounds.width
        guard size > 0 else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let ringWidth = max(2, (size * 0.09).rounded())
        let radius = size / 2 - borderWidth - ringWidth / 2 - 1
        guard radius > 2 else { return }

        // Track
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = ringWidth
        NSColor.white.withAlphaComponent(0.16).setStroke()
        track.stroke()

        // Progress, clockwise from 12 o'clock.
        let fraction = min(1, max(0, (value ?? 0) / metric.fullScale))
        if fraction > 0.001 {
            let progress = NSBezierPath()
            progress.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
            progress.lineWidth = ringWidth
            progress.lineCapStyle = fraction < 0.999 ? .round : .butt
            (isHot ? hotColor : coldColor).setStroke()
            progress.stroke()
        }

        // Text
        let inner = radius - ringWidth / 2 - 1
        let textWidth = inner * 1.75
        let withLabel = showLabel && size >= 36
        let text = metric.format(value)
        if withLabel {
            drawCentered(text, at: CGPoint(x: center.x, y: center.y + inner * 0.18),
                         fontSize: inner * 0.66, weight: .semibold, color: .white, maxWidth: textWidth)
            drawCentered(metric.shortLabel, at: CGPoint(x: center.x, y: center.y - inner * 0.42),
                         fontSize: inner * 0.34, weight: .medium, color: NSColor.white.withAlphaComponent(0.7), maxWidth: textWidth)
        } else {
            drawCentered(text, at: center, fontSize: inner * 0.78, weight: .semibold, color: .white, maxWidth: textWidth)
        }
    }
}
