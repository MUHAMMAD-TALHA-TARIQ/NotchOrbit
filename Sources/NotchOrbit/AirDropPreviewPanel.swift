import AppKit
import Quartz

/// A floating Quick Look card showing what just arrived, centred on the
/// point the ripple spreads from. Esc or the close button dismisses it.
final class AirDropPreviewPanel: NSObject {
    private var panel: KeyablePanel?
    private var urls: [URL] = []

    func show(_ urls: [URL], centeredAt point: CGPoint, on screen: NSScreen) {
        close()
        guard let first = urls.first else { return }
        self.urls = urls

        let barHeight: CGFloat = 52
        let previewSize = Self.previewSize(for: first, on: screen)
        let size = CGSize(width: previewSize.width, height: previewSize.height + barHeight)

        // Centre on the ripple origin, but stay fully on the screen.
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        var origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)

        let panel = KeyablePanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.onCancel = { [weak self] in self?.close() }

        let background = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.masksToBounds = true
        panel.contentView = background

        if let preview = QLPreviewView(
            frame: CGRect(x: 0, y: barHeight, width: size.width, height: previewSize.height), style: .normal) {
            preview.autostarts = true
            preview.previewItem = first as NSURL
            background.addSubview(preview)
        }

        let title = urls.count == 1
            ? first.lastPathComponent
            : "\(first.lastPathComponent) and \(urls.count - 1) more"
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let subtitle = NSTextField(labelWithString: "Received via AirDrop")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        let text = NSStackView(views: [label, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let open = NSButton(title: "Open", target: self, action: #selector(openFiles))
        open.keyEquivalent = "\r"
        let reveal = NSButton(title: "Show in Finder", target: self, action: #selector(revealFiles))
        let dismiss = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        for button in [open, reveal, dismiss] { button.bezelStyle = .rounded }

        let bar = NSStackView(views: [text, NSView(), dismiss, reveal, open])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 14)
        bar.frame = CGRect(x: 0, y: 0, width: size.width, height: barHeight)
        background.addSubview(bar)

        self.panel = panel
        animateIn(panel, content: background)
        debugLog("preview panel: \(urls.count) item(s), frame=\(panel.frame)")
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        urls = []
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: {
            // Dropping the content view releases the Quick Look preview.
            panel.contentView = nil
            panel.orderOut(nil)
        })
    }

    /// Grows out of the ripple's centre just behind the wave front.
    private func animateIn(_ panel: NSPanel, content: NSView) {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()

        if let layer = content.layer {
            let size = content.bounds.size
            var small = CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0)
            small = CATransform3DScale(small, 0.55, 0.55, 1)
            small = CATransform3DTranslate(small, -size.width / 2, -size.height / 2, 0)
            let grow = CASpringAnimation(keyPath: "transform")
            grow.fromValue = small
            grow.toValue = CATransform3DIdentity
            grow.beginTime = CACurrentMediaTime() + 0.12
            grow.fillMode = .backwards
            grow.damping = 16
            grow.initialVelocity = 2
            grow.duration = grow.settlingDuration
            layer.add(grow, forKey: "grow")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                panel.animator().alphaValue = 1
            }
        }
    }

    @objc private func openFiles() {
        urls.forEach { NSWorkspace.shared.open($0) }
        close()
    }

    @objc private func revealFiles() {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
        close()
    }

    @objc private func closeClicked() { close() }

    /// Pictures get a card in their own shape; everything else a 4:3 one.
    private static func previewSize(for url: URL, on screen: NSScreen) -> CGSize {
        var aspect: CGFloat = 4.0 / 3.0
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
           let h = props[kCGImagePropertyPixelHeight] as? CGFloat, w > 0, h > 0 {
            // Orientations 5–8 are rotated a quarter turn.
            let rotated = ((props[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
            aspect = rotated ? h / w : w / h
        }
        aspect = min(max(aspect, 0.5), 2.2)
        let maxWidth = min(screen.visibleFrame.width * 0.5, 900)
        let maxHeight = min(screen.visibleFrame.height * 0.6, 700)
        var width = maxWidth
        var height = width / aspect
        if height > maxHeight {
            height = maxHeight
            width = height * aspect
        }
        return CGSize(width: max(width.rounded(), 380), height: height.rounded())
    }
}

/// Borderless panels refuse key status by default; this one takes it so
/// Esc, Return and the Quick Look controls work.
private final class KeyablePanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
