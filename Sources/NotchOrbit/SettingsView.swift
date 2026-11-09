import SwiftUI
import ServiceManagement
import AVFoundation
import CoreLocation

// MARK: - Pages

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, notch, circles, island, stats, weather

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .notch:   return "Notch Shape"
        case .circles: return "Circles"
        case .island:  return "Dynamic Island"
        case .stats:   return "System Stats"
        case .weather: return "Weather"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Overlay, startup, privacy and maintenance."
        case .notch:   return "Reshape the hardware notch with a coloured overlay."
        case .circles: return "The two discs that sit beside or inside the notch."
        case .island:  return "A virtual notch for displays that don't have one."
        case .stats:   return "Live readings, thresholds, emoji and the expandable panel."
        case .weather: return "Current conditions and temperature in the right circle."
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .notch:   return "rectangle.topthird.inset.filled"
        case .circles: return "circle.lefthalf.filled"
        case .island:  return "capsule.fill"
        case .stats:   return "gauge.medium"
        case .weather: return "cloud.sun.fill"
        }
    }

    static let appearance: [SettingsPage] = [.notch, .circles, .island]
    static let features: [SettingsPage] = [.stats, .weather]
}

// MARK: - Root

struct SettingsView: View {
    let overlay: OverlayController
    @EnvironmentObject var store: SettingsStore
    @State private var page: SettingsPage = .notch

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section("Appearance") {
                    ForEach(SettingsPage.appearance) { row($0) }
                }
                Section("Features") {
                    ForEach(SettingsPage.features) { row($0) }
                }
                Section {
                    row(.general)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 2) {
                    Text("NotchOrbit").font(.caption.weight(.semibold))
                    Text("Version \(AppInfo.version)").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
        } detail: {
            SettingsPageContainer(page: page) {
                switch page {
                case .general: GeneralPage(overlay: overlay)
                case .notch:   NotchPage()
                case .circles: CirclesPage()
                case .island:  IslandPage()
                case .stats:   StatsPage()
                case .weather: WeatherPage()
                }
            }
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    private func row(_ page: SettingsPage) -> some View {
        Label(page.title, systemImage: page.icon).tag(page)
    }
}

/// Title block above each page's form.
struct SettingsPageContainer<Content: View>: View {
    let page: SettingsPage
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: page.icon)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(page.title).font(.title2.weight(.semibold))
                    Text(page.subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 14)
            Divider()
            content()
        }
        .navigationTitle(page.title)
    }
}

enum AppInfo {
    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (s?, b?) where s != b: return "\(s) (\(b))"
        case let (s?, _): return s
        default: return "development build"
        }
    }
}

// MARK: - Notch shape

struct NotchPage: View {
    @EnvironmentObject var store: SettingsStore

    var body: some View {
        Form {
            PreviewSection {
                NotchPreview(params: store.settings.effectiveShape,
                             color: store.settings.notchColor.nsColor,
                             circles: store.settings.circles)
            }
            Section {
                Picker("Preset", selection: presetBinding) {
                    ForEach(NotchPreset.allCases) { Text($0.title).tag($0) }
                }
                ColorPicker("Overlay colour", selection: colorBinding($store.settings.notchColor))
            } header: {
                Text("Style")
            } footer: {
                Text("The hardware notch itself can't be hidden. NotchOrbit paints over the menu bar around it, so the notch appears wider, taller, squarer or more pill-shaped.")
            }
            Section {
                LabeledSlider("Extra width per side", value: shape(\.extraWidth), range: 0...200, unit: " pt")
                LabeledSlider("Extra height", value: shape(\.extraHeight), range: 0...60, unit: " pt")
                LabeledSlider("Bottom corner radius", value: shape(\.bottomRadius), range: 0...40, unit: " pt")
                LabeledSlider("Top ear radius", value: shape(\.earRadius), range: 0...30, unit: " pt")
            } header: {
                Text("Fine-tune")
            } footer: {
                Text(store.settings.preset == .original
                     ? "Choose a preset other than Original to adjust the shape."
                     : "Moving any slider switches the preset to Custom.")
            }
            .disabled(store.settings.preset == .original)
        }
        .formStyle(.grouped)
    }

    private var presetBinding: Binding<NotchPreset> {
        Binding(
            get: { store.settings.preset },
            set: { preset in
                store.settings.preset = preset
                if let params = preset.params { store.settings.shape = params }
            })
    }

    private func shape(_ keyPath: WritableKeyPath<NotchShapeParams, Double>) -> Binding<Double> {
        Binding(
            get: { store.settings.shape[keyPath: keyPath] },
            set: { value in
                store.settings.shape[keyPath: keyPath] = value
                store.settings.preset = .custom
            })
    }
}

// MARK: - Circles

struct CirclesPage: View {
    @EnvironmentObject var store: SettingsStore
    @ObservedObject private var monitor = SystemStatsMonitor.shared
    @ObservedObject private var weather = WeatherService.shared

    var body: some View {
        let c = $store.settings.circles
        let statsOn = store.settings.stats.enabled
        let weatherOn = store.settings.weather.enabled
        Form {
            PreviewSection {
                NotchPreview(params: store.settings.effectiveShape,
                             color: store.settings.notchColor.nsColor,
                             circles: store.settings.circles,
                             stats: statsOn ? StatsPreview(settings: store.settings.stats, snapshot: monitor.snapshot) : nil,
                             weather: weatherOn ? WeatherPreview(settings: store.settings.weather, reading: weather.currentReading) : nil)
            }
            Section {
                Toggle("Show circles", isOn: c.enabled)
                Toggle("Left circle", isOn: c.showLeft)
                Toggle("Right circle", isOn: c.showRight)
            } header: {
                Text("Visibility")
            } footer: {
                Text(circlesFooter(statsOn: statsOn, weatherOn: weatherOn))
            }
            Section("Layout") {
                LabeledSlider("Size", value: c.size, range: 16...80, unit: " pt")
                LabeledSlider("Gap from notch", value: c.gap, range: 0...80, unit: " pt")
                LabeledSlider("Vertical offset", value: c.verticalOffset, range: -24...24, unit: " pt")
            }
            Section("Border") {
                LabeledSlider("Width", value: c.borderWidth, range: 0...6, unit: " pt")
                ColorPicker("Colour", selection: colorBinding(c.borderColor))
            }
            Section {
                Toggle("Make the circles part of the notch", isOn: c.attachToNotch)
                LabeledSlider("Padding around circles", value: c.attachPadding, range: 0...24, unit: " pt")
                    .disabled(!store.settings.circles.attachToNotch)
            } header: {
                Text("Attach to notch")
            } footer: {
                Text("The overlay stretches out to wrap the circles, so they sit inside the notch instead of beside it.")
            }
        }
        .formStyle(.grouped)
    }

    private func circlesFooter(statsOn: Bool, weatherOn: Bool) -> String {
        switch (statsOn, weatherOn) {
        case (true, true):   return "System stats mode is on: the left circle is the gauge. Weather is on: the right circle shows the current conditions."
        case (true, false):  return "System stats mode is on: the left circle is the gauge and the right one is the emoji."
        case (false, true):  return "Weather is on: the right circle shows the current conditions. The left circle is a plain tinted disc."
        case (false, false): return "Without system stats or weather the circles are plain tinted discs."
        }
    }
}

// MARK: - System stats

struct StatsPage: View {
    @EnvironmentObject var store: SettingsStore
    @ObservedObject private var monitor = SystemStatsMonitor.shared
    @ObservedObject private var weather = WeatherService.shared

    var body: some View {
        let s = $store.settings.stats
        let stats = store.settings.stats
        let metric = stats.metric
        let value = monitor.snapshot.value(for: metric)
        let weatherOn = store.settings.weather.enabled
        Form {
            PreviewSection {
                NotchPreview(params: store.settings.effectiveShape,
                             color: store.settings.notchColor.nsColor,
                             circles: store.settings.circles,
                             stats: StatsPreview(settings: stats, snapshot: monitor.snapshot),
                             weather: weatherOn ? WeatherPreview(settings: store.settings.weather, reading: weather.currentReading) : nil)
            }
            Section {
                Toggle("Show system stats in the circles", isOn: s.enabled)
            } footer: {
                Text(weatherOn
                     ? "The left circle becomes a live gauge for the chosen reading. Weather is on, so the right circle shows the current conditions instead of the threshold emoji; turn weather off to get the emoji back. Click the gauge to open the panel."
                     : "The left circle becomes a live gauge for the chosen reading and the right circle shows an emoji that changes with your threshold. Click the gauge to open the panel; click the emoji for a full-screen burst.")
            }
            Section {
                Picker("Reading", selection: s.metric) {
                    ForEach(StatMetric.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Current value") {
                    Text(metric.format(value)).monospacedDigit().foregroundStyle(.secondary)
                }
                Toggle("Show the reading's name inside the gauge", isOn: s.showLabel)
                LabeledSlider("Refresh every", value: s.refreshInterval, range: 1...10, unit: " s", step: 1)
            } header: {
                Text("Reading")
            } footer: {
                if metric == .apps {
                    Text("Counts apps that appear in the Dock and the ⌘-Tab switcher. The ring is full at 20 apps.")
                }
            }
            Section {
                LabeledSlider("Above", value: thresholdBinding, range: metric.thresholdRange, unit: metric.unit)
                EmojiField(title: "Emoji above threshold", emoji: s.hotEmoji,
                           fallback: "🔥", suggestions: ["🔥", "⚡️", "🌋", "🚀", "🥵", "💀", "🚨", "😤"])
                EmojiField(title: "Emoji at or below", emoji: s.coldEmoji,
                           fallback: "❄️", suggestions: ["❄️", "🧊", "😎", "🌙", "💤", "🍃", "✅", "🐢"])
            } header: {
                Text("Threshold")
            } footer: {
                Text("\(metric.title) is \(metric.format(value)) right now, so the circle shows \(stats.emoji(for: value)). Each reading remembers its own threshold. Leave an emoji empty to use the default.")
            }
            Section {
                Toggle("Animate the emoji", isOn: s.animateEmoji)
                LabeledSlider("Full-screen burst lasts", value: s.burstDuration, range: StatsSettings.burstDurationRange, unit: " s", step: 1)
            } header: {
                Text("Animation")
            } footer: {
                Text("Above the threshold the emoji flickers over rising embers; at or below it turns slowly while snow falls. Animation is paused automatically when Reduce Motion is on. Clicking the emoji fills the screen with the same effect for the chosen duration.")
            }
            Section {
                LabeledContent("Stats tab") {
                    Text("All readings in a row; click one for its history graph").foregroundStyle(.secondary)
                }
                LabeledContent("Weather tab") {
                    Text("Animated conditions, details and hourly forecast (when weather is on)").foregroundStyle(.secondary)
                }
                LabeledContent("Mic tab") {
                    Text("Voice effects, playthrough and voice recording").foregroundStyle(.secondary)
                }
                LabeledContent("Camera tab") {
                    Text("Live webcam preview, mic meter and photo shutter").foregroundStyle(.secondary)
                }
                LabeledContent("Screenshot & Record") {
                    Text("Capture the screen without NotchOrbit's overlay").foregroundStyle(.secondary)
                }
                LabeledContent("Gear") {
                    Text("Opens this window").foregroundStyle(.secondary)
                }
            } header: {
                Text("Expanded panel")
            }
            Section {
                Picker("Preview shape", selection: s.cameraShape) {
                    ForEach(CameraShape.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Preview") {
                    CameraShapePreview(shape: stats.cameraShape)
                }
                PhotoFolderRow(directory: s.photoDirectory)
            } header: {
                Text("Camera tab")
            } footer: {
                Text("Shows a live webcam preview with a microphone level meter beside it and a shutter button for photos. Photos, screenshots, voice and screen recordings are all saved to the folder above (Downloads unless you change it); NotchOrbit's own overlay is left out of screenshots and recordings. Circle and square keep equal sides; the other shapes fill the panel width. Camera and microphone are only active while the tab is open; permissions are under General › Privacy.")
            }
            MicSection()
        }
        .formStyle(.grouped)
        .onAppear { monitor.sampleNow() }
    }

    private var thresholdBinding: Binding<Double> {
        Binding(
            get: { store.settings.stats.threshold },
            set: { value in
                let metric = store.settings.stats.metric
                store.settings.stats.setThreshold(value, for: metric)
            })
    }
}

/// The panel's Mic tab: effect, fine-tuning, playthrough and device choices.
struct MicSection: View {
    @EnvironmentObject var store: SettingsStore
    @ObservedObject private var changer = VoiceChanger.shared
    @ObservedObject private var installer = BlackHoleInstaller.shared
    @State private var inputs = AudioDevices.inputs()
    @State private var outputs = AudioDevices.outputs()
    @State private var loopback = AudioDevices.loopbackDevice()
    @State private var virtualMicError: String?

    var body: some View {
        let m = $store.settings.stats.mic
        let mic = store.settings.stats.mic
        Section {
            Picker("Voice effect", selection: m.effect) {
                ForEach(VoiceEffect.allCases) { Text($0.title).tag($0) }
            }
            LabeledContent("") {
                Text(mic.effect.summary).foregroundStyle(.secondary)
            }
            LabeledSlider("Pitch", value: m.pitch, range: MicSettings.pitchRange, unit: " st", step: 1)
            LabeledSlider("Effect amount", value: m.amount, range: MicSettings.amountRange, unit: "%", step: 5)
            LabeledContent("Status") {
                Text(statusText).foregroundStyle(.secondary)
            }
        } header: {
            Text("Mic tab · Voice")
        } footer: {
            Text("Pick an effect by clicking its chip in the panel or here. Pitch shifts the voice in semitones on top of the effect; Effect amount scales how strongly it is applied (0% is your plain voice). The mic only listens while the Mic tab is open.")
        }
        Section {
            Toggle("Play my voice through the output", isOn: m.playthrough)
            LabeledSlider("Playback volume", value: m.volume, range: MicSettings.volumeRange, unit: "%", step: 5)
            Toggle("Keep running after the panel closes", isOn: m.stayOn)
            Toggle("Echo cancellation", isOn: m.echoCancellation)
            Picker("Microphone", selection: deviceBinding(m.inputDeviceUID, in: inputs.filter { !AudioDevices.isLoopback($0) })) {
                deviceOptions(mic.inputDeviceUID, in: inputs.filter { !AudioDevices.isLoopback($0) })
            }
            Picker("Play through", selection: deviceBinding(m.outputDeviceUID, in: outputs)) {
                deviceOptions(mic.outputDeviceUID, in: outputs)
            }
            LabeledContent("") {
                Button("Refresh device list") { refreshDevices() }.controlSize(.small)
            }
        } header: {
            Text("Mic tab · Playthrough & devices")
        } footer: {
            Text("Playthrough lets you hear the changed voice — wear headphones, or the speakers feed back into the mic. Echo cancellation runs the mic through Apple's voice processing, which removes what the speakers are playing (the other side of a call, or your own playthrough) from the mic signal. “System default” means your real microphone, never a loopback device. Recordings made with the Record button are saved as .m4a next to your photos.")
        }
        Section {
            LabeledContent("Virtual audio device") {
                HStack(spacing: 8) {
                    if let loopback {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(loopback.name).foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        Text("Not installed").foregroundStyle(.secondary)
                        Button(installer.state == .downloading ? "Downloading…" : "Install BlackHole…") { installer.install() }
                            .controlSize(.small)
                            .disabled(installer.state == .downloading)
                    }
                    Button {
                        refreshDevices()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .help("Check again")
                }
            }
            if loopback == nil {
                switch installer.state {
                case .opened:
                    Text("The BlackHole installer is open. Finish it (macOS asks for your password), then click ↻ here.")
                        .font(.caption).foregroundStyle(.secondary)
                case .failed(let message):
                    HStack {
                        Text(message).font(.caption).foregroundStyle(.red)
                        Link("Get it from existential.audio", destination: BlackHoleInstaller.homepage).font(.caption)
                    }
                default:
                    Text("BlackHole \(BlackHoleInstaller.version) is a free, open-source loopback driver by Existential Audio (about 100 KB). NotchOrbit downloads it, checks its checksum and opens the installer.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Use the changed voice as my microphone", isOn: virtualMicBinding)
                .disabled(loopback == nil && !mic.useAsMicrophone)
            if let virtualMicError {
                Text(virtualMicError).font(.caption).foregroundStyle(.red)
            }
            if mic.useAsMicrophone, loopback != nil {
                let published = AudioDevices.virtualMicrophone()?.name ?? AudioDevices.virtualMicrophoneName
                LabeledContent("Listening to") {
                    Text(changer.inputName ?? "your microphone").foregroundStyle(.secondary)
                }
                LabeledContent("System microphone") {
                    Text(published).foregroundStyle(.secondary)
                }
                LabeledContent("In the other app") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("FaceTime: nothing to do (uses the system microphone)")
                        Text("Teams: Settings › Devices › Microphone › \(published) or Same as system")
                        Text("WhatsApp / Zoom / Slack / Discord: pick \(published) in their microphone picker")
                    }
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
            }
            if let out = AudioDevices.defaultDevice(input: false).flatMap(AudioDevices.name(of:)), AudioDevices.loopbackMarkers.contains(where: { out.localizedCaseInsensitiveContains($0) }) {
                Label("The system output is \(out), so you won't hear the call. Pick your speakers or headphones in System Settings › Sound › Output.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Calls · FaceTime, Teams, Zoom…")
        } footer: {
            Text("Other apps can't read NotchOrbit's audio directly, so the changed voice is played into a virtual loopback device, which NotchOrbit publishes to the rest of macOS as “\(AudioDevices.virtualMicrophoneName)”. Turning this on makes that device the system microphone (FaceTime can only use the system one); your real microphone is put back when you turn it off or quit. NotchOrbit itself keeps listening to your real microphone — with echo cancellation, so the other side of the call isn't sent back to them — in the background, even with the panel closed, until you turn this off. Don't pick the loopback device as the speaker/output anywhere. You won't hear yourself while this is on; the people you call will.")
        }
        .onAppear(perform: refreshDevices)
    }

    private var virtualMicBinding: Binding<Bool> {
        Binding(
            get: { store.settings.stats.mic.useAsMicrophone },
            set: { on in
                virtualMicError = nil
                if on {
                    do { try VirtualMicrophone.enable() } catch { virtualMicError = error.localizedDescription }
                } else {
                    VirtualMicrophone.disable()
                }
            })
    }

    private var statusText: String {
        switch changer.state {
        case .idle:               return "Off (opens with the Mic tab)"
        case .starting:           return "Starting…"
        case .running:            return "Listening on \(changer.inputName ?? "the microphone")" + (changer.isRecording ? " · recording" : "")
        case .failed(let message): return message
        }
    }

    private func refreshDevices() {
        inputs = AudioDevices.inputs()
        outputs = AudioDevices.outputs()
        loopback = AudioDevices.loopbackDevice()
    }

    /// "" stands for the system default; an unplugged device keeps its UID selectable.
    private func deviceBinding(_ uid: Binding<String?>, in list: [AudioDeviceInfo]) -> Binding<String> {
        Binding(get: { uid.wrappedValue ?? "" }, set: { uid.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    @ViewBuilder private func deviceOptions(_ current: String?, in list: [AudioDeviceInfo]) -> some View {
        Text("System default").tag("")
        ForEach(list) { Text($0.name).tag($0.uid) }
        if let current, !list.contains(where: { $0.uid == current }) {
            Text("Not connected").tag(current)
        }
    }
}

/// Where shutter-button photos are saved, with a folder picker.
struct PhotoFolderRow: View {
    @Binding var directory: String?

    private var url: URL {
        directory.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? StatsSettings.defaultPhotoDirectory
    }

    var body: some View {
        LabeledContent("Save captures to") {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill").foregroundStyle(.secondary)
                Text(displayPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(url.path)
                Button("Choose…", action: choose)
                    .controlSize(.small)
                if directory != nil {
                    Button("Use Downloads") { directory = nil }
                        .controlSize(.small)
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .controlSize(.small)
                .help("Show in Finder")
            }
        }
    }

    private var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.message = "Choose where NotchOrbit saves photos"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = url
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        directory = chosen.path == StatsSettings.defaultPhotoDirectory.path ? nil : chosen.path
    }
}

/// Miniature of the panel's camera area in the chosen outline.
struct CameraShapePreview: View {
    let shape: CameraShape

    var body: some View {
        let area = CGRect(x: 0, y: 0, width: 132, height: 72)
        let frame = shape.frame(in: area)
        let radius = shape.cornerRadius(for: frame.size)
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.85))
            RoundedRectangle(cornerRadius: radius)
                .fill(LinearGradient(colors: [Color(red: 0.45, green: 0.55, blue: 0.70), Color(red: 0.25, green: 0.30, blue: 0.45)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: radius).stroke(.white.opacity(0.25)))
                .overlay(Image(systemName: "person.fill").font(.system(size: 20)).foregroundStyle(.white.opacity(0.7)))
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
            RoundedRectangle(cornerRadius: 3)
                .fill(.white.opacity(0.12))
                .frame(width: 10, height: 56)
                .position(x: area.maxX + 12, y: area.midY)
        }
        .frame(width: area.width + 24, height: area.height)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.85)))
    }
}

/// Single-emoji editor: large swatch, a text field limited to one character,
/// quick picks, and a button for the system emoji picker.
struct EmojiField: View {
    let title: String
    @Binding var emoji: String
    let fallback: String
    let suggestions: [String]
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(emoji.isEmpty ? fallback : emoji)
                    .font(.system(size: 26))
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(emoji.isEmpty ? "Default (\(fallback))" : "Custom").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                TextField(fallback, text: $emoji)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .frame(width: 56)
                    .focused($focused)
                    .onChange(of: emoji) { newValue in
                        // Keep a single grapheme cluster; a freshly typed emoji replaces the old one.
                        if newValue.count > 1 { emoji = String(newValue.suffix(1)) }
                    }
                Button {
                    focused = true
                    DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
                } label: {
                    Image(systemName: "face.smiling")
                }
                .help("Open the emoji picker")
            }
            HStack(spacing: 6) {
                ForEach(suggestions, id: \.self) { s in
                    Button(s) { emoji = s }
                        .buttonStyle(.plain)
                        .font(.system(size: 16))
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(emoji == s ? 0.14 : 0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.accentColor.opacity(emoji == s ? 0.8 : 0)))
                        .help(s)
                }
                Spacer()
                if !emoji.isEmpty, emoji != fallback {
                    Button("Reset") { emoji = "" }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// What the previews need to draw stats mode.
struct StatsPreview {
    let settings: StatsSettings
    let snapshot: StatSnapshot
}

/// SwiftUI twin of `StatGaugeView` for the settings previews.
struct GaugePreviewContent: View {
    let metric: StatMetric
    let value: Double?
    let isHot: Bool
    let showLabel: Bool
    let size: CGFloat
    let borderWidth: CGFloat

    var body: some View {
        let ring = max(2, (size * 0.09).rounded())
        let inset = borderWidth + ring / 2 + 1
        let inner = size / 2 - inset - ring / 2 - 1
        let fraction = min(1, max(0, (value ?? 0) / metric.fullScale))
        let withLabel = showLabel && size >= 36
        let tint = isHot ? Color(red: 1.0, green: 0.36, blue: 0.22) : Color(red: 0.40, green: 0.78, blue: 1.0)
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.16), lineWidth: ring)
                .padding(inset)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: ring, lineCap: fraction < 0.999 ? .round : .butt))
                .rotationEffect(.degrees(-90))
                .padding(inset)
            if inner > 2 {
                VStack(spacing: 0) {
                    Text(metric.format(value))
                        .font(.system(size: inner * (withLabel ? 0.66 : 0.78), weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                    if withLabel {
                        Text(metric.shortLabel)
                            .font(.system(size: inner * 0.34, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .frame(width: inner * 1.75)
            }
        }
    }
}

/// What the previews need to draw weather mode.
struct WeatherPreview {
    let settings: WeatherSettings
    let reading: WeatherReading?
}

/// SwiftUI twin of `WeatherBadgeView` for the settings previews.
struct WeatherPreviewContent: View {
    let reading: WeatherReading?
    let settings: WeatherSettings
    let size: CGFloat
    let borderWidth: CGFloat

    var body: some View {
        let inner = size - 2 * borderWidth
        if let reading {
            if settings.showTemperature {
                HStack(spacing: size * 0.10) {
                    Text(reading.temperature(in: settings.unit))
                        .font(.system(size: size * 0.42, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                    icon(reading, pointSize: inner * 0.58)
                        .frame(width: size * 0.70)
                }
                .padding(.leading, size * 0.30)
                .padding(.trailing, size * 0.22)
            } else {
                icon(reading, pointSize: inner * 0.58)
            }
        } else {
            Image(systemName: "cloud")
                .font(.system(size: inner * 0.5))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    @ViewBuilder private func icon(_ reading: WeatherReading, pointSize: CGFloat) -> some View {
        switch settings.iconStyle {
        case .emoji:
            Text(reading.emoji()).font(.system(size: pointSize))
        case .symbol:
            Image(systemName: reading.symbolName())
                .symbolRenderingMode(.multicolor)
                .font(.system(size: pointSize, weight: .medium))
        }
    }
}

// MARK: - Weather

struct WeatherPage: View {
    @EnvironmentObject var store: SettingsStore
    @ObservedObject private var service = WeatherService.shared
    @ObservedObject private var monitor = SystemStatsMonitor.shared
    @State private var query = ""
    @State private var results: [WeatherPlace] = []
    @State private var searching = false
    @State private var searchMessage: String?

    var body: some View {
        let w = $store.settings.weather
        let weather = store.settings.weather
        let reading = service.currentReading
        Form {
            PreviewSection {
                NotchPreview(params: store.settings.effectiveShape,
                             color: store.settings.notchColor.nsColor,
                             circles: store.settings.circles,
                             stats: store.settings.stats.enabled ? StatsPreview(settings: store.settings.stats, snapshot: monitor.snapshot) : nil,
                             weather: WeatherPreview(settings: weather, reading: reading))
            }
            Section {
                Toggle("Show the weather in the right circle", isOn: w.enabled)
            } footer: {
                Text("The right circle shows the current condition (and the temperature) instead of a plain disc or the system-stats emoji. Click it for a full-screen animation of the weather; this also refreshes the forecast. With system stats on, the expanded panel gains a Weather tab with an animated scene, details and the hourly forecast. Forecast data comes from Open-Meteo; no account is needed.")
            }
            Section {
                Picker("Weather for", selection: w.locationMode) {
                    ForEach(WeatherLocationMode.allCases) { Text($0.title).tag($0) }
                }
                if weather.locationMode == .current {
                    locationAccessRow
                } else {
                    citySearch(place: w.place)
                }
            } header: {
                Text("Location")
            } footer: {
                Text(weather.locationMode == .current
                     ? "Uses your Mac's approximate location (to about a kilometre). macOS asks for permission the first time; the location never leaves your Mac except as coordinates sent to the weather service."
                     : "Type a city and pick a match. Only its coordinates are sent to the weather service.")
            }
            Section {
                Picker("Condition icon", selection: w.iconStyle) {
                    ForEach(WeatherIconStyle.allCases) { Text($0.title).tag($0) }
                }
                Picker("Temperature unit", selection: w.unit) {
                    ForEach(TemperatureUnit.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show the temperature beside the icon", isOn: w.showTemperature)
                LabeledSlider("Refresh every", value: w.refreshMinutes, range: WeatherSettings.refreshRange, unit: " min", step: 5)
            } header: {
                Text("Display")
            } footer: {
                Text("With the temperature on, the circle stretches into a capsule: temperature on the left, condition on the right. Automatic follows the system's measurement setting.")
            }
            Section {
                Toggle("Play a full-screen animation when the circle is clicked", isOn: w.animateOnClick)
                LabeledSlider("Animation lasts", value: w.burstDuration, range: StatsSettings.burstDurationRange, unit: " s", step: 1)
                    .disabled(!weather.animateOnClick)
            } header: {
                Text("Click")
            } footer: {
                Text("The scene matches the weather: sunshine and drifting suns on a clear day, stars and moons at night, clouds sliding across, fog, rain streaks, lightning flashes in a thunderstorm, or falling snow. Click also refreshes the forecast.")
            }
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 10) {
                        Text(weather.enabled ? service.status.message : "Weather is off")
                            .foregroundStyle(statusIsError ? .red : .secondary)
                            .multilineTextAlignment(.trailing)
                        Button("Refresh") { service.refresh(force: true) }
                            .controlSize(.small)
                            .disabled(!weather.enabled)
                    }
                }
                if let reading {
                    LabeledContent("Condition") {
                        HStack(spacing: 6) {
                            Text(reading.emoji())
                            Text(reading.condition.title).foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Temperature") {
                        Text(reading.temperature(in: weather.unit, withUnit: true)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if let feels = reading.apparent(in: weather.unit) {
                        LabeledContent("Feels like") { Text(feels).monospacedDigit().foregroundStyle(.secondary) }
                    }
                    if let humidity = reading.humidity {
                        LabeledContent("Humidity") { Text("\(Int(humidity.rounded()))%").monospacedDigit().foregroundStyle(.secondary) }
                    }
                    if let wind = reading.windKmh {
                        LabeledContent("Wind") { Text(windText(kmh: wind)).monospacedDigit().foregroundStyle(.secondary) }
                    }
                    LabeledContent("Location") {
                        Text(reading.placeName ?? String(format: "%.2f, %.2f", reading.latitude, reading.longitude))
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Updated") {
                        HStack(spacing: 0) {
                            Text(reading.fetchedAt, style: .relative)
                            Text(" ago")
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Right now")
            }
        }
        .formStyle(.grouped)
        .onAppear { service.refreshAuthorization() }
    }

    private var statusIsError: Bool {
        if case .failed = service.status { return store.settings.weather.enabled }
        return false
    }

    private func windText(kmh: Double) -> String {
        store.settings.weather.unit.usesFahrenheit
            ? "\(Int((kmh * 0.621371).rounded())) mph"
            : "\(Int(kmh.rounded())) km/h"
    }

    @ViewBuilder private var locationAccessRow: some View {
        LabeledContent("Location access") {
            HStack(spacing: 10) {
                Label(locationState.text, systemImage: locationState.symbol)
                    .foregroundStyle(locationState.color)
                    .labelStyle(.titleAndIcon)
                if service.authorization == .notDetermined {
                    Button("Allow…") { service.requestLocationAccess() }.controlSize(.small)
                } else if service.isLocationDenied {
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var locationState: (text: String, symbol: String, color: Color) {
        switch service.authorization {
        case .authorizedAlways, .authorizedWhenInUse, .authorized:
            return ("Allowed", "checkmark.circle.fill", .green)
        case .denied:     return ("Denied", "xmark.circle.fill", .red)
        case .restricted: return ("Restricted", "xmark.circle.fill", .red)
        case .notDetermined: return ("Not asked yet", "questionmark.circle", .secondary)
        @unknown default: return ("Unknown", "questionmark.circle", .secondary)
        }
    }

    @ViewBuilder private func citySearch(place: Binding<WeatherPlace?>) -> some View {
        LabeledContent("Chosen city") {
            Text(place.wrappedValue?.name ?? "None yet")
                .foregroundStyle(place.wrappedValue == nil ? .red : .secondary)
                .multilineTextAlignment(.trailing)
        }
        HStack(spacing: 8) {
            TextField("Search for a city", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit(search)
            Button(action: search) {
                if searching { ProgressView().controlSize(.small) } else { Text("Search") }
            }
            .disabled(searching || query.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if let searchMessage {
            Text(searchMessage).font(.caption).foregroundStyle(.secondary)
        }
        ForEach(Array(results.enumerated()), id: \.offset) { _, result in
            Button {
                place.wrappedValue = result
                results = []
                searchMessage = nil
            } label: {
                HStack {
                    Image(systemName: "mappin.and.ellipse").foregroundStyle(.secondary)
                    Text(result.name)
                    Spacer()
                    Text(String(format: "%.2f, %.2f", result.latitude, result.longitude))
                        .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !searching else { return }
        searching = true
        searchMessage = nil
        WeatherService.searchPlaces(q) { result in
            searching = false
            switch result {
            case .success(let places):
                results = places
                searchMessage = places.isEmpty ? "No places found for “\(q)”." : nil
            case .failure(let error):
                results = []
                searchMessage = "Search failed: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Previews

/// Grouped-form section that frames a live preview with a caption.
struct PreviewSection<Content: View>: View {
    var caption = "Live preview · 1:1 scale"
    @ViewBuilder var content: () -> Content

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                content()
                    .frame(height: 120)
                Text(caption).font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
        }
    }
}

/// Subdued desktop-like backdrop shared by the previews.
private let previewBackdrop = LinearGradient(
    colors: [Color(red: 0.16, green: 0.20, blue: 0.32), Color(red: 0.30, green: 0.22, blue: 0.40)],
    startPoint: .topLeading, endPoint: .bottomTrailing)

/// 1:1 preview of the top of a 14"/16" MacBook Pro screen.
struct NotchPreview: View {
    let params: NotchShapeParams?
    let color: NSColor
    let circles: CircleSettings
    var stats: StatsPreview? = nil
    var weather: WeatherPreview? = nil

    var body: some View {
        GeometryReader { geo in
            let notch = CGRect(x: (geo.size.width - 185) / 2, y: 0, width: 185, height: 32)
            let extra = CGFloat(params?.extraWidth ?? 0)
            let size = CGFloat(circles.size)
            let rightWidth = weather.map { WeatherBadgeView.preferredWidth(height: size, reading: $0.reading, settings: $0.settings) } ?? size
            let cy = notch.midY + CGFloat(circles.verticalOffset)
            ZStack(alignment: .topLeading) {
                previewBackdrop
                Rectangle().fill(.white.opacity(0.14)).frame(height: 32)   // menu bar
                Path(NotchShapeBuilder.hardwarePath(notch: notch)).fill(Color.black)
                if let params {
                    let embraced: [CGRect] = circles.enabled && circles.attachToNotch
                        ? [(circles.showLeft, notch.minX - extra - CGFloat(circles.gap) - size, size),
                           (circles.showRight, notch.maxX + extra + CGFloat(circles.gap), rightWidth)]
                            .filter { $0.0 }
                            .map { CGRect(x: $0.1, y: cy - size / 2, width: $0.2, height: size) }
                        : []
                    Path(NotchShapeBuilder.path(notch: notch, params: params, embracing: embraced,
                                                padding: CGFloat(circles.attachPadding)))
                        .fill(Color(nsColor: color))
                }
                if circles.enabled {
                    ForEach([(-1.0, circles.showLeft), (1.0, circles.showRight)], id: \.0) { side, shown in
                        if shown {
                            let width = side < 0 ? size : rightWidth
                            let x = side < 0 ? notch.minX - extra - CGFloat(circles.gap) - size / 2
                                             : notch.maxX + extra + CGFloat(circles.gap) + width / 2
                            circleContent(side: side, size: size)
                                .frame(width: width, height: size)
                                .position(x: x, y: cy)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1)))
        }
    }

    @ViewBuilder private func circleContent(side: Double, size: CGFloat) -> some View {
        let disc = Circle()
            .fill(.black.opacity(0.35))
            .overlay(Circle().stroke(Color(nsColor: circles.borderColor.nsColor), lineWidth: CGFloat(circles.borderWidth)))
        if side > 0, let weather {
            // Capsule: same look as the disc but stretches to fit the temperature.
            Capsule()
                .fill(.black.opacity(0.35))
                .overlay(Capsule().stroke(Color(nsColor: circles.borderColor.nsColor), lineWidth: CGFloat(circles.borderWidth)))
                .overlay(WeatherPreviewContent(reading: weather.reading, settings: weather.settings,
                                               size: size, borderWidth: CGFloat(circles.borderWidth)))
        } else if let stats {
            let value = stats.snapshot.value(for: stats.settings.metric)
            if side < 0 {
                disc.overlay(GaugePreviewContent(metric: stats.settings.metric, value: value,
                                                 isHot: stats.settings.isHot(value), showLabel: stats.settings.showLabel,
                                                 size: size, borderWidth: CGFloat(circles.borderWidth)))
            } else {
                disc.overlay(Text(stats.settings.emoji(for: value)).font(.system(size: size * 0.58)))
            }
        } else {
            disc
        }
    }
}

// MARK: - Dynamic Island (external displays)

struct IslandPage: View {
    @EnvironmentObject var store: SettingsStore

    var body: some View {
        let i = $store.settings.island
        Form {
            PreviewSection(caption: "Live preview · external display") {
                IslandPreview(island: store.settings.island,
                              shape: store.settings.shape,
                              color: store.settings.notchColor.nsColor,
                              circles: store.settings.circles)
            }
            Section {
                Toggle("Show a Dynamic Island on displays without a notch", isOn: i.enabled)
            } footer: {
                Text("External monitors and Macs without a notch get a virtual island at the top centre, with the circles beside or inside it. Displays with a real notch are unaffected.")
            }
            Section {
                LabeledSlider("Width", value: i.width, range: 80...500, unit: " pt")
                LabeledSlider("Height", value: i.height, range: 16...80, unit: " pt")
                LabeledSlider("Distance from top", value: i.topOffset, range: 0...80, unit: " pt")
                LabeledSlider("Corner radius", value: i.cornerRadius, range: 0...40, unit: " pt")
            } header: {
                Text("Size & position")
            } footer: {
                Text("A distance of 0 hangs the island from the screen edge like a notch. Any other value floats it as a pill. Colour, border and attach mode are shared with the notch.")
            }
            .disabled(!store.settings.island.enabled)
        }
        .formStyle(.grouped)
    }
}

/// 1:1 preview of the top of an external display (24 pt menu bar).
struct IslandPreview: View {
    let island: IslandSettings
    let shape: NotchShapeParams
    let color: NSColor
    let circles: CircleSettings

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(x: (geo.size.width - island.width) / 2, y: island.topOffset,
                              width: island.width, height: island.height)
            let size = CGFloat(circles.size)
            let cy = rect.midY + CGFloat(circles.verticalOffset)
            let frames: [(Bool, CGRect)] = [
                (circles.showLeft,  CGRect(x: rect.minX - CGFloat(circles.gap) - size, y: cy - size / 2, width: size, height: size)),
                (circles.showRight, CGRect(x: rect.maxX + CGFloat(circles.gap),        y: cy - size / 2, width: size, height: size)),
            ]
            let embraced = circles.enabled && circles.attachToNotch ? frames.filter { $0.0 }.map { $0.1 } : []
            ZStack(alignment: .topLeading) {
                previewBackdrop
                Rectangle().fill(.white.opacity(0.14)).frame(height: 24)   // external menu bar
                if island.enabled {
                    Path(NotchShapeBuilder.islandPath(rect: rect, cornerRadius: CGFloat(island.cornerRadius), shape: shape,
                                                      embracing: embraced, padding: CGFloat(circles.attachPadding)))
                        .fill(Color(nsColor: color))
                    if circles.enabled {
                        ForEach(Array(frames.enumerated()), id: \.offset) { _, item in
                            if item.0 {
                                Circle()
                                    .fill(.black.opacity(0.35))
                                    .overlay(Circle().stroke(Color(nsColor: circles.borderColor.nsColor), lineWidth: CGFloat(circles.borderWidth)))
                                    .frame(width: size, height: size)
                                    .position(x: item.1.midX, y: item.1.midY)
                            }
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1)))
        }
    }
}

// MARK: - General

struct GeneralPage: View {
    let overlay: OverlayController
    @EnvironmentObject var store: SettingsStore
    @State private var confirmReset = false
    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var screenAllowed = ScreenCaptureService.shared.hasPermission
    @ObservedObject private var weather = WeatherService.shared

    var body: some View {
        Form {
            Section("Overlay") {
                Toggle("Show overlay", isOn: $store.settings.overlayVisible)
                LabeledContent("Displays") {
                    Text(overlay.targets.isEmpty ? "No notch and Dynamic Island disabled"
                                                 : overlay.targets.map(\.description).joined(separator: "\n"))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            Section {
                Toggle("Launch at login", isOn: launchAtLoginBinding)
                if let loginError = store.launchAtLoginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Startup")
            } footer: {
                Text("NotchOrbit lives in the menu bar and has no Dock icon.")
            }
            Section {
                PermissionRow(title: "Camera", state: .init(cameraStatus), anchor: "Privacy_Camera")
                PermissionRow(title: "Microphone", state: .init(micStatus), anchor: "Privacy_Microphone")
                PermissionRow(title: "Screen Recording", state: screenAllowed ? .allowed : .notAsked("Not allowed"),
                              anchor: "Privacy_ScreenCapture")
                PermissionRow(title: "Location", state: .init(weather.authorization), anchor: "Privacy_LocationServices")
            } header: {
                Text("Privacy")
            } footer: {
                Text("The camera is used only by the Camera tab of the stats panel while it is open; the microphone by the Camera and Mic tabs (and, if you choose Keep running, by the Mic tab's playthrough after the panel closes). Screen Recording is needed for the screenshot and recording buttons; after allowing it, relaunch NotchOrbit. Location is used only by the Weather feature when it is set to your current location.")
            }
            Section {
                LabeledContent("Reset") {
                    Button("Reset All Settings…", role: .destructive) { confirmReset = true }
                }
            } header: {
                Text("Maintenance")
            } footer: {
                Text("Restores every option to its default. Launch at login is left as it is.")
            }
            Section {
                LabeledContent("Version") { Text(AppInfo.version).foregroundStyle(.secondary) }
                LabeledContent("Requires") { Text("macOS 13 or later").foregroundStyle(.secondary) }
                HStack {
                    Spacer()
                    Button("Quit NotchOrbit") { NSApp.terminate(nil) }
                }
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset all settings to their defaults?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset All Settings", role: .destructive) { store.resetToDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Notch shape, circles, Dynamic Island, system stats and weather options will all go back to their defaults.")
        }
        .onAppear { weather.refreshAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            screenAllowed = ScreenCaptureService.shared.hasPermission
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { store.settings.launchAtLogin },
            set: { enabled in
                do {
                    if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    store.settings.launchAtLogin = enabled
                    store.launchAtLoginError = nil
                } catch {
                    store.launchAtLoginError = "Couldn't update the login item: \(error.localizedDescription). Run the built .app bundle, not the bare executable."
                }
            })
    }
}

enum PermissionState {
    case allowed, denied(String), notAsked(String)

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized:    self = .allowed
        case .denied:        self = .denied("Denied")
        case .restricted:    self = .denied("Restricted")
        case .notDetermined: self = .notAsked("Not asked yet")
        @unknown default:    self = .notAsked("Unknown")
        }
    }

    init(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse, .authorized: self = .allowed
        case .denied:        self = .denied("Denied")
        case .restricted:    self = .denied("Restricted")
        case .notDetermined: self = .notAsked("Not asked yet")
        @unknown default:    self = .notAsked("Unknown")
        }
    }
}

struct PermissionRow: View {
    let title: String
    let state: PermissionState
    let anchor: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Label(statusText, systemImage: statusSymbol)
                    .foregroundStyle(statusColor)
                    .labelStyle(.titleAndIcon)
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private var statusText: String {
        switch state {
        case .allowed: return "Allowed"
        case .denied(let text), .notAsked(let text): return text
        }
    }

    private var statusSymbol: String {
        switch state {
        case .allowed:  return "checkmark.circle.fill"
        case .denied:   return "xmark.circle.fill"
        case .notAsked: return "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch state {
        case .allowed:  return .green
        case .denied:   return .red
        case .notAsked: return .secondary
        }
    }
}

// MARK: - Helpers

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String
    let step: Double?

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String = "", step: Double? = nil) {
        self.title = title
        self._value = value
        self.range = range
        self.unit = unit
        self.step = step
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                if let step {
                    Slider(value: $value, in: range, step: step)
                } else {
                    Slider(value: $value, in: range)
                }
                Text("\(Int(value.rounded()))\(unit)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
            .frame(maxWidth: 300)
        }
    }
}

func colorBinding(_ binding: Binding<CodableColor>) -> Binding<Color> {
    Binding(
        get: { Color(nsColor: binding.wrappedValue.nsColor) },
        set: { binding.wrappedValue = CodableColor(NSColor($0)) })
}
