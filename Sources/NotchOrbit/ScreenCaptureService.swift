import AppKit

/// Screenshots and screen recordings via the system `screencapture` tool. While a
/// capture runs, NotchOrbit's own overlay windows are excluded from it, so the
/// result shows the plain screen rather than the expanded stats panel.
final class ScreenCaptureService {
    static let shared = ScreenCaptureService()
    static let stateDidChange = Notification.Name("NotchOrbit.screenCaptureStateDidChange")

    enum CaptureError: LocalizedError {
        case permissionNeeded
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .permissionNeeded:
                return "Allow Screen Recording for NotchOrbit in System Settings › Privacy & Security, then relaunch the app."
            case .failed(let reason):
                return reason
            }
        }
    }

    private(set) var isRecording = false
    private(set) var recordingStartedAt: Date?
    /// Outcome of the most recent recording, for views that weren't around when it ended.
    private(set) var lastRecordingResult: Result<URL, CaptureError>?

    private var recorder: Process?
    private var onRecordingFinished: ((Result<URL, CaptureError>) -> Void)?
    private let tool = URL(fileURLWithPath: "/usr/sbin/screencapture")

    private init() {}

    /// True when macOS lets this app record the screen. Asking adds NotchOrbit to the
    /// Screen Recording list; the user then has to tick it and relaunch.
    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    private func ensurePermission() -> Bool {
        if hasPermission { return true }
        CGRequestScreenCaptureAccess()
        return false
    }

    // MARK: Screenshot

    func takeScreenshot(into directory: URL, completion: @escaping (Result<URL, CaptureError>) -> Void) {
        guard ensurePermission() else { return completion(.failure(.permissionNeeded)) }
        let url: URL
        do { url = try Self.prepare(directory, name: "NotchOrbit Screenshot", ext: "png") }
        catch { return completion(.failure(.failed(error.localizedDescription))) }

        setOverlaysExcluded(true)
        let process = Process()
        process.executableURL = tool
        process.arguments = ["-x", "-t", "png", url.path]
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                self.setOverlaysExcluded(self.isRecording)
                if proc.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) {
                    completion(.success(url))
                } else {
                    completion(.failure(.failed("Screenshot failed (screencapture exited with \(proc.terminationStatus)).")))
                }
            }
        }
        // Give the window server a moment to apply the exclusion before the grab.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            do { try process.run() } catch {
                self.setOverlaysExcluded(self.isRecording)
                completion(.failure(.failed(error.localizedDescription)))
            }
        }
    }

    // MARK: Recording

    /// Starts a full-screen recording. Returns nil on success.
    @discardableResult
    func startRecording(into directory: URL) -> CaptureError? {
        guard !isRecording else { return nil }
        guard ensurePermission() else { return .permissionNeeded }
        let url: URL
        do { url = try Self.prepare(directory, name: "NotchOrbit Recording", ext: "mov") }
        catch { return .failed(error.localizedDescription) }

        let process = Process()
        process.executableURL = tool
        process.arguments = ["-v", "-x", url.path]
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.recordingEnded(proc, url: url) }
        }
        setOverlaysExcluded(true)
        do { try process.run() } catch {
            setOverlaysExcluded(false)
            return .failed(error.localizedDescription)
        }
        recorder = process
        isRecording = true
        recordingStartedAt = Date()
        lastRecordingResult = nil
        NotificationCenter.default.post(name: Self.stateDidChange, object: self)
        return nil
    }

    /// Stops the recording; `screencapture` finalises the movie when interrupted.
    func stopRecording(completion: ((Result<URL, CaptureError>) -> Void)? = nil) {
        guard isRecording, let recorder else {
            completion?(.failure(.failed("No recording is running.")))
            return
        }
        onRecordingFinished = completion ?? { _ in }
        recorder.interrupt()
    }

    /// Called on quit so an in-progress movie is written out instead of lost.
    func finishForTermination() {
        guard isRecording, let recorder else { return }
        recorder.interrupt()
        let deadline = Date().addingTimeInterval(2)
        while recorder.isRunning, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    private func recordingEnded(_ process: Process, url: URL) {
        let stoppedByUs = onRecordingFinished != nil
        isRecording = false
        recorder = nil
        recordingStartedAt = nil
        setOverlaysExcluded(false)

        let result: Result<URL, CaptureError>
        if FileManager.default.fileExists(atPath: url.path) {
            result = .success(url)
        } else if stoppedByUs {
            result = .failure(.failed("No movie was written (screencapture exited with \(process.terminationStatus))."))
        } else {
            result = .failure(.failed("Recording stopped unexpectedly (status \(process.terminationStatus))."))
        }
        lastRecordingResult = result
        onRecordingFinished?(result)
        onRecordingFinished = nil
        NotificationCenter.default.post(name: Self.stateDidChange, object: self)
    }

    // MARK: Helpers

    private static func prepare(_ directory: URL, name: String, ext: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return directory.appendingPathComponent("\(name) \(formatter.string(from: Date())).\(ext)")
    }

    /// Hide or show NotchOrbit's own windows in screen captures.
    private func setOverlaysExcluded(_ excluded: Bool) {
        for window in NSApp.windows where window is OverlayWindow {
            window.sharingType = excluded ? .none : .readOnly
        }
    }
}
