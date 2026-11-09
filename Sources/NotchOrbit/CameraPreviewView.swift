import AppKit
import AVFoundation

/// Live webcam preview for the stats panel's camera tab. The capture session only
/// runs while the view is asked to (`start()`), so the camera light is off otherwise.
/// A shutter button saves a mirrored still (what you see) to the configured folder.
final class CameraPreviewView: NSView, AVCapturePhotoCaptureDelegate {
    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "NotchOrbit.camera")
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private let flashLayer = CALayer()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let shutter = ShutterButton(symbol: "camera.fill", accessibility: "Take a picture")
    private let toast = ToastView(frame: .zero)
    private var configured = false
    private var wantsRunning = false
    private var capturing = false

    /// Where captured stills go; the panel sets this from the user's settings.
    var saveDirectory = StatsSettings.defaultPhotoDirectory

    private static let deniedMessage = "Camera access is off. Allow NotchOrbit in System Settings › Privacy & Security › Camera."

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor

        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)

        flashLayer.backgroundColor = NSColor.white.cgColor
        flashLayer.opacity = 0
        layer?.addSublayer(flashLayer)

        status.font = .systemFont(ofSize: 11, weight: .medium)
        status.textColor = NSColor.white.withAlphaComponent(0.6)
        status.alignment = .center
        status.maximumNumberOfLines = 3
        status.isHidden = true
        addSubview(status)

        shutter.target = self
        shutter.action = #selector(shutterPressed)
        shutter.toolTip = "Take a picture"
        shutter.isHidden = true
        addSubview(shutter)
        addSubview(toast)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Outline of the preview; the panel sets this from the user's settings.
    var shape: CameraShape = .rounded {
        didSet { if shape != oldValue { needsLayout = true } }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        flashLayer.frame = bounds
        layer?.cornerRadius = shape.cornerRadius(for: bounds.size)
        CATransaction.commit()
        let inset = bounds.insetBy(dx: 16, dy: 8)
        let height = status.sizeThatFits(NSSize(width: inset.width, height: inset.height)).height
        status.frame = CGRect(x: inset.minX, y: inset.midY - height / 2, width: inset.width, height: height)
        let side = ShutterButton.size
        shutter.frame = CGRect(x: bounds.midX - side / 2, y: 10, width: side, height: side)
        let toastSize = toast.fittingSize(maxWidth: bounds.width - 24)
        toast.frame = CGRect(x: bounds.midX - toastSize.width / 2, y: bounds.maxY - toastSize.height - 14,
                             width: toastSize.width, height: toastSize.height)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        previewLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    // MARK: Control

    func start() {
        guard !wantsRunning else { return }
        wantsRunning = true
        // Without a usage description TCC kills the process on first camera access,
        // which is what happens when running the bare executable instead of the .app.
        guard Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil else {
            show("The camera needs the app bundle. Build with build.sh and launch NotchOrbit.app.")
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            beginSession()
        case .notDetermined:
            show("Waiting for camera permission…")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.wantsRunning else { return }
                    if granted { self.beginSession() } else { self.show(Self.deniedMessage) }
                }
            }
        default:
            show(Self.deniedMessage)
        }
    }

    func stop() {
        guard wantsRunning else { return }
        wantsRunning = false
        status.isHidden = true
        shutter.isHidden = true
        toast.hide()
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    // MARK: Session

    private func beginSession() {
        show("Starting camera…")
        queue.async { [weak self] in
            guard let self else { return }
            let ok = self.configureIfNeeded()
            if ok, !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.wantsRunning else { return }
                if ok {
                    self.status.isHidden = true
                    self.shutter.isHidden = false
                    self.mirrorPreview()
                } else {
                    self.show("No camera found on this Mac.")
                }
            }
        }
    }

    /// Runs on `queue`. Returns false when there is no usable camera.
    private func configureIfNeeded() -> Bool {
        if configured { return true }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // 720p: fine for the small preview and good enough for a snapshot, and a
        // fraction of the frame memory and CPU of the camera's native resolution.
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.addInput(input)
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        configured = true
        return true
    }

    /// Selfie-style preview, like FaceTime / Photo Booth.
    private func mirrorPreview() {
        guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
    }

    private func show(_ message: String) {
        status.stringValue = message
        status.isHidden = false
        needsLayout = true
    }

    // MARK: Photo capture

    @objc private func shutterPressed() {
        guard wantsRunning, !capturing, photoOutput.connection(with: .video) != nil else {
            toast.show("Camera isn't ready yet")
            return
        }
        capturing = true
        shutter.isEnabled = false
        let settings = AVCapturePhotoSettings()
        queue.async { [weak self] in
            guard let self else { return }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.capturing = false
            self.shutter.isEnabled = true
            if let error {
                self.toast.show("Couldn't capture: \(error.localizedDescription)")
                return
            }
            guard let data, let image = NSImage(data: data) else {
                self.toast.show("Couldn't read the captured frame")
                return
            }
            self.flash()
            do {
                let url = try Self.save(Self.mirrored(image), in: self.saveDirectory)
                self.toast.show("Saved to \(self.saveDirectory.lastPathComponent) › \(url.lastPathComponent)")
            } catch {
                self.toast.show("Couldn't save: \(error.localizedDescription)")
            }
        }
    }

    /// Flips horizontally so the file matches the mirrored preview (like Photo Booth).
    private static func mirrored(_ image: NSImage) -> NSImage {
        let size = image.size
        return NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: rect.width, y: 0)
            context.scaleBy(x: -1, y: 1)
            image.draw(in: rect)
            return true
        }
    }

    private static func save(_ image: NSImage, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = directory.appendingPathComponent("NotchOrbit \(formatter.string(from: Date())).jpg")
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try jpeg.write(to: url, options: .atomic)
        return url
    }

    private func flash() {
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 0.85
        anim.toValue = 0
        anim.duration = 0.45
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        flashLayer.add(anim, forKey: "flash")
    }
}

/// Round translucent control button drawn over the preview.
final class ShutterButton: NSButton {
    static let size: CGFloat = 40

    /// Resting background; highlighted state brightens it.
    var fillColor = NSColor.white.withAlphaComponent(0.22) {
        didSet { refreshFill() }
    }

    init(symbol: String, accessibility: String) {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))
        isBordered = false
        title = ""
        imagePosition = .imageOnly
        setSymbol(symbol)
        image?.accessibilityDescription = accessibility
        contentTintColor = .white
        wantsLayer = true
        layer?.cornerRadius = Self.size / 2
        layer?.borderColor = NSColor.white.withAlphaComponent(0.7).cgColor
        layer?.borderWidth = 2
        setButtonType(.momentaryChange)
        refreshFill()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setSymbol(_ name: String) {
        image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var isHighlighted: Bool {
        didSet { refreshFill() }
    }

    private func refreshFill() {
        layer?.backgroundColor = (isHighlighted ? fillColor.blended(withFraction: 0.35, of: .white) ?? fillColor : fillColor).cgColor
    }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.5 }
    }
}
