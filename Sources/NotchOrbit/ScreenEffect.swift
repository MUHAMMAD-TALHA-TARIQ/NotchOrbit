import AppKit
import QuartzCore

/// What a full-screen burst shows. Fire and snow come from the stats emoji;
/// the rest are picked from the current weather condition.
enum ScreenEffectKind: Equatable {
    case fire, snow, sun, night, clouds, fog, rain, heavyRain, thunder

    init(condition: WeatherCondition, isDay: Bool) {
        switch condition {
        case .clear, .mainlyClear:                               self = isDay ? .sun : .night
        case .partlyCloudy, .overcast, .unknown:                 self = .clouds
        case .fog:                                               self = .fog
        case .drizzle, .freezingDrizzle, .rain, .freezingRain, .rainShowers: self = .rain
        case .heavyRain, .heavyShowers:                          self = .heavyRain
        case .snow, .heavySnow, .snowGrains, .snowShowers:       self = .snow
        case .thunderstorm, .thunderstormHail:                   self = .thunder
        }
    }
}

/// Plays a full-screen particle burst (fire, snow or a weather scene) on one display
/// when a circle is clicked. Length comes from settings. One burst per display at a time.
final class ScreenEffectPlayer {
    static let shared = ScreenEffectPlayer()

    /// The window fades out over the last `fadeDuration` seconds of the burst;
    /// particles are emitted until then.
    static let fadeDuration: TimeInterval = 0.8

    private var active: [ScreenEffectWindow] = []

    /// - Parameter duration: total on-screen time (clamped to `StatsSettings.burstDurationRange`).
    func play(_ effect: ScreenEffectKind, emoji: String, on screen: NSScreen, duration: TimeInterval) {
        guard !active.contains(where: { $0.frame == screen.frame }) else { return }
        let range = StatsSettings.burstDurationRange
        let total = min(range.upperBound, max(range.lowerBound, duration))
        let window = ScreenEffectWindow(screen: screen)
        active.append(window)
        window.play(effect, emoji: emoji, emitFor: total - Self.fadeDuration, fadeOver: Self.fadeDuration) { [weak self] in
            self?.active.removeAll { $0 === window }
        }
    }
}

/// Transparent click-through window covering one whole display, above the notch overlay.
final class ScreenEffectWindow: NSPanel {
    private let effectView = ScreenEffectView()

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        contentView = effectView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func play(_ effect: ScreenEffectKind, emoji: String, emitFor emitDuration: TimeInterval,
              fadeOver fade: TimeInterval, completion: @escaping () -> Void) {
        alphaValue = 0
        orderFrontRegardless()
        effectView.layoutSubtreeIfNeeded()
        effectView.start(effect, emoji: emoji)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            animator().alphaValue = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + emitDuration) { [weak self] in
            guard let self else { return }
            self.effectView.stopEmitting()
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = fade
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.animator().alphaValue = 0
            }, completionHandler: {
                self.effectView.stopEmitting()
                self.orderOut(nil)
                self.close()
                completion()
            })
        }
    }
}

/// The particle layers: a glow gradient along one edge, embers/snowflakes/raindrops,
/// copies of the badge emoji drifting across the screen, and a lightning flash layer.
final class ScreenEffectView: NSView {
    private let glow = CAGradientLayer()
    private let particles = CAEmitterLayer()
    private let emojis = CAEmitterLayer()
    private let flash = CALayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        glow.opacity = 0
        particles.birthRate = 0
        emojis.birthRate = 0
        flash.backgroundColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        flash.opacity = 0
        layer?.addSublayer(glow)
        layer?.addSublayer(particles)
        layer?.addSublayer(emojis)
        layer?.addSublayer(flash)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        particles.frame = bounds
        emojis.frame = bounds
        flash.frame = bounds
        CATransaction.commit()
    }

    func stopEmitting() {
        particles.birthRate = 0
        emojis.birthRate = 0
    }

    /// Starts (or restarts) an effect. `emojiPointSize` scales the floating emoji and
    /// cloud sprites: 48 for a full screen, much smaller for the panel backdrop.
    func start(_ effect: ScreenEffectKind, emoji: String, emojiPointSize: CGFloat = 48) {
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let emojiSprite = ParticleSprites.text(emoji, pointSize: emojiPointSize, scale: scale)
        let spriteScale = emojiPointSize / 48

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Clean slate, so the view can be reused for another effect.
        for l in [glow, particles, emojis, flash] as [CALayer] { l.removeAllAnimations() }
        particles.setAffineTransform(.identity)
        flash.opacity = 0
        glow.opacity = 0

        switch effect {
        case .fire:
            // Warm glow rising from the bottom edge, breathing.
            glow.frame = CGRect(x: 0, y: 0, width: w, height: h * 0.4)
            glow.colors = [CGColor(srgbRed: 1.0, green: 0.4, blue: 0.08, alpha: 0.6),
                           CGColor(srgbRed: 1.0, green: 0.5, blue: 0.1, alpha: 0.0)]
            glow.startPoint = CGPoint(x: 0.5, y: 0)
            glow.endPoint = CGPoint(x: 0.5, y: 1)
            glow.opacity = 0.85
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 0.6; breathe.toValue = 1.0
            breathe.duration = 0.4; breathe.autoreverses = true; breathe.repeatCount = .infinity
            glow.add(breathe, forKey: "breathe")

            // Embers and flame tongues from the whole bottom edge.
            let ember = CAEmitterCell()
            ember.contents = ParticleSprites.ember
            ember.contentsScale = 2
            ember.birthRate = Float(w / 2.5)
            ember.lifetime = 2.0
            ember.lifetimeRange = 0.7
            ember.velocity = h * 0.35
            ember.velocityRange = h * 0.15
            ember.emissionLongitude = .pi / 2
            ember.emissionRange = .pi / 9
            ember.yAcceleration = h * 0.12
            ember.scale = 30 / ParticleSprites.points
            ember.scaleRange = ember.scale * 0.6
            ember.scaleSpeed = -ember.scale * 0.45
            ember.alphaSpeed = -0.5
            ember.color = CGColor(srgbRed: 1.0, green: 0.5, blue: 0.12, alpha: 0.9)
            ember.redRange = 0.05
            ember.greenRange = 0.35
            ember.alphaRange = 0.3
            configure(particles, cells: [ember], position: CGPoint(x: w / 2, y: -20), width: w, additive: true)

            // The badge emoji itself floating up and tumbling.
            let flame = CAEmitterCell()
            flame.contents = emojiSprite
            flame.contentsScale = scale
            flame.birthRate = Float(max(6, w / 55))
            flame.lifetime = 2.6
            flame.lifetimeRange = 0.6
            flame.velocity = h * 0.3
            flame.velocityRange = h * 0.1
            flame.emissionLongitude = .pi / 2
            flame.emissionRange = .pi / 8
            flame.yAcceleration = h * 0.08
            flame.scale = 1.0
            flame.scaleRange = 0.5
            flame.spin = 0.6
            flame.spinRange = 1.2
            flame.alphaSpeed = -0.35
            configure(emojis, cells: [flame], position: CGPoint(x: w / 2, y: -40), width: w, additive: false)

        case .snow:
            // Cool haze at the top edge.
            glow.frame = CGRect(x: 0, y: h * 0.65, width: w, height: h * 0.35)
            glow.colors = [CGColor(srgbRed: 0.7, green: 0.88, blue: 1.0, alpha: 0.0),
                           CGColor(srgbRed: 0.75, green: 0.9, blue: 1.0, alpha: 0.3)]
            glow.startPoint = CGPoint(x: 0.5, y: 0)
            glow.endPoint = CGPoint(x: 0.5, y: 1)
            glow.opacity = 1

            let flake = CAEmitterCell()
            flake.name = "flake"
            flake.contents = ParticleSprites.snowflake
            flake.contentsScale = 2
            flake.birthRate = Float(w / 4)
            flake.lifetime = 5
            flake.lifetimeRange = 1
            flake.velocity = h * 0.3
            flake.velocityRange = h * 0.12
            flake.emissionLongitude = -.pi / 2
            flake.emissionRange = .pi / 10
            flake.yAcceleration = -h * 0.05
            flake.scale = 22 / ParticleSprites.points
            flake.scaleRange = flake.scale * 0.6
            flake.spin = 1.0
            flake.spinRange = 2.0
            flake.color = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9)
            flake.alphaRange = 0.3
            configure(particles, cells: [flake], position: CGPoint(x: w / 2, y: h + 30), width: w, additive: false)

            let drop = CAEmitterCell()
            drop.name = "emoji"
            drop.contents = emojiSprite
            drop.contentsScale = scale
            drop.birthRate = Float(max(6, w / 55))
            drop.lifetime = 5
            drop.lifetimeRange = 1
            drop.velocity = h * 0.28
            drop.velocityRange = h * 0.1
            drop.emissionLongitude = -.pi / 2
            drop.emissionRange = .pi / 10
            drop.yAcceleration = -h * 0.04
            drop.scale = 1.0
            drop.scaleRange = 0.5
            drop.spin = 0.5
            drop.spinRange = 1.5
            configure(emojis, cells: [drop], position: CGPoint(x: w / 2, y: h + 60), width: w, additive: false)

            // Gusts of wind pushing everything side to side.
            for (layer, name) in [(particles, "flake"), (emojis, "emoji")] {
                let wind = CABasicAnimation(keyPath: "emitterCells.\(name).xAcceleration")
                wind.fromValue = -h * 0.15; wind.toValue = h * 0.15
                wind.duration = 2.0; wind.autoreverses = true; wind.repeatCount = .infinity
                wind.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(wind, forKey: "wind")
            }

        case .sun:
            // Warm sunshine pouring in from the top, slowly breathing.
            setGlow(top: true, height: 0.45,
                    from: CGColor(srgbRed: 1.0, green: 0.85, blue: 0.35, alpha: 0.0),
                    to: CGColor(srgbRed: 1.0, green: 0.8, blue: 0.3, alpha: 0.55))
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 0.7; breathe.toValue = 1.0
            breathe.duration = 1.6; breathe.autoreverses = true; breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glow.add(breathe, forKey: "breathe")

            // Golden motes drifting up through the light.
            let mote = CAEmitterCell()
            mote.contents = ParticleSprites.ember
            mote.contentsScale = 2
            mote.birthRate = Float(w / 10)
            mote.lifetime = 5
            mote.lifetimeRange = 1.5
            mote.velocity = h * 0.07
            mote.velocityRange = h * 0.04
            mote.emissionLongitude = .pi / 2
            mote.emissionRange = .pi / 4
            mote.scale = 14 / ParticleSprites.points
            mote.scaleRange = mote.scale * 0.7
            mote.alphaSpeed = -0.2
            mote.color = CGColor(srgbRed: 1.0, green: 0.9, blue: 0.5, alpha: 0.9)
            mote.alphaRange = 0.4
            configure(particles, cells: [mote], shape: .rectangle, position: CGPoint(x: w / 2, y: h / 2),
                      size: CGSize(width: w, height: h), additive: true)

            // Suns rising gently from the bottom edge.
            let sun = CAEmitterCell()
            sun.contents = emojiSprite
            sun.contentsScale = scale
            sun.birthRate = Float(max(3, w / 160))
            sun.lifetime = 7
            sun.lifetimeRange = 1.5
            sun.velocity = h * 0.16
            sun.velocityRange = h * 0.05
            sun.emissionLongitude = .pi / 2
            sun.emissionRange = .pi / 14
            sun.scale = 1.1
            sun.scaleRange = 0.6
            sun.spin = 0.25
            sun.spinRange = 0.3
            sun.alphaSpeed = -0.12
            configure(emojis, cells: [sun], shape: .line, position: CGPoint(x: w / 2, y: -60),
                      size: CGSize(width: w, height: 0), additive: false)

        case .night:
            // Deep blue dusk settling from the top, with twinkling stars everywhere.
            setGlow(top: true, height: 0.6,
                    from: CGColor(srgbRed: 0.1, green: 0.12, blue: 0.35, alpha: 0.0),
                    to: CGColor(srgbRed: 0.08, green: 0.1, blue: 0.3, alpha: 0.55))

            let star = CAEmitterCell()
            star.contents = ParticleSprites.ember
            star.contentsScale = 2
            star.birthRate = Float(w / 6)
            star.lifetime = 2.2
            star.lifetimeRange = 1.0
            star.velocity = 0
            star.scale = 9 / ParticleSprites.points
            star.scaleRange = star.scale * 0.8
            star.scaleSpeed = star.scale * 0.6     // twinkle: grow while fading
            star.alphaSpeed = -0.5
            star.color = CGColor(srgbRed: 1, green: 1, blue: 0.95, alpha: 1)
            star.alphaRange = 0.3
            configure(particles, cells: [star], shape: .rectangle, position: CGPoint(x: w / 2, y: h / 2),
                      size: CGSize(width: w, height: h), additive: true)

            // Moons drifting down slowly.
            let moon = CAEmitterCell()
            moon.name = "emoji"
            moon.contents = emojiSprite
            moon.contentsScale = scale
            moon.birthRate = Float(max(3, w / 140))
            moon.lifetime = 8
            moon.lifetimeRange = 2
            moon.velocity = h * 0.12
            moon.velocityRange = h * 0.04
            moon.emissionLongitude = -.pi / 2
            moon.emissionRange = .pi / 12
            moon.scale = 1.0
            moon.scaleRange = 0.5
            moon.spin = 0.2
            moon.spinRange = 0.4
            configure(emojis, cells: [moon], shape: .line, position: CGPoint(x: w / 2, y: h + 60),
                      size: CGSize(width: w, height: 0), additive: false)
            addWind(to: emojis, cell: "emoji", strength: h * 0.05, period: 3)

        case .clouds, .fog:
            let foggy = effect == .fog
            // Grey overcast haze (clouds) or a white blanket rising from the bottom (fog).
            if foggy {
                setGlow(top: false, height: 0.6,
                        from: CGColor(srgbRed: 0.9, green: 0.92, blue: 0.95, alpha: 0.5),
                        to: CGColor(srgbRed: 0.9, green: 0.92, blue: 0.95, alpha: 0.0))
            } else {
                setGlow(top: true, height: 0.4,
                        from: CGColor(srgbRed: 0.6, green: 0.65, blue: 0.72, alpha: 0.0),
                        to: CGColor(srgbRed: 0.55, green: 0.6, blue: 0.68, alpha: 0.4))
            }

            // Big clouds sliding in from the left edge.
            let cloud = CAEmitterCell()
            cloud.contents = ParticleSprites.text("☁️", pointSize: 110 * spriteScale, scale: scale)
            cloud.contentsScale = scale
            cloud.birthRate = foggy ? 2.2 : 1.4
            cloud.velocity = w * (foggy ? 0.06 : 0.1)
            cloud.velocityRange = w * 0.03
            cloud.lifetime = Float(w / cloud.velocity) * 1.4
            cloud.emissionLongitude = 0
            cloud.emissionRange = .pi / 60
            cloud.scale = foggy ? 1.8 : 1.2
            cloud.scaleRange = 0.7
            cloud.color = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: foggy ? 0.45 : 0.85)
            cloud.alphaRange = 0.15
            configure(particles, cells: [cloud], shape: .rectangle,
                      position: CGPoint(x: -140 * spriteScale, y: foggy ? h * 0.3 : h * 0.62),
                      size: CGSize(width: 1, height: foggy ? h * 0.6 : h * 0.7), additive: false)

            // The badge emoji drifting along a little faster, in front.
            let drift = CAEmitterCell()
            drift.contents = emojiSprite
            drift.contentsScale = scale
            drift.birthRate = 1.5
            drift.velocity = w * 0.14
            drift.velocityRange = w * 0.04
            drift.lifetime = Float(w / drift.velocity) * 1.3
            drift.emissionLongitude = 0
            drift.emissionRange = .pi / 40
            drift.scale = 1.0
            drift.scaleRange = 0.5
            drift.color = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: foggy ? 0.6 : 1)
            configure(emojis, cells: [drift], shape: .rectangle, position: CGPoint(x: -60 * spriteScale, y: h * 0.55),
                      size: CGSize(width: 1, height: h * 0.8), additive: false)

        case .rain, .heavyRain, .thunder:
            let heavy = effect != .rain
            // Steel-blue sky pressing down from the top.
            setGlow(top: true, height: 0.5,
                    from: CGColor(srgbRed: 0.3, green: 0.38, blue: 0.5, alpha: 0.0),
                    to: CGColor(srgbRed: 0.25, green: 0.32, blue: 0.45, alpha: heavy ? 0.5 : 0.35))

            // Raindrop streaks, slightly wind-blown.
            let lean: CGFloat = heavy ? 0.22 : 0.12
            let drop = CAEmitterCell()
            drop.contents = ParticleSprites.raindrop
            drop.contentsScale = 2
            drop.birthRate = Float(w / (heavy ? 1.2 : 2.5))
            drop.lifetime = 2.5
            drop.lifetimeRange = 0.5
            drop.velocity = h * (heavy ? 1.1 : 0.8)
            drop.velocityRange = h * 0.2
            drop.emissionLongitude = -.pi / 2 - lean
            drop.emissionRange = .pi / 60
            drop.yAcceleration = -h * 0.3
            drop.scale = (heavy ? 1.6 : 1.2) * max(0.6, spriteScale)
            drop.scaleRange = 0.4
            drop.color = CGColor(srgbRed: 0.8, green: 0.9, blue: 1.0, alpha: heavy ? 0.75 : 0.6)
            drop.alphaRange = 0.25
            drop.spin = 0
            // Streaks are drawn upright; lean them to match their direction of travel.
            drop.emissionLatitude = 0
            configure(particles, cells: [drop], shape: .line, position: CGPoint(x: w / 2 + h * lean * 0.5, y: h + 40),
                      size: CGSize(width: w + h * lean, height: 0), additive: false)
            particles.setAffineTransform(CGAffineTransform(rotationAngle: lean))

            // The badge emoji tumbling down with the rain.
            let fall = CAEmitterCell()
            fall.contents = emojiSprite
            fall.contentsScale = scale
            fall.birthRate = Float(max(5, w / 70))
            fall.lifetime = 3.5
            fall.lifetimeRange = 0.8
            fall.velocity = h * 0.45
            fall.velocityRange = h * 0.15
            fall.emissionLongitude = -.pi / 2 - lean * 0.6
            fall.emissionRange = .pi / 16
            fall.yAcceleration = -h * 0.12
            fall.scale = 1.0
            fall.scaleRange = 0.5
            fall.spin = 0.4
            fall.spinRange = 1.0
            var cells = [fall]
            if effect == .thunder {
                let bolt = CAEmitterCell()
                bolt.contents = ParticleSprites.text("⚡️", pointSize: 56 * spriteScale, scale: scale)
                bolt.contentsScale = scale
                bolt.birthRate = Float(max(2, w / 300))
                bolt.lifetime = 2.5
                bolt.velocity = h * 0.6
                bolt.velocityRange = h * 0.2
                bolt.emissionLongitude = -.pi / 2
                bolt.emissionRange = .pi / 20
                bolt.scale = 1.0
                bolt.scaleRange = 0.4
                bolt.alphaSpeed = -0.35
                cells.append(bolt)
            }
            configure(emojis, cells: cells, shape: .line, position: CGPoint(x: w / 2, y: h + 60),
                      size: CGSize(width: w, height: 0), additive: false)

            if effect == .thunder { startLightning() }
        }
    }

    /// Gradient along the top or bottom edge covering `height` of the screen (fraction).
    private func setGlow(top: Bool, height: CGFloat, from: CGColor, to: CGColor) {
        let h = bounds.height
        glow.frame = top ? CGRect(x: 0, y: h * (1 - height), width: bounds.width, height: h * height)
                         : CGRect(x: 0, y: 0, width: bounds.width, height: h * height)
        glow.colors = [from, to]
        glow.startPoint = CGPoint(x: 0.5, y: 0)
        glow.endPoint = CGPoint(x: 0.5, y: 1)
        glow.opacity = 1
    }

    /// Sways the named cell's sideways acceleration back and forth.
    private func addWind(to emitter: CAEmitterLayer, cell: String, strength: CGFloat, period: CFTimeInterval) {
        let wind = CABasicAnimation(keyPath: "emitterCells.\(cell).xAcceleration")
        wind.fromValue = -strength; wind.toValue = strength
        wind.duration = period; wind.autoreverses = true; wind.repeatCount = .infinity
        wind.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        emitter.add(wind, forKey: "wind")
    }

    /// Two irregular double-flashes every few seconds, whitening the whole screen.
    private func startLightning() {
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values =   [0,   0,    0.85, 0.15, 0.6, 0,    0,    0,    0.7,  0.1,  0.9,  0.2,  0,    0]
        anim.keyTimes = [0,   0.06, 0.07, 0.10, 0.12, 0.16, 0.5,  0.58, 0.59, 0.62, 0.64, 0.67, 0.72, 1]
        anim.duration = 5.5
        anim.calculationMode = .linear
        anim.repeatCount = .infinity
        anim.beginTime = CACurrentMediaTime() + 0.4
        flash.add(anim, forKey: "lightning")
    }

    private func configure(_ emitter: CAEmitterLayer, cells: [CAEmitterCell], position: CGPoint, width: CGFloat, additive: Bool) {
        configure(emitter, cells: cells, shape: .line, position: position, size: CGSize(width: width, height: 0), additive: additive)
    }

    private func configure(_ emitter: CAEmitterLayer, cells: [CAEmitterCell], shape: CAEmitterLayerEmitterShape,
                           position: CGPoint, size: CGSize, additive: Bool) {
        emitter.emitterCells = cells
        emitter.emitterShape = shape
        emitter.emitterPosition = position
        emitter.emitterSize = size
        emitter.renderMode = additive ? .additive : .unordered
        emitter.beginTime = CACurrentMediaTime()
        emitter.birthRate = 1
    }
}
