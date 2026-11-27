import Accelerate
import AVFoundation
@preconcurrency import ScreenCaptureKit

/// A beat heard in whatever the Mac is playing.
struct Beat {
    enum Kind { case low, high }   // kick/bass hit, or snare/hi-hat/clap
    let kind: Kind
    let strength: Float            // 0...1, how hard it hit relative to the music around it
}

/// Listens to the system's audio output and reports beats as they happen.
///
/// The audio comes from ScreenCaptureKit, which is covered by the Screen
/// Recording permission the app already holds. Nothing is recorded or kept:
/// each buffer is reduced to two loudness numbers and dropped.
final class MusicListener: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let onBeat: (Beat) -> Void
    private let queue = DispatchQueue(label: "NotchOrbit.MusicListener")
    private var stream: SCStream?
    private var wanted = false
    private var detector: BeatDetector?

    /// `onBeat` is called on the main queue.
    init(onBeat: @escaping (Beat) -> Void) {
        self.onBeat = onBeat
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
        }
    }

    private func open() {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else { throw CocoaError(.featureUnsupported) }
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48_000
                config.channelCount = 2
                // A stream cannot be audio-only, so ask for the least video possible.
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 10, timescale: 1)
                config.showsCursor = false

                let stream = SCStream(
                    filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []),
                    configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
                // Unhandled video frames are logged as dropped; take them and ignore them.
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                try await stream.startCapture()
                queue.async { [self] in
                    if wanted {
                        self.stream = stream
                        debugLog("music: listening")
                    } else {
                        stream.stopCapture { _ in }
                    }
                }
            } catch {
                debugLog("music: could not start: \(error.localizedDescription)")
                retryLater()
            }
        }
    }

    /// The system ends the stream on sleep and on some display changes.
    private func retryLater() {
        queue.asyncAfter(deadline: .now() + 5) { [self] in
            if wanted && stream == nil { open() }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        debugLog("music: stream stopped: \(error.localizedDescription)")
        queue.async { [self] in
            if self.stream === stream { self.stream = nil }
            retryLater()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let format = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else { return }

        if detector?.sampleRate != format.mSampleRate {
            detector = BeatDetector(sampleRate: format.mSampleRate)
        }
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let channels = Int(format.mChannelsPerFrame)
        let frames = sampleBuffer.numSamples
        var mono = [Float](repeating: 0, count: frames)

        try? sampleBuffer.withAudioBufferList { list, _ in
            for buffer in list {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                if interleaved {
                    for channel in 0..<channels {
                        vDSP_vadd(mono, 1, data + channel, channels, &mono, 1, vDSP_Length(frames))
                    }
                } else {
                    let count = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                    vDSP_vadd(mono, 1, data, 1, &mono, 1, vDSP_Length(count))
                }
            }
        }
        var gain = 1 / Float(max(channels, 1))
        vDSP_vsmul(mono, 1, &gain, &mono, 1, vDSP_Length(frames))

        for beat in detector?.process(mono) ?? [] {
            if Debug.ripple {
                debugLog(String(format: "music: beat %@ strength=%.2f t=%.3f",
                                beat.kind == .low ? "low " : "high", beat.strength, CACurrentMediaTime()))
            }
            DispatchQueue.main.async { [onBeat] in onBeat(beat) }
        }
    }
}

/// Onset detection by spectral flux: a beat is a sudden rise in a band's
/// spectrum that stands well clear of how much that band has been moving
/// over the last second or so. Comparing against the recent past rather than
/// a fixed level makes it work the same at any volume.
private final class BeatDetector {
    let sampleRate: Double
    private let size = 2048              // ~43 ms window at 48 kHz
    private let hop = 512                // ~11 ms between looks
    private let setup: FFTSetup
    private let window: [Float]
    private var pending: [Float] = []
    private var previous: [Float]
    private var bands: [Band]
    private var time: Double = 0         // seconds of audio seen

    private struct Band {
        let kind: Beat.Kind
        let bins: Range<Int>
        let sensitivity: Float           // standard deviations above the mean
        let rest: Double                 // shortest gap between two beats, seconds
        var history: [Float] = []        // flux over the last ~1.5 s
        var lastBeat: Double = -1
        var lastFlux: Float = 0
    }

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        setup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: 2048, isHalfWindow: false)
        previous = [Float](repeating: 0, count: 1024)
        let binWidth = sampleRate / 2048
        func bins(_ low: Double, _ high: Double) -> Range<Int> {
            max(1, Int(low / binWidth))..<min(1024, Int(high / binWidth) + 1)
        }
        bands = [
            Band(kind: .low, bins: bins(40, 170), sensitivity: 2.0, rest: 0.19),
            Band(kind: .high, bins: bins(2_000, 9_000), sensitivity: 2.6, rest: 0.24),
        ]
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func process(_ samples: [Float]) -> [Beat] {
        pending += samples
        var beats: [Beat] = []
        var start = 0
        while pending.count - start >= size {
            beats += analyse(Array(pending[start..<start + size]))
            start += hop
            time += Double(hop) / sampleRate
        }
        pending.removeFirst(start)
        return beats
    }

    private func analyse(_ frame: [Float]) -> [Beat] {
        var windowed = vDSP.multiply(frame, window)
        var real = [Float](repeating: 0, count: size / 2)
        var imag = [Float](repeating: 0, count: size / 2)
        var magnitude = [Float](repeating: 0, count: size / 2)
        real.withUnsafeMutableBufferPointer { realPointer in
            imag.withUnsafeMutableBufferPointer { imagPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                windowed.withUnsafeMutableBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(size / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, 11, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitude, 1, vDSP_Length(size / 2))
            }
        }
        var normalise = 1 / Float(size)
        vDSP_vsmul(magnitude, 1, &normalise, &magnitude, 1, vDSP_Length(size / 2))

        var beats: [Beat] = []
        for index in bands.indices {
            var flux: Float = 0
            var level: Float = 0
            for bin in bands[index].bins {
                flux += max(0, magnitude[bin] - previous[bin])
                level += magnitude[bin]
            }
            let band = bands[index]
            let history = band.history
            if history.count >= 40 {
                let mean = vDSP.mean(history)
                let deviation = sqrt(max(0, vDSP.meanSquare(history) - mean * mean))
                let threshold = mean + band.sensitivity * deviation
                // Fire on the first look that clears the bar while still rising,
                // and only when the band is not near-silent.
                if flux > threshold, flux > mean * 2.2, flux > band.lastFlux,
                   level > 0.0004, time - band.lastBeat >= band.rest {
                    bands[index].lastBeat = time
                    let over = (flux - threshold) / max(threshold, 1e-9)
                    beats.append(Beat(kind: band.kind, strength: min(1, 0.45 + over * 0.35)))
                }
            }
            bands[index].lastFlux = flux
            bands[index].history.append(flux)
            if bands[index].history.count > 140 { bands[index].history.removeFirst() }
        }
        previous = magnitude
        return beats
    }
}
