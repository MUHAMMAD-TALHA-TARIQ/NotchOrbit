import AppKit
import AVFoundation
import Combine
import VideoToolbox
import ImageIO

/// An identity enrolled on the face server (enrolment, with its consent attestations,
/// happens in the server's own web app).
struct FaceIdentity: Identifiable, Equatable {
    let id: String
    let name: String
    let samples: Int
    let thumbnail: Data?
}

/// Face Transform engine: a native client of the local deep-facial server.
///
/// The server (FastAPI + ONNX Runtime, bound to 127.0.0.1) does the detection, swap,
/// compositing and the burned-in "AI TRANSFORMED" badge. This class
///   - finds a running server or launches one from the project folder,
///   - lists enrolled identities,
///   - runs a live session: camera frames go out as JPEG over the `/ws/live`
///     WebSocket, transformed frames come back and are handed to the Camera tab,
///   - asks the server to route the output into its virtual camera for calls.
///
/// A session needs the performer's consent for that session; `start(performerConsent:)`
/// is only called from the Camera tab's confirmation card, and the server refuses the
/// handshake without it. The badge is drawn by the server on every transformed frame
/// and there is no switch for it here.
///
/// Published state is only touched on the main thread. The capture queue and the
/// WebSocket callbacks share the small `Shared` block behind `lock`.
final class FaceTransform: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private static var instance: FaceTransform?

    /// Created on first use: the Camera tab with the feature enabled, or the Settings page.
    static var shared: FaceTransform {
        if let instance { return instance }
        let made = FaceTransform()
        instance = made
        return made
    }

    /// The engine if anything has used it yet (quit handling, menu, tab icon).
    static var current: FaceTransform? { instance }

    enum ServerState: Equatable {
        case unknown, stopped, starting, loadingModels, ready, failed(String)
    }

    enum SessionState: Equatable {
        case idle, connecting, live, failed(String)

        var isActive: Bool { self == .connecting || self == .live }
    }

    struct VirtualCamera: Equatable {
        var allowed = true
        var available = false
        var reason = ""
        var active = false
        var pending = false
        var device: String?
        var error: String?
    }

    struct LiveStats: Equatable {
        var fps: Double = 0
        var transformed = false
        var fallbackReason: String?
    }

    struct Failure: Error, Equatable {
        let message: String
    }

    @Published private(set) var serverState: ServerState = .unknown
    @Published private(set) var sessionState: SessionState = .idle
    @Published private(set) var identities: [FaceIdentity] = []
    @Published private(set) var activeIdentityName: String?
    @Published private(set) var stats = LiveStats()
    @Published private(set) var virtualCamera = VirtualCamera()
    /// Execution providers reported by the server ("CoreML", "CPU").
    @Published private(set) var providers: String?
    /// One-off messages from the server during a session (shown as a toast).
    let notices = PassthroughSubject<String, Never>()

    /// False in test harnesses, which feed frames through `submit(_:)` instead of the camera.
    var usesCamera = true

    /// The engine's camera session while a session is live, for the Camera tab's input feed.
    var captureSession: AVCaptureSession? { capture }

    /// True while NotchOrbit itself launched the server process (and will stop it).
    var ownsServer: Bool { process?.isRunning == true }

    static let logURL: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/NotchOrbit/face-server.log")

    private var settings: FaceSettings { SettingsStore.shared.settings.stats.face }
    /// Settings the running session was last told about.
    private var applied = FaceSettings()

    // Server process
    private var process: Process?
    private var launchedInThisPoll = false
    private var polling = false
    private var pollDeadline = Date()
    private var waiters: [(Result<Void, Failure>) -> Void] = []
    private var idleStop: DispatchWorkItem?
    /// How long a server NotchOrbit launched is kept after the last session (it holds
    /// about a gigabyte of models, and takes 5–20 s to start again).
    private static let idleStopDelay: TimeInterval = 300

    // Session
    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
    private var socket: URLSessionWebSocketTask?
    private var generation = 0
    private var serverError: String?
    private var frameHandler: ((CGImage) -> Void)?
    private var lastStatsPublish: CFTimeInterval = 0

    // Capture. The session, its output and the video output only exist while a session
    // is live, so an idle engine holds no camera or GPU resources.
    private var capture: AVCaptureSession?
    private let captureQueue = DispatchQueue(label: "NotchOrbit.face.capture")
    /// Longest side the output feed is decoded at; the pane is far smaller than a 1280 px frame.
    private static let displayPixels = 720

    /// State shared between the capture queue, the WebSocket callbacks and the main thread.
    private struct Shared {
        var task: URLSessionWebSocketTask?
        var inFlight = 0
        var lastSend: CFTimeInterval = 0
        var lastReceive: CFTimeInterval = 0
        var sendWidth: Double = 640
        var hasViewer = false
        var lastJPEG: Data?
        var lastTransformed = false
        /// Newest decoded frame and stats waiting for the main thread. One slot: if the
        /// main thread is busy, frames replace each other here instead of queueing up.
        var pendingImage: CGImage?
        var pendingStats = LiveStats()
        var flushScheduled = false
    }
    private var shared = Shared()
    private let lock = NSLock()

    private static let maxInFlight = 2
    private static let maxSendRate: Double = 30

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: SettingsStore.didChange, object: nil)
    }

    private var baseURL: String { "http://127.0.0.1:\(settings.port)" }

    /// The server's own web app (enrolment with consent attestations, video jobs).
    var webAppURL: URL { URL(string: baseURL + "/") ?? URL(fileURLWithPath: "/") }

    // MARK: Server

    /// Checks the server and loads the identity list. With `launch`, a server that
    /// isn't running is started from the project folder first.
    func refresh(launch: Bool, completion: ((Result<Void, Failure>) -> Void)? = nil) {
        ensureServer(launchIfNeeded: launch) { [weak self] result in
            guard let self, case .success = result else { completion?(result); return }
            self.loadIdentities { completion?(result) }
        }
    }

    /// Opens the web app in the browser, starting the server if it has to.
    func openWebApp() {
        ensureServer(launchIfNeeded: true) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success: NSWorkspace.shared.open(self.webAppURL)
            case .failure(let failure): self.notices.send(failure.message)
            }
        }
    }

    func startServer() {
        refresh(launch: true)
    }

    /// Stops the server if NotchOrbit launched it. A server started elsewhere is left alone.
    func stopServer() {
        idleStop?.cancel()
        idleStop = nil
        if sessionState.isActive { stop() }
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    private func ensureServer(launchIfNeeded: Bool, completion: @escaping (Result<Void, Failure>) -> Void) {
        waiters.append(completion)
        guard !polling else { return }
        polling = true
        launchedInThisPoll = false
        pollDeadline = Date().addingTimeInterval(120)
        poll(launchIfNeeded: launchIfNeeded)
    }

    private func finishPoll(_ result: Result<Void, Failure>) {
        polling = false
        if case .failure(let failure) = result, serverState != .stopped { serverState = .failed(failure.message) }
        let pending = waiters
        waiters = []
        pending.forEach { $0(result) }
    }

    private func poll(launchIfNeeded: Bool) {
        fetchHealth { [weak self] health in
            guard let self else { return }
            if let health {
                self.apply(health: health)
                switch health["status"] as? String {
                case "ready":
                    self.serverState = .ready
                    self.finishPoll(.success(()))
                case "error":
                    let detail = health["error"] as? String ?? "unknown error"
                    self.finishPoll(.failure(Failure(message: "The face models failed to load: \(detail)")))
                default:
                    self.serverState = .loadingModels
                    self.pollAgain(launchIfNeeded)
                }
            } else if self.process?.isRunning == true {
                self.serverState = .starting
                self.pollAgain(launchIfNeeded)
            } else if self.launchedInThisPoll {
                self.finishPoll(.failure(Failure(message: "The face server stopped while starting. See \(Self.logURL.path)")))
            } else if launchIfNeeded {
                do {
                    try self.launch()
                    self.launchedInThisPoll = true
                    self.serverState = .starting
                    self.pollAgain(launchIfNeeded)
                } catch let failure as Failure {
                    self.finishPoll(.failure(failure))
                } catch {
                    self.finishPoll(.failure(Failure(message: "Couldn't start the face server: \(error.localizedDescription)")))
                }
            } else {
                self.serverState = .stopped
                self.finishPoll(.failure(Failure(message: "The face server isn't running.")))
            }
        }
    }

    private func pollAgain(_ launchIfNeeded: Bool) {
        guard Date() < pollDeadline else {
            finishPoll(.failure(Failure(message: "The face server didn't become ready in time. See \(Self.logURL.path)")))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.poll(launchIfNeeded: launchIfNeeded) }
    }

    /// `python -m server` in the project folder, bound to the loopback interface.
    private func launch() throws {
        guard let path = settings.projectPath, !path.isEmpty else {
            throw Failure(message: "Choose the deep-facial folder in Settings › Camera & Face Swap.")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let python = root.appendingPathComponent(".venv/bin/python")
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.appendingPathComponent("server/__main__.py").path) else {
            throw Failure(message: "“\(root.lastPathComponent)” doesn't look like the deep-facial project (no server folder).")
        }
        guard fm.isExecutableFile(atPath: python.path) else {
            throw Failure(message: "No Python environment in “\(root.lastPathComponent)”. Run “make setup” and “make models” there first.")
        }
        try fm.createDirectory(at: Self.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: Self.logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: Self.logURL)

        let process = Process()
        process.executableURL = python
        process.arguments = ["-m", "server"]
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["RTIT_HOST"] = "127.0.0.1"
        environment["RTIT_PORT"] = String(settings.port)
        // Apps launched from Finder get a bare PATH; the server looks for ffmpeg on it.
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] finished in
            try? log.close()
            DispatchQueue.main.async {
                guard let self, self.process === finished else { return }
                self.process = nil
                if !self.polling { self.serverState = .stopped }
                debugLog("[face] server exited with status", finished.terminationStatus)
            }
        }
        try process.run()
        self.process = process
        debugLog("[face] launched server pid", process.processIdentifier, "in", root.path)
    }

    private func fetchHealth(_ completion: @escaping ([String: Any]?) -> Void) {
        guard let url = URL(string: baseURL + "/api/health") else { completion(nil); return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        urlSession.dataTask(with: request) { data, response, _ in
            var health: [String: Any]?
            if let data, (response as? HTTPURLResponse)?.statusCode == 200 {
                health = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
            // Something else answering on the port is not our server.
            if health?["status"] == nil || health?["profiles"] == nil { health = nil }
            DispatchQueue.main.async { completion(health) }
        }.resume()
    }

    private func apply(health: [String: Any]) {
        if let camera = health["virtual_camera"] as? [String: Any] { apply(virtualCamera: camera, availability: true) }
        if let engine = health["engine"] as? [String: Any], let all = engine["providers"] as? [String: [String]] {
            let first = (all["swapper"] ?? []).first ?? ""
            providers = first.replacingOccurrences(of: "ExecutionProvider", with: "")
        }
    }

    private func apply(virtualCamera info: [String: Any], availability: Bool) {
        var camera = virtualCamera
        if availability {
            camera.allowed = info["allowed"] as? Bool ?? true
            camera.available = info["available"] as? Bool ?? false
            camera.reason = info["reason"] as? String ?? ""
        }
        camera.active = info["active"] as? Bool ?? false
        camera.pending = info["pending"] as? Bool ?? false
        camera.device = info["device"] as? String
        camera.error = info["error"] as? String
        if camera != virtualCamera { virtualCamera = camera }
    }

    private func loadIdentities(_ completion: @escaping () -> Void) {
        guard let url = URL(string: baseURL + "/api/identities") else { completion(); return }
        urlSession.dataTask(with: url) { [weak self] data, _, _ in
            var list: [FaceIdentity]?
            if let data, let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
                list = rows.compactMap { row in
                    guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
                    let thumbnail = (row["thumbnail_jpeg_b64"] as? String).flatMap { Data(base64Encoded: $0) }
                    return FaceIdentity(id: id, name: name, samples: row["n_samples"] as? Int ?? 0, thumbnail: thumbnail)
                }
                list?.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
            DispatchQueue.main.async {
                if let self, let list {
                    if list != self.identities { self.identities = list }
                    self.reconcileChosenIdentity()
                }
                completion()
            }
        }.resume()
    }

    /// Keeps the stored display name in step with the server, and forgets an identity
    /// that has been deleted there.
    private func reconcileChosenIdentity() {
        guard let chosen = settings.identityID else { return }
        if let match = identities.first(where: { $0.id == chosen }) {
            if settings.identityName != match.name { SettingsStore.shared.settings.stats.face.identityName = match.name }
        } else if !sessionState.isActive {
            SettingsStore.shared.settings.stats.face.identityID = nil
            SettingsStore.shared.settings.stats.face.identityName = nil
        }
    }

    // MARK: Enrolment

    struct Enrollment {
        let identity: FaceIdentity
        let accepted: Int
        let total: Int
        let warnings: [String]
    }

    /// Enrols a new identity from photos or short clips. Both attestations are
    /// required: the identity's owner agreed to be enrolled and rendered, and the
    /// performers agreed to be transformed. The server stores them with the record
    /// (and refuses the request without them).
    func enroll(name: String, attestedBy: String, ownerConsent: Bool, performerConsent: Bool, files: [URL],
                completion: @escaping (Result<Enrollment, Failure>) -> Void) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let attestedBy = attestedBy.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ownerConsent, performerConsent else {
            completion(.failure(Failure(message: "Both consent attestations are needed to enrol an identity.")))
            return
        }
        guard !name.isEmpty, !attestedBy.isEmpty, !files.isEmpty else {
            completion(.failure(Failure(message: "Give the identity a name, say who is attesting, and add at least one photo or clip.")))
            return
        }
        ensureServer(launchIfNeeded: settings.autoStartServer) { [weak self] result in
            guard let self else { return }
            if case .failure(let failure) = result { completion(.failure(failure)); return }
            guard let url = URL(string: self.baseURL + "/api/identities") else { return }
            let fields = ["name": name, "attested_by": attestedBy, "notes": "Enrolled from NotchOrbit",
                          "consent_identity_owner": "true", "consent_performer": "true"]
            DispatchQueue.global(qos: .userInitiated).async {
                let boundary = "NotchOrbit-\(UUID().uuidString)"
                let body = FileManager.default.temporaryDirectory.appendingPathComponent("\(boundary).multipart")
                guard Self.writeMultipart(to: body, boundary: boundary, fields: fields, files: files) else {
                    DispatchQueue.main.async { completion(.failure(Failure(message: "Couldn't read the chosen files."))) }
                    return
                }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = 600
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                self.urlSession.uploadTask(with: request, fromFile: body) { data, response, error in
                    try? FileManager.default.removeItem(at: body)
                    let outcome = Self.enrollmentOutcome(data: data, status: (response as? HTTPURLResponse)?.statusCode,
                                                         error: error, sent: files.count)
                    DispatchQueue.main.async {
                        if case .success(let enrolled) = outcome {
                            SettingsStore.shared.settings.stats.face.identityName = enrolled.identity.name
                            SettingsStore.shared.settings.stats.face.identityID = enrolled.identity.id
                            self.loadIdentities {}
                        }
                        completion(outcome)
                    }
                }.resume()
            }
        }
    }

    private static func writeMultipart(to url: URL, boundary: String, fields: [String: String], files: [URL]) -> Bool {
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? handle.close() }
        func write(_ text: String) { handle.write(Data(text.utf8)) }
        for (key, value) in fields {
            write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
        }
        for file in files {
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return false }
            let filename = file.lastPathComponent.replacingOccurrences(of: "\"", with: "_")
            write("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(filename)\"\r\n")
            write("Content-Type: application/octet-stream\r\n\r\n")
            handle.write(data)
            write("\r\n")
        }
        write("--\(boundary)--\r\n")
        return true
    }

    private static func enrollmentOutcome(data: Data?, status: Int?, error: Error?, sent: Int) -> Result<Enrollment, Failure> {
        guard let data, let status else {
            return .failure(Failure(message: "The face server didn't answer: \(error?.localizedDescription ?? "no response")"))
        }
        let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let samples = reply["diagnostics"] as? [[String: Any]] ?? []
        let warnings = reply["warnings"] as? [String] ?? []
        if status == 201, let row = reply["identity"] as? [String: Any],
           let id = row["id"] as? String, let name = row["name"] as? String {
            let thumbnail = (row["thumbnail_jpeg_b64"] as? String).flatMap { Data(base64Encoded: $0) }
            let accepted = row["n_samples"] as? Int ?? samples.filter { $0["accepted"] as? Bool == true }.count
            let identity = FaceIdentity(id: id, name: name, samples: accepted, thumbnail: thumbnail)
            return .success(Enrollment(identity: identity, accepted: accepted, total: max(samples.count, accepted), warnings: warnings))
        }
        if !samples.isEmpty {
            // Nothing passed the quality gates: say why, most common reason first.
            var reasons: [String: Int] = [:]
            for sample in samples { reasons[sample["reason"] as? String ?? "rejected", default: 0] += 1 }
            let summary = reasons.sorted { $0.value > $1.value }.map { "\($0.value) × \($0.key)" }.joined(separator: ", ")
            return .failure(Failure(message: "No usable face in the \(samples.count) sample\(samples.count == 1 ? "" : "s") (\(summary)). Use sharp, well-lit photos where the face is large."))
        }
        let detail = reply["detail"] as? String ?? "HTTP \(status)"
        return .failure(Failure(message: "The face server refused the enrolment: \(detail)"))
    }

    // MARK: Session

    /// Starts transforming the camera into the chosen identity. `performerConsent` is
    /// the person on camera agreeing to this session; without it nothing starts (and
    /// the server would refuse the handshake anyway).
    func start(performerConsent: Bool) {
        guard performerConsent, !sessionState.isActive else { return }
        let face = settings
        guard face.enabled else { return }
        guard let identity = face.identityID else {
            sessionState = .failed("Choose who to appear as first.")
            return
        }
        guard !usesCamera || AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            sessionState = .failed("Camera access is off.")
            return
        }
        idleStop?.cancel()
        idleStop = nil
        generation += 1
        let current = generation
        serverError = nil
        sessionState = .connecting
        ensureServer(launchIfNeeded: face.autoStartServer) { [weak self] result in
            guard let self, self.generation == current, self.sessionState == .connecting else { return }
            switch result {
            case .failure(let failure):
                self.sessionState = .failed(failure.message)
            case .success:
                self.connect(identity: identity, consent: performerConsent)
                self.loadIdentities {}
            }
        }
    }

    func stop() {
        generation += 1
        closeSession()
        if sessionState != .idle { sessionState = .idle }
        scheduleIdleStop()
    }

    private func closeSession() {
        stopCapture()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        lock.lock()
        shared.task = nil
        shared.inFlight = 0
        shared.lastJPEG = nil
        shared.lastTransformed = false
        shared.pendingImage = nil
        lock.unlock()
        activeIdentityName = nil
        if stats != LiveStats() { stats = LiveStats() }
        var camera = virtualCamera
        camera.active = false
        camera.pending = false
        camera.device = nil
        camera.error = nil
        if camera != virtualCamera { virtualCamera = camera }
    }

    private func scheduleIdleStop() {
        idleStop?.cancel()
        guard ownsServer else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.sessionState.isActive else { return }
            self.stopServer()
        }
        idleStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleStopDelay, execute: work)
    }

    private func connect(identity: String, consent: Bool) {
        guard let url = URL(string: "ws://127.0.0.1:\(settings.port)/ws/live") else { return }
        let face = settings
        let task = urlSession.webSocketTask(with: url)
        task.maximumMessageSize = 16 << 20
        socket = task
        applied = face
        lock.lock()
        shared.task = nil            // frames only flow once the server says "started"
        shared.inFlight = 0
        shared.sendWidth = face.profile.sendWidth
        lock.unlock()
        task.resume()
        send([
            "type": "start",
            "identity_id": identity,
            "performer_consent": consent,
            "options": Self.options(face),
            "vcam": Self.cameraRequest(face),
            "client": "NotchOrbit/\(AppInfo.version)",
        ], on: task)
        receive(on: task)
    }

    private static func options(_ face: FaceSettings) -> [String: Any] {
        ["profile": face.profile.rawValue, "color_match": face.colorMatch, "stabilize": face.stabilize,
         "preserve_mouth": face.preserveMouth, "swap_every": face.swapEverySecondFrame ? 2 : 1]
    }

    private static func cameraRequest(_ face: FaceSettings) -> [String: Any] {
        ["enabled": face.virtualCamera, "fallback": face.cameraFallback.rawValue]
    }

    private func send(_ message: [String: Any], on task: URLSessionWebSocketTask? = nil) {
        guard let task = task ?? socket, let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                DispatchQueue.main.async { self.socketClosed(task) }
            case .success(.data(let data)):
                self.handleFrame(data, from: task)
                self.receive(on: task)
            case .success(.string(let text)):
                DispatchQueue.main.async { self.handleControl(text, from: task) }
                self.receive(on: task)
            @unknown default:
                self.receive(on: task)
            }
        }
    }

    private func socketClosed(_ task: URLSessionWebSocketTask) {
        guard task === socket else { return }
        let wasLive = sessionState == .live
        closeSession()
        sessionState = .failed(serverError.map { "Face server: \($0)" }
                               ?? (wasLive ? "The face server closed the connection." : "Couldn't connect to the face server."))
        scheduleIdleStop()
    }

    private func handleControl(_ text: String, from task: URLSessionWebSocketTask) {
        guard task === socket, let data = text.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        switch message["type"] as? String {
        case "started":
            activeIdentityName = (message["identity"] as? [String: Any])?["name"] as? String
            lock.lock()
            shared.task = task
            shared.lastReceive = CACurrentMediaTime()
            lock.unlock()
            startCapture()
            sessionState = .live
        case "identity":
            activeIdentityName = (message["identity"] as? [String: Any])?["name"] as? String
        case "vcam":
            apply(virtualCamera: message, availability: false)
            if let error = message["error"] as? String, message["enabled"] as? Bool != true {
                notices.send("Virtual camera: \(error)")
            }
        case "error":
            let error = message["error"] as? String ?? "unknown error"
            if message["seq"] != nil {
                // One frame couldn't be decoded; it will not get a reply.
                lock.lock()
                shared.inFlight = max(0, shared.inFlight - 1)
                lock.unlock()
            } else if sessionState == .live {
                notices.send("Face server: \(error)")
            } else {
                serverError = error      // the server closes the socket right after
            }
        default:
            break
        }
    }

    /// Runs on the URL session's delegate queue. Layout: u32 big-endian header length,
    /// JSON header, JPEG.
    private func handleFrame(_ data: Data, from task: URLSessionWebSocketTask) {
        autoreleasepool {
            guard data.count > 4 else { return }
            let headerLength = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard headerLength > 0, data.count > 4 + headerLength else { return }
            let start = data.startIndex + 4
            let header = (try? JSONSerialization.jsonObject(with: data[start ..< start + headerLength])) as? [String: Any]
            let jpeg = data.subdata(in: start + headerLength ..< data.endIndex)
            let frameStats = header?["stats"] as? [String: Any]
            let transformed = frameStats?["transformed"] as? Bool ?? false

            lock.lock()
            guard shared.task === task else { lock.unlock(); return }
            shared.inFlight = max(0, shared.inFlight - 1)
            shared.lastReceive = CACurrentMediaTime()
            shared.lastJPEG = jpeg
            shared.lastTransformed = transformed
            let wantsImage = shared.hasViewer
            lock.unlock()

            var image: CGImage?
            if wantsImage, let source = CGImageSourceCreateWithData(jpeg as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) {
                // Decoded here (not on the main thread at draw time) and no larger than the pane needs.
                image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: Self.displayPixels,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
            }
            let live = LiveStats(fps: header?["fps"] as? Double ?? 0, transformed: transformed,
                                 fallbackReason: frameStats?["fallback_reason"] as? String)
            lock.lock()
            if let image { shared.pendingImage = image }
            shared.pendingStats = live
            let schedule = !shared.flushScheduled
            shared.flushScheduled = true
            lock.unlock()
            if schedule { DispatchQueue.main.async { [weak self] in self?.flushFrame(from: task) } }
        }
    }

    /// Main thread: hand the newest frame to the viewer and publish stats.
    private func flushFrame(from task: URLSessionWebSocketTask) {
        lock.lock()
        let image = shared.pendingImage
        let live = shared.pendingStats
        shared.pendingImage = nil
        shared.flushScheduled = false
        lock.unlock()
        guard task === socket else { return }
        if let image { frameHandler?(image) }
        // Twice a second is plenty for the status text and the Settings page.
        let now = CACurrentMediaTime()
        if now - lastStatsPublish > 0.5 || live.transformed != stats.transformed {
            lastStatsPublish = now
            if live != stats { stats = live }
        }
    }

    /// The Camera tab shows the transformed feed while it is open.
    func attachViewer(_ handler: @escaping (CGImage) -> Void) {
        frameHandler = handler
        lock.lock()
        shared.hasViewer = true
        lock.unlock()
    }

    /// The panel closed. The session ends with it unless it feeds the virtual camera
    /// and "Keep running" is on.
    func detachViewer() {
        frameHandler = nil
        lock.lock()
        shared.hasViewer = false
        lock.unlock()
        if sessionState.isActive, !settings.runsInBackground {
            stop()
        } else if case .failed = sessionState {
            sessionState = .idle
        }
    }

    /// The most recent output frame (JPEG, badge included when transformed).
    func snapshot() -> (jpeg: Data, transformed: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        return shared.lastJPEG.map { ($0, shared.lastTransformed) }
    }

    @objc private func settingsChanged() {
        let face = settings
        guard sessionState.isActive else { return }
        if !face.enabled {
            stop()
            return
        }
        guard sessionState == .live else { return }
        if face.identityID != applied.identityID, let identity = face.identityID {
            send(["type": "identity", "identity_id": identity])
        }
        if Self.options(face) as NSDictionary != Self.options(applied) as NSDictionary {
            send(["type": "options", "options": Self.options(face)])
            lock.lock()
            shared.sendWidth = face.profile.sendWidth
            lock.unlock()
        }
        if face.virtualCamera != applied.virtualCamera || face.cameraFallback != applied.cameraFallback {
            var request = Self.cameraRequest(face)
            request["type"] = "vcam"
            send(request)
        }
        applied = face
        // "Keep running" switched off while the panel is closed: nothing is watching any more.
        if frameHandler == nil, !face.runsInBackground { stop() }
    }

    /// Quit: end the session and stop a server NotchOrbit launched.
    func shutdown() {
        if sessionState.isActive { closeSession() }
        idleStop?.cancel()
        if let process, process.isRunning { process.terminate() }
    }

    // MARK: Capture

    private func startCapture() {
        guard usesCamera, capture == nil else { return }
        let session = AVCaptureSession()
        capture = session
        captureQueue.async { [weak self] in
            guard let self else { return }
            var ready = false
            session.beginConfiguration()
            if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
            if let device = AVCaptureDevice.default(for: .video),
               let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: self.captureQueue)
                if session.canAddOutput(output) {
                    session.addOutput(output)
                    ready = true
                }
            }
            session.commitConfiguration()
            guard ready else {
                DispatchQueue.main.async {
                    guard self.capture === session else { return }
                    self.closeSession()
                    self.sessionState = .failed("No camera found on this Mac.")
                }
                return
            }
            session.startRunning()
        }
    }

    /// Stops the camera and drops the session.
    private func stopCapture() {
        let session = capture
        capture = nil
        captureQueue.async {
            if let session, session.isRunning { session.stopRunning() }
        }
    }

    /// Capture queue. At most two frames are in flight and at most 30 are sent per
    /// second; the server keeps only the newest one it hasn't started on.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) { submit(pixels) }
    }

    /// Offers one camera frame to the session; dropped unless the server has room for it.
    func submit(_ pixels: CVPixelBuffer) {
        // Capture callbacks arrive back to back; without a pool of their own the
        // autoreleased images and buffers pile up until the queue goes idle.
        autoreleasepool { send(pixels) }
    }

    private func send(_ pixels: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        lock.lock()
        guard let task = shared.task else { lock.unlock(); return }
        if shared.inFlight >= Self.maxInFlight {
            // A reply that never comes (a frame the server dropped) must not stall the feed.
            guard now - shared.lastReceive > 1.5 else { lock.unlock(); return }
            shared.inFlight = 0
        }
        guard now - shared.lastSend >= 1 / Self.maxSendRate else { lock.unlock(); return }
        let width = shared.sendWidth
        shared.lastSend = now
        shared.inFlight += 1
        lock.unlock()

        guard let jpeg = encode(pixels, width: width) else {
            lock.lock()
            shared.inFlight = max(0, shared.inFlight - 1)
            lock.unlock()
            return
        }
        task.send(.data(jpeg)) { _ in }
    }

    /// JPEG at most `width` pixels wide, through VideoToolbox and ImageIO. (Core Image
    /// did the same job but left about 10 MB of GPU state behind after a session.)
    private func encode(_ pixels: CVPixelBuffer, width: Double) -> Data? {
        var converted: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &converted)
        guard let image = converted else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.8]
        if Double(image.width) > width { options[kCGImageDestinationImageMaxPixelSize] = Int(width) }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
