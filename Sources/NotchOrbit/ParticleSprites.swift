import AppKit

/// Small bitmaps used as `CAEmitterCell` contents and for the emoji badge.
/// Particle sprites are 32 px and shown at 16 pt via `contentsScale = 2`.
enum ParticleSprites {
    static let pixels = 32
    static var points: CGFloat { CGFloat(pixels) / 2 }

    static func bitmapContext(width: Int, height: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Renders `text` (typically a single emoji) with the system font into a bitmap.
    static func text(_ text: String, pointSize: CGFloat, scale: CGFloat) -> CGImage? {
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: pointSize)])
        let measured = attributed.size()
        let w = Int((measured.width * scale).rounded(.up)), h = Int((measured.height * scale).rounded(.up))
        guard w > 0, h > 0, let ctx = bitmapContext(width: w, height: h) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        attributed.draw(at: .zero)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// Soft white dot; emitter cells tint it orange/yellow for embers.
    static let ember: CGImage? = {
        let px = pixels
        guard let ctx = bitmapContext(width: px, height: px),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(colorsSpace: space,
                                        colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                                                 CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.55),
                                                 CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                                        locations: [0, 0.35, 1]) else { return nil }
        let c = CGPoint(x: CGFloat(px) / 2, y: CGFloat(px) / 2)
        ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(px) / 2, options: [])
        return ctx.makeImage()
    }()

    /// Vertical white streak, brighter at the bottom: a falling raindrop.
    static let raindrop: CGImage? = {
        let px = pixels
        guard let ctx = bitmapContext(width: px, height: px),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(colorsSpace: space,
                                        colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
                                                 CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95)] as CFArray,
                                        locations: [0, 1]) else { return nil }
        let x = CGFloat(px) / 2
        ctx.addRect(CGRect(x: x - 1.5, y: 2, width: 3, height: CGFloat(px) - 4))
        ctx.clip()
        ctx.drawLinearGradient(gradient, start: CGPoint(x: x, y: CGFloat(px)), end: CGPoint(x: x, y: 0), options: [])
        return ctx.makeImage()
    }()

    /// Six-armed white snowflake with short side branches.
    static let snowflake: CGImage? = {
        let px = pixels
        guard let ctx = bitmapContext(width: px, height: px) else { return nil }
        let c = CGPoint(x: CGFloat(px) / 2, y: CGFloat(px) / 2)
        let r = CGFloat(px) / 2 - 2.5
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.setLineWidth(2.6)
        ctx.setLineCap(.round)
        for i in 0..<6 {
            let a = CGFloat(i) * .pi / 3
            let dir = CGPoint(x: cos(a), y: sin(a))
            ctx.move(to: c)
            ctx.addLine(to: CGPoint(x: c.x + dir.x * r, y: c.y + dir.y * r))
            let branch = CGPoint(x: c.x + dir.x * r * 0.58, y: c.y + dir.y * r * 0.58)
            for side: CGFloat in [-1, 1] {
                let ba = a + side * .pi / 3
                ctx.move(to: branch)
                ctx.addLine(to: CGPoint(x: branch.x + cos(ba) * r * 0.32, y: branch.y + sin(ba) * r * 0.32))
            }
        }
        ctx.strokePath()
        return ctx.makeImage()
    }()
}
