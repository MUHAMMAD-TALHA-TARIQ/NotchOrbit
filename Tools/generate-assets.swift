// Generates Assets/sample.gif (an orbiting-dots animation), Assets/AppIcon.icns
// and Assets/dmg-background.tiff (installer window backdrop, 1x + 2x in one file).
// Usage: swiftc -O Tools/generate-assets.swift -o /tmp/gen && /tmp/gen Assets
//
// Everything is drawn into 16-bit contexts and converted to 8-bit afterwards. Core
// Graphics dithers gradients when it draws straight into an 8-bit bitmap, and that
// noise makes the PNGs 4–5× larger (a plain 1024 px gradient: 950 KB dithered,
// 185 KB clean) with no visible gain at icon sizes.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Assets")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

/// 16-bit drawing surface; see the note at the top.
func context(width: Int, height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
}

func context(_ size: Int) -> CGContext { context(width: size, height: size) }

/// Converts a 16-bit image to 8-bit without dithering.
func eightBit(_ image: CGImage) -> CGImage {
    let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .none
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return ctx.makeImage()!
}

func fileSize(_ url: URL) -> String {
    let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    return "\(bytes / 1024) KB"
}

// MARK: sample.gif
do {
    let size = 256, frameCount = 48
    let url = outDir.appendingPathComponent("sample.gif")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frameCount, nil)!
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let colors: [(CGFloat, CGFloat, CGFloat)] = [(1, 0.45, 0.2), (0.3, 0.85, 1), (0.8, 0.4, 1)]
    for f in 0..<frameCount {
        let ctx = context(size)
        let t = CGFloat(f) / CGFloat(frameCount)
        let c = CGFloat(size) / 2
        // background radial gradient
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [CGColor(red: 0.16, green: 0.12, blue: 0.35, alpha: 1), CGColor(red: 0.02, green: 0.02, blue: 0.08, alpha: 1)] as CFArray,
                           locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: c, y: c), startRadius: 0, endCenter: CGPoint(x: c, y: c), endRadius: c * 1.3, options: [])
        // orbit ring
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12)); ctx.setLineWidth(3)
        ctx.addEllipse(in: CGRect(x: c - 78, y: c - 78, width: 156, height: 156)); ctx.strokePath()
        // orbiting dots
        for (i, col) in colors.enumerated() {
            let a = t * 2 * .pi + CGFloat(i) * 2 * .pi / 3
            let r: CGFloat = 78
            let p = CGPoint(x: c + cos(a) * r, y: c + sin(a) * r)
            for (k, alpha) in [(2.2, 0.12), (1.5, 0.3), (1.0, 1.0)] {
                ctx.setFillColor(CGColor(red: col.0, green: col.1, blue: col.2, alpha: alpha))
                let rad = 16 * k
                ctx.fillEllipse(in: CGRect(x: p.x - rad, y: p.y - rad, width: rad * 2, height: rad * 2))
            }
        }
        // pulsing core
        let pulse = 22 + 6 * sin(t * 4 * .pi)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        ctx.fillEllipse(in: CGRect(x: c - pulse, y: c - pulse, width: pulse * 2, height: pulse * 2))
        CGImageDestinationAddImage(dest, eightBit(ctx.makeImage()!),
                                   [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.04]] as CFDictionary)
    }
    CGImageDestinationFinalize(dest)
    print("wrote", url.path, fileSize(url))
}

// MARK: Shared drawing

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

/// macOS-style icon: dark squircle, menu-bar strip, hardware notch flanked by the
/// two NotchOrbit circles (gauge on the left, glowing emoji disc on the right) and
/// an orbit ring with a bright satellite underneath. `s` is the canvas side.
func drawAppIcon(in ctx: CGContext, side s: CGFloat, withShadow: Bool) {
    let inset = s * 0.0625                      // Apple's icon grid: content is 824/1024
    let content = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = content.width * 0.2237
    let shape = CGPath(roundedRect: content, cornerWidth: radius, cornerHeight: radius, transform: nil)

    if withShadow {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: rgba(0, 0, 0, 0.45))
        ctx.setFillColor(rgba(0.08, 0.10, 0.18))
        ctx.addPath(shape); ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()

    // Background: deep navy with an indigo bloom.
    let base = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [rgba(0.16, 0.19, 0.34), rgba(0.07, 0.08, 0.16)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: content.minX, y: content.maxY),
                           end: CGPoint(x: content.maxX, y: content.minY), options: [])
    let bloom = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [rgba(0.45, 0.35, 0.95, 0.55), rgba(0.45, 0.35, 0.95, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(bloom, startCenter: CGPoint(x: content.midX, y: content.midY - s * 0.05), startRadius: 0,
                           endCenter: CGPoint(x: content.midX, y: content.midY - s * 0.05), endRadius: s * 0.55, options: [])

    // Orbit rings + satellite (the "orbit" in NotchOrbit).
    let orbitCenter = CGPoint(x: content.midX, y: content.minY + content.height * 0.38)
    for (k, alpha) in [(0.30, 0.22), (0.21, 0.14)] as [(CGFloat, CGFloat)] {
        let rx = content.width * k, ry = rx * 0.42
        ctx.setStrokeColor(rgba(1, 1, 1, alpha)); ctx.setLineWidth(s * 0.008)
        ctx.strokeEllipse(in: CGRect(x: orbitCenter.x - rx, y: orbitCenter.y - ry, width: 2 * rx, height: 2 * ry))
    }
    do {  // planet
        let r = content.width * 0.085
        let planet = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                colors: [rgba(0.70, 0.78, 1.0), rgba(0.36, 0.44, 0.92)] as CFArray, locations: [0, 1])!
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: orbitCenter.x - r, y: orbitCenter.y - r, width: 2 * r, height: 2 * r)); ctx.clip()
        ctx.drawLinearGradient(planet, start: CGPoint(x: orbitCenter.x - r, y: orbitCenter.y + r),
                               end: CGPoint(x: orbitCenter.x + r, y: orbitCenter.y - r), options: [])
        ctx.restoreGState()
    }
    do {  // satellite on the outer ring, lower right, with a glow
        let rx = content.width * 0.30, ry = rx * 0.42
        let a: CGFloat = -0.55
        let p = CGPoint(x: orbitCenter.x + cos(a) * rx, y: orbitCenter.y + sin(a) * ry)
        let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [rgba(0.40, 0.78, 1.0, 0.9), rgba(0.40, 0.78, 1.0, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: p, startRadius: 0, endCenter: p, endRadius: s * 0.07, options: [])
        ctx.setFillColor(rgba(1, 1, 1)); let r = s * 0.018
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
    }

    // Menu bar strip.
    let barH = content.height * 0.175
    let bar = CGRect(x: content.minX, y: content.maxY - barH, width: content.width, height: barH)
    ctx.setFillColor(rgba(1, 1, 1, 0.09)); ctx.fill(bar)
    ctx.setFillColor(rgba(0, 0, 0, 0.18)); ctx.fill(CGRect(x: bar.minX, y: bar.minY - s * 0.003, width: bar.width, height: s * 0.003))

    // Hardware notch hanging from the top edge.
    let notchW = content.width * 0.34, notchH = barH * 0.78, notchR = notchH * 0.42
    let notchRect = CGRect(x: content.midX - notchW / 2, y: content.maxY - notchH, width: notchW, height: notchH + notchR)
    ctx.setFillColor(rgba(0, 0, 0)); ctx.addPath(CGPath(roundedRect: notchRect, cornerWidth: notchR, cornerHeight: notchR, transform: nil)); ctx.fillPath()

    // Circles beside the notch.
    let cr = content.width * 0.078
    let cy = bar.midY
    let gap = content.width * 0.035
    let leftC = CGPoint(x: notchRect.minX - gap - cr, y: cy)
    let rightC = CGPoint(x: notchRect.maxX + gap + cr, y: cy)
    for c in [leftC, rightC] {
        ctx.setFillColor(rgba(0, 0, 0, 0.55))
        ctx.fillEllipse(in: CGRect(x: c.x - cr, y: c.y - cr, width: 2 * cr, height: 2 * cr))
        ctx.setStrokeColor(rgba(1, 1, 1, 0.85)); ctx.setLineWidth(s * 0.009)
        ctx.strokeEllipse(in: CGRect(x: c.x - cr, y: c.y - cr, width: 2 * cr, height: 2 * cr))
    }
    do {  // left: gauge ring, three quarters full
        let ringR = cr * 0.68, w = cr * 0.22
        ctx.setLineWidth(w); ctx.setLineCap(.round)
        ctx.setStrokeColor(rgba(1, 1, 1, 0.16))
        ctx.strokeEllipse(in: CGRect(x: leftC.x - ringR, y: leftC.y - ringR, width: 2 * ringR, height: 2 * ringR))
        ctx.setStrokeColor(rgba(0.40, 0.78, 1.0))
        ctx.addArc(center: leftC, radius: ringR, startAngle: .pi / 2, endAngle: .pi / 2 - 1.5 * .pi, clockwise: true)
        ctx.strokePath()
    }
    do {  // right: warm glowing core (the "hot" emoji)
        let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [rgba(1.0, 0.62, 0.30), rgba(1.0, 0.36, 0.22), rgba(1.0, 0.36, 0.22, 0)] as CFArray,
                              locations: [0, 0.45, 1])!
        ctx.drawRadialGradient(glow, startCenter: rightC, startRadius: 0, endCenter: rightC, endRadius: cr * 0.85, options: [])
    }
    ctx.restoreGState()
}

func writePNG(_ image: CGImage, to url: URL) {
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, image.bitsPerComponent == 8 ? image : eightBit(image), nil)
    CGImageDestinationFinalize(d)
}

@discardableResult
func run(_ tool: String, _ arguments: [String]) -> Int32 {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: tool)
    task.arguments = arguments
    try! task.run(); task.waitUntilExit()
    return task.terminationStatus
}

// MARK: AppIcon.icns
do {
    let base = 1024
    let ctx = context(base)
    drawAppIcon(in: ctx, side: CGFloat(base), withShadow: true)
    let master = eightBit(ctx.makeImage()!)
    writePNG(master, to: outDir.appendingPathComponent("AppIcon-1024.png"))

    let iconset = outDir.appendingPathComponent("AppIcon.iconset")
    try? FileManager.default.removeItem(at: iconset)
    try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                       ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                       ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
        let c = context(px)
        c.interpolationQuality = .high
        c.draw(master, in: CGRect(x: 0, y: 0, width: px, height: px))
        writePNG(c.makeImage()!, to: iconset.appendingPathComponent(name + ".png"))
    }
    let icns = outDir.appendingPathComponent("AppIcon.icns")
    let status = run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", icns.path])
    try? FileManager.default.removeItem(at: iconset)
    print("wrote", icns.path, fileSize(icns), "status", status)
}

// MARK: DMG background (660 × 400 pt window; app icon at x 180, Applications at x 480, y 185)
// Finder shows a window background at 1 image pixel per point, so the 1x and 2x
// renderings are combined into one HiDPI TIFF (tiffutil -cathidpicheck) that it
// picks the right representation from.
var backgroundPNGs: [URL] = []
for scale in [1, 2] as [CGFloat] {
    let w = 660, h = 400
    let ctx = context(width: Int(CGFloat(w) * scale), height: Int(CGFloat(h) * scale))
    ctx.scaleBy(x: scale, y: scale)
    let W = CGFloat(w), H = CGFloat(h)
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [rgba(0.13, 0.15, 0.27), rgba(0.06, 0.07, 0.13)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])
    let bloom = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [rgba(0.45, 0.35, 0.95, 0.35), rgba(0.45, 0.35, 0.95, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(bloom, startCenter: CGPoint(x: W * 0.5, y: H * 0.45), startRadius: 0,
                           endCenter: CGPoint(x: W * 0.5, y: H * 0.45), endRadius: W * 0.45, options: [])

    // Faint notch motif along the top, like the menu bar of a MacBook.
    ctx.setFillColor(rgba(1, 1, 1, 0.05)); ctx.fill(CGRect(x: 0, y: H - 28, width: W, height: 28))
    ctx.setFillColor(rgba(0, 0, 0, 0.9))
    ctx.addPath(CGPath(roundedRect: CGRect(x: W / 2 - 80, y: H - 24, width: 160, height: 34), cornerWidth: 10, cornerHeight: 10, transform: nil)); ctx.fillPath()

    // Arrow between the two drop targets (icons are placed by the Finder layout script).
    let y: CGFloat = H - 185     // CG is y-up; Finder positions are measured from the top
    ctx.setStrokeColor(rgba(1, 1, 1, 0.55)); ctx.setLineWidth(5); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 270, y: y)); ctx.addLine(to: CGPoint(x: 385, y: y)); ctx.strokePath()
    ctx.move(to: CGPoint(x: 362, y: y + 20)); ctx.addLine(to: CGPoint(x: 388, y: y)); ctx.addLine(to: CGPoint(x: 362, y: y - 20)); ctx.strokePath()

    // Text.
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    func text(_ string: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, y: CGFloat) {
        let a = NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor(white: 1, alpha: alpha)])
        let m = a.size()
        a.draw(at: CGPoint(x: (W - m.width) / 2, y: y))
    }
    text("NotchOrbit", size: 26, weight: .bold, alpha: 0.95, y: H - 86)
    text("Drag NotchOrbit to the Applications folder to install", size: 13, weight: .medium, alpha: 0.65, y: 84)
    text("First launch: if macOS says it can't verify the app, open System Settings › Privacy & Security", size: 10.5, weight: .regular, alpha: 0.45, y: 62)
    text("and click “Open Anyway”. NotchOrbit then lives in the menu bar. See Read Me for details.", size: 10.5, weight: .regular, alpha: 0.45, y: 46)
    NSGraphicsContext.restoreGraphicsState()

    let png = outDir.appendingPathComponent(scale == 1 ? "dmg-background.png" : "dmg-background@2x.png")
    writePNG(ctx.makeImage()!, to: png)
    backgroundPNGs.append(png)
}
do {
    let tiff = outDir.appendingPathComponent("dmg-background.tiff")
    let status = run("/usr/bin/tiffutil", ["-cathidpicheck"] + backgroundPNGs.map(\.path) + ["-out", tiff.path])
    for png in backgroundPNGs { try? FileManager.default.removeItem(at: png) }
    print("wrote", tiff.path, fileSize(tiff), "status", status)
}
