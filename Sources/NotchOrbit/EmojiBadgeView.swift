import AppKit
import QuartzCore

/// Right circle in stats mode: the hot/cold emoji, optionally animated.
///
/// - `.fire`: the emoji flickers and stretches like a flame with a pulsing
///   orange glow while glowing embers rise from behind it.
/// - `.snow`: the emoji slowly turns and drifts while snowflakes fall past it
///   with a gentle side-to-side wind.
///
/// Everything runs on Core Animation (no timers, no redraws); the emoji itself
/// is rendered once into a bitmap and only re-rendered when text/size/scale change.
final class EmojiBadgeView: CircleBadgeView {
    enum Effect: Equatable { case none, fire, snow }

    var emoji: String = "❄️" { didSet { if emoji != oldValue { renderEmoji() } } }
    var effect: Effect = .none { didSet { if effect != oldValue { applyEffect() } } }

    private let emojiLayer = CALayer()
    private let emitter = CAEmitterLayer()

    private var renderedEmoji = ""
    private var renderedInner: CGFloat = 0
    private var renderedScale: CGFloat = 0
    private var laidOutSize: CGSize = .zero

    private static let motionKey = "notchorbit.motion"
    private static let glowKey = "notchorbit.glow"
    private static let windKey = "notchorbit.wind"

    override init(frame: NSRect) {
        super.init(frame: frame)
        emojiLayer.contentsGravity = .center
        emitter.birthRate = 0
        layer?.addSublayer(emitter)
        layer?.addSublayer(emojiLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Layout & rendering

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emitter.frame = bounds
        placeEmojiLayer()
        CATransaction.commit()
        renderEmoji()
        if bounds.size != laidOutSize {
            laidOutSize = bounds.size
            applyEffect()   // particle speeds scale with the circle
        }
    }

    override func configure(borderWidth: CGFloat, borderColor: CGColor) {
        super.configure(borderWidth: borderWidth, borderColor: borderColor)
        renderEmoji()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderEmoji()
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyEffect() }
    override func viewDidHide() { super.viewDidHide(); applyEffect() }
    override func viewDidUnhide() { super.viewDidUnhide(); applyEffect() }

    /// Flames are anchored near the bottom so stretching grows upward; snow spins about the centre.
    private func placeEmojiLayer() {
        let anchor = effect == .fire ? CGPoint(x: 0.5, y: 0.22) : CGPoint(x: 0.5, y: 0.5)
        emojiLayer.anchorPoint = anchor
        emojiLayer.bounds = bounds
        emojiLayer.position = CGPoint(x: bounds.minX + bounds.width * anchor.x,
                                      y: bounds.minY + bounds.height * anchor.y)
    }

    private func renderEmoji() {
        let inner = bounds.width - 2 * borderWidth
        let scale = window?.backingScaleFactor ?? 2
        guard inner > 0 else { emojiLayer.contents = nil; renderedInner = 0; return }
        guard emoji != renderedEmoji || inner != renderedInner || scale != renderedScale else { return }
        renderedEmoji = emoji; renderedInner = inner; renderedScale = scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emojiLayer.contentsScale = scale
        emojiLayer.contents = ParticleSprites.text(emoji, pointSize: inner * 0.58, scale: scale)
        CATransaction.commit()
    }

    /// Quick "pop" of the whole circle as click feedback.
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
        pop.values = [CATransform3DIdentity, scaled(1.3), scaled(0.94), CATransform3DIdentity]
        pop.duration = 0.45
        pop.calculationMode = .cubic
        layer.add(pop, forKey: "notchorbit.pop")
    }

    // MARK: Effects

    private var canAnimate: Bool {
        window != nil && !isHiddenOrHasHiddenAncestor && bounds.width > 0
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func applyEffect() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        emojiLayer.removeAllAnimations()
        emitter.removeAllAnimations()
        emojiLayer.shadowOpacity = 0
        placeEmojiLayer()

        guard canAnimate, effect != .none else {
            emitter.birthRate = 0
            emitter.emitterCells = nil
            return
        }
        switch effect {
        case .fire: startFire()
        case .snow: startSnow()
        case .none: break
        }
    }

    private func startFire() {
        let size = bounds.width

        // Emoji: fast irregular flicker — stretch up, lean, settle — like a flame.
        let steps: [(sx: CGFloat, sy: CGFloat, rot: CGFloat, dy: CGFloat)] = [
            (1.00, 1.00,  0.00, 0.0), (1.03, 1.09, -0.05, 1.0), (0.97, 1.02,  0.03, 0.3),
            (1.05, 1.12,  0.04, 1.5), (0.98, 0.96, -0.03, -0.4), (1.02, 1.06,  0.02, 0.8),
            (0.99, 1.03, -0.04, 0.2), (1.00, 1.00,  0.00, 0.0),
        ]
        let flicker = CAKeyframeAnimation(keyPath: "transform")
        flicker.values = steps.map { s in
            var t = CATransform3DMakeTranslation(0, s.dy, 0)
            t = CATransform3DRotate(t, s.rot, 0, 0, 1)
            return CATransform3DScale(t, s.sx, s.sy, 1)
        }
        flicker.duration = 1.15
        flicker.calculationMode = .cubic
        flicker.repeatCount = .infinity
        emojiLayer.add(flicker, forKey: Self.motionKey)

        // Warm glow that breathes with the flame.
        emojiLayer.shadowColor = CGColor(srgbRed: 1.0, green: 0.45, blue: 0.1, alpha: 1)
        emojiLayer.shadowOffset = .zero
        emojiLayer.shadowRadius = size * 0.09
        emojiLayer.shadowOpacity = 0.75
        let glow = CABasicAnimation(keyPath: "shadowOpacity")
        glow.fromValue = 0.45; glow.toValue = 0.95
        glow.duration = 0.55
        glow.autoreverses = true
        glow.repeatCount = .infinity
        glow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        emojiLayer.add(glow, forKey: Self.glowKey)

        // Embers rising from behind the emoji. Layer y grows upward (view isn't flipped).
        let cell = CAEmitterCell()
        cell.name = "ember"
        cell.contents = ParticleSprites.ember
        cell.contentsScale = 2
        cell.birthRate = 26
        cell.lifetime = 1.0
        cell.lifetimeRange = 0.35
        cell.velocity = size * 0.6
        cell.velocityRange = size * 0.22
        cell.emissionLongitude = .pi / 2
        cell.emissionRange = .pi / 7
        cell.yAcceleration = size * 0.4
        let diameter = size * 0.17
        cell.scale = diameter / ParticleSprites.points
        cell.scaleRange = cell.scale * 0.45
        cell.scaleSpeed = -cell.scale * 0.55
        cell.alphaSpeed = -0.95
        cell.color = CGColor(srgbRed: 1.0, green: 0.55, blue: 0.15, alpha: 0.95)
        cell.redRange = 0.05
        cell.greenRange = 0.3
        cell.alphaRange = 0.2

        emitter.emitterCells = [cell]
        emitter.emitterShape = .line
        emitter.emitterPosition = CGPoint(x: bounds.midX, y: bounds.minY + size * 0.24)
        emitter.emitterSize = CGSize(width: size * 0.45, height: 0)
        emitter.renderMode = .additive
        emitter.zPosition = -1
        emitter.beginTime = CACurrentMediaTime()
        emitter.birthRate = 1
    }

    private func startSnow() {
        let size = bounds.width

        // Emoji: slow turn plus a lazy vertical drift.
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * CGFloat.pi
        spin.duration = 16
        spin.repeatCount = .infinity
        emojiLayer.add(spin, forKey: Self.motionKey)

        let drift = CAKeyframeAnimation(keyPath: "transform.translation.y")
        drift.values = [0, size * 0.05, 0, -size * 0.05, 0]
        drift.duration = 4.5
        drift.calculationMode = .cubic
        drift.repeatCount = .infinity
        emojiLayer.add(drift, forKey: Self.motionKey + ".drift")

        // Cool, steady halo.
        emojiLayer.shadowColor = CGColor(srgbRed: 0.6, green: 0.85, blue: 1.0, alpha: 1)
        emojiLayer.shadowOffset = .zero
        emojiLayer.shadowRadius = size * 0.07
        emojiLayer.shadowOpacity = 0.45

        // Snowflakes falling in from just above the circle, in front of the emoji.
        let cell = CAEmitterCell()
        cell.name = "flake"
        cell.contents = ParticleSprites.snowflake
        cell.contentsScale = 2
        cell.birthRate = 7
        cell.lifetime = 6
        cell.lifetimeRange = 1.5
        cell.velocity = size * 0.3
        cell.velocityRange = size * 0.1
        cell.emissionLongitude = -.pi / 2
        cell.emissionRange = .pi / 12
        cell.yAcceleration = -size * 0.04
        let diameter = size * 0.14
        cell.scale = diameter / ParticleSprites.points
        cell.scaleRange = cell.scale * 0.5
        cell.spin = 0.8
        cell.spinRange = 1.6
        cell.color = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9)
        cell.alphaRange = 0.3

        emitter.emitterCells = [cell]
        emitter.emitterShape = .line
        emitter.emitterPosition = CGPoint(x: bounds.midX, y: bounds.maxY + diameter)
        emitter.emitterSize = CGSize(width: size * 0.95, height: 0)
        emitter.renderMode = .unordered
        emitter.zPosition = 1
        emitter.birthRate = 1

        // Gentle wind: sway the flakes' sideways acceleration back and forth.
        let wind = CABasicAnimation(keyPath: "emitterCells.flake.xAcceleration")
        wind.fromValue = -size * 0.18
        wind.toValue = size * 0.18
        wind.duration = 3
        wind.autoreverses = true
        wind.repeatCount = .infinity
        wind.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        emitter.add(wind, forKey: Self.windKey)
    }
}
