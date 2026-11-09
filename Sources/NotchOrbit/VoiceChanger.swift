import AudioToolbox
import AVFoundation
import Combine
import CoreAudio
import os

// MARK: - Audio devices

/// An input or output device as CoreAudio lists it.
struct AudioDeviceInfo: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioDevices {
    static func inputs() -> [AudioDeviceInfo] { devices(scope: kAudioObjectPropertyScopeInput) }
    static func outputs() -> [AudioDeviceInfo] { devices(scope: kAudioObjectPropertyScopeOutput) }

    /// The system's current default input / output device.
    static func defaultDevice(input: Bool) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    static func name(of id: AudioDeviceID) -> String? { string(id, kAudioObjectPropertyName) }
    static func uid(of id: AudioDeviceID) -> String? { string(id, kAudioDevicePropertyDeviceUID) }

    /// Makes `id` the system's default input / output device.
    @discardableResult
    static func setDefaultDevice(_ id: AudioDeviceID, input: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = id
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                                UInt32(MemoryLayout<AudioDeviceID>.size), &device)
        if status != noErr { debugLog("[debug] voice changer: couldn't set default device", id, "status", status) }
        return status == noErr
    }

    /// Calls `handler` on the main queue whenever the system default input or output
    /// device changes. Keep the returned token alive for as long as you want callbacks.
    static func observeDefaultDevices(_ handler: @escaping () -> Void) -> () -> Void {
        var addresses = [
            AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain),
            AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain),
        ]
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        for i in addresses.indices {
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addresses[i], DispatchQueue.main, block)
        }
        return {
            for i in addresses.indices {
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addresses[i], DispatchQueue.main, block)
            }
        }
    }

    /// Names of virtual loopback drivers: whatever is played into them comes back out
    /// of their input side, which is how the changed voice becomes a "microphone".
    static let loopbackMarkers = ["BlackHole", "Loopback", "VB-Cable", "Soundflower"]

    static func isLoopback(_ device: AudioDeviceInfo) -> Bool {
        device.uid == virtualMicrophoneUID
            || loopbackMarkers.contains { device.name.localizedCaseInsensitiveContains($0) }
    }

    /// The device other apps see when "Use as Mic" is on. It's a public (system-wide)
    /// aggregate wrapping the loopback driver, so it carries NotchOrbit's own name in
    /// every microphone picker instead of "BlackHole 2ch". Public aggregates persist in
    /// coreaudiod even if the creating process dies, so look for an existing one first.
    static let virtualMicrophoneUID = "com.talha.NotchOrbit.microphone"
    static let virtualMicrophoneName = "NotchOrbit Microphone"

    static func virtualMicrophone() -> AudioDeviceInfo? {
        inputs().first { $0.uid == virtualMicrophoneUID }
    }

    /// Publishes the "NotchOrbit Microphone" device around `loopback` (or returns the
    /// one already published).
    static func publishVirtualMicrophone(wrapping loopback: AudioDeviceInfo) -> AudioDeviceInfo? {
        if let existing = virtualMicrophone() { return existing }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: virtualMicrophoneName,
            kAudioAggregateDeviceUIDKey: virtualMicrophoneUID,
            kAudioAggregateDeviceIsPrivateKey: 0,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: loopback.uid,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: loopback.uid]],
        ]
        var id = AudioObjectID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr, id != 0 else {
            debugLog("[debug] virtual microphone: couldn't publish device, status", status)
            return nil
        }
        // coreaudiod lists the new device a moment later.
        for _ in 0..<10 {
            if let made = virtualMicrophone() { return made }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return AudioDeviceInfo(id: id, uid: virtualMicrophoneUID, name: virtualMicrophoneName)
    }

    /// Removes the published device so it doesn't linger (silent) in other apps' pickers.
    static func unpublishVirtualMicrophone() {
        guard let device = virtualMicrophone() else { return }
        let status = AudioHardwareDestroyAggregateDevice(device.id)
        if status != noErr { debugLog("[debug] virtual microphone: couldn't remove device, status", status) }
    }

    /// The loopback device to route the changed voice through, if one is installed
    /// (it must have both an output and an input side). BlackHole 2ch is preferred.
    static func loopbackDevice() -> AudioDeviceInfo? {
        let inputUIDs = Set(inputs().map(\.uid))
        let candidates = outputs().filter { isLoopback($0) && inputUIDs.contains($0.uid) }
        return candidates.first { $0.name.contains("2ch") } ?? candidates.first
    }

    /// A private aggregate of one input and one output device. AVAudioEngine's I/O
    /// unit serves both directions from a single device, so to pair an arbitrary
    /// microphone with an arbitrary output the two are wrapped in an aggregate (the
    /// same thing CoreAudio does for the default pair). Destroy it with
    /// `AudioHardwareDestroyAggregateDevice` when done.
    static func makeAggregate(inputUID: String, outputUID: String) -> AudioDeviceID? {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NotchOrbit Voice",
            kAudioAggregateDeviceUIDKey: "com.talha.NotchOrbit.voice.\(ProcessInfo.processInfo.processIdentifier)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: inputUID, kAudioSubDeviceDriftCompensationKey: 1],
                [kAudioSubDeviceUIDKey: outputUID],
            ],
        ]
        var id = AudioObjectID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr, id != 0 else {
            debugLog("[debug] voice changer: couldn't create aggregate device, status", status)
            return nil
        }
        return id
    }

    private static func devices(scope: AudioObjectPropertyScope) -> [AudioDeviceInfo] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard channelCount(id, scope: scope) > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName),
                  // CoreAudio's own default-pair aggregates aren't meant to be picked,
                  // and the published NotchOrbit Microphone is only ever an input.
                  !name.hasPrefix("CADefaultDeviceAggregate"),
                  scope == kAudioObjectPropertyScopeInput || uid != virtualMicrophoneUID else { return nil }
            return AudioDeviceInfo(id: id, uid: uid, name: name)
        }
    }

    private static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

// MARK: - Effect recipes

/// Node settings that make up one `VoiceEffect`. Mixes are 0–100 %.
struct VoiceEffectParams {
    var pitch: Float = 0                                   // cents
    var distortionPreset: AVAudioUnitDistortionPreset?
    var distortionMix: Float = 0
    var distortionPreGain: Float = -6                      // dB
    var delayTime: TimeInterval = 0
    var delayFeedback: Float = 0                           // %
    var delayLowPass: Float = 15000                        // Hz
    var delayMix: Float = 0
    var reverbPreset: AVAudioUnitReverbPreset = .mediumRoom
    var reverbMix: Float = 0
    var highPass: Float?                                   // Hz; cuts lows below
    var lowPass: Float?                                    // Hz; cuts highs above
}

extension VoiceEffect {
    var params: VoiceEffectParams {
        switch self {
        case .normal:
            return VoiceEffectParams()
        case .deep:
            return VoiceEffectParams(pitch: -500, reverbPreset: .smallRoom, reverbMix: 12)
        case .chipmunk:
            return VoiceEffectParams(pitch: 700)
        case .robot:
            // A very short, strongly fed-back delay rings like a comb filter; the
            // decimator adds the synthetic crunch.
            return VoiceEffectParams(distortionPreset: .multiDecimated2, distortionMix: 30,
                                     delayTime: 0.008, delayFeedback: 72, delayLowPass: 4500, delayMix: 55)
        case .echo:
            return VoiceEffectParams(delayTime: 0.33, delayFeedback: 42, delayLowPass: 8000, delayMix: 45)
        case .cathedral:
            return VoiceEffectParams(reverbPreset: .cathedral, reverbMix: 65)
        case .radio:
            return VoiceEffectParams(distortionPreset: .speechRadioTower, distortionMix: 40,
                                     highPass: 500, lowPass: 3200)
        case .alien:
            return VoiceEffectParams(pitch: 300, distortionPreset: .speechAlienChatter, distortionMix: 35,
                                     delayTime: 0.05, delayFeedback: 30, delayLowPass: 6000, delayMix: 25)
        case .monster:
            return VoiceEffectParams(pitch: -1000, distortionPreset: .multiBrokenSpeaker, distortionMix: 20,
                                     reverbPreset: .largeHall, reverbMix: 25)
        case .underwater:
            return VoiceEffectParams(pitch: -150, reverbPreset: .largeRoom2, reverbMix: 35, lowPass: 450)
        }
    }
}

// MARK: - Engine

/// Single-channel FIFO between the input sink and the output source. Both sides run
/// on realtime audio threads; the critical sections are a short memcpy each.
final class VoiceRingBuffer {
    private let capacity: Int
    private let data: UnsafeMutablePointer<Float>
    private var readIndex = 0
    private var writeIndex = 0
    private var count = 0
    private var lock = os_unfair_lock()

    init(capacity: Int) {
        self.capacity = capacity
        data = .allocate(capacity: capacity)
        data.initialize(repeating: 0, count: capacity)
    }

    deinit { data.deallocate() }

    /// Appends `n` frames; when the FIFO is full the oldest frames are dropped so the
    /// latency stays bounded if the input clock runs ahead of the output clock.
    func write(_ source: UnsafePointer<Float>, count n: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        var n = n
        var src = source
        if n > capacity { src += n - capacity; n = capacity }
        if count + n > capacity {
            let drop = count + n - capacity
            readIndex = (readIndex + drop) % capacity
            count -= drop
        }
        let first = min(n, capacity - writeIndex)
        (data + writeIndex).update(from: src, count: first)
        if n > first { data.update(from: src + first, count: n - first) }
        writeIndex = (writeIndex + n) % capacity
        count += n
    }

    /// Fills `destination` with `n` frames, zero-padding when there aren't enough.
    func read(into destination: UnsafeMutablePointer<Float>, count n: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let available = min(n, count)
        let first = min(available, capacity - readIndex)
        destination.update(from: data + readIndex, count: first)
        if available > first { (destination + first).update(from: data, count: available - first) }
        if available < n { (destination + available).update(repeating: 0, count: n - available) }
        readIndex = (readIndex + available) % capacity
        count -= available
    }
}

/// Microphone → effects → output. Runs while the panel's Mic tab is open (and, if
/// "stay on" is set, keeps going with playthrough after the panel closes, or always
/// while "use as microphone" is on). The processed voice feeds a level meter and can
/// be recorded to an .m4a file.
///
/// Two engines. The *capture* engine owns the microphone: with echo cancellation on it
/// runs Apple's voice-processing I/O on the system default mic and output, which
/// removes whatever the speakers are playing (the other side of a call) from the mic
/// signal; otherwise a plain I/O unit on the chosen mic. It drops frames into a small
/// ring buffer. The *playback* engine pulls them out through the effect chain and
/// renders to the chosen output device — speakers / headphones for playthrough, or a
/// loopback device (BlackHole…) that other apps use as their microphone.
///
/// Why not one engine: AVAudioEngine refuses to wire the input node (even via a
/// mixer) into a converter-type unit such as AVAudioUnitTimePitch, a tap would add
/// 100 ms of latency, and the voice-processing unit only works on the default devices
/// while the effect output has to go somewhere else. The reverb on macOS only renders
/// stereo, so the chain is mono up to the reverb and stereo after it.
final class VoiceChanger: ObservableObject {
    private static var instance: VoiceChanger?

    /// Created on first use: the Mic tab, "Use as Mic", or the Settings window.
    static var shared: VoiceChanger {
        if let instance { return instance }
        let made = VoiceChanger()
        instance = made
        return made
    }

    /// The engine if anything has used it yet; callers that only need to tidy up or
    /// inspect state use this so they don't bring the audio system up themselves.
    static var current: VoiceChanger? { instance }

    enum State: Equatable {
        case idle, starting, running, failed(String)

        var message: String? {
            if case .failed(let text) = self { return text }
            return nil
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var isRecording = false
    private(set) var recordingStartedAt: Date?
    /// Name of the microphone currently in use (once running).
    @Published private(set) var inputName: String?
    /// True while the capture engine runs with Apple's echo cancellation.
    @Published private(set) var echoCancellationActive = false
    /// Levels of the processed voice (RMS and peak, linear 0…1), on the main thread, ~10×/s.
    var onLevel: ((Float, Float) -> Void)?

    var settings = MicSettings() {
        didSet {
            guard settings != oldValue else { return }
            applyParameters()
            let rebuild = settings.inputDeviceUID != oldValue.inputDeviceUID
                || settings.outputDeviceUID != oldValue.outputDeviceUID
                || settings.echoCancellation != oldValue.echoCancellation
            if rebuild, capture != nil {
                teardown()
                wantsRunning = false
                startIfNeeded()
            }
            reconcile()
        }
    }

    /// True while the panel's Mic tab is showing. Opening it "arms" the engine; with
    /// stay-on it keeps running after the tab closes until playthrough is switched off.
    var panelOpen = false {
        didSet {
            guard panelOpen != oldValue else { return }
            if panelOpen { armed = true }
            reconcile()
        }
    }

    /// Microphone side, feeding the ring buffer: either Apple's voice-processing I/O
    /// unit (echo cancellation) or an AVAudioEngine input node → sink.
    private enum Capture {
        case voiceProcessing(VoiceProcessingCapture)
        case engine(AVAudioEngine, aggregate: AudioDeviceID?)

        var isRunning: Bool {
            switch self {
            case .voiceProcessing(let capture): return capture.isRunning
            case .engine(let engine, _): return engine.isRunning
            }
        }

        func stop() {
            switch self {
            case .voiceProcessing(let capture):
                capture.stop()
            case .engine(let engine, let aggregate):
                engine.stop()
                if let aggregate { AudioHardwareDestroyAggregateDevice(aggregate) }
            }
        }
    }

    /// Effect side: source ← ring buffer → effects → wet → output device.
    private struct Playback {
        let engine: AVAudioEngine
        let source: AVAudioSourceNode
        let pitch = AVAudioUnitTimePitch()
        let distortion = AVAudioUnitDistortion()
        let eq = AVAudioUnitEQ(numberOfBands: 2)
        let delay = AVAudioUnitDelay()
        let reverb = AVAudioUnitReverb()
        /// Post-effects stereo mix; tapped for metering and recording.
        let wet = AVAudioMixerNode()
        let stereo: AVAudioFormat
        /// Private aggregate created for an output-only device (the I/O unit wants both sides).
        let aggregate: AudioDeviceID?
    }

    private var capture: Capture?
    private var playback: Playback?
    private var armed = false
    private var wantsRunning = false
    private let fileLock = NSLock()
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var loggedFirstBuffer = false
    private var storeSubscription: AnyCancellable?
    private var deviceListener: (() -> Void)?
    private var restartWork: DispatchWorkItem?
    /// AVAudioEngine stops itself when its device's configuration changes (sample rate,
    /// channel layout, Bluetooth re-negotiation…); these observers restart the chain.
    private var engineObservers: [NSObjectProtocol] = []
    /// The routing the running chain was built for: real mic UID, chosen output UID and
    /// the default output UID (which the plain capture engine pairs the mic with).
    private var activeRoute: (input: String, output: String?, defaultOutput: String?, pinnedCapture: Bool)?
    /// Debug counters (NOTCHORBIT_DEBUG): callbacks seen on the audio threads.
    private var sinkCalls = 0
    private var sourceCalls = 0
    private var tapCalls = 0

    /// Bounds the capture → playback latency at ~170 ms in the worst case (clock drift
    /// between two devices; the FIFO drops the oldest frames when it fills).
    private static let ringCapacity = 8192

    private static let deniedMessage = "Microphone access is off. Allow NotchOrbit in System Settings › Privacy & Security › Microphone."

    private init() {
        // Follow the Mic settings wherever they are changed (panel, Settings window, menu).
        storeSubscription = SettingsStore.shared.$settings.map(\.stats.mic).removeDuplicates()
            .sink { [weak self] in self?.settings = $0 }
        // FaceTime's microphone picker changes the *system* input device. If that lands on
        // the loopback device while we run, the capture must move to the real mic again.
        deviceListener = AudioDevices.observeDefaultDevices { [weak self] in self?.devicesChanged() }
    }

    private func devicesChanged() {
        // macOS moves the system input itself (AirPods connecting, a USB mic plugged in);
        // while "use as microphone" is on, calls must keep reading the loopback device.
        if settings.useAsMicrophone { VirtualMicrophone.reassertIfNeeded() }
        guard wantsRunning else { return }
        if let route = activeRoute, routeStillValid(route) {
            debugLog("[debug] voice changer: default audio device changed, routing unchanged, keeping the chain")
            resumePlaybackIfStopped()
            return
        }
        scheduleRestart()
    }

    /// Whether the chain built for `route` would be built the same way now.
    private func routeStillValid(_ route: (input: String, output: String?, defaultOutput: String?, pinnedCapture: Bool)) -> Bool {
        let inputs = AudioDevices.inputs()
        guard let realMic = Self.realMicrophone(settings: settings, inputs: inputs), realMic.uid == route.input else { return false }
        let outputUID = settings.outputDeviceUID.flatMap { uid in AudioDevices.outputs().first { $0.uid == uid }?.uid }
        guard outputUID == route.output else { return false }
        // The voice-processing capture follows the default output on its own (it's the echo
        // reference); the plain engine pairs the mic with it explicitly, so it must restart.
        if !route.pinnedCapture, AudioDevices.defaultDevice(input: false).flatMap(AudioDevices.uid(of:)) != route.defaultOutput { return false }
        return true
    }

    /// AVAudioEngine stops itself on a configuration change; start it again in place
    /// rather than rebuilding the capture (which would flip Bluetooth profiles again).
    private func resumePlaybackIfStopped() {
        guard let playback, !playback.engine.isRunning else { return }
        do {
            try playback.engine.start()
            debugLog("[debug] voice changer: playback engine resumed")
        } catch {
            debugLog("[debug] voice changer: playback engine couldn't resume:", error.localizedDescription)
            scheduleRestart()
        }
    }

    private func scheduleRestart() {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.wantsRunning else { return }
            debugLog("[debug] voice changer: default audio device changed, restarting capture")
            self.teardown()
            self.wantsRunning = false
            self.startIfNeeded()
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// The microphone to listen to: the chosen one, else the system default, but never a
    /// loopback device (that would be our own output). Falls back to any real input.
    static func realMicrophone(settings: MicSettings, inputs: [AudioDeviceInfo]) -> AudioDeviceInfo? {
        let chosen = settings.inputDeviceUID.flatMap { uid in inputs.first { $0.uid == uid } }
        let systemDefault = AudioDevices.defaultDevice(input: true).flatMap { id in inputs.first { $0.id == id } }
        let remembered = settings.restoreInputDeviceUID.flatMap { uid in inputs.first { $0.uid == uid } }
        return [chosen, systemDefault, remembered].compactMap { $0 }.first { !AudioDevices.isLoopback($0) }
            ?? inputs.first { !AudioDevices.isLoopback($0) }
    }

    // MARK: Lifecycle

    private func reconcile() {
        let should = panelOpen || (armed && settings.stayOn && settings.playthrough) || settings.useAsMicrophone
        if Debug.enabled {
            debugLog("[debug] voice changer reconcile: panelOpen", panelOpen, "armed", armed, "should", should, "wantsRunning", wantsRunning, "state", state)
        }
        if should {
            startIfNeeded()
        } else {
            armed = false
            stop()
        }
    }

    private func startIfNeeded() {
        guard !wantsRunning else { return }
        wantsRunning = true
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            fail("The microphone needs the app bundle. Build with build.sh and launch NotchOrbit.app.")
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startEngines()
        case .notDetermined:
            state = .starting
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.wantsRunning else { return }
                    if granted { self.startEngines() } else { self.fail(Self.deniedMessage) }
                }
            }
        default:
            fail(Self.deniedMessage)
        }
    }

    /// Starts listening as if the panel had been opened (used when "use as microphone"
    /// is on at launch, so calls get the changed voice without opening the panel).
    func startInBackground() {
        armed = true
        reconcile()
    }

    /// Stops listening, finishing any recording first.
    func stop() {
        guard wantsRunning || capture != nil || playback != nil else { return }
        if Debug.enabled { debugLog("[debug] voice changer stop") }
        wantsRunning = false
        teardown()
        state = .idle
        inputName = nil
        echoCancellationActive = false
    }

    private func teardown() {
        _ = finishRecording()
        if let playback {
            playback.wet.removeTap(onBus: 0)
            playback.engine.stop()
            if let aggregate = playback.aggregate { AudioHardwareDestroyAggregateDevice(aggregate) }
        }
        capture?.stop()
        engineObservers.forEach(NotificationCenter.default.removeObserver)
        engineObservers = []
        activeRoute = nil
        playback = nil
        capture = nil
        scratch = nil
    }

    private func watchConfiguration(of engine: AVAudioEngine, label: String) {
        let token = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                           queue: .main) { [weak self] _ in
            guard let self, self.wantsRunning else { return }
            debugLog("[debug] voice changer:", label, "engine configuration changed")
            if engine === self.playback?.engine { self.resumePlaybackIfStopped() } else { self.scheduleRestart() }
        }
        engineObservers.append(token)
    }

    private func fail(_ message: String) {
        teardown()
        state = .failed(message)
        echoCancellationActive = false
        debugLog("[debug] voice changer:", message)
    }

    private func startEngines() {
        state = .starting
        let inputs = AudioDevices.inputs()
        let outputs = AudioDevices.outputs()
        let outputID = settings.outputDeviceUID.flatMap { uid in outputs.first { $0.uid == uid }?.id }
        let defaultInput = AudioDevices.defaultDevice(input: true)
        let defaultOutput = AudioDevices.defaultDevice(input: false)
        let ring = VoiceRingBuffer(capacity: Self.ringCapacity)

        // ---- Capture ----
        guard let realMic = Self.realMicrophone(settings: settings, inputs: inputs) else {
            fail("No microphone found on this Mac.")
            return
        }
        var capture: Capture?
        var captureRate: Double = 0
        var pendingVoiceProcessing: VoiceProcessingCapture?
        if settings.echoCancellation {
            // Apple's voice processing: the echo reference is the system default output.
            // The input side is pinned to the real mic, because the system default input
            // is the loopback device while "use as microphone" is on.
            let pin = realMic.id != defaultInput ? realMic.id : nil
            if let vp = VoiceProcessingCapture(ring: ring, inputDevice: pin, counter: { [weak self] in self?.sinkCalls += 1 }) {
                capture = .voiceProcessing(vp)
                captureRate = VoiceProcessingCapture.sampleRate
                pendingVoiceProcessing = vp
            } else {
                debugLog("[debug] voice changer: voice processing unavailable, capturing without echo cancellation")
            }
        }
        if capture == nil {
            let captureEngine = AVAudioEngine()
            var captureAggregate: AudioDeviceID?
            if realMic.id != defaultInput, let outputUID = defaultOutput.flatMap(AudioDevices.uid(of:)) {
                // The I/O unit takes one device for both directions: pair the real mic
                // with the default output in a private aggregate.
                if realMic.uid == outputUID {
                    Self.setDevice(realMic.id, on: captureEngine.inputNode)
                } else if let made = AudioDevices.makeAggregate(inputUID: realMic.uid, outputUID: outputUID) {
                    captureAggregate = made
                    Self.setDevice(made, on: captureEngine.inputNode)
                }
            }
            let input = captureEngine.inputNode
            let hardware = input.outputFormat(forBus: 0)
            guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
                if let captureAggregate { AudioHardwareDestroyAggregateDevice(captureAggregate) }
                fail("That microphone isn't available right now.")
                return
            }
            let channels = Int(hardware.channelCount)
            let interleaved = hardware.isInterleaved && channels > 1
            let scratch = UnsafeMutablePointer<Float>.allocate(capacity: Self.ringCapacity)
            self.scratch = scratch
            // Takes the first channel of whatever the microphone delivers.
            let sink = AVAudioSinkNode { [weak self] _, frameCount, list -> OSStatus in
                self?.sinkCalls += 1
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
                guard let first = buffers.first, let samples = first.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                let n = min(Int(frameCount), VoiceChanger.ringCapacity)
                if interleaved {
                    for i in 0..<n { scratch[i] = samples[i * channels] }
                    ring.write(scratch, count: n)
                } else {
                    ring.write(samples, count: n)
                }
                return noErr
            }
            captureEngine.attach(sink)
            captureEngine.connect(input, to: sink, format: hardware)
            captureEngine.mainMixerNode.outputVolume = 0   // this engine never plays anything
            capture = .engine(captureEngine, aggregate: captureAggregate)
            captureRate = hardware.sampleRate
        }
        guard let capture,
              let mono = AVAudioFormat(standardFormatWithSampleRate: captureRate, channels: 1),
              let stereo = AVAudioFormat(standardFormatWithSampleRate: captureRate, channels: 2) else {
            fail("No microphone found on this Mac.")
            return
        }
        let voiceProcessing = pendingVoiceProcessing != nil
        let captureName: String? = realMic.name

        // ---- Playback engine ----
        let playEngine = AVAudioEngine()
        var playAggregate: AudioDeviceID?
        if let outputID, outputID != defaultOutput, let outputUID = AudioDevices.uid(of: outputID) {
            if inputs.contains(where: { $0.id == outputID }) {
                // Has an input side too (loopback devices, USB interfaces): usable as is.
                Self.setDevice(outputID, on: playEngine.outputNode)
            } else if let inputUID = defaultInput.flatMap(AudioDevices.uid(of:)),
                      let made = AudioDevices.makeAggregate(inputUID: inputUID, outputUID: outputUID) {
                playAggregate = made
                Self.setDevice(made, on: playEngine.outputNode)
            }
        }
        let source = AVAudioSourceNode(format: mono) { [weak self] _, _, frameCount, list -> OSStatus in
            self?.sourceCalls += 1
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard let first = buffers.first, let samples = first.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            ring.read(into: samples, count: Int(frameCount))
            return noErr
        }
        let playback = Playback(engine: playEngine, source: source, stereo: stereo, aggregate: playAggregate)
        for node in [playback.source, playback.pitch, playback.distortion, playback.eq, playback.delay, playback.reverb, playback.wet] as [AVAudioNode] {
            playEngine.attach(node)
        }
        playEngine.connect(playback.source, to: playback.pitch, format: mono)
        playEngine.connect(playback.pitch, to: playback.distortion, format: mono)
        playEngine.connect(playback.distortion, to: playback.eq, format: mono)
        playEngine.connect(playback.eq, to: playback.delay, format: mono)
        playEngine.connect(playback.delay, to: playback.reverb, format: mono)
        playEngine.connect(playback.reverb, to: playback.wet, format: stereo)
        playEngine.connect(playback.wet, to: playEngine.mainMixerNode, format: stereo)
        playback.eq.bands[0].filterType = .highPass
        playback.eq.bands[1].filterType = .lowPass
        playback.wet.installTap(onBus: 0, bufferSize: 4096, format: stereo) { [weak self] buffer, _ in
            self?.tapCalls += 1
            self?.process(buffer)
        }

        self.capture = capture
        self.playback = playback
        loggedFirstBuffer = false
        applyParameters()
        watchConfiguration(of: playEngine, label: "playback")
        if case .engine(let engine, _) = capture { watchConfiguration(of: engine, label: "capture") }

        do {
            if case .engine(let engine, _) = capture {
                engine.prepare()
                try engine.start()
            }
            playEngine.prepare()
            try playEngine.start()
        } catch {
            fail("Microphone unavailable: \(error.localizedDescription)")
            return
        }
        if let vp = pendingVoiceProcessing {
            // The voice-processing unit needs a moment after the device is pinned, and its
            // input side occasionally never comes up; `start` waits, verifies and retries.
            vp.start { [weak self] ok in
                if Debug.enabled {
                    debugLog("[debug] voice processing start completion:", ok, "current:", self?.playback?.engine === playEngine)
                }
                guard let self, self.playback?.engine === playEngine else { return }   // superseded
                if ok {
                    self.state = .running
                } else {
                    self.fail("Echo cancellation couldn't start on \(realMic.name). Turn it off in Settings › System Stats › Mic tab to use the plain capture.")
                }
            }
        } else {
            state = .running
        }
        echoCancellationActive = voiceProcessing
        inputName = captureName ?? "Microphone"
        activeRoute = (input: realMic.uid, output: outputID.flatMap(AudioDevices.uid(of:)),
                       defaultOutput: defaultOutput.flatMap(AudioDevices.uid(of:)), pinnedCapture: voiceProcessing)
        if Debug.enabled {
            debugLog("[debug] voice changer running:", inputName ?? "?", "→", outputID.flatMap(AudioDevices.name(of:)) ?? "default output",
                     "rate:", captureRate, "effect:", settings.effect.rawValue, "playthrough:", settings.playthrough,
                     "echo cancellation:", voiceProcessing)
            sinkCalls = 0; sourceCalls = 0; tapCalls = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                debugLog("[debug] voice changer after 1.5 s: sink", self.sinkCalls, "source", self.sourceCalls, "tap", self.tapCalls,
                         "capture running:", self.capture?.isRunning ?? false, "playback running:", self.playback?.engine.isRunning ?? false,
                         "state:", self.state)
            }
        }
    }

    /// Scratch space for de-interleaving in the sink; lives as long as the capture engine.
    private var scratch: UnsafeMutablePointer<Float>? {
        didSet { oldValue?.deallocate() }
    }

    private static func setDevice(_ id: AudioDeviceID, on node: AVAudioIONode) {
        guard let unit = node.audioUnit else { return }
        var device = id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr { debugLog("[debug] voice changer: couldn't select device", id, "status", status) }
    }

    // MARK: Parameters

    /// Pushes the current effect, fine-tuning and playthrough volume into the nodes.
    private func applyParameters() {
        guard let chain = playback else { return }
        let p = settings.effect.params
        let amount = Float(settings.amount / 100)
        let cents = p.pitch * amount + Float(settings.pitch) * 100
        chain.pitch.pitch = cents
        chain.pitch.bypass = abs(cents) < 1

        if let preset = p.distortionPreset, p.distortionMix * amount > 0.5 {
            chain.distortion.loadFactoryPreset(preset)
            chain.distortion.preGain = p.distortionPreGain
            chain.distortion.wetDryMix = p.distortionMix * amount
            chain.distortion.bypass = false
        } else {
            chain.distortion.bypass = true
        }

        let delayMix = p.delayMix * amount
        chain.delay.delayTime = p.delayTime
        chain.delay.feedback = p.delayFeedback * amount
        chain.delay.lowPassCutoff = p.delayLowPass
        chain.delay.wetDryMix = delayMix
        chain.delay.bypass = delayMix < 0.5

        let reverbMix = p.reverbMix * amount
        chain.reverb.loadFactoryPreset(p.reverbPreset)
        chain.reverb.wetDryMix = reverbMix
        chain.reverb.bypass = reverbMix < 0.5

        let high = chain.eq.bands[0]
        high.frequency = p.highPass ?? 20
        high.bypass = p.highPass == nil || amount < 0.05
        let low = chain.eq.bands[1]
        low.frequency = p.lowPass ?? 20000
        low.bypass = p.lowPass == nil || amount < 0.05

        chain.engine.mainMixerNode.outputVolume = settings.playthrough ? Float(settings.volume / 100) : 0
    }

    // MARK: Audio thread

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        let samples = data[0]
        var sum: Float = 0
        var maxAbs: Float = 0
        for i in 0..<n {
            let v = samples[i]
            sum += v * v
            maxAbs = max(maxAbs, abs(v))
        }
        let rms = (sum / Float(n)).squareRoot()
        fileLock.lock()
        if let file {
            do { try file.write(from: buffer) } catch { debugLog("[debug] voice recording write failed:", error) }
        }
        fileLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.loggedFirstBuffer, Debug.enabled {
                self.loggedFirstBuffer = true
                debugLog("[debug] voice changer first buffer:", n, "frames, rms", rms, "peak", maxAbs)
            }
            self.onLevel?(rms, maxAbs)
        }
    }

    // MARK: Recording

    /// Starts writing the processed voice to a new .m4a in `directory`.
    func startRecording(into directory: URL) -> Error? {
        guard state == .running, let playback else {
            return NSError(domain: "NotchOrbit", code: 1,
                           userInfo: [NSLocalizedDescriptionKey: "The microphone isn't running yet"])
        }
        guard !isRecording else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let url = directory.appendingPathComponent("NotchOrbit Voice \(formatter.string(from: Date())).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: playback.stereo.sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let newFile = try AVAudioFile(forWriting: url, settings: settings)
            fileLock.lock()
            file = newFile
            fileURL = url
            fileLock.unlock()
            recordingStartedAt = Date()
            isRecording = true
            return nil
        } catch {
            return error
        }
    }

    /// Stops the recording and returns the file it was written to.
    @discardableResult
    func finishRecording() -> URL? {
        fileLock.lock()
        let url = fileURL
        file = nil        // closing the AVAudioFile flushes it
        fileURL = nil
        fileLock.unlock()
        if isRecording {
            isRecording = false
            recordingStartedAt = nil
        }
        return url
    }
}

// MARK: - Voice-processing capture

/// Apple's VoiceProcessingIO audio unit driven directly: echo cancellation, noise
/// suppression and gain control on the system default microphone, with the system
/// default output as the echo reference (it cancels audio played by *other* processes
/// too, which is what a call needs). Input frames are rendered in the unit's input
/// callback and written to the ring buffer; the output renders silence.
///
/// AVAudioEngine's `setVoiceProcessingEnabled` wraps the same unit but, on this
/// hardware, exposes the raw multi-channel mic stream and then fails to initialise the
/// output; the bare unit with explicit mono client formats works.
final class VoiceProcessingCapture {
    static let sampleRate: Double = 48000
    /// Time the unit gets after the input device is pinned before it is initialised;
    /// without it the input side races the device switch and never starts.
    private static let settleDelay: TimeInterval = 0.6
    private static let startAttempts = 3

    private var unit: AudioUnit?
    private let ring: VoiceRingBuffer
    private let counter: () -> Void
    private let inputDevice: AudioDeviceID?
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchCapacity = 8192
    private var inputCallbacks = 0
    private(set) var isRunning = false
    private var cancelled = false

    /// Creates the unit and pins its input device. Configuration and start happen in `start`.
    init?(ring: VoiceRingBuffer, inputDevice: AudioDeviceID?, counter: @escaping () -> Void) {
        self.ring = ring
        self.counter = counter
        self.inputDevice = inputDevice
        scratch = .allocate(capacity: scratchCapacity)
        guard let unit = Self.makeUnit(inputDevice: inputDevice) else { scratch.deallocate(); return nil }
        self.unit = unit
    }

    deinit {
        stop()
        if let unit { AudioComponentInstanceDispose(unit) }
        scratch.deallocate()
    }

    private static func makeUnit(inputDevice: AudioDeviceID?) -> AudioUnit? {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                                    componentSubType: kAudioUnitSubType_VoiceProcessingIO,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple,
                                                    componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { return nil }
        var instance: AudioUnit?
        guard AudioComponentInstanceNew(component, &instance) == noErr, let unit = instance else { return nil }
        var enabled: UInt32 = 1
        let size = UInt32(MemoryLayout<UInt32>.size)
        var steps: [(String, OSStatus)] = [
            ("enable input", AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled, size)),
            ("enable output", AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enabled, size)),
        ]
        if let inputDevice {
            var device = inputDevice
            // The unit keeps separate devices per scope: global = output (echo reference,
            // left on the system default), input scope element 1 = the microphone.
            steps.append(("pin input device", AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Input, 1,
                                                                   &device, UInt32(MemoryLayout<AudioDeviceID>.size))))
        }
        if let failed = steps.first(where: { $0.1 != noErr }) {
            debugLog("[debug] voice processing: \(failed.0) failed, status \(failed.1)")
            AudioComponentInstanceDispose(unit)
            return nil
        }
        return unit
    }

    /// Formats, callbacks and initialisation; done after the settle delay.
    private func configure(_ unit: AudioUnit) -> Bool {
        var format = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let me = Unmanaged.passUnretained(self).toOpaque()
        var inputCallback = AURenderCallbackStruct(inputProc: { refCon, flags, timestamp, bus, frames, _ -> OSStatus in
            Unmanaged<VoiceProcessingCapture>.fromOpaque(refCon).takeUnretainedValue().render(flags: flags, timestamp: timestamp, bus: bus, frames: frames)
        }, inputProcRefCon: me)
        var renderCallback = AURenderCallbackStruct(inputProc: { _, flags, _, _, _, list -> OSStatus in
            if let list { for buffer in UnsafeMutableAudioBufferListPointer(list) { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) } }
            flags.pointee.insert(.unitRenderAction_OutputIsSilence)
            return noErr
        }, inputProcRefCon: nil)
        let callbackSize = UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        let steps: [(String, OSStatus)] = [
            ("input format", AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, formatSize)),
            ("output format", AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, formatSize)),
            ("input callback", AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &inputCallback, callbackSize)),
            ("render callback", AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &renderCallback, callbackSize)),
            ("initialize", AudioUnitInitialize(unit)),
        ]
        if let failed = steps.first(where: { $0.1 != noErr }) {
            debugLog("[debug] voice processing: \(failed.0) failed, status \(failed.1)")
            return false
        }
        return true
    }

    /// Waits for the device to settle, starts, and checks that input frames actually
    /// arrive; if they don't, the unit is rebuilt and tried again. `completion` gets the
    /// final outcome on the main thread.
    func start(completion: @escaping (Bool) -> Void) {
        attempt(1, completion: completion)
    }

    private func attempt(_ number: Int, completion: @escaping (Bool) -> Void) {
        guard !cancelled, let unit else { return completion(false) }
        if Debug.enabled { debugLog("[debug] voice processing attempt", number, "pinned:", inputDevice as Any) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
            guard let self, !self.cancelled, self.unit == unit else {
                if Debug.enabled { debugLog("[debug] voice processing attempt", number, "abandoned (cancelled:", self?.cancelled as Any, ")") }
                return completion(false)
            }
            guard self.configure(unit), AudioOutputUnitStart(unit) == noErr else { return self.retry(number, completion: completion) }
            self.isRunning = true
            self.inputCallbacks = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, !self.cancelled, self.unit == unit else { return completion(false) }
                if self.inputCallbacks > 0 {
                    completion(true)
                } else {
                    debugLog("[debug] voice processing: no input after start (attempt \(number))")
                    self.retry(number, completion: completion)
                }
            }
        }
    }

    private func retry(_ number: Int, completion: @escaping (Bool) -> Void) {
        stop()
        if let unit { AudioComponentInstanceDispose(unit) }
        unit = nil
        guard number < Self.startAttempts, let fresh = Self.makeUnit(inputDevice: inputDevice) else { return completion(false) }
        unit = fresh
        attempt(number + 1, completion: completion)
    }

    func stop() {
        cancelled = true
        guard let unit, isRunning else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        isRunning = false
    }

    /// Input callback (realtime thread): pull the processed mic frames and queue them.
    private func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timestamp: UnsafePointer<AudioTimeStamp>,
                        bus: UInt32, frames: UInt32) -> OSStatus {
        guard let unit else { return noErr }
        let n = min(Int(frames), scratchCapacity)
        let buffer = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * MemoryLayout<Float>.size), mData: UnsafeMutableRawPointer(scratch))
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)
        let status = AudioUnitRender(unit, flags, timestamp, bus, UInt32(n), &list)
        inputCallbacks += 1
        counter()
        if status == noErr { ring.write(scratch, count: n) }
        return status
    }
}

// MARK: - Virtual microphone

/// Turns the changed voice into a microphone for other apps (FaceTime, Teams, Zoom,
/// WhatsApp…): the playback engine renders into a loopback driver such as BlackHole, a
/// system-wide "NotchOrbit Microphone" device is published around it, and that device is
/// made the system default input (FaceTime can only use the system default; apps with
/// their own picker list it by name or offer "same as system"). NotchOrbit keeps
/// capturing the real microphone explicitly, so the loopback device never feeds back.
enum VirtualMicrophone {
    enum Failure: LocalizedError {
        case noLoopbackDevice, noMicrophone, couldNotPublish, couldNotSwitch

        var errorDescription: String? {
            switch self {
            case .noLoopbackDevice:
                return "Needs a virtual audio device. Install BlackHole from Settings › System Stats › Mic tab."
            case .noMicrophone:
                return "No real microphone to listen to."
            case .couldNotPublish:
                return "macOS wouldn't create the “\(AudioDevices.virtualMicrophoneName)” device."
            case .couldNotSwitch:
                return "macOS wouldn't change the default microphone."
            }
        }
    }

    static var isOn: Bool { SettingsStore.shared.settings.stats.mic.useAsMicrophone }

    /// The device other apps pick as the microphone: the published "NotchOrbit
    /// Microphone" while the feature is on, otherwise the loopback driver it would wrap.
    static var device: AudioDeviceInfo? { AudioDevices.virtualMicrophone() ?? AudioDevices.loopbackDevice() }

    /// What the user has to do in the other app once this is on.
    static func instructions(deviceName: String) -> String {
        "FaceTime uses it automatically. In Teams, WhatsApp, Zoom, Slack… pick “\(deviceName)” (or “Same as system”) as the microphone."
    }

    /// Routes the changed voice into the loopback driver, publishes the NotchOrbit
    /// Microphone device around it, makes that the system microphone and keeps the
    /// engine running.
    static func enable() throws {
        guard let loopback = AudioDevices.loopbackDevice() else { throw Failure.noLoopbackDevice }
        let store = SettingsStore.shared
        var mic = store.settings.stats.mic
        let inputs = AudioDevices.inputs()
        let currentDefault = AudioDevices.defaultDevice(input: true).flatMap { id in inputs.first { $0.id == id } }
        guard let realMic = VoiceChanger.realMicrophone(settings: mic, inputs: inputs) else { throw Failure.noMicrophone }
        guard let published = AudioDevices.publishVirtualMicrophone(wrapping: loopback) else { throw Failure.couldNotPublish }
        if let currentDefault, !AudioDevices.isLoopback(currentDefault) { mic.restoreInputDeviceUID = currentDefault.uid }
        if mic.restoreInputDeviceUID == nil { mic.restoreInputDeviceUID = realMic.uid }
        if currentDefault?.id != published.id {
            guard AudioDevices.setDefaultDevice(published.id, input: true) else { throw Failure.couldNotSwitch }
        }
        mic.outputDeviceUID = loopback.uid
        mic.playthrough = true
        mic.useAsMicrophone = true
        mic.loopbackWasUsed = true
        store.settings.stats.mic = mic
        VoiceChanger.shared.startInBackground()
    }

    /// Puts the real microphone back as the system default and stops routing into the
    /// loopback device.
    static func disable() {
        let store = SettingsStore.shared
        var mic = store.settings.stats.mic
        restoreDefaultInput(mic)
        AudioDevices.unpublishVirtualMicrophone()
        mic.useAsMicrophone = false
        mic.playthrough = false
        mic.restoreInputDeviceUID = nil
        if mic.outputDeviceUID.map({ uid in AudioDevices.outputs().first { $0.uid == uid }.map(AudioDevices.isLoopback) ?? false }) ?? false {
            mic.outputDeviceUID = nil
        }
        store.settings.stats.mic = mic
    }

    /// If macOS (or the user) moved the system input off the loopback device while the
    /// feature is on, remember the new real mic and put the loopback device back.
    static func reassertIfNeeded() {
        guard isOn, let loopback = AudioDevices.loopbackDevice(),
              let published = AudioDevices.publishVirtualMicrophone(wrapping: loopback) else { return }
        let inputs = AudioDevices.inputs()
        guard let current = AudioDevices.defaultDevice(input: true).flatMap({ id in inputs.first { $0.id == id } }),
              current.id != published.id else { return }
        let store = SettingsStore.shared
        if !AudioDevices.isLoopback(current) { store.settings.stats.mic.restoreInputDeviceUID = current.uid }
        AudioDevices.setDefaultDevice(published.id, input: true)
        debugLog("[debug] virtual microphone: system input moved to", current.name, "→ back to", published.name)
    }

    /// At launch: if the feature was left on, make the loopback device the system mic
    /// again and start listening, so calls work without opening the panel.
    static func resumeAtLaunch() {
        let mic = SettingsStore.shared.settings.stats.mic
        if mic.useAsMicrophone {
            do { try enable() } catch {
                debugLog("[debug] virtual microphone couldn't resume:", error.localizedDescription)
                SettingsStore.shared.settings.stats.mic.useAsMicrophone = false
                restoreDefaultInput(SettingsStore.shared.settings.stats.mic)
            }
        } else if mic.loopbackWasUsed {
            // Not in use, but it has been: never leave the system mic on a loopback device
            // (a crash while it was on), and don't leave a silent NotchOrbit Microphone in
            // other apps' pickers. Anyone who never used the feature skips this, so the
            // audio HAL isn't loaded at launch.
            restoreDefaultInput(mic)
            AudioDevices.unpublishVirtualMicrophone()
        }
    }

    /// At quit: give the real microphone back to the system (the feature stays enabled
    /// in settings and resumes at the next launch).
    static func restoreForQuit() {
        let mic = SettingsStore.shared.settings.stats.mic
        guard mic.useAsMicrophone || mic.loopbackWasUsed else { return }
        restoreDefaultInput(mic)
        AudioDevices.unpublishVirtualMicrophone()
    }

    /// If the system default input is a loopback device, put a real microphone back.
    static func restoreDefaultInput(_ mic: MicSettings) {
        let inputs = AudioDevices.inputs()
        let current = AudioDevices.defaultDevice(input: true).flatMap { id in inputs.first { $0.id == id } }
        guard current.map(AudioDevices.isLoopback) ?? false else { return }
        guard let target = VoiceChanger.realMicrophone(settings: mic, inputs: inputs) else { return }
        AudioDevices.setDefaultDevice(target.id, input: true)
        debugLog("[debug] virtual microphone: system input was", current?.name ?? "?", "→ set back to", target.name)
    }
}
