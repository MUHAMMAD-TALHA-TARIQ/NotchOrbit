import AppKit
import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

// Face Transform in the panel's Camera tab: the output feed beside the camera (input)
// feed, and a row of controls below both — Transform, the face to appear as, Enroll
// and a "more" menu. Plus the window that enrols a new face.

/// Small pill label over a feed ("INPUT", "OUTPUT").
final class FeedCaptionView: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue; needsLayout = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = 7
        label.font = .systemFont(ofSize: 8.5, weight: .bold)
        label.textColor = NSColor.white.withAlphaComponent(0.9)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var fittingSize: NSSize {
        let s = label.fittingSize
        return NSSize(width: s.width + 12, height: 14)
    }

    override func layout() {
        super.layout()
        let s = label.fittingSize
        label.frame = CGRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Rounded text button used in the control row.
final class PanelPillButton: NSButton {
    static let height: CGFloat = 26
    private var tint: NSColor?

    init(target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 9
        imageHugsTitle = true
        setButtonType(.momentaryChange)
        set(title: "", symbol: nil, tint: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// `tint` fills the pill (the running state); nil is the resting translucent look.
    func set(title: String, symbol: String?, tint: NSColor?) {
        self.tint = tint
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style,
        ])
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            contentTintColor = .white
            imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        } else {
            image = nil
            imagePosition = .noImage
        }
        refreshFill()
    }

    func fittingWidth(max: CGFloat) -> CGFloat {
        var width = attributedTitle.size().width.rounded(.up) + 20
        if let image { width += image.size.width + (attributedTitle.length > 0 ? 4 : 0) }
        return min(max, width)
    }

    override var isHighlighted: Bool {
        didSet { refreshFill() }
    }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.45 }
    }

    private func refreshFill() {
        let base = tint ?? NSColor.white.withAlphaComponent(0.12)
        layer?.backgroundColor = (isHighlighted ? base.blended(withFraction: 0.25, of: .white) ?? base : base).cgColor
    }
}

/// The transformed feed, beside the camera feed. Shown unmirrored, the way a call sees
/// it, so the burned-in badge reads correctly. Also hosts the consent card.
final class FaceOutputView: NSView {
    private let imageLayer = CALayer()
    private let caption = FeedCaptionView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private weak var card: NSView?

    static let idleMessage = "The transformed feed shows here. Choose a face and press Transform."

    var shape: CameraShape = .rounded {
        didSet { if shape != oldValue { needsLayout = true } }
    }

    /// Text in the middle of the pane while there is no feed.
    var message: String = FaceOutputView.idleMessage {
        didSet { status.stringValue = message; needsLayout = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.isHidden = true
        layer?.addSublayer(imageLayer)
        status.font = .systemFont(ofSize: 10.5, weight: .medium)
        status.textColor = NSColor.white.withAlphaComponent(0.55)
        status.alignment = .center
        status.maximumNumberOfLines = 4
        status.stringValue = message
        addSubview(status)
        caption.text = "OUTPUT"
        addSubview(caption)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        layer?.cornerRadius = shape.cornerRadius(for: bounds.size)
        CATransaction.commit()
        let inset = bounds.insetBy(dx: shape == .circle ? 30 : 14, dy: 8)
        let height = status.sizeThatFits(NSSize(width: inset.width, height: inset.height)).height
        status.frame = CGRect(x: inset.minX, y: inset.midY - height / 2, width: inset.width, height: height)
        let captionSize = caption.fittingSize
        caption.frame = CGRect(x: bounds.midX - captionSize.width / 2, y: bounds.maxY - captionSize.height - 8,
                               width: captionSize.width, height: captionSize.height)
        card?.frame = bounds
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    func show(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        imageLayer.isHidden = false
        CATransaction.commit()
        status.isHidden = true
    }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = nil
        imageLayer.isHidden = true
        CATransaction.commit()
        status.isHidden = false
    }

    func present(_ view: NSView) {
        dismissCard()
        view.frame = bounds
        addSubview(view)
        card = view
    }

    func dismissCard() {
        card?.removeFromSuperview()
        card = nil
    }

    var isShowingCard: Bool { card != nil }
}

/// Covers the output pane before a session starts. The person on camera confirms that
/// they agree to be transformed and that the identity's owner gave permission; the
/// session (and the server's handshake) only goes ahead on "Start".
final class FaceConsentView: NSView {
    var onDecision: ((Bool) -> Void)?

    private let label: NSTextField
    private let startButton = NSButton(title: "I Agree · Start", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    init(identity: String, toCamera: Bool) {
        let destination = toCamera ? " It also goes to the virtual camera; tell the people on the call." : ""
        label = NSTextField(wrappingLabelWithString:
            "Appear as “\(identity)”?\nOnly continue if you agree to be transformed on camera and \(identity) has given permission. Every transformed frame is labelled AI TRANSFORMED.\(destination)")
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.05, alpha: 0.97).cgColor
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.maximumNumberOfLines = 0
        addSubview(label)
        for (button, action) in [(startButton, #selector(agree)), (cancelButton, #selector(cancel))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11, weight: .semibold)
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Clicks on the card must not reach anything underneath it.
    override func mouseDown(with event: NSEvent) {}

    override func layout() {
        super.layout()
        let width = min(bounds.width - 20, 340)
        let textHeight = label.sizeThatFits(NSSize(width: width, height: bounds.height)).height
        let buttonHeight: CGFloat = 24
        let total = textHeight + 8 + buttonHeight
        let top = bounds.midY + total / 2
        label.frame = CGRect(x: bounds.midX - width / 2, y: top - textHeight, width: width, height: textHeight)
        let startWidth = startButton.fittingSize.width, cancelWidth = cancelButton.fittingSize.width
        let x = bounds.midX - (startWidth + 6 + cancelWidth) / 2
        cancelButton.frame = CGRect(x: x, y: top - total, width: cancelWidth, height: buttonHeight)
        startButton.frame = CGRect(x: x + cancelWidth + 6, y: top - total, width: startWidth, height: buttonHeight)
    }

    @objc private func agree() { onDecision?(true) }
    @objc private func cancel() { onDecision?(false) }
}

/// The control row under the two feeds. Owns the Camera tab's side of a session:
/// consent, start / stop, face selection, enrolment and the virtual-camera options.
final class FaceControlBar: NSView {
    /// The transformed feed (also where the consent card goes) and the camera feed.
    weak var output: FaceOutputView?
    weak var camera: CameraPreviewView?
    var onToast: ((String, TimeInterval) -> Void)?

    /// Mirrors `StatsSettings.face`; the panel sets it whenever settings change.
    var settings = FaceSettings() {
        didSet { if settings != oldValue { sync() } }
    }

    private lazy var transformButton = PanelPillButton(target: self, action: #selector(transformPressed))
    private lazy var faceButton = PanelPillButton(target: self, action: #selector(showFaceMenu))
    private lazy var enrollButton = PanelPillButton(target: self, action: #selector(enrollPressed))
    private lazy var moreButton = PanelPillButton(target: self, action: #selector(showMoreMenu))
    private let status = NSTextField(labelWithString: "")
    private let face = FaceTransform.shared
    private var subscriptions = Set<AnyCancellable>()
    private var active = false
    private var feedAttached = false
    private var startAfterChoosing = false
    private static let liveColor = NSColor(srgbRed: 0.85, green: 0.18, blue: 0.18, alpha: 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        enrollButton.set(title: "Enroll Face", symbol: "person.crop.circle.badge.plus", tint: nil)
        enrollButton.toolTip = "Add a new face from photos or clips"
        moreButton.set(title: "", symbol: "ellipsis", tint: nil)
        moreButton.toolTip = "Virtual camera and more"
        faceButton.toolTip = "Choose the face to appear as"
        status.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        status.textColor = NSColor.white.withAlphaComponent(0.6)
        status.alignment = .right
        status.lineBreakMode = .byTruncatingTail
        for view in [transformButton, faceButton, enrollButton, moreButton, status] as [NSView] { addSubview(view) }
        sync()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let height = min(bounds.height, PanelPillButton.height)
        let y = (bounds.height - height) / 2
        var x: CGFloat = 0
        for (button, limit) in [(transformButton, 110), (faceButton, 130), (enrollButton, 110), (moreButton, 34)] as [(PanelPillButton, CGFloat)] {
            let width = button.fittingWidth(max: limit)
            button.frame = CGRect(x: x, y: y, width: width, height: height)
            x += width + 6
        }
        let textHeight = status.fittingSize.height
        status.frame = CGRect(x: x + 2, y: (bounds.height - textHeight) / 2, width: max(0, bounds.width - x - 2), height: textHeight)
    }

    // MARK: Lifecycle

    /// The Camera tab came on screen (true) or is going away (false).
    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on {
            if subscriptions.isEmpty {
                face.$sessionState.receive(on: DispatchQueue.main).sink { [weak self] in self?.stateChanged($0) }
                    .store(in: &subscriptions)
                face.$stats.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.sync() }.store(in: &subscriptions)
                face.$activeIdentityName.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.sync() }
                    .store(in: &subscriptions)
                face.$virtualCamera.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.sync() }
                    .store(in: &subscriptions)
                face.notices.receive(on: DispatchQueue.main).sink { [weak self] message in
                    guard let self, self.active else { return }
                    self.onToast?(message, 4)
                }.store(in: &subscriptions)
            }
            face.attachViewer { [weak self] image in
                guard let self, self.active, self.face.sessionState == .live else { return }
                self.output?.show(image)
            }
            // The face list is only read from a server that is already up; nothing is
            // launched just because the tab was opened.
            face.refresh(launch: false)
        } else {
            subscriptions.removeAll()
            output?.dismissCard()
            setFeed(live: false)
            // Ends the session with the panel, unless it is pinned to the virtual camera.
            face.detachViewer()
        }
        sync()
    }

    private func stateChanged(_ state: FaceTransform.SessionState) {
        guard active else { return }
        switch state {
        case .connecting:
            output?.message = face.serverState == .ready ? "Starting…" : "Starting the face server…\nThe first start takes up to 20 s."
            setFeed(live: false)
        case .live:
            if !feedAttached {
                let name = face.activeIdentityName ?? settings.identityName ?? "the chosen face"
                onToast?("You now appear as “\(name)”. Every transformed frame is labelled AI TRANSFORMED.", 4)
            }
            output?.message = "Waiting for the first frame…"
            setFeed(live: true)
        case .idle:
            output?.message = FaceOutputView.idleMessage
            setFeed(live: false)
        case .failed(let message):
            output?.message = message
            setFeed(live: false)
        }
        sync()
    }

    /// During a session the engine owns the camera; the input pane previews its session.
    private func setFeed(live: Bool) {
        guard live != feedAttached else {
            if !live { output?.clear() }
            return
        }
        feedAttached = live
        if live {
            camera?.externalSession = face.captureSession
            camera?.liveSnapshot = { [weak face] in face?.snapshot() }
        } else {
            camera?.liveSnapshot = nil
            camera?.externalSession = nil
            output?.clear()
        }
    }

    private func sync() {
        let state = face.sessionState
        switch state {
        case .live, .connecting:
            transformButton.set(title: "Stop", symbol: "stop.fill", tint: Self.liveColor)
            transformButton.toolTip = "Stop the transformation"
        default:
            transformButton.set(title: "Transform", symbol: "theatermasks.fill", tint: nil)
            transformButton.toolTip = "Appear as the chosen face"
        }
        let name = (state == .live ? face.activeIdentityName : nil) ?? settings.identityName
        faceButton.set(title: (name ?? "Choose Face") + " ▾", symbol: "person.crop.circle", tint: nil)
        switch state {
        case .live:
            var parts = ["\(Int(face.stats.fps.rounded())) fps", face.stats.transformed ? "transforming" : "no face"]
            if face.virtualCamera.active { parts.append("on virtual camera") }
            status.stringValue = parts.joined(separator: " · ")
        case .connecting:
            status.stringValue = "starting…"
        default:
            status.stringValue = settings.virtualCamera ? "virtual camera armed" : ""
        }
        needsLayout = true
    }

    // MARK: Transform

    @objc private func transformPressed() {
        if face.sessionState.isActive {
            face.stop()
            onToast?("Transformation off", 2.6)
        } else if output?.isShowingCard == true {
            output?.dismissCard()
        } else if settings.identityID == nil {
            startAfterChoosing = true
            onToast?("Choose the face to appear as, or enroll one", 2.6)
            showFaceMenu()
        } else {
            showConsent()
        }
    }

    /// Each session starts with the person on camera agreeing to it.
    private func showConsent() {
        guard let output else { return }
        let card = FaceConsentView(identity: settings.identityName ?? "the chosen face", toCamera: settings.virtualCamera)
        card.onDecision = { [weak self] agreed in
            guard let self else { return }
            self.output?.dismissCard()
            if agreed { self.face.start(performerConsent: true) }
        }
        output.present(card)
    }

    // MARK: Face selection

    private func item(_ title: String, _ action: Selector?, on: Bool = false, enabled: Bool = true, object: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        item.isEnabled = enabled && action != nil
        item.representedObject = object
        return item
    }

    @objc private func showFaceMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item("Appear as", nil))
        if !face.identities.isEmpty {
            // One compact, scrolling list instead of a menu item per face: the menu stays
            // the same small size however many faces are enrolled.
            let list = FaceListView(identities: face.identities, selected: settings.identityID) { [weak self, weak menu] identity in
                menu?.cancelTracking()
                self?.choose(identity)
            }
            let entry = NSMenuItem()
            entry.view = list
            menu.addItem(entry)
        }
        if face.identities.isEmpty {
            switch face.serverState {
            case .ready: menu.addItem(item("No faces enrolled yet", nil))
            case .failed(let message): menu.addItem(item(message, nil))
            default: menu.addItem(item("Loading faces… open this menu again in a moment", nil))
            }
        }
        // Opening the picker is a reason to bring the server up (if that is allowed).
        face.refresh(launch: settings.autoStartServer)
        menu.addItem(.separator())
        menu.addItem(item("Enroll a New Face…", #selector(enrollPressed)))
        // A pick is handled inside popUp (the list calls back before the menu closes).
        menu.popUp(positioning: nil, at: CGPoint(x: faceButton.frame.minX, y: faceButton.frame.maxY + 4), in: self)
        startAfterChoosing = false
    }

    private func choose(_ identity: FaceIdentity) {
        let begin = startAfterChoosing
        startAfterChoosing = false
        SettingsStore.shared.settings.stats.face.identityName = identity.name
        SettingsStore.shared.settings.stats.face.identityID = identity.id
        settings.identityName = identity.name
        settings.identityID = identity.id
        if begin, !face.sessionState.isActive { showConsent() }
    }

    @objc private func enrollPressed() {
        FaceEnrollWindowController.show()
    }

    // MARK: More

    @objc private func showMoreMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let camera = face.virtualCamera
        let usable = camera.allowed && (camera.available || face.serverState != .ready)
        menu.addItem(item(usable ? "Send Output to Virtual Camera (for calls)" : "Virtual Camera Unavailable",
                          #selector(toggleVirtualCamera), on: settings.virtualCamera, enabled: usable || settings.virtualCamera))
        menu.addItem(item("Keep Running After the Panel Closes", #selector(toggleStayOn), on: settings.stayOn,
                          enabled: settings.virtualCamera))
        menu.addItem(.separator())
        menu.addItem(item("Manage Faces in the Web App…", #selector(openWebApp)))
        menu.addItem(item("Camera & Face Swap Settings…", #selector(openSettings)))
        menu.popUp(positioning: nil, at: CGPoint(x: moreButton.frame.minX, y: moreButton.frame.maxY + 4), in: self)
    }

    @objc private func toggleVirtualCamera() {
        let on = !settings.virtualCamera
        SettingsStore.shared.settings.stats.face.virtualCamera = on
        onToast?(on ? "The output goes to “OBS Virtual Camera” while a session runs. Pick it in your call app, and tell the people on the call."
                    : "Virtual camera off", on ? 7 : 2.6)
    }

    @objc private func toggleStayOn() {
        SettingsStore.shared.settings.stats.face.stayOn.toggle()
    }

    @objc private func openWebApp() {
        face.openWebApp()
    }

    @objc private func openSettings() {
        NotificationCenter.default.post(name: StatsPanelView.openSettingsRequested, object: self)
    }
}

/// The face picker's list: compact rows (thumbnail, name, tick on the chosen one) in a
/// scroll view that shows at most six of them. Sits inside a menu item.
final class FaceListView: NSView {
    private static let rowHeight: CGFloat = 24
    private static let visibleRows = 6
    private static let width: CGFloat = 210

    init(identities: [FaceIdentity], selected: String?, onPick: @escaping (FaceIdentity) -> Void) {
        let shown = min(identities.count, Self.visibleRows)
        super.init(frame: CGRect(x: 0, y: 0, width: Self.width, height: CGFloat(shown) * Self.rowHeight))
        let content = FlippedView(frame: CGRect(x: 0, y: 0, width: Self.width, height: CGFloat(identities.count) * Self.rowHeight))
        var selectedRow: NSView?
        for (index, identity) in identities.enumerated() {
            let row = FaceRowView(identity: identity, chosen: identity.id == selected) { onPick(identity) }
            row.frame = CGRect(x: 0, y: CGFloat(index) * Self.rowHeight, width: Self.width, height: Self.rowHeight)
            row.autoresizingMask = [.width]
            content.addSubview(row)
            if identity.id == selected { selectedRow = row }
        }
        let scroll = NSScrollView(frame: bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = identities.count > Self.visibleRows
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none
        scroll.documentView = content
        addSubview(scroll)
        if let selectedRow {
            // Open with the chosen face in view (centred where possible).
            content.scrollToVisible(selectedRow.frame.insetBy(dx: 0, dy: -Self.rowHeight * 2))
        }
        if scroll.hasVerticalScroller { DispatchQueue.main.async { scroll.flashScrollers() } }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}

/// One face in the picker's list.
private final class FaceRowView: NSView {
    private let identity: FaceIdentity
    private let chosen: Bool
    private let onPick: () -> Void
    private let thumbnail: NSImage?
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }

    init(identity: FaceIdentity, chosen: Bool, onPick: @escaping () -> Void) {
        self.identity = identity
        self.chosen = chosen
        self.onPick = onPick
        thumbnail = identity.thumbnail.flatMap { NSImage(data: $0) }
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        setAccessibilityLabel(identity.name)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPick() }
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        let color: NSColor = hovered ? .white : .labelColor
        if chosen {
            NSAttributedString(string: "✓", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: color])
                .draw(at: CGPoint(x: 10, y: bounds.midY - 8))
        }
        let side: CGFloat = 18
        let avatar = CGRect(x: 27, y: bounds.midY - side / 2, width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: avatar).addClip()
        if let thumbnail {
            thumbnail.draw(in: avatar, from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            NSColor.tertiaryLabelColor.setFill()
            avatar.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let name = NSAttributedString(string: identity.name, attributes: [
            .font: NSFont.menuFont(ofSize: 13), .foregroundColor: color, .paragraphStyle: style,
        ])
        let height = name.size().height
        name.draw(in: CGRect(x: avatar.maxX + 7, y: bounds.midY - height / 2, width: bounds.width - avatar.maxX - 17, height: height))
    }
}

// MARK: - Enrolment window

/// "Enroll Face": name, photos or clips, and the two consent attestations the server
/// records with the identity. One window at a time; released when it closes.
final class FaceEnrollWindowController: NSWindowController, NSWindowDelegate {
    private static var current: FaceEnrollWindowController?

    static func show() {
        if current == nil { current = FaceEnrollWindowController() }
        NSApp.activate(ignoringOtherApps: true)
        current?.showWindow(nil)
        current?.window?.makeKeyAndOrderFront(nil)
    }

    private init() {
        let host = NSHostingController(rootView: FaceEnrollView { FaceEnrollWindowController.current?.close() })
        let window = NSWindow(contentViewController: host)
        window.title = "Enroll Face"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { Self.current = nil }
    }
}

struct FaceEnrollView: View {
    let close: () -> Void

    private enum Phase: Equatable {
        case editing, working, done(String), failed(String)
    }

    @State private var name = ""
    @State private var attestedBy = NSFullUserName()
    @State private var ownerConsent = false
    @State private var performerConsent = false
    @State private var files: [URL] = []
    @State private var phase: Phase = .editing

    private static let fileTypes = ["jpg", "jpeg", "png", "webp", "bmp", "mp4", "mov", "m4v", "webm", "mkv", "avi"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                TextField("Name", text: $name, prompt: Text("Who this face belongs to"))
                LabeledContent("Photos or clips") {
                    HStack(spacing: 8) {
                        Text(files.isEmpty ? "None chosen" : "\(files.count) file\(files.count == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: choose)
                    }
                }
                TextField("Attested by", text: $attestedBy, prompt: Text("Your name"))
            }
            Text("Best results: 30–100 sharp, well-lit photos or short clips of the same person — front, three-quarter and profile. Each one is quality-checked; blurry, small or mismatching faces are left out.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Toggle("The person in these photos has given permission for their face to be enrolled and rendered onto others.", isOn: $ownerConsent)
                Toggle("Everyone who will be transformed into this face on camera agrees to it.", isOn: $performerConsent)
            }
            .toggleStyle(.checkbox)
            .fixedSize(horizontal: false, vertical: true)
            Text("Both statements are stored with the face, with your name and the time. The face is kept encrypted on this Mac by the face server, and every transformed frame is labelled AI TRANSFORMED.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            switch phase {
            case .editing:
                EmptyView()
            case .working:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking the samples and enrolling… this can take a minute.").font(.callout)
                }
            case .done(let message):
                Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if case .done = phase {
                    Button("Done", action: close).keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                    Button("Enroll", action: enroll)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canEnroll)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var canEnroll: Bool {
        phase != .working && ownerConsent && performerConsent && !files.isEmpty
            && !name.trimmingCharacters(in: .whitespaces).isEmpty && !attestedBy.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.message = "Choose photos or short clips of one person"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.fileTypes.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        files = panel.urls
        if phase != .working { phase = .editing }
    }

    private func enroll() {
        phase = .working
        FaceTransform.shared.enroll(name: name, attestedBy: attestedBy, ownerConsent: ownerConsent,
                                    performerConsent: performerConsent, files: files) { result in
            switch result {
            case .success(let enrolled):
                var message = "Enrolled “\(enrolled.identity.name)” from \(enrolled.accepted) of \(enrolled.total) sample\(enrolled.total == 1 ? "" : "s"). It is now the chosen face."
                if !enrolled.warnings.isEmpty { message += "\n" + enrolled.warnings.joined(separator: "\n") }
                phase = .done(message)
            case .failure(let failure):
                phase = .failed(failure.message)
            }
        }
    }
}
