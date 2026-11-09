import AppKit
import AVFoundation

/// Vertical microphone level meter shown beside the camera preview. Taps the
/// default input through AVAudioEngine while `start()`ed and draws a segmented
/// bar (green → yellow → red) with a peak-hold marker. Not flipped: y grows upward.
final class MicLevelView: NSView {
    private enum State: Equatable { case idle, running, message(String) }

    private let engine = AVAudioEngine()
    private var wantsRunning = false
    private var tapInstalled = false
    private var state: State = .idle { didSet { if state != oldValue { needsDisplay = true } } }

    /// Smoothed level and held peak, both 0…1 on a −60…0 dBFS scale.
    private var level: CGFloat = 0
    private var peak: CGFloat = 0
    private var peakHoldUntil: CFTimeInterval = 0

    private let segments = 14
    private let iconHeight: CGFloat = 26
    private static let deniedMessage = "Microphone access is off. Allow NotchOrbit in System Settings › Privacy & Security › Microphone."

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        toolTip = "Microphone level"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Control

    func start() {
        guard !wantsRunning else { return }
        wantsRunning = true
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            fail("The microphone needs the app bundle. Build with build.sh and launch NotchOrbit.app.")
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startEngine()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.wantsRunning else { return }
                    if granted { self.startEngine() } else { self.fail(Self.deniedMessage) }
                }
            }
        default:
            fail(Self.deniedMessage)
        }
    }

    func stop() {
        guard wantsRunning else { return }
        wantsRunning = false
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        level = 0
        peak = 0
        state = .idle
        toolTip = "Microphone level"
    }

    private func startEngine() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            fail("No microphone found on this Mac.")
            return
        }
        if !tapInstalled {
            // The tap fires ~47 times a second at 48 kHz; the meter is redrawn at most 30
            // times a second from the buffers accumulated in between.
            var sumSquares: Float = 0, count = 0, peak: Float = 0
            var lastSent: CFTimeInterval = 0
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let self, let channels = buffer.floatChannelData else { return }
                let n = Int(buffer.frameLength)
                guard n > 0 else { return }
                let samples = channels[0]
                for i in 0..<n {
                    let v = samples[i]
                    sumSquares += v * v
                    peak = max(peak, abs(v))
                }
                count += n
                let now = CACurrentMediaTime()
                guard now - lastSent >= 1.0 / 30 else { return }
                lastSent = now
                let rms = (sumSquares / Float(count)).squareRoot()
                let maxAbs = peak
                sumSquares = 0; count = 0; peak = 0
                DispatchQueue.main.async { self.ingest(rms: rms, peak: maxAbs) }
            }
            tapInstalled = true
        }
        do {
            engine.prepare()
            try engine.start()
            state = .running
            toolTip = "Microphone level"
        } catch {
            fail("Microphone unavailable: \(error.localizedDescription)")
        }
    }

    private func fail(_ message: String) {
        state = .message(message)
        toolTip = message
    }

    // MARK: Levels

    private static func normalized(_ linear: Float) -> CGFloat {
        let db = 20 * log10(max(Double(linear), 1e-6))
        return CGFloat(min(1, max(0, (db + 60) / 60)))
    }

    private func ingest(rms: Float, peak sample: Float) {
        guard wantsRunning else { return }
        let now = CACurrentMediaTime()
        let target = Self.normalized(rms)
        level = target > level ? target : level * 0.82 + target * 0.18

        let instantPeak = Self.normalized(sample)
        if instantPeak >= peak {
            peak = instantPeak
            peakHoldUntil = now + 1.2
        } else if now > peakHoldUntil {
            peak = max(instantPeak, peak - 0.015)
        }
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let barArea = CGRect(x: 0, y: iconHeight, width: bounds.width, height: bounds.height - iconHeight)
        let iconArea = CGRect(x: 0, y: 0, width: bounds.width, height: iconHeight)

        if case .message = state {
            PanelDrawing.drawSymbol("mic.slash.fill", in: CGRect(x: 0, y: bounds.midY - 10, width: bounds.width, height: 20),
                       pointSize: 14, color: NSColor.white.withAlphaComponent(0.45))
            return
        }

        drawSegments(in: barArea.insetBy(dx: 11, dy: 10))
        PanelDrawing.drawSymbol("mic.fill", in: iconArea, pointSize: 11,
                   color: NSColor.white.withAlphaComponent(state == .running ? 0.8 : 0.4))
    }

    private func drawSegments(in rect: CGRect) {
        guard rect.height > 20, rect.width > 4 else { return }
        let gap: CGFloat = 2.5
        let segmentHeight = (rect.height - gap * CGFloat(segments - 1)) / CGFloat(segments)
        for i in 0..<segments {
            let fraction = CGFloat(i) / CGFloat(segments)
            let y = rect.minY + CGFloat(i) * (segmentHeight + gap)
            let segment = NSBezierPath(roundedRect: CGRect(x: rect.minX, y: y, width: rect.width, height: segmentHeight),
                                       xRadius: 1.5, yRadius: 1.5)
            let lit = state == .running && fraction < level
            color(forFraction: fraction).withAlphaComponent(lit ? 1 : 0.14).setFill()
            segment.fill()
        }
        // Peak-hold marker
        if state == .running, peak > 0.02 {
            let y = rect.minY + peak * rect.height
            let marker = NSBezierPath(roundedRect: CGRect(x: rect.minX, y: min(rect.maxY - 2, y - 1), width: rect.width, height: 2),
                                      xRadius: 1, yRadius: 1)
            NSColor.white.withAlphaComponent(0.9).setFill()
            marker.fill()
        }
    }

    private func color(forFraction f: CGFloat) -> NSColor {
        if f >= 0.85 { return NSColor(srgbRed: 1.0, green: 0.36, blue: 0.30, alpha: 1) }
        if f >= 0.60 { return NSColor(srgbRed: 1.0, green: 0.80, blue: 0.25, alpha: 1) }
        return NSColor(srgbRed: 0.35, green: 0.85, blue: 0.50, alpha: 1)
    }
}
