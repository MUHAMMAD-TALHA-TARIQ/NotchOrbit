import AppKit
import Combine

// MARK: - Model

struct CodableColor: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    static let black = CodableColor(r: 0, g: 0, b: 0, a: 1)
    static let white = CodableColor(r: 1, g: 1, b: 1, a: 1)

    init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        r = c.redComponent; g = c.greenComponent; b = c.blueComponent; a = c.alphaComponent
    }

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var cgColor: CGColor { nsColor.cgColor }
}

/// Parameters that describe how the black overlay around the notch is drawn.
/// All values are in points. `extraWidth` is added on *each* side.
struct NotchShapeParams: Codable, Equatable {
    var extraWidth: Double = 0
    var extraHeight: Double = 0
    var bottomRadius: Double = 12
    var earRadius: Double = 10
}

enum NotchPreset: String, Codable, CaseIterable, Identifiable {
    case original, rounded, island, square, wide, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "Original (no overlay)"
        case .rounded:  return "Rounded"
        case .island:   return "Island (pill)"
        case .square:   return "Square"
        case .wide:     return "Wide"
        case .custom:   return "Custom"
        }
    }

    /// Preset parameters. `nil` for presets that keep the current parameters.
    var params: NotchShapeParams? {
        switch self {
        case .original, .custom: return nil
        case .rounded: return NotchShapeParams(extraWidth: 0,  extraHeight: 0, bottomRadius: 12, earRadius: 10)
        case .island:  return NotchShapeParams(extraWidth: 16, extraHeight: 6, bottomRadius: 19, earRadius: 8)
        case .square:  return NotchShapeParams(extraWidth: 0,  extraHeight: 0, bottomRadius: 0,  earRadius: 0)
        case .wide:    return NotchShapeParams(extraWidth: 70, extraHeight: 0, bottomRadius: 14, earRadius: 10)
        }
    }
}

struct CircleSettings: Codable, Equatable {
    var enabled = true
    var showLeft = true
    var showRight = true
    var size: Double = 28
    var gap: Double = 12
    var verticalOffset: Double = 0
    var borderWidth: Double = 1.5
    var borderColor = CodableColor(r: 1, g: 1, b: 1, a: 0.85)
    /// Extend the black overlay so the circles sit *inside* the notch.
    var attachToNotch = false
    /// Black margin around attached circles.
    var attachPadding: Double = 6
}

/// Virtual "Dynamic Island" drawn on displays that have no hardware notch.
struct IslandSettings: Codable, Equatable {
    var enabled = true
    var width: Double = 220
    var height: Double = 36
    /// Distance from the top edge of the screen. 0 = hangs from the edge like a notch;
    /// anything else floats it as a pill (the default).
    var topOffset: Double = 6
    var cornerRadius: Double = 18
}

/// Which system reading the left circle shows.
enum StatMetric: String, Codable, CaseIterable, Identifiable {
    case cpu, memory, gpu, disk, battery, apps

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu:     return "CPU usage"
        case .memory:  return "Memory usage"
        case .gpu:     return "GPU usage"
        case .disk:    return "Disk usage"
        case .battery: return "Battery level"
        case .apps:    return "Apps running"
        }
    }

    /// Short name drawn inside the gauge.
    var shortLabel: String {
        switch self {
        case .cpu:     return "CPU"
        case .memory:  return "RAM"
        case .gpu:     return "GPU"
        case .disk:    return "DISK"
        case .battery: return "BAT"
        case .apps:    return "APPS"
        }
    }

    /// Percent metrics read 0–100; `apps` is a plain count.
    var isPercent: Bool { self != .apps }

    var unit: String { isPercent ? "%" : " apps" }

    var thresholdRange: ClosedRange<Double> { isPercent ? 0...100 : 0...40 }

    var defaultThreshold: Double {
        switch self {
        case .cpu:     return 70
        case .memory:  return 80
        case .gpu:     return 70
        case .disk:    return 90
        case .battery: return 50
        case .apps:    return 12
        }
    }

    /// Reading that fills the ring completely.
    var fullScale: Double { isPercent ? 100 : 20 }

    func format(_ value: Double?) -> String {
        guard let value else { return "–" }
        let n = Int(value.rounded())
        return isPercent ? "\(n)%" : "\(n)"
    }
}

/// Outline of the webcam preview in the stats panel's Camera tab.
enum CameraShape: String, Codable, CaseIterable, Identifiable {
    case rounded, rectangle, square, circle, capsule

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rounded:   return "Rounded rectangle"
        case .rectangle: return "Rectangle"
        case .square:    return "Square"
        case .circle:    return "Circle"
        case .capsule:   return "Capsule"
        }
    }

    /// Circle and square use equal sides; the others fill the available width.
    var isEqualSided: Bool { self == .circle || self == .square }

    /// Corner radius for a view of `size`.
    func cornerRadius(for size: CGSize) -> CGFloat {
        switch self {
        case .rounded:   return 12
        case .rectangle: return 0
        case .square:    return 10
        case .circle:    return min(size.width, size.height) / 2
        case .capsule:   return min(size.width, size.height) / 2
        }
    }

    /// Frame for the preview inside `area`, centred when the shape doesn't fill it.
    func frame(in area: CGRect) -> CGRect {
        guard isEqualSided else { return area }
        let side = min(area.width, area.height)
        return CGRect(x: area.midX - side / 2, y: area.midY - side / 2, width: side, height: side)
    }
}

/// Voice effect applied to the microphone in the panel's Mic tab.
enum VoiceEffect: String, Codable, CaseIterable, Identifiable {
    case normal, deep, chipmunk, robot, echo, cathedral, radio, alien, monster, underwater

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal:     return "Normal"
        case .deep:       return "Deep"
        case .chipmunk:   return "Chipmunk"
        case .robot:      return "Robot"
        case .echo:       return "Echo"
        case .cathedral:  return "Cathedral"
        case .radio:      return "Radio"
        case .alien:      return "Alien"
        case .monster:    return "Monster"
        case .underwater: return "Underwater"
        }
    }

    /// SF Symbol drawn on the effect's chip in the panel.
    var symbolName: String {
        switch self {
        case .normal:     return "waveform"
        case .deep:       return "tortoise.fill"
        case .chipmunk:   return "hare.fill"
        case .robot:      return "cpu.fill"
        case .echo:       return "wave.3.right"
        case .cathedral:  return "building.columns.fill"
        case .radio:      return "radio.fill"
        case .alien:      return "sparkles"
        case .monster:    return "flame.fill"
        case .underwater: return "drop.fill"
        }
    }

    /// One-line description used in Settings.
    var summary: String {
        switch self {
        case .normal:     return "Your voice as it is."
        case .deep:       return "Pitched down with a touch of room."
        case .chipmunk:   return "Pitched way up."
        case .robot:      return "Metallic ring and a crushed, synthetic edge."
        case .echo:       return "Repeats that trail off behind you."
        case .cathedral:  return "Huge, long reverb."
        case .radio:      return "Narrow, crackly, like an old transmitter."
        case .alien:      return "Pitched up with warbling chatter."
        case .monster:    return "Very low, growly and slightly broken."
        case .underwater: return "Muffled and lower, with a wash of room."
        }
    }
}

/// The panel's Mic tab: effect, fine-tuning, playthrough and device choices.
struct MicSettings: Codable, Equatable {
    var effect: VoiceEffect = .normal
    /// Extra pitch shift on top of the effect, in semitones.
    var pitch: Double = 0
    /// How strongly the effect is applied, 0–100 %.
    var amount: Double = 100
    /// Play the processed voice through the output device (use headphones!).
    var playthrough = false
    /// Playthrough volume, 0–100 %.
    var volume: Double = 80
    /// CoreAudio UID of the microphone to use. `nil` = system default input.
    var inputDeviceUID: String?
    /// CoreAudio UID of the device the voice is played through. `nil` = system default output.
    var outputDeviceUID: String?
    /// Keep listening and playing through after the panel closes (while playthrough is on).
    var stayOn = false
    /// Feed the changed voice into a loopback device (BlackHole…) and make that the
    /// system microphone, so calls in FaceTime, Teams, Zoom… hear the effect.
    var useAsMicrophone = false
    /// System default input to put back if a loopback device was left as the default.
    var restoreInputDeviceUID: String?
    /// Set once "Use as Mic" has ever been switched on. Launch and quit only touch the
    /// audio system (restoring the default input, removing the published device) when
    /// this is set, so users who never use the feature don't load the audio HAL at all.
    var loopbackWasUsed = false
    /// Capture through Apple's voice-processing unit: cancels what the speakers play (the
    /// other side of a call) from the mic signal. Uses the system default microphone.
    var echoCancellation = true

    static let pitchRange: ClosedRange<Double> = -12...12
    static let amountRange: ClosedRange<Double> = 0...100
    static let volumeRange: ClosedRange<Double> = 0...100
}

/// Quality profile of the face server's per-frame pipeline (detector size and inference width).
enum FaceProfile: String, Codable, CaseIterable, Identifiable {
    case fast, balanced, quality

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast:     return "Fast (640 px)"
        case .balanced: return "Balanced (960 px)"
        case .quality:  return "Quality (1280 px)"
        }
    }

    /// Width of the frames sent to the server; matches the profile's inference width.
    var sendWidth: Double {
        switch self {
        case .fast:     return 640
        case .balanced: return 960
        case .quality:  return 1280
        }
    }
}

/// What the virtual camera shows while no face can be transformed.
enum FaceCameraFallback: String, Codable, CaseIterable, Identifiable {
    case hold, original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hold:     return "Hold the last transformed frame"
        case .original: return "Pass the original camera through"
        }
    }
}

/// Face Transform in the panel's Camera tab: NotchOrbit sends camera frames to a local
/// deep-facial server (FastAPI + ONNX Runtime) and shows what comes back.
struct FaceSettings: Codable, Equatable {
    /// Show the face button and identity chip in the Camera tab.
    var enabled = false
    /// Folder of the deep-facial project (holds `.venv` and `server/`). Only needed to
    /// start the server from NotchOrbit; a server that is already running is used as is.
    var projectPath: String?
    /// The server listens on 127.0.0.1 at this port.
    var port = 8787
    /// Launch the server from `projectPath` when a session needs it and none is running.
    var autoStartServer = true
    /// Enrolled identity to appear as, and its name for display before the server is up.
    var identityID: String?
    var identityName: String?
    var profile: FaceProfile = .fast
    var colorMatch = true
    var stabilize = true
    /// Keep the performer's own lips: sharper lip-sync, weaker likeness.
    var preserveMouth = false
    /// Run the swapper on every second frame and re-warp in between (about 2× the frame rate).
    var swapEverySecondFrame = false
    /// Also feed the output into the server's virtual camera (OBS Virtual Camera) for calls.
    var virtualCamera = false
    var cameraFallback: FaceCameraFallback = .hold
    /// Keep the session running after the panel closes (only while the virtual camera is on).
    var stayOn = false

    /// The session may outlive the panel.
    var runsInBackground: Bool { stayOn && virtualCamera }
}

/// Live system-stats mode: left circle = gauge, right circle = hot/cold emoji.
struct StatsSettings: Codable, Equatable {
    var enabled = false
    var metric: StatMetric = .cpu
    /// Threshold per metric (keyed by `StatMetric.rawValue`); missing = metric default.
    var thresholds: [String: Double] = [:]
    /// Seconds between samples.
    var refreshInterval: Double = 2
    /// Draw the metric's short name under the value.
    var showLabel = true
    var hotEmoji = "🔥"
    var coldEmoji = "❄️"
    /// Animate the right circle: flame flicker + embers when hot, drifting emoji + falling snow when cold.
    var animateEmoji = true
    /// Length of the full-screen burst played when the emoji is clicked, in seconds.
    var burstDuration: Double = 3
    /// Outline of the webcam preview in the panel's Camera tab.
    var cameraShape: CameraShape = .rounded
    /// Folder for photos taken with the shutter button. `nil` = Downloads.
    var photoDirectory: String?
    /// The panel's Mic tab: voice effect, playthrough and device choices.
    var mic = MicSettings()
    /// Face Transform in the panel's Camera tab.
    var face = FaceSettings()

    static var defaultPhotoDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    var photoDirectoryURL: URL {
        photoDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultPhotoDirectory
    }

    static let burstDurationRange: ClosedRange<Double> = 3...20

    func threshold(for metric: StatMetric) -> Double {
        thresholds[metric.rawValue] ?? metric.defaultThreshold
    }

    mutating func setThreshold(_ value: Double, for metric: StatMetric) {
        thresholds[metric.rawValue] = value
    }

    /// Threshold of the currently selected metric.
    var threshold: Double { threshold(for: metric) }

    /// Strictly above the threshold → hot. Unknown readings are never hot.
    func isHot(_ value: Double?) -> Bool {
        guard let value else { return false }
        return value > threshold
    }

    func emoji(for value: Double?) -> String {
        let e = isHot(value) ? hotEmoji : coldEmoji
        return e.isEmpty ? (isHot(value) ? "🔥" : "❄️") : e
    }
}

// MARK: - Weather

enum TemperatureUnit: String, Codable, CaseIterable, Identifiable {
    case automatic, celsius, fahrenheit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:  return "Automatic (system)"
        case .celsius:    return "Celsius"
        case .fahrenheit: return "Fahrenheit"
        }
    }

    /// Resolves `automatic` using the system's measurement setting.
    var usesFahrenheit: Bool {
        switch self {
        case .celsius:    return false
        case .fahrenheit: return true
        case .automatic:  return Locale.current.measurementSystem == .us
        }
    }
}

/// How the weather condition is drawn in the circle.
enum WeatherIconStyle: String, Codable, CaseIterable, Identifiable {
    case emoji, symbol

    var id: String { rawValue }

    var title: String {
        switch self {
        case .emoji:  return "Emoji"
        case .symbol: return "Colour symbol"
        }
    }
}

/// A place chosen in Settings (from the city search).
struct WeatherPlace: Codable, Equatable {
    var name: String
    var latitude: Double
    var longitude: Double
}

enum WeatherLocationMode: String, Codable, CaseIterable, Identifiable {
    case current, place

    var id: String { rawValue }

    var title: String {
        switch self {
        case .current: return "Current location"
        case .place:   return "Chosen city"
        }
    }
}

/// Weather mode: the right circle shows the current condition (and temperature).
struct WeatherSettings: Codable, Equatable {
    var enabled = false
    var locationMode: WeatherLocationMode = .current
    var place: WeatherPlace?
    var unit: TemperatureUnit = .automatic
    var iconStyle: WeatherIconStyle = .emoji
    /// Draw the temperature under the condition icon (needs a circle of at least 36 pt).
    var showTemperature = true
    /// Minutes between forecast refreshes.
    var refreshMinutes: Double = 15
    /// Clicking the circle plays a full-screen animation of the current weather.
    var animateOnClick = true
    /// Length of that animation, in seconds (same range as the stats burst).
    var burstDuration: Double = 5

    static let refreshRange: ClosedRange<Double> = 5...60
}

struct AppSettings: Codable, Equatable {
    var overlayVisible = true
    var circles = CircleSettings()
    var preset: NotchPreset = .original
    var shape = NotchShapeParams()
    var notchColor = CodableColor.black
    var island = IslandSettings()
    var stats = StatsSettings()
    var weather = WeatherSettings()
    var launchAtLogin = false

    /// Shape to draw, or nil when the hardware notch is left untouched.
    /// Attached circles always need an overlay, so they fall back to "Rounded".
    var effectiveShape: NotchShapeParams? {
        if preset != .original { return shape }
        return circles.enabled && circles.attachToNotch ? NotchPreset.rounded.params : nil
    }
}

// MARK: - Store

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    static let didChange = Notification.Name("NotchOrbit.settingsDidChange")

    private let defaultsKey = "NotchOrbit.settings"
    private(set) var isFirstLaunch = false

    /// Transient UI state (not persisted).
    @Published var launchAtLoginError: String?

    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            scheduleSave()
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    private var saveWork: DispatchWorkItem?

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = Self.decodeLenient(data) {
            settings = decoded
        } else {
            settings = AppSettings()
            isFirstLaunch = UserDefaults.standard.data(forKey: defaultsKey) == nil
        }
    }

    /// Decodes stored JSON on top of the current defaults, so settings saved by
    /// an older version (missing newer keys) still load instead of being reset.
    private static func decodeLenient(_ data: Data) -> AppSettings? {
        guard let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaultsData = try? JSONEncoder().encode(AppSettings()),
              let defaults = try? JSONSerialization.jsonObject(with: defaultsData) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: deepMerge(defaults, stored)) else { return nil }
        return try? JSONDecoder().decode(AppSettings.self, from: merged)
    }

    private static func deepMerge(_ base: [String: Any], _ overlay: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in overlay {
            if let b = result[key] as? [String: Any], let o = value as? [String: Any] {
                result[key] = deepMerge(b, o)
            } else {
                result[key] = value
            }
        }
        return result
    }

    /// Back to factory defaults. Launch-at-login mirrors the real login item, so it is kept.
    func resetToDefaults() {
        var fresh = AppSettings()
        fresh.launchAtLogin = settings.launchAtLogin
        settings = fresh
    }

    /// Writes are coalesced: a slider drag changes the settings dozens of times a
    /// second, and each change used to encode and write the whole blob.
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Writes a pending change immediately (used on quit).
    func flush() {
        guard let saveWork else { return }
        saveWork.cancel()
        save()
    }

    private func save() {
        saveWork = nil
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
