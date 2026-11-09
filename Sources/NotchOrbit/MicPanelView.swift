import AppKit
import Combine

/// Content of the panel's Mic tab: the microphone in use with a live level meter,
/// a grid of voice effects, pitch / effect / volume sliders, and buttons for
/// playthrough, recording and stay-on. Choices go straight into the settings
/// store; `VoiceChanger.shared` does the audio work. Flipped (y down).
final class MicPanelView: NSView {
    /// Mirrors `StatsSettings.mic`; the panel sets it whenever settings change.
    var settings = MicSettings() {
        didSet {
            guard settings != oldValue else { return }
            syncControls()
            needsDisplay = true
        }
    }
    /// Where voice recordings go; the panel sets this from the user's settings.
    var saveDirectory = StatsSettings.defaultPhotoDirectory

    private let changer = VoiceChanger.shared
    private let toast = ToastView(frame: .zero)
    private let pitchSlider = PanelSlider(title: "Pitch", range: MicSettings.pitchRange)
    private let amountSlider = PanelSlider(title: "Effect", range: MicSettings.amountRange)
    private let volumeSlider = PanelSlider(title: "Volume", range: MicSettings.volumeRange)
    private var subscriptions = Set<AnyCancellable>()
    private var recTimer: Timer?
    private var active = false

    /// Smoothed level and held peak, 0…1 on a −60…0 dBFS scale.
    private var level: CGFloat = 0
    private var peak: CGFloat = 0
    private var peakHoldUntil: CFTimeInterval = 0

    private let headerHeight: CGFloat = 24
    private let chipGap: CGFloat = 6
    private let chipHeight: CGFloat = 46
    private let sliderHeight: CGFloat = 22
    private let buttonHeight: CGFloat = 30
    private let columns = 5
    private let accent = NSColor(srgbRed: 0.62, green: 0.80, blue: 1.0, alpha: 1)
    private let recordColor = NSColor(srgbRed: 1.0, green: 0.30, blue: 0.30, alpha: 1)

    private enum Button: CaseIterable { case playthrough, record, stayOn, useAsMic }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        pitchSlider.format = { v in
            let n = Int(v.rounded())
            return n > 0 ? "+\(n) st" : "\(n) st"
        }
        pitchSlider.snap = 1
        pitchSlider.onChange = { v in SettingsStore.shared.settings.stats.mic.pitch = v }
        amountSlider.format = { "\(Int($0.rounded()))%" }
        amountSlider.onChange = { v in SettingsStore.shared.settings.stats.mic.amount = v.rounded() }
        volumeSlider.format = { "\(Int($0.rounded()))%" }
        volumeSlider.onChange = { v in SettingsStore.shared.settings.stats.mic.volume = v.rounded() }
        for slider in [pitchSlider, amountSlider, volumeSlider] { addSubview(slider) }
        addSubview(toast)
        syncControls()

        changer.$state.receive(on: DispatchQueue.main).sink { [weak self] state in
            guard let self else { return }
            if case .failed(let message) = state, self.active { self.toast.show(message, duration: 4) }
            self.needsDisplay = true
        }.store(in: &subscriptions)
        changer.$inputName.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.needsDisplay = true }
            .store(in: &subscriptions)
        changer.$isRecording.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.syncRecordingTimer() }
            .store(in: &subscriptions)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { recTimer?.invalidate() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Control

    /// Listen while the tab is showing. Stopping hands over to the engine's own
    /// stay-on rule, so playthrough can continue after the panel closes.
    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on {
            changer.onLevel = { [weak self] rms, peak in self?.ingest(rms: rms, peak: peak) }
            changer.panelOpen = true
        } else {
            changer.panelOpen = false
            changer.onLevel = nil
            toast.hide()
            level = 0
            peak = 0
        }
        needsDisplay = true
    }

    private func syncControls() {
        pitchSlider.value = settings.pitch
        amountSlider.value = settings.amount
        volumeSlider.value = settings.volume
        volumeSlider.isDimmed = !settings.playthrough
    }

    private func syncRecordingTimer() {
        recTimer?.invalidate()
        recTimer = nil
        if changer.isRecording {
            recTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.needsDisplay = true }
        }
        needsDisplay = true
    }

    // MARK: Levels

    private static func normalized(_ linear: Float) -> CGFloat {
        let db = 20 * log10(max(Double(linear), 1e-6))
        return CGFloat(min(1, max(0, (db + 60) / 60)))
    }

    private func ingest(rms: Float, peak sample: Float) {
        guard active else { return }
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
        setNeedsDisplay(headerRect)
    }

    // MARK: Geometry

    private var headerRect: CGRect { CGRect(x: 0, y: 0, width: bounds.width, height: headerHeight) }
    private var meterRect: CGRect { CGRect(x: bounds.width - 128, y: 6, width: 128, height: headerHeight - 12) }
    /// The microphone name / status in the header; click it to pick a microphone.
    private var microphoneRect: CGRect { CGRect(x: 0, y: 0, width: meterRect.minX - 10, height: headerHeight) }

    private var gridTop: CGFloat { headerHeight + 10 }

    private func chipRects() -> [(VoiceEffect, CGRect)] {
        let effects = VoiceEffect.allCases
        let width = (bounds.width - chipGap * CGFloat(columns - 1)) / CGFloat(columns)
        return effects.enumerated().map { i, effect in
            let column = CGFloat(i % columns)
            let row = CGFloat(i / columns)
            return (effect, CGRect(x: column * (width + chipGap), y: gridTop + row * (chipHeight + chipGap),
                                   width: width, height: chipHeight))
        }
    }

    private var gridBottom: CGFloat {
        let rows = CGFloat((VoiceEffect.allCases.count + columns - 1) / columns)
        return gridTop + rows * chipHeight + (rows - 1) * chipGap
    }

    private var slidersTop: CGFloat { gridBottom + 10 }

    private var buttonsRect: CGRect {
        CGRect(x: 0, y: bounds.height - buttonHeight, width: bounds.width, height: buttonHeight)
    }

    private func buttonRect(_ button: Button) -> CGRect {
        let all = Button.allCases
        let gap: CGFloat = 6
        let width = (bounds.width - gap * CGFloat(all.count - 1)) / CGFloat(all.count)
        let index = CGFloat(all.firstIndex(of: button) ?? 0)
        return CGRect(x: index * (width + gap), y: buttonsRect.minY, width: width, height: buttonHeight)
    }

    override func layout() {
        super.layout()
        let gap: CGFloat = 10
        let width = (bounds.width - gap * 2) / 3
        for (i, slider) in [pitchSlider, amountSlider, volumeSlider].enumerated() {
            slider.frame = CGRect(x: CGFloat(i) * (width + gap), y: slidersTop, width: width, height: sliderHeight)
        }
        let toastSize = toast.fittingSize(maxWidth: bounds.width - 24)
        toast.frame = CGRect(x: bounds.midX - toastSize.width / 2, y: gridTop + 4,
                             width: toastSize.width, height: toastSize.height)
    }

    // MARK: Interaction

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if microphoneRect.contains(p) {
            showMicrophoneMenu(at: p)
            return
        }
        if let hit = chipRects().first(where: { $0.1.contains(p) }) {
            SettingsStore.shared.settings.stats.mic.effect = hit.0
            return
        }
        for button in Button.allCases where buttonRect(button).contains(p) {
            press(button)
            return
        }
    }

    // MARK: Microphone picker

    /// Lists the real input devices (never a loopback device) with the current choice
    /// ticked. "System default" follows System Settings › Sound › Input, except that a
    /// loopback device there is skipped in favour of a real microphone.
    private func showMicrophoneMenu(at point: CGPoint) {
        let inputs = AudioDevices.inputs().filter { !AudioDevices.isLoopback($0) }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let systemDefault = AudioDevices.defaultDevice(input: true).flatMap { id in inputs.first { $0.id == id } }
        let defaultTitle = systemDefault.map { "System default (\($0.name))" } ?? "System default"
        let defaultItem = NSMenuItem(title: defaultTitle, action: #selector(microphoneChosen(_:)), keyEquivalent: "")
        defaultItem.target = self
        defaultItem.state = settings.inputDeviceUID == nil ? .on : .off
        menu.addItem(defaultItem)
        menu.addItem(.separator())
        for device in inputs {
            let item = NSMenuItem(title: device.name, action: #selector(microphoneChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = settings.inputDeviceUID == device.uid ? .on : .off
            menu.addItem(item)
        }
        if let chosen = settings.inputDeviceUID, !inputs.contains(where: { $0.uid == chosen }) {
            let missing = NSMenuItem(title: "Chosen microphone not connected (using the system default)", action: nil, keyEquivalent: "")
            missing.isEnabled = false
            menu.addItem(missing)
        }
        if inputs.isEmpty {
            let none = NSMenuItem(title: "No microphone found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: microphoneRect.minX, y: microphoneRect.maxY + 2), in: self)
    }

    @objc private func microphoneChosen(_ sender: NSMenuItem) {
        let uid = sender.representedObject as? String
        guard uid != settings.inputDeviceUID else { return }
        SettingsStore.shared.settings.stats.mic.inputDeviceUID = uid
        let name = uid.flatMap { chosen in AudioDevices.inputs().first { $0.uid == chosen }?.name } ?? "the system default microphone"
        toast.show("Listening to \(name)")
    }

    private func press(_ button: Button) {
        switch button {
        case .playthrough:
            let on = !settings.playthrough
            SettingsStore.shared.settings.stats.mic.playthrough = on
            if on, settings.outputDeviceUID == nil {
                toast.show("Playing your voice through the speakers — use headphones to avoid feedback")
            }
        case .stayOn:
            let on = !settings.stayOn
            SettingsStore.shared.settings.stats.mic.stayOn = on
            if on {
                toast.show(settings.playthrough ? "Mic stays on after the panel closes (while playthrough is on)"
                                                : "Turn on Play Through to keep the mic running after the panel closes")
            }
        case .useAsMic:
            if VirtualMicrophone.isOn {
                VirtualMicrophone.disable()
                toast.show("Your real microphone is the system mic again")
            } else {
                do {
                    try VirtualMicrophone.enable()
                    let name = VirtualMicrophone.device?.name ?? "the loopback device"
                    toast.show("“\(name)” is now the system mic with your \(settings.effect.title) voice. " + VirtualMicrophone.instructions(deviceName: name), duration: 7)
                } catch VirtualMicrophone.Failure.noLoopbackDevice {
                    toast.show(VirtualMicrophone.Failure.noLoopbackDevice.localizedDescription, duration: 4)
                    NotificationCenter.default.post(name: StatsPanelView.openSettingsRequested, object: self)
                } catch {
                    toast.show(error.localizedDescription, duration: 4)
                }
            }
        case .record:
            if changer.isRecording {
                if let url = changer.finishRecording() {
                    toast.show("Recording saved to \(saveDirectory.lastPathComponent) › \(url.lastPathComponent)")
                }
            } else if let error = changer.startRecording(into: saveDirectory) {
                toast.show(error.localizedDescription, duration: 4)
            } else {
                toast.show("Recording your voice with the \(settings.effect.title) effect. Click ■ to stop.")
            }
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 100, bounds.height > 100 else { return }
        drawHeader()
        // Level-meter ticks only invalidate the header; skip the rest of the panel then.
        guard dirtyRect.maxY > headerRect.maxY else { return }
        for (effect, rect) in chipRects() { drawChip(effect, in: rect) }
        drawButton(.playthrough, symbol: settings.playthrough ? "speaker.wave.2.fill" : "speaker.slash.fill",
                   title: "Play Through", on: settings.playthrough, tint: accent)
        drawRecordButton()
        drawButton(.stayOn, symbol: "pin.fill", title: "Stay On", on: settings.stayOn, tint: accent)
        drawButton(.useAsMic, symbol: settings.useAsMicrophone ? "phone.connection.fill" : "phone.fill", title: "Use as Mic",
                   on: settings.useAsMicrophone, tint: NSColor(srgbRed: 0.55, green: 0.9, blue: 0.6, alpha: 1))
    }

    private func drawHeader() {
        let rect = headerRect
        let running = changer.state == .running
        let symbol: String
        let text: String
        let color: NSColor
        switch changer.state {
        case .running:
            symbol = "mic.fill"
            text = changer.inputName ?? "Microphone"
            color = NSColor.white.withAlphaComponent(0.9)
        case .starting:
            symbol = "mic"
            text = "Starting microphone…"
            color = NSColor.white.withAlphaComponent(0.6)
        case .idle:
            symbol = "mic"
            text = "Microphone off"
            color = NSColor.white.withAlphaComponent(0.6)
        case .failed(let message):
            symbol = "mic.slash.fill"
            text = message
            color = NSColor(srgbRed: 1.0, green: 0.55, blue: 0.5, alpha: 1)
        }
        PanelDrawing.drawSymbol(symbol, in: CGRect(x: 0, y: rect.minY, width: 20, height: rect.height), pointSize: 12, color: color)
        // Name, then a chevron right after it: the header is a microphone picker.
        let attrs = PanelDrawing.attributes(size: 11.5, weight: .semibold, color: color)
        let maxTextWidth = microphoneRect.width - 24 - 18
        let measured = min(NSAttributedString(string: text, attributes: attrs).size().width, maxTextWidth)
        let textRect = CGRect(x: 24, y: rect.minY + 4, width: maxTextWidth, height: rect.height - 8)
        draw(text, in: textRect, size: 11.5, weight: .semibold, color: color, truncating: true)
        PanelDrawing.drawSymbol("chevron.down", in: CGRect(x: 24 + measured + 2, y: rect.minY, width: 14, height: rect.height),
                   pointSize: 8, color: color.withAlphaComponent(0.7))
        drawMeter(in: meterRect, lit: running)
    }

    /// Horizontal segmented meter: green → yellow → red, with a peak-hold marker.
    private func drawMeter(in rect: CGRect, lit: Bool) {
        let segments = 16
        let gap: CGFloat = 2
        let width = (rect.width - gap * CGFloat(segments - 1)) / CGFloat(segments)
        for i in 0..<segments {
            let fraction = CGFloat(i) / CGFloat(segments)
            let x = rect.minX + CGFloat(i) * (width + gap)
            let segment = NSBezierPath(roundedRect: CGRect(x: x, y: rect.minY, width: width, height: rect.height),
                                       xRadius: 1.5, yRadius: 1.5)
            let on = lit && fraction < level
            meterColor(forFraction: fraction).withAlphaComponent(on ? 1 : 0.14).setFill()
            segment.fill()
        }
        if lit, peak > 0.02 {
            let x = rect.minX + peak * rect.width
            let marker = NSBezierPath(roundedRect: CGRect(x: min(rect.maxX - 2, x - 1), y: rect.minY, width: 2, height: rect.height),
                                      xRadius: 1, yRadius: 1)
            NSColor.white.withAlphaComponent(0.9).setFill()
            marker.fill()
        }
    }

    private func meterColor(forFraction f: CGFloat) -> NSColor {
        if f >= 0.85 { return NSColor(srgbRed: 1.0, green: 0.36, blue: 0.30, alpha: 1) }
        if f >= 0.60 { return NSColor(srgbRed: 1.0, green: 0.80, blue: 0.25, alpha: 1) }
        return NSColor(srgbRed: 0.35, green: 0.85, blue: 0.50, alpha: 1)
    }

    private func drawChip(_ effect: VoiceEffect, in rect: CGRect) {
        let isSelected = effect == settings.effect
        let background = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor.white.withAlphaComponent(isSelected ? 0.18 : 0.06).setFill()
        background.fill()
        if isSelected {
            background.lineWidth = 1
            accent.withAlphaComponent(0.8).setStroke()
            background.stroke()
        }
        PanelDrawing.drawSymbol(effect.symbolName, in: CGRect(x: rect.minX, y: rect.minY + 5, width: rect.width, height: 20),
                   pointSize: 13, color: isSelected ? accent : NSColor.white.withAlphaComponent(0.75))
        draw(effect.title, in: CGRect(x: rect.minX, y: rect.maxY - 18, width: rect.width, height: 14),
             size: 9.5, weight: .semibold, color: NSColor.white.withAlphaComponent(isSelected ? 1 : 0.7), truncating: true)
    }

    private func drawButton(_ button: Button, symbol: String, title: String, on: Bool, tint: NSColor) {
        let rect = buttonRect(button)
        let background = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        (on ? tint.withAlphaComponent(0.28) : NSColor.white.withAlphaComponent(0.06)).setFill()
        background.fill()
        let color = on ? NSColor.white : NSColor.white.withAlphaComponent(0.75)
        let label = NSAttributedString(string: title, attributes: PanelDrawing.attributes(size: 10.5, weight: .semibold, color: color))
        let symbolWidth: CGFloat = 18
        let total = symbolWidth + 6 + label.size().width
        let x = rect.midX - total / 2
        PanelDrawing.drawSymbol(symbol, in: CGRect(x: x, y: rect.minY, width: symbolWidth, height: rect.height), pointSize: 12,
                   color: on ? tint : color)
        label.draw(at: CGPoint(x: x + symbolWidth + 6, y: rect.midY - label.size().height / 2))
    }

    private func drawRecordButton() {
        let rect = buttonRect(.record)
        if changer.isRecording, let start = changer.recordingStartedAt {
            let background = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
            recordColor.withAlphaComponent(0.28).setFill()
            background.fill()
            let seconds = Int(Date().timeIntervalSince(start))
            let label = NSAttributedString(string: String(format: "Stop  %02d:%02d", seconds / 60, seconds % 60),
                                           attributes: PanelDrawing.attributes(size: 11, weight: .bold, color: .white))
            let total = 18 + 6 + label.size().width
            let x = rect.midX - total / 2
            PanelDrawing.drawSymbol("stop.fill", in: CGRect(x: x, y: rect.minY, width: 18, height: rect.height), pointSize: 11, color: recordColor)
            label.draw(at: CGPoint(x: x + 24, y: rect.midY - label.size().height / 2))
        } else {
            drawButton(.record, symbol: "record.circle", title: "Record", on: false, tint: recordColor)
        }
    }

    // MARK: Text helpers

    /// Vertically centred in `rect`; left-aligned when truncating, centred otherwise.
    private func draw(_ text: String, in rect: CGRect, size: CGFloat, weight: NSFont.Weight, color: NSColor, truncating: Bool) {
        var attrs = PanelDrawing.attributes(size: size, weight: weight, color: color)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = truncating && rect.minX < 30 ? .left : .center
        attrs[.paragraphStyle] = paragraph
        let a = NSAttributedString(string: text, attributes: attrs)
        let height = a.size().height
        a.draw(in: CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height))
    }
}

/// Compact slider drawn to match the panel: title on the left, track with a knob,
/// value on the right. Drag anywhere on the track to set it.
final class PanelSlider: NSView {
    let title: String
    let range: ClosedRange<Double>
    var value: Double = 0 { didSet { needsDisplay = true } }
    /// Round to multiples of this while dragging (nil = continuous).
    var snap: Double?
    var format: (Double) -> String = { String(Int($0.rounded())) }
    var onChange: ((Double) -> Void)?
    var isDimmed = false { didSet { alphaValue = isDimmed ? 0.45 : 1 } }

    private let titleWidth: CGFloat = 44
    private let valueWidth: CGFloat = 40
    private let accent = NSColor(srgbRed: 0.62, green: 0.80, blue: 1.0, alpha: 1)

    init(title: String, range: ClosedRange<Double>) {
        self.title = title
        self.range = range
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var trackRect: CGRect {
        CGRect(x: titleWidth, y: bounds.midY - 2, width: max(0, bounds.width - titleWidth - valueWidth - 6), height: 4)
    }

    override func mouseDown(with event: NSEvent) { update(with: event) }
    override func mouseDragged(with event: NSEvent) { update(with: event) }

    private func update(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let track = trackRect
        guard track.width > 0 else { return }
        let fraction = min(1, max(0, (p.x - track.minX) / track.width))
        var v = range.lowerBound + Double(fraction) * (range.upperBound - range.lowerBound)
        if let snap { v = (v / snap).rounded() * snap }
        guard v != value else { return }
        value = v
        onChange?(v)
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        let titleText = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.6)])
        titleText.draw(at: CGPoint(x: 0, y: bounds.midY - titleText.size().height / 2))

        let track = trackRect
        let base = NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2)
        NSColor.white.withAlphaComponent(0.14).setFill()
        base.fill()
        let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
        let knobX = track.minX + fraction * track.width
        // Fill from the neutral point (0 when the range straddles it) to the knob.
        let zeroX = range.contains(0) ? track.minX + CGFloat(-range.lowerBound / (range.upperBound - range.lowerBound)) * track.width : track.minX
        let fill = NSBezierPath(roundedRect: CGRect(x: min(zeroX, knobX), y: track.minY, width: abs(knobX - zeroX), height: track.height),
                                xRadius: 2, yRadius: 2)
        accent.withAlphaComponent(0.8).setFill()
        fill.fill()
        let knob = NSBezierPath(ovalIn: CGRect(x: knobX - 6, y: track.midY - 6, width: 12, height: 12))
        NSColor.white.setFill()
        knob.fill()

        let valueText = NSAttributedString(string: format(value), attributes: [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.85)])
        valueText.draw(at: CGPoint(x: bounds.width - valueText.size().width, y: bounds.midY - valueText.size().height / 2))
    }
}
