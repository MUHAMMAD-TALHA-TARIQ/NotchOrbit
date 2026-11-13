import AppKit

/// Content of the expanded notch. Tab row: one Stats tab (graph of the chosen
/// reading with a strip of all readings above it), a Weather tab (when weather mode
/// is on), a Mic tab (voice effects, playthrough, recording), a Camera tab (webcam
/// preview + mic meter), a screenshot button, a record / stop button and a gear that
/// opens Settings. Flipped (y down) like the overlay. Handles its own clicks.
///
/// Tab content is built when its tab is first opened. The camera tab (capture
/// session, audio engine, preview layer) is released again whenever the panel closes.
final class StatsPanelView: NSView {
    enum Tab: Equatable { case stats, weather, mic, camera }

    /// Posted when the gear button is clicked; the app delegate opens Settings.
    static let openSettingsRequested = Notification.Name("NotchOrbit.openSettingsRequested")

    /// Panel content height below the notch for the Stats, Weather, Mic and Camera tabs.
    static let baseHeight: CGFloat = 190
    static let weatherHeight: CGFloat = 252
    static let micHeight: CGFloat = 265
    static let cameraHeight: CGFloat = 265
    /// Extra height of the Camera tab for the Face Transform control row.
    static let faceBarHeight: CGFloat = 36

    var history: [StatSnapshot] = [] { didSet { needsDisplay = true } }
    var snapshot = StatSnapshot() { didSet { if snapshot != oldValue { needsDisplay = true } } }
    var settings = StatsSettings() {
        didSet {
            guard settings != oldValue else { return }
            needsDisplay = true
            if settings.cameraShape != oldValue.cameraShape || settings.photoDirectory != oldValue.photoDirectory {
                needsLayout = true
            }
            faceBar?.settings = settings.face
            if settings.face.enabled != oldValue.face.enabled {
                syncCamera()
                needsLayout = true
                if tab == .camera { onPreferredHeightChange?() }
            }
            micView?.settings = settings.mic
            micView?.saveDirectory = settings.photoDirectoryURL
        }
    }
    var interval: Double = 2 { didSet { if interval != oldValue { needsDisplay = true } } }
    /// Latest forecast, its status and the weather settings (drives the Weather tab).
    var weather: (reading: WeatherReading?, status: WeatherService.Status, settings: WeatherSettings)
        = (nil, .idle, WeatherSettings()) {
        didSet {
            let enabledChanged = weather.settings.enabled != oldValue.settings.enabled
            weatherView?.update(reading: weather.reading, status: weather.status, settings: weather.settings)
            if enabledChanged {
                if !weather.settings.enabled, tab == .weather { setTab(.stats, notify: true) }
                needsLayout = true
            }
            needsDisplay = true
        }
    }
    /// Reading shown in the graph.
    var selected: StatMetric = .cpu { didSet { if selected != oldValue { needsDisplay = true } } }
    /// Which tab's content is showing.
    private(set) var tab: Tab = .stats
    /// Webcam tab selected instead of the stats graph.
    var showingCamera: Bool { tab == .camera }
    /// Called after a user tab click changes `preferredHeight`, so the overlay can re-layout.
    var onPreferredHeightChange: (() -> Void)?

    var preferredHeight: CGFloat {
        switch tab {
        case .stats:   return Self.baseHeight
        case .weather: return Self.weatherHeight
        case .mic:     return Self.micHeight
        case .camera:  return Self.cameraHeight + (settings.face.enabled ? Self.faceBarHeight : 0)
        }
    }

    private var camera: CameraPreviewView?
    private var faceOutput: FaceOutputView?
    private var faceBar: FaceControlBar?
    private var mic: MicLevelView?
    private var micView: MicPanelView?
    private var weatherView: WeatherPanelView?
    private var toastView: ToastView?
    private var captureObserver: NSObjectProtocol?
    private var recTimer: Timer?
    private var screenshotInFlight = false

    private let micWidth: CGFloat = 44
    private let tabHeight: CGFloat = 36
    private let tabGap: CGFloat = 4
    private let iconTabWidth: CGFloat = 48
    private let gearWidth: CGFloat = 36
    private let chipHeight: CGFloat = 26
    private let hotColor = NSColor(srgbRed: 1.0, green: 0.36, blue: 0.22, alpha: 1)
    private let coldColor = NSColor(srgbRed: 0.40, green: 0.78, blue: 1.0, alpha: 1)
    private let recordColor = NSColor(srgbRed: 1.0, green: 0.30, blue: 0.30, alpha: 1)
    private let micAccent = NSColor(srgbRed: 0.62, green: 0.80, blue: 1.0, alpha: 1)
    private let weatherAccent = NSColor(srgbRed: 1.0, green: 0.8, blue: 0.35, alpha: 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        captureObserver = NotificationCenter.default.addObserver(forName: ScreenCaptureService.stateDidChange, object: nil,
                                                                 queue: .main) { [weak self] _ in self?.syncRecordingState() }
        syncRecordingState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let captureObserver { NotificationCenter.default.removeObserver(captureObserver) }
        recTimer?.invalidate()
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The overlay hides the panel when it collapses; that must switch the camera,
    /// the mic tab and the weather backdrop off.
    override var isHidden: Bool {
        didSet { syncTabs() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncTabs()
    }

    override func layout() {
        super.layout()
        let area = contentArea
        mic?.frame = CGRect(x: area.maxX - micWidth, y: area.minY, width: micWidth, height: area.height)
        if let camera {
            var cameraArea = CGRect(x: area.minX, y: area.minY, width: max(0, area.width - micWidth - 8), height: area.height)
            camera.shape = settings.cameraShape
            camera.saveDirectory = settings.photoDirectoryURL
            if let faceOutput, let faceBar {
                // Face Transform: input and output feeds side by side, controls in a row below them.
                let barHeight = Self.faceBarHeight - 8
                faceBar.frame = CGRect(x: area.minX, y: area.maxY - barHeight, width: area.width, height: barHeight)
                cameraArea.size.height = max(0, area.height - Self.faceBarHeight)
                mic?.frame.size.height = cameraArea.height
                let paneWidth = max(0, (cameraArea.width - 8) / 2)
                let outputArea = CGRect(x: cameraArea.minX + paneWidth + 8, y: cameraArea.minY, width: paneWidth, height: cameraArea.height)
                cameraArea.size.width = paneWidth
                faceOutput.shape = settings.cameraShape
                faceOutput.frame = settings.cameraShape.frame(in: outputArea)
            }
            camera.frame = settings.cameraShape.frame(in: cameraArea)
        }
        micView?.frame = area
        weatherView?.frame = area
        if let toastView {
            let toastSize = toastView.fittingSize(maxWidth: bounds.width - 24)
            toastView.frame = CGRect(x: bounds.midX - toastSize.width / 2, y: bounds.maxY - toastSize.height - 6,
                                     width: toastSize.width, height: toastSize.height)
        }
    }

    // MARK: Tabs

    /// Show a reading's graph (used when the panel opens). Does not notify the overlay.
    func show(metric: StatMetric) {
        selected = metric
        setTab(.stats, notify: false)
    }

    /// Debug aid (`NOTCHORBIT_DEBUG_TAB=stats|weather|mic|camera`): select a tab by name.
    func debugSelectTab(named name: String) {
        switch name {
        case "weather": setTab(.weather, notify: true)
        case "mic":     setTab(.mic, notify: true)
        case "camera":  setTab(.camera, notify: true)
        default:        setTab(.stats, notify: true)
        }
    }

    private func setTab(_ new: Tab, notify: Bool) {
        guard new != tab else { return }
        tab = new
        needsLayout = true
        needsDisplay = true
        syncTabs()
        if notify { onPreferredHeightChange?() }
    }

    /// The panel is on screen and showing content.
    private var isShowing: Bool { !isHidden && window != nil }

    private func syncTabs() {
        syncCamera()
        syncMic()
        syncWeather()
    }

    /// Adds a tab view underneath the toast, so messages stay on top.
    private func install<V: NSView>(_ view: V) -> V {
        if let toastView { addSubview(view, positioned: .below, relativeTo: toastView) } else { addSubview(view) }
        needsLayout = true
        return view
    }

    private var toast: ToastView {
        if let toastView { return toastView }
        let toast = ToastView(frame: .zero)
        addSubview(toast)
        toastView = toast
        return toast
    }

    private func syncCamera() {
        guard showingCamera, isShowing else {
            // Not just stopped: dropped, so the capture pipeline and audio engine don't
            // stay resident between uses.
            removeFaceViews()
            camera?.stop(); camera?.removeFromSuperview(); camera = nil
            mic?.stop(); mic?.removeFromSuperview(); mic = nil
            return
        }
        if camera == nil { camera = install(CameraPreviewView(frame: .zero)) }
        if mic == nil { mic = install(MicLevelView(frame: .zero)) }
        camera?.start()
        mic?.start()
        if settings.face.enabled {
            if faceBar == nil {
                let output = install(FaceOutputView(frame: .zero))
                let bar = install(FaceControlBar(frame: .zero))
                bar.output = output
                bar.camera = camera
                bar.onToast = { [weak self] message, duration in self?.toast.show(message, duration: duration) }
                bar.settings = settings.face
                faceOutput = output
                faceBar = bar
                camera?.caption = "INPUT"
                bar.setActive(true)
            }
        } else {
            removeFaceViews()
        }
    }

    /// Ends the session with the panel, unless it is pinned to the virtual camera.
    private func removeFaceViews() {
        guard faceBar != nil else { return }
        faceBar?.setActive(false)
        faceBar?.removeFromSuperview(); faceBar = nil
        faceOutput?.removeFromSuperview(); faceOutput = nil
        camera?.caption = nil
        needsLayout = true
    }

    private func syncMic() {
        let show = tab == .mic && isShowing
        if show, micView == nil {
            let view = install(MicPanelView(frame: .zero))
            view.settings = settings.mic
            view.saveDirectory = settings.photoDirectoryURL
            micView = view
        }
        micView?.isHidden = !show
        micView?.setActive(show)
    }

    private var weatherTabVisible: Bool { weather.settings.enabled }

    private func syncWeather() {
        let show = tab == .weather && isShowing
        if show, weatherView == nil {
            let view = install(WeatherPanelView(frame: .zero))
            view.update(reading: weather.reading, status: weather.status, settings: weather.settings)
            weatherView = view
        }
        weatherView?.isHidden = !show
        weatherView?.setActive(show)
    }

    private var contentArea: CGRect {
        CGRect(x: 0, y: tabHeight + 8, width: bounds.width, height: max(0, bounds.height - tabHeight - 8))
    }

    // Tab row, right to left: gear, record, screenshot, camera, mic, (weather); the Stats tab takes the rest.
    private var gearRect: CGRect {
        CGRect(x: bounds.width - gearWidth, y: 0, width: gearWidth, height: tabHeight)
    }
    private var recordRect: CGRect {
        CGRect(x: gearRect.minX - tabGap - iconTabWidth, y: 0, width: iconTabWidth, height: tabHeight)
    }
    private var screenshotRect: CGRect {
        CGRect(x: recordRect.minX - tabGap - iconTabWidth, y: 0, width: iconTabWidth, height: tabHeight)
    }
    private var cameraTabRect: CGRect {
        CGRect(x: screenshotRect.minX - tabGap - iconTabWidth, y: 0, width: iconTabWidth, height: tabHeight)
    }
    private var micTabRect: CGRect {
        CGRect(x: cameraTabRect.minX - tabGap - iconTabWidth, y: 0, width: iconTabWidth, height: tabHeight)
    }
    /// Only present while weather mode is on (zero-width otherwise).
    private var weatherTabRect: CGRect {
        guard weatherTabVisible else { return CGRect(x: micTabRect.minX - tabGap, y: 0, width: 0, height: tabHeight) }
        return CGRect(x: micTabRect.minX - tabGap - iconTabWidth, y: 0, width: iconTabWidth, height: tabHeight)
    }
    private var statsTabRect: CGRect {
        let next = weatherTabVisible ? weatherTabRect : micTabRect
        return CGRect(x: 0, y: 0, width: max(0, next.minX - tabGap), height: tabHeight)
    }

    /// Reading chips along the top of the Stats tab content.
    private func chipRects() -> [(StatMetric, CGRect)] {
        let metrics = StatMetric.allCases
        let area = contentArea
        let width = (area.width - tabGap * CGFloat(metrics.count - 1)) / CGFloat(metrics.count)
        return metrics.enumerated().map { i, m in
            (m, CGRect(x: area.minX + CGFloat(i) * (width + tabGap), y: area.minY, width: width, height: chipHeight))
        }
    }

    private var graphArea: CGRect {
        let area = contentArea
        return CGRect(x: area.minX, y: area.minY + chipHeight + 6, width: area.width, height: max(0, area.height - chipHeight - 6))
    }

    // MARK: Interaction

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if gearRect.contains(p) {
            NotificationCenter.default.post(name: Self.openSettingsRequested, object: self)
        } else if recordRect.contains(p) {
            toggleRecording()
        } else if screenshotRect.contains(p) {
            takeScreenshot()
        } else if cameraTabRect.contains(p) {
            setTab(.camera, notify: true)
        } else if micTabRect.contains(p) {
            setTab(.mic, notify: true)
        } else if weatherTabVisible, weatherTabRect.contains(p) {
            setTab(.weather, notify: true)
        } else if statsTabRect.contains(p) {
            setTab(.stats, notify: true)
        } else if tab == .stats, let hit = chipRects().first(where: { $0.1.contains(p) }) {
            selected = hit.0
        }
        if Debug.enabled { debugLog("[debug] panel click at", p, "frame:", frame, "selected:", selected, "tab:", tab) }
    }

    // MARK: Screenshot & recording

    private func takeScreenshot() {
        guard !screenshotInFlight else { return }
        screenshotInFlight = true
        needsDisplay = true
        let directory = settings.photoDirectoryURL
        ScreenCaptureService.shared.takeScreenshot(into: directory) { [weak self] result in
            guard let self else { return }
            self.screenshotInFlight = false
            self.needsDisplay = true
            switch result {
            case .success(let url):
                self.toast.show("Screenshot saved to \(directory.lastPathComponent) › \(url.lastPathComponent)")
            case .failure(let error):
                self.toast.show(error.localizedDescription, duration: 4)
            }
        }
    }

    private func toggleRecording() {
        let service = ScreenCaptureService.shared
        if service.isRecording {
            let directory = settings.photoDirectoryURL
            service.stopRecording { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let url):
                    self.toast.show("Recording saved to \(directory.lastPathComponent) › \(url.lastPathComponent)")
                case .failure(let error):
                    self.toast.show(error.localizedDescription, duration: 4)
                }
            }
        } else if let error = service.startRecording(into: settings.photoDirectoryURL) {
            toast.show(error.localizedDescription, duration: 4)
        } else {
            toast.show("Recording the screen. Click ■ to stop.")
        }
    }

    /// Redraw the record button and keep its timer ticking while a recording runs.
    private func syncRecordingState() {
        recTimer?.invalidate()
        recTimer = nil
        if ScreenCaptureService.shared.isRecording {
            recTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.needsDisplay = true }
        }
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 40, bounds.height > tabHeight + 30 else { return }
        drawStatsTab()
        if weatherTabVisible {
            drawIconTab(weatherTabRect, symbol: weatherTabSymbol, selected: tab == .weather, accent: weatherAccent)
        }
        drawIconTab(micTabRect, symbol: micTabSymbol, selected: tab == .mic, accent: micAccent)
        drawIconTab(cameraTabRect, symbol: cameraTabSymbol, selected: tab == .camera, accent: coldColor)
        drawIconTab(screenshotRect, symbol: "camera.viewfinder", selected: false, accent: coldColor,
                    dimmed: screenshotInFlight)
        drawRecordTab()
        drawIconTab(gearRect, symbol: "gearshape.fill", selected: false, accent: coldColor)
        if tab == .stats {
            drawChips()
            drawGraph(in: graphArea)
        }
    }

    /// The tab shows the live condition when there is one.
    private var weatherTabSymbol: String { weather.reading?.symbolName() ?? "cloud.sun.fill" }
    /// The camera tab shows masks while a face session keeps running for the virtual camera.
    private var cameraTabSymbol: String { FaceTransform.current?.sessionState == .live && tab != .camera ? "theatermasks.fill" : "video.fill" }
    /// The mic tab shows a badge while the voice changer keeps running in the background.
    private var micTabSymbol: String { VoiceChanger.current?.state == .running && tab != .mic ? "mic.badge.plus" : "mic.fill" }

    private func tabBackground(_ rect: CGRect, selected: Bool) {
        let background = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        NSColor.white.withAlphaComponent(selected ? 0.16 : 0.06).setFill()
        background.fill()
    }

    private func selectionBar(_ rect: CGRect, color: NSColor) {
        let bar = NSBezierPath(roundedRect: CGRect(x: rect.minX + 10, y: rect.maxY - 2.5, width: rect.width - 20, height: 2.5),
                               xRadius: 1.25, yRadius: 1.25)
        color.setFill()
        bar.fill()
    }

    /// Single Stats tab: chart icon, "Stats", and the gauge reading on the right.
    private func drawStatsTab() {
        let rect = statsTabRect
        guard rect.width > 60 else { return }
        let isSelected = tab == .stats
        let metric = settings.metric
        let value = snapshot.value(for: metric)
        let hot = settings.isHot(value)
        tabBackground(rect, selected: isSelected)
        if isSelected { selectionBar(rect, color: hot ? hotColor : coldColor) }
        PanelDrawing.drawSymbol("chart.xyaxis.line", in: CGRect(x: rect.minX + 10, y: rect.minY, width: 18, height: rect.height),
                                pointSize: 12, color: NSColor.white.withAlphaComponent(isSelected ? 0.95 : 0.7))
        PanelDrawing.draw("Stats", at: CGPoint(x: rect.minX + 34, y: rect.midY - 8), size: 12.5, weight: .semibold,
                          color: NSColor.white.withAlphaComponent(isSelected ? 1 : 0.75), align: .left)
        PanelDrawing.draw("\(metric.shortLabel) \(metric.format(value))", at: CGPoint(x: rect.maxX - 12, y: rect.midY - 8),
                          size: 12.5, weight: .semibold, color: hot ? hotColor : NSColor.white.withAlphaComponent(0.85), align: .right)
    }

    /// A tab that holds a single SF Symbol (camera tab, screenshot, settings gear).
    private func drawIconTab(_ rect: CGRect, symbol: String, selected isSelected: Bool, accent: NSColor, dimmed: Bool = false) {
        tabBackground(rect, selected: isSelected)
        if isSelected { selectionBar(rect, color: accent) }
        PanelDrawing.drawSymbol(symbol, in: rect, pointSize: 13,
                                color: NSColor.white.withAlphaComponent(dimmed ? 0.35 : (isSelected ? 1 : 0.75)))
    }

    /// Record button: red dot when idle, red stop square with elapsed time while recording.
    private func drawRecordTab() {
        let rect = recordRect
        let service = ScreenCaptureService.shared
        if service.isRecording, let start = service.recordingStartedAt {
            let background = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
            recordColor.withAlphaComponent(0.28).setFill()
            background.fill()
            selectionBar(rect, color: recordColor)
            PanelDrawing.drawSymbol("stop.fill", in: CGRect(x: rect.minX, y: rect.minY + 3, width: rect.width, height: 16),
                                    pointSize: 11, color: recordColor)
            let seconds = Int(Date().timeIntervalSince(start))
            PanelDrawing.draw(String(format: "%02d:%02d", seconds / 60, seconds % 60),
                              centeredIn: CGRect(x: rect.minX, y: rect.minY + 20, width: rect.width, height: 12),
                              size: 8.5, weight: .bold, color: .white)
        } else {
            tabBackground(rect, selected: false)
            PanelDrawing.drawSymbol("record.circle", in: rect, pointSize: 13, color: recordColor.withAlphaComponent(0.9))
        }
    }

    /// All readings in a row; the highlighted one feeds the graph.
    private func drawChips() {
        for (metric, rect) in chipRects() {
            let isSelected = metric == selected
            let value = snapshot.value(for: metric)
            let hot = settings.isHot(value) && value != nil
            let background = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            NSColor.white.withAlphaComponent(isSelected ? 0.16 : 0.05).setFill()
            background.fill()
            if isSelected {
                let bar = NSBezierPath(roundedRect: CGRect(x: rect.minX + 8, y: rect.maxY - 2, width: rect.width - 16, height: 2),
                                       xRadius: 1, yRadius: 1)
                (hot ? hotColor : coldColor).setFill()
                bar.fill()
            }
            let label = PanelDrawing.text(metric.shortLabel, size: 8, weight: .semibold,
                                          color: NSColor.white.withAlphaComponent(isSelected ? 0.8 : 0.5))
            let number = PanelDrawing.text(metric.format(value), size: 11, weight: .semibold,
                                           color: hot ? hotColor : (isSelected ? .white : NSColor.white.withAlphaComponent(0.85)))
            let labelSize = label.size(), numberSize = number.size()
            let total = labelSize.width + 5 + numberSize.width
            var x = rect.midX - total / 2
            label.draw(at: CGPoint(x: x, y: rect.midY - labelSize.height / 2 + 1))
            x += labelSize.width + 5
            number.draw(at: CGPoint(x: x, y: rect.midY - numberSize.height / 2))
        }
    }

    private func drawGraph(in area: CGRect) {
        let metric = selected
        let values = history.map { $0.value(for: metric) }
        let current = snapshot.value(for: metric)
        let threshold = settings.threshold(for: metric)
        let hot = current.map { $0 > threshold } ?? false
        let accent = hot ? hotColor : coldColor

        // Title row
        let titleY = area.minY
        let title = "\(metric.title)  \(metric.format(current))"
        PanelDrawing.draw(title, at: CGPoint(x: area.minX + 2, y: titleY), size: 11, weight: .semibold, color: .white, align: .left)
        let span = Double(SystemStatsMonitor.historyCapacity) * interval
        let spanText = span >= 120 ? "\(Int((span / 60).rounded())) min window" : "\(Int(span)) s window"
        PanelDrawing.draw(spanText, at: CGPoint(x: area.maxX - 2, y: titleY + 1), size: 9, weight: .medium,
                          color: NSColor.white.withAlphaComponent(0.5), align: .right)

        // Plot rect: room for y labels on the right and time labels at the bottom.
        let plot = CGRect(x: area.minX + 2, y: titleY + 20, width: area.width - 36, height: area.height - 20 - 12)
        guard plot.height > 20 else { return }
        let labelX = plot.maxX + 6

        let known = values.compactMap { $0 }
        let fullScale: Double = metric.isPercent ? 100 : max(metric.fullScale, ((known.max() ?? 0) * 1.25 / 5).rounded(.up) * 5)
        func yFor(_ v: Double) -> CGFloat { plot.maxY - CGFloat(min(1, max(0, v / fullScale))) * plot.height }

        // Grid + labels
        let grid = NSBezierPath()
        grid.lineWidth = 0.5
        for step in 0...4 {
            let frac = Double(step) / 4
            let y = (yFor(frac * fullScale)).rounded() + 0.25
            grid.move(to: CGPoint(x: plot.minX, y: y))
            grid.line(to: CGPoint(x: plot.maxX, y: y))
            let label = metric.isPercent ? "\(Int(frac * 100))%" : "\(Int((frac * fullScale).rounded()))"
            PanelDrawing.draw(label, at: CGPoint(x: labelX, y: y - 5.5), size: 8, weight: .medium,
                              color: NSColor.white.withAlphaComponent(0.45), align: .left)
        }
        NSColor.white.withAlphaComponent(0.12).setStroke()
        grid.stroke()

        // Threshold
        if threshold > 0, threshold < fullScale {
            let y = yFor(threshold).rounded() + 0.25
            let line = NSBezierPath()
            line.move(to: CGPoint(x: plot.minX, y: y)); line.line(to: CGPoint(x: plot.maxX, y: y))
            line.lineWidth = 1
            line.setLineDash([3, 3], count: 2, phase: 0)
            hotColor.withAlphaComponent(0.55).setStroke()
            line.stroke()
        }

        // Time labels
        PanelDrawing.draw(spanAgoLabel(span), at: CGPoint(x: plot.minX, y: plot.maxY + 2), size: 8, weight: .medium,
                          color: NSColor.white.withAlphaComponent(0.4), align: .left)
        PanelDrawing.draw("now", at: CGPoint(x: plot.maxX, y: plot.maxY + 2), size: 8, weight: .medium,
                          color: NSColor.white.withAlphaComponent(0.4), align: .right)

        // Series: newest sample at the right edge, fixed spacing per sample.
        let n = values.count
        let step = plot.width / CGFloat(max(1, SystemStatsMonitor.historyCapacity - 1))
        var points: [CGPoint] = []
        for (i, v) in values.enumerated() {
            guard let v else { continue }
            points.append(CGPoint(x: plot.maxX - CGFloat(n - 1 - i) * step, y: yFor(v)))
        }
        guard points.count >= 2 else {
            let message = known.isEmpty && n > 2 ? "Not available on this Mac" : "Collecting…"
            PanelDrawing.draw(message, at: CGPoint(x: plot.midX, y: plot.midY - 6), size: 10, weight: .medium,
                              color: NSColor.white.withAlphaComponent(0.5), align: .center)
            return
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: plot).addClip()
        let line = NSBezierPath()
        line.move(to: points[0])
        for p in points.dropFirst() { line.line(to: p) }

        let fill = line.copy() as! NSBezierPath
        fill.line(to: CGPoint(x: points[points.count - 1].x, y: plot.maxY))
        fill.line(to: CGPoint(x: points[0].x, y: plot.maxY))
        fill.close()
        if let gradient = NSGradient(starting: accent.withAlphaComponent(0.4), ending: accent.withAlphaComponent(0.02)) {
            gradient.draw(in: fill, angle: 270)   // top → bottom in a flipped view
        }

        line.lineWidth = 1.8
        line.lineJoinStyle = .round
        line.lineCapStyle = .round
        accent.setStroke()
        line.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // Current value marker
        let last = points[points.count - 1]
        let dot = NSBezierPath(ovalIn: CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6))
        accent.setFill(); dot.fill()
        NSColor.white.setStroke(); dot.lineWidth = 1.2; dot.stroke()
    }

    private func spanAgoLabel(_ span: Double) -> String {
        span >= 120 ? "−\(Int((span / 60).rounded())) min" : "−\(Int(span)) s"
    }
}
