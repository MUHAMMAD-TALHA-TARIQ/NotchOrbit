// Renders Assets/screenshots/*.png for the README. This file is top-level code, so it
// has to be compiled as main.swift together with the app's sources (minus the app's
// own main.swift), with the Xcode toolchain for the SwiftUI macros:
//
//   mkdir -p /tmp/shots/src && cp Sources/NotchOrbit/*.swift /tmp/shots/src && rm /tmp/shots/src/main.swift
//   cp Tools/render-screenshots.swift /tmp/shots/main.swift
//   cd /tmp/shots && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -O main.swift src/*.swift -o shots
//   ./shots "$OLDPWD/Assets/screenshots"
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// Offscreen renders of NotchOrbit's overlay "faces" for the README. The views are the
// app's own classes; draw(_:) is called directly, and the few layer-only parts (shape
// layer, disc backgrounds, emoji badge, camera preview) are painted by hand.
_ = NSApplication.shared
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let scale: CGFloat = 2

// MARK: Rendering

func disc(_ view: NSView, in ctx: CGContext) {
    guard let layer = view.layer else { return }
    let b = view.bounds
    let r = min(b.width, b.height) / 2
    let path = CGPath(roundedRect: b, cornerWidth: r, cornerHeight: r, transform: nil)
    ctx.addPath(path); ctx.setFillColor(layer.backgroundColor ?? CGColor(gray: 0, alpha: 0.35)); ctx.fillPath()
    if layer.borderWidth > 0, let c = layer.borderColor {
        ctx.addPath(CGPath(roundedRect: b.insetBy(dx: layer.borderWidth / 2, dy: layer.borderWidth / 2),
                           cornerWidth: max(0, r - layer.borderWidth / 2), cornerHeight: max(0, r - layer.borderWidth / 2), transform: nil))
        ctx.setStrokeColor(c); ctx.setLineWidth(layer.borderWidth); ctx.strokePath()
    }
}

func drawText(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, at p: CGPoint, align: Int = 0) {
    let a = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
    let m = a.size()
    let x = align == 0 ? p.x : (align == 1 ? p.x - m.width / 2 : p.x - m.width)
    a.draw(at: CGPoint(x: x, y: p.y))
}

func render(_ view: NSView, in ctx: CGContext, parentFlipped: Bool) {
    guard !view.isHidden else { return }
    ctx.saveGState()
    let f = view.frame
    if view.isFlipped == parentFlipped { ctx.translateBy(x: f.minX, y: f.minY) }
    else { ctx.translateBy(x: f.minX, y: f.maxY); ctx.scaleBy(x: 1, y: -1) }
    ctx.clip(to: view.bounds)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: view.isFlipped)
    var recurse = true
    switch view {
    case let overlay as OverlayView:
        if let shape = overlay.layer?.sublayers?.compactMap({ $0 as? CAShapeLayer }).first, !shape.isHidden, let path = shape.path {
            var t = CGAffineTransform(translationX: shape.frame.minX, y: shape.frame.minY)
            if let moved = path.copy(using: &t) { ctx.addPath(moved); ctx.setFillColor(shape.fillColor ?? .black); ctx.fillPath() }
        }
    case let badge as EmojiBadgeView:
        disc(badge, in: ctx)
        let inner = badge.bounds.width - 2 * badge.borderWidth
        let a = NSAttributedString(string: badge.emoji, attributes: [.font: NSFont.systemFont(ofSize: inner * 0.58)])
        let m = a.size()
        ctx.setShadow(offset: .zero, blur: inner * 0.18, color: badge.effect == .fire
                      ? CGColor(srgbRed: 1, green: 0.45, blue: 0.1, alpha: 0.9) : CGColor(srgbRed: 0.6, green: 0.85, blue: 1, alpha: 0.6))
        a.draw(at: CGPoint(x: badge.bounds.midX - m.width / 2, y: badge.bounds.midY - m.height / 2))
        recurse = false
    case let badge as CircleBadgeView:
        disc(badge, in: ctx); badge.draw(badge.bounds)
    case let d as CircleDiscView:
        disc(d, in: ctx)
    case let w as WeatherPanelView:
        // Sky gradient (layer in the app) under the content view.
        let b = w.bounds
        ctx.addPath(CGPath(roundedRect: b, cornerWidth: WeatherPanelView.cornerRadius, cornerHeight: WeatherPanelView.cornerRadius, transform: nil)); ctx.clip()
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [CGColor(srgbRed: 0.16, green: 0.45, blue: 0.85, alpha: 1), CGColor(srgbRed: 0.99, green: 0.70, blue: 0.30, alpha: 1)] as CFArray,
                           locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: b.height), options: [])
        let scrim = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                               colors: [CGColor(gray: 0, alpha: 0.42), CGColor(gray: 0, alpha: 0)] as CFArray, locations: [0, 0.55])!
        ctx.drawLinearGradient(scrim, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: b.height), options: [])
        // A few hand-placed clouds and suns stand in for the particle scene.
        for (x, y, s) in [(0.62, 0.72, 44.0), (0.80, 0.86, 30.0), (0.48, 0.92, 24.0)] {
            let a = NSAttributedString(string: "☁️", attributes: [.font: NSFont.systemFont(ofSize: s)])
            a.draw(at: CGPoint(x: b.width * x, y: b.height * y - s / 2))
        }
    case let cam as CameraPreviewView:
        let b = cam.bounds, r = cam.layer?.cornerRadius ?? 12
        ctx.addPath(CGPath(roundedRect: b, cornerWidth: r, cornerHeight: r, transform: nil)); ctx.clip()
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [CGColor(srgbRed: 0.45, green: 0.55, blue: 0.70, alpha: 1), CGColor(srgbRed: 0.20, green: 0.24, blue: 0.38, alpha: 1)] as CFArray,
                           locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: b.width, y: b.height), options: [])
        PanelDrawing.drawSymbol("person.crop.circle", in: b.insetBy(dx: 0, dy: b.height * 0.1), pointSize: b.height * 0.42, weight: .regular,
                                color: NSColor.white.withAlphaComponent(0.55))
        let side = ShutterButton.size
        let shutter = CGRect(x: b.midX - side / 2, y: 10, width: side, height: side)   // the view is y-up
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.22)); ctx.fillEllipse(in: shutter)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.7)); ctx.setLineWidth(2); ctx.strokeEllipse(in: shutter.insetBy(dx: 1, dy: 1))
        PanelDrawing.drawSymbol("camera.fill", in: shutter, pointSize: 15, color: .white)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12)); ctx.setLineWidth(1)
        ctx.addPath(CGPath(roundedRect: b.insetBy(dx: 0.5, dy: 0.5), cornerWidth: r, cornerHeight: r, transform: nil)); ctx.strokePath()
        if let caption = cam.caption { feedCaption(caption, in: b) }
        recurse = false
    case let out as FaceOutputView:
        // Stand-in for a live transformed feed: a different "person", the badge the
        // server burns into every transformed frame, and the caption.
        let b = out.bounds, r = out.layer?.cornerRadius ?? 12
        ctx.addPath(CGPath(roundedRect: b, cornerWidth: r, cornerHeight: r, transform: nil)); ctx.clip()
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [CGColor(srgbRed: 0.62, green: 0.48, blue: 0.66, alpha: 1), CGColor(srgbRed: 0.28, green: 0.20, blue: 0.40, alpha: 1)] as CFArray,
                           locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: b.width, y: b.height), options: [])
        PanelDrawing.drawSymbol("person.crop.circle.fill", in: b.insetBy(dx: 0, dy: b.height * 0.1), pointSize: b.height * 0.42, weight: .regular,
                                color: NSColor.white.withAlphaComponent(0.7))
        let badge = PanelDrawing.text("AI TRANSFORMED", size: 8.5, weight: .bold, color: .white)
        let badgeRect = CGRect(x: 8, y: 8, width: badge.size().width + 10, height: badge.size().height + 5)
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.75, alpha: 0.9)); ctx.fill(badgeRect)
        badge.draw(at: CGPoint(x: badgeRect.minX + 5, y: badgeRect.minY + 2.5))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12)); ctx.setLineWidth(1)
        ctx.addPath(CGPath(roundedRect: b.insetBy(dx: 0.5, dy: 0.5), cornerWidth: r, cornerHeight: r, transform: nil)); ctx.strokePath()
        feedCaption("OUTPUT", in: b)
        recurse = false
    case let bar as FaceControlBar:
        // The control row as it looks during a session (the real one needs a live server).
        let h = min(bar.bounds.height, PanelPillButton.height), y = (bar.bounds.height - h) / 2
        var x: CGFloat = 0
        let pills: [(String, String, NSColor)] = [
            ("stop.fill", "Stop", NSColor(srgbRed: 0.85, green: 0.18, blue: 0.18, alpha: 1)),
            ("person.crop.circle", "Alex ▾", NSColor.white.withAlphaComponent(0.12)),
            ("person.crop.circle.badge.plus", "Enroll Face", NSColor.white.withAlphaComponent(0.12)),
            ("ellipsis", "", NSColor.white.withAlphaComponent(0.12)),
        ]
        for (symbol, title, fill) in pills {
            let label = PanelDrawing.text(title, size: 11, weight: .semibold, color: .white)
            let icon: CGFloat = 16
            let w = title.isEmpty ? 34 : label.size().width + icon + 24
            let rect = CGRect(x: x, y: y, width: w, height: h)
            fill.setFill(); NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
            if title.isEmpty {
                PanelDrawing.drawSymbol(symbol, in: rect, pointSize: 11, color: .white)
            } else {
                PanelDrawing.drawSymbol(symbol, in: CGRect(x: rect.minX + 10, y: rect.minY, width: icon, height: h), pointSize: 11, color: .white)
                label.draw(at: CGPoint(x: rect.minX + 10 + icon + 4, y: rect.midY - label.size().height / 2))
            }
            x += w + 6
        }
        let status = PanelDrawing.text("11 fps · transforming", size: 10, weight: .medium, color: NSColor.white.withAlphaComponent(0.6))
        status.draw(at: CGPoint(x: bar.bounds.maxX - status.size().width, y: bar.bounds.midY - status.size().height / 2))
        recurse = false
    case let meter as MicLevelView:
        let b = meter.bounds
        ctx.addPath(CGPath(roundedRect: b, cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.06)); ctx.fillPath()
        // Segments, drawn like the view does, with a level of ~55 %.
        let rect = CGRect(x: 0, y: 26, width: b.width, height: b.height - 26).insetBy(dx: 11, dy: 10)
        let segments = 14, gap: CGFloat = 2.5
        let h = (rect.height - gap * CGFloat(segments - 1)) / CGFloat(segments)
        for i in 0..<segments {
            let f = CGFloat(i) / CGFloat(segments)
            let y = rect.minY + CGFloat(i) * (h + gap)   // view is y-up; we are in its own space
            let color = f >= 0.85 ? NSColor(srgbRed: 1, green: 0.36, blue: 0.3, alpha: 1)
                      : f >= 0.6 ? NSColor(srgbRed: 1, green: 0.8, blue: 0.25, alpha: 1) : NSColor(srgbRed: 0.35, green: 0.85, blue: 0.5, alpha: 1)
            color.withAlphaComponent(f < 0.55 ? 1 : 0.14).setFill()
            NSBezierPath(roundedRect: CGRect(x: rect.minX, y: y, width: rect.width, height: h), xRadius: 1.5, yRadius: 1.5).fill()
        }
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: CGRect(x: rect.minX, y: rect.minY + rect.height * 0.7, width: rect.width, height: 2), xRadius: 1, yRadius: 1).fill()
        PanelDrawing.drawSymbol("mic.fill", in: CGRect(x: 0, y: 0, width: b.width, height: 26), pointSize: 11, color: NSColor.white.withAlphaComponent(0.8))
        recurse = false
    case let mic as MicPanelView:
        mic.draw(mic.bounds)
        let header = CGRect(x: 0, y: 0, width: mic.bounds.width, height: 24)
        ctx.setFillColor(.black); ctx.fill(header)
        let white = NSColor.white.withAlphaComponent(0.9)
        PanelDrawing.drawSymbol("mic.fill", in: CGRect(x: 0, y: 0, width: 20, height: 24), pointSize: 12, color: white)
        let name = PanelDrawing.text("MacBook Pro Microphone", size: 11.5, weight: .semibold, color: white)
        name.draw(at: CGPoint(x: 24, y: 12 - name.size().height / 2))
        PanelDrawing.drawSymbol("chevron.down", in: CGRect(x: 24 + name.size().width + 2, y: 0, width: 14, height: 24), pointSize: 8,
                                color: white.withAlphaComponent(0.7))
        let meter = CGRect(x: mic.bounds.width - 128, y: 6, width: 128, height: 12)
        let segments = 16, gap: CGFloat = 2
        let w = (meter.width - gap * CGFloat(segments - 1)) / CGFloat(segments)
        for i in 0..<segments {
            let f = CGFloat(i) / CGFloat(segments)
            let color = f >= 0.85 ? NSColor(srgbRed: 1, green: 0.36, blue: 0.3, alpha: 1)
                      : f >= 0.6 ? NSColor(srgbRed: 1, green: 0.8, blue: 0.25, alpha: 1) : NSColor(srgbRed: 0.35, green: 0.85, blue: 0.5, alpha: 1)
            color.withAlphaComponent(f < 0.62 ? 1 : 0.14).setFill()
            NSBezierPath(roundedRect: CGRect(x: meter.minX + CGFloat(i) * (w + gap), y: meter.minY, width: w, height: meter.height), xRadius: 1.5, yRadius: 1.5).fill()
        }
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: CGRect(x: meter.minX + meter.width * 0.78, y: meter.minY, width: 2, height: meter.height), xRadius: 1, yRadius: 1).fill()
    case is ToastView:
        recurse = false
    default:
        view.draw(view.bounds)
    }
    if recurse { for sub in view.subviews { render(sub, in: ctx, parentFlipped: view.isFlipped) } }
    NSGraphicsContext.restoreGraphicsState()
    ctx.restoreGState()
}

/// The "INPUT" / "OUTPUT" pill at the top of a feed (drawn in the feed's own y-up space).
func feedCaption(_ text: String, in b: CGRect) {
    let label = PanelDrawing.text(text, size: 8.5, weight: .bold, color: NSColor.white.withAlphaComponent(0.9))
    let size = CGSize(width: label.size().width + 12, height: 14)
    let rect = CGRect(x: b.midX - size.width / 2, y: b.maxY - size.height - 8, width: size.width, height: size.height)
    NSColor.black.withAlphaComponent(0.55).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
    label.draw(at: CGPoint(x: rect.minX + 6, y: rect.midY - label.size().height / 2))
}

/// A SwiftUI window's content, rendered offscreen at `size` (dark appearance).
func windowShot<V: View>(_ name: String, _ view: V, size: CGSize) {
    let hosting = NSHostingView(rootView: view.environmentObject(SettingsStore.shared).preferredColorScheme(.dark))
    hosting.frame = CGRect(origin: .zero, size: size)
    // The window's own background isn't part of an offscreen capture, so paint one.
    let backdrop = NSView(frame: hosting.frame)
    backdrop.wantsLayer = true
    backdrop.layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor
    backdrop.addSubview(hosting)
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = backdrop
    backdrop.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(1.5))   // let SwiftUI settle (and the server row resolve)
    guard let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) else { return }
    backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
    let url = outDir.appendingPathComponent(name + ".png")
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    print("wrote \(name).png \(bytes / 1024) KB")
}

/// Mock desktop: wallpaper, menu bar with a few items; `notchHeight` 0 means no hardware notch.
func scene(width: CGFloat, height: CGFloat, menuBar: CGFloat, hardwareNotch: CGRect?, name: String, draw: (CGContext) -> Void) {
    let ctx = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 16, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    // Flip: y grows downward from here on, like the overlay.
    ctx.translateBy(x: 0, y: height); ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    // Wallpaper
    ctx.setFillColor(CGColor(srgbRed: 0.19, green: 0.22, blue: 0.36, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(CGColor(srgbRed: 0.30, green: 0.22, blue: 0.42, alpha: 1))
    ctx.fill(CGRect(x: width * 0.55, y: 0, width: width * 0.45, height: height))
    ctx.setFillColor(CGColor(srgbRed: 0.24, green: 0.22, blue: 0.39, alpha: 1))
    ctx.fill(CGRect(x: width * 0.35, y: 0, width: width * 0.2, height: height))
    // Menu bar
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.14)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: menuBar))
    let items = ["", "Finder", "File", "Edit", "View"]
    var x: CGFloat = 16
    for (i, item) in items.enumerated() {
        drawText(item, size: i == 0 ? 15 : 13, weight: i <= 1 ? .bold : .regular, color: NSColor.white.withAlphaComponent(0.92),
                 at: CGPoint(x: x, y: menuBar / 2 - (i == 0 ? 10 : 8)))
        x += (i == 0 ? 28 : NSAttributedString(string: item, attributes: [.font: NSFont.systemFont(ofSize: 13)]).size().width + 20)
    }
    drawText("Sun 9 Nov  12:34", size: 13, color: NSColor.white.withAlphaComponent(0.92), at: CGPoint(x: width - 16, y: menuBar / 2 - 8), align: 2)
    PanelDrawing.drawSymbol("circle.lefthalf.filled", in: CGRect(x: width - 150, y: 0, width: 22, height: menuBar), pointSize: 13, weight: .regular, color: .white)
    PanelDrawing.drawSymbol("wifi", in: CGRect(x: width - 180, y: 0, width: 22, height: menuBar), pointSize: 13, weight: .regular, color: .white)
    PanelDrawing.drawSymbol("battery.75percent", in: CGRect(x: width - 212, y: 0, width: 26, height: menuBar), pointSize: 14, weight: .regular, color: .white)
    if let n = hardwareNotch {
        ctx.addPath(NotchShapeBuilder.hardwarePath(notch: n)); ctx.setFillColor(.black); ctx.fillPath()
    }
    draw(ctx)
    NSGraphicsContext.restoreGraphicsState()
    let wide = ctx.makeImage()!
    let c8 = CGContext(data: nil, width: wide.width, height: wide.height, bitsPerComponent: 8, bytesPerRow: 0,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c8.interpolationQuality = .none
    c8.draw(wide, in: CGRect(x: 0, y: 0, width: wide.width, height: wide.height))
    let image = c8.makeImage()!
    let url = outDir.appendingPathComponent(name + ".png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil); CGImageDestinationFinalize(dest)
    let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    print("wrote \(name).png \(bytes / 1024) KB")
}

// MARK: Data

func hourly() -> [HourForecast] {
    let conds: [WeatherCondition] = [.partlyCloudy, .partlyCloudy, .mainlyClear, .clear, .clear, .partlyCloudy, .overcast, .rain]
    return conds.enumerated().map { i, c in HourForecast(hour: (12 + i) % 24, temperatureC: [21, 22, 23, 23, 22, 20, 18, 17][i], condition: c, isDay: i < 6) }
}
let reading = WeatherReading(condition: .partlyCloudy, wmoCode: 2, isDay: true, temperatureC: 21, apparentC: 20, humidity: 58, windKmh: 14,
                             latitude: 51.5, longitude: -0.12, placeName: "London", fetchedAt: Date().addingTimeInterval(-240), hourly: hourly(), highC: 23, lowC: 15)
UserDefaults.standard.set(try! JSONEncoder().encode(reading), forKey: "NotchOrbit.weatherCache")
func snapshot(cpu: Double) -> StatSnapshot { StatSnapshot(cpu: cpu, memory: 63, gpu: 18, disk: 71, battery: 86, apps: 9) }
func history() -> [StatSnapshot] {
    (0..<90).map { i in
        let t = Double(i) / 89
        let cpu = 22 + 18 * sin(t * 9) + 10 * sin(t * 23 + 1) + (t > 0.75 ? 25 * (t - 0.75) * 4 : 0)
        var s = snapshot(cpu: min(97, max(4, cpu)))
        s.memory = 60 + 4 * sin(t * 5)
        return s
    }
}

// MARK: Overlay builder

/// Lays out an OverlayView like the controller does and returns it, ready to render.
func overlay(_ settings: AppSettings, width: CGFloat, height: CGFloat, rect: CGRect, kind: OverlayKind,
             expandedTab: String? = nil, cpu: Double = 42) -> (OverlayView, NSWindow) {
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
    let view = OverlayView()
    view.frame = CGRect(x: 0, y: 0, width: width, height: height)
    window.contentView = view
    view.apply(settings: settings, rect: rect, kind: kind)
    if let tab = expandedTab {
        view.debugExpand(tab: tab)
        VoiceChanger.current?.stop()
        view.layoutSubtreeIfNeeded()
    }
    view.update(snapshot: snapshot(cpu: cpu), history: history(), settings: settings)
    view.updateWeather(reading: settings.weather.enabled ? reading : nil, status: .ready, settings: settings)
    view.layoutSubtreeIfNeeded()
    return (view, window)
}

var base = AppSettings()
base.circles.size = 28
base.circles.borderWidth = 1.5

let W: CGFloat = 820
let notchW: CGFloat = 185, notchH: CGFloat = 32
let notch = CGRect(x: (W - notchW) / 2, y: 0, width: notchW, height: notchH)
let strip: CGFloat = 64

func notchScene(_ name: String, _ settings: AppSettings, height: CGFloat = strip, tab: String? = nil, cpu: Double = 42) {
    scene(width: W, height: height, menuBar: notchH, hardwareNotch: notch, name: name) { ctx in
        let (view, window) = overlay(settings, width: W, height: height, rect: notch, kind: .notch, expandedTab: tab, cpu: cpu)
        render(view, in: ctx, parentFlipped: true)
        _ = window
    }
}

// Shapes
var s = base; s.preset = .original
notchScene("shape-original", s)
for preset in [NotchPreset.rounded, .island, .square, .wide] {
    var s = base; s.preset = preset; s.shape = preset.params!
    notchScene("shape-\(preset.rawValue)", s)
}
var attached = base; attached.preset = .rounded; attached.shape = NotchPreset.rounded.params!; attached.circles.attachToNotch = true
notchScene("shape-attached", attached)

// Faces of the circles
var stats = base; stats.preset = .rounded; stats.shape = NotchPreset.rounded.params!; stats.stats.enabled = true; stats.circles.size = 30
notchScene("stats-cold", stats, cpu: 42)
notchScene("stats-hot", stats, cpu: 84)
var weather = stats; weather.weather.enabled = true
notchScene("weather", weather)
var weatherOnly = base; weatherOnly.preset = .rounded; weatherOnly.shape = NotchPreset.rounded.params!; weatherOnly.weather.enabled = true; weatherOnly.circles.size = 30
notchScene("weather-plain", weatherOnly)

// Dynamic Island on an external display (24 pt menu bar, no notch).
do {
    var s = base; s.preset = .rounded; s.shape = NotchPreset.rounded.params!
    let island = CGRect(x: (W - s.island.width) / 2, y: s.island.topOffset, width: s.island.width, height: s.island.height)
    scene(width: W, height: 70, menuBar: 24, hardwareNotch: nil, name: "island") { ctx in
        let (view, window) = overlay(s, width: W, height: 70, rect: island, kind: .island)
        render(view, in: ctx, parentFlipped: true); _ = window
    }
    var hanging = s; hanging.island.topOffset = 0; hanging.island.height = 28; hanging.island.cornerRadius = 12
    let hangRect = CGRect(x: (W - hanging.island.width) / 2, y: 0, width: hanging.island.width, height: hanging.island.height)
    scene(width: W, height: 70, menuBar: 24, hardwareNotch: nil, name: "island-hanging") { ctx in
        let (view, window) = overlay(hanging, width: W, height: 70, rect: hangRect, kind: .island)
        render(view, in: ctx, parentFlipped: true); _ = window
    }
}

// Expanded panel tabs
var panel = weather
panel.stats.mic.effect = .robot
panel.stats.mic.pitch = -2
panel.stats.mic.amount = 70
panel.stats.cameraShape = .rounded
notchScene("panel-stats", panel, height: 300, tab: "stats", cpu: 58)
notchScene("panel-weather", panel, height: 360, tab: "weather")
notchScene("panel-mic", panel, height: 372, tab: "mic")
notchScene("panel-camera", panel, height: 372, tab: "camera")

// Face Transform: the Camera tab with both feeds, the Settings page and the enrolment
// window. No real face or name is shown: the feeds are stand-ins, and the Settings page
// only reports whether a face server happens to be running on this Mac.
var faced = panel
faced.stats.face.enabled = true
faced.stats.face.port = 9
faced.stats.face.projectPath = "/Users/you/deep-facial"
faced.stats.face.identityID = "0000000000000000"
faced.stats.face.identityName = "Alex"
SettingsStore.shared.settings = faced
notchScene("panel-camera-face", faced, height: 408, tab: "camera")
SettingsStore.shared.settings.stats.face.port = 8787
windowShot("settings-face", SettingsPageContainer(page: .face) { FacePage() }, size: CGSize(width: 640, height: 880))
windowShot("enroll-face", FaceEnrollView(attestedBy: "Your Name") {}, size: CGSize(width: 460, height: 400))
print("done")
