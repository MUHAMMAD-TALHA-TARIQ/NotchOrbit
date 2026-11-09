import AppKit

/// Plain tinted disc used for the circles when neither stats nor weather mode fills them.
final class CircleDiscView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = bounds.width / 2
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
    }

    func configure(borderWidth: CGFloat, borderColor: CGColor) {
        layer?.borderWidth = borderWidth
        layer?.borderColor = borderColor
    }
}
