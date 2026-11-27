import AppKit
import Metal
@preconcurrency import ScreenCaptureKit

/// A live picture of one display, without this app's own windows, as a Metal
/// texture. The music effects bend it, which is what makes them look like
/// glass or water lying on the screen rather than light drawn over it.
///
/// Frames arrive as IOSurfaces and are wrapped, not copied.
final class LiveScreen: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Frames are delivered in this colour space; the overlay's layer is
    /// tagged with it so bent pixels match the untouched ones around them.
    static let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    private let device: MTLDevice
    private let displayID: CGDirectDisplayID
    private let scale: CGFloat
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var latest: (texture: MTLTexture, frame: CMSampleBuffer)?   // the frame keeps its surface out of the pool
    private var stream: SCStream?
    private var wanted = false

    init(device: MTLDevice, screen: NSScreen, displayID: CGDirectDisplayID) {
        self.device = device
        self.displayID = displayID
        scale = screen.backingScaleFactor
        queue = DispatchQueue(label: "NotchOrbit.LiveScreen.\(displayID)")
    }

    /// The newest frame, or nil until the first one arrives.
    var texture: MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        return latest?.texture
    }

    func start() {
        queue.async { [self] in
            guard !wanted else { return }
            wanted = true
            open()
        }
    }

    func stop() {
        queue.async { [self] in
            wanted = false
            let stream = self.stream
            self.stream = nil
            stream?.stopCapture { _ in }
            lock.lock(); latest = nil; lock.unlock()
        }
    }

    private func open() {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    throw CocoaError(.featureUnsupported)
                }
                let pid = ProcessInfo.processInfo.processIdentifier
                let config = SCStreamConfiguration()
                config.width = Int(CGFloat(display.width) * scale)
                config.height = Int(CGFloat(display.height) * scale)
                config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.colorSpaceName = CGColorSpace.displayP3
                config.showsCursor = false
                config.queueDepth = 5

                let stream = SCStream(
                    filter: SCContentFilter(
                        display: display,
                        excludingApplications: content.applications.filter { $0.processID == pid },
                        exceptingWindows: []),
                    configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                try await stream.startCapture()
                queue.async { [self] in
                    if wanted {
                        self.stream = stream
                        debugLog("live screen \(displayID): started \(config.width)x\(config.height)")
                    } else {
                        stream.stopCapture { _ in }
                    }
                }
            } catch {
                debugLog("live screen \(displayID): could not start: \(error.localizedDescription)")
                queue.async { [self] in wanted = false }   // the next beat tries again
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        debugLog("live screen \(displayID): stopped: \(error.localizedDescription)")
        queue.async { [self] in
            guard self.stream === stream else { return }
            self.stream = nil
            wanted = false
            lock.lock(); latest = nil; lock.unlock()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Frames with no new content carry no picture; the last one stays current.
        guard type == .screen, wanted, sampleBuffer.isValid,
              let pixels = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pixels)?.takeUnretainedValue() else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: CVPixelBufferGetWidth(pixels),
            height: CVPixelBufferGetHeight(pixels), mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else { return }
        lock.lock()
        let first = latest == nil
        latest = (texture, sampleBuffer)
        lock.unlock()
        if first { debugLog("live screen \(displayID): first frame \(texture.width)x\(texture.height)") }
    }
}
