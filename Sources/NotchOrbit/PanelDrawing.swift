import AppKit

/// Drawing helpers shared by the panel views (tab row, Mic tab, Weather tab, level
/// meter): tinted SF Symbols served from a small bitmap cache, and attributed-text
/// shortcuts. Symbols used to be re-rendered from their vector form, and tinted
/// through a throwaway image, on every redraw of every panel view.
enum PanelDrawing {
    enum Align { case left, center, right }

    private static let symbols = NSCache<NSString, NSImage>()

    /// A monochrome SF Symbol tinted with `color`, rasterised once at 2× per
    /// (name, size, weight, colour) and reused.
    static func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .semibold, color: NSColor) -> NSImage? {
        let c = color.usingColorSpace(.sRGB) ?? color
        let key = "\(name)|\(pointSize)|\(weight.rawValue)|\(c.redComponent),\(c.greenComponent),\(c.blueComponent),\(c.alphaComponent)" as NSString
        if let hit = symbols.object(forKey: key) { return hit }
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight)) else { return nil }
        let size = base.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int((size.width * scale).rounded(.up)),
                                         pixelsHigh: Int((size.height * scale).rounded(.up)),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let pixelFrame = NSRect(x: 0, y: 0, width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh))
        base.draw(in: pixelFrame)
        color.set()
        pixelFrame.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
        rep.size = size
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        symbols.countLimit = 96
        symbols.setObject(image, forKey: key)
        return image
    }

    /// Draws the symbol centred in `rect`.
    static func drawSymbol(_ name: String, in rect: CGRect, pointSize: CGFloat, weight: NSFont.Weight = .semibold, color: NSColor) {
        guard let image = symbol(name, pointSize: pointSize, weight: weight, color: color) else { return }
        let size = image.size
        image.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    static func attributes(size: CGFloat, weight: NSFont.Weight, color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight), .foregroundColor: color]
    }

    static func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: attributes(size: size, weight: weight, color: color))
    }

    /// Anchored at `point` (top edge), aligned left / centre / right of it. Shrinks
    /// the font to fit `maxWidth` when one is given.
    static func draw(_ string: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor,
                     align: Align, maxWidth: CGFloat? = nil) {
        var a = text(string, size: size, weight: weight, color: color)
        if let maxWidth, a.size().width > maxWidth, a.size().width > 0 {
            a = text(string, size: max(6, size * maxWidth / a.size().width), weight: weight, color: color)
        }
        let m = a.size()
        let x: CGFloat
        switch align {
        case .left:   x = point.x
        case .center: x = point.x - m.width / 2
        case .right:  x = point.x - m.width
        }
        a.draw(at: CGPoint(x: x, y: point.y))
    }

    /// Centred in `rect`.
    static func draw(_ string: String, centeredIn rect: CGRect, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let a = text(string, size: size, weight: weight, color: color)
        let m = a.size()
        a.draw(at: CGPoint(x: rect.midX - m.width / 2, y: rect.midY - m.height / 2))
    }
}
