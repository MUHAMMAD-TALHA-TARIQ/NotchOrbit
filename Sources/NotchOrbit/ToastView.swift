import AppKit

/// Small translucent message that fades in, lingers, and fades out. The owner
/// positions it using `fittingSize(maxWidth:)` in its `layout()`.
final class ToastView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var timer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        layer?.cornerRadius = 8
        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 2
        addSubview(label)
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 10, dy: 4)
    }

    func fittingSize(maxWidth: CGFloat) -> CGSize {
        let s = label.sizeThatFits(NSSize(width: max(40, maxWidth - 20), height: 40))
        return CGSize(width: min(maxWidth, s.width + 20), height: s.height + 8)
    }

    func show(_ message: String, duration: TimeInterval = 2.6) {
        timer?.invalidate()
        label.stringValue = message
        isHidden = false
        superview?.needsLayout = true
        superview?.layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            animator().alphaValue = 1
        }
        timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in self?.hide() }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        guard !isHidden else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.isHidden = true
        })
    }
}
