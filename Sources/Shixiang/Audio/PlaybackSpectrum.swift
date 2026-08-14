import Accelerate
import Foundation
@preconcurrency import AVFoundation

private let playbackSpectrumBandCount = 64

/// Time-addressable FFT cache for the player bar. Each frame describes the actual frequency
/// balance of the source at that point in time, from low frequencies on the left to high on the
/// right. It is deliberately separate from the list's static amplitude waveform.
@MainActor
final class PlaybackSpectrum: ObservableObject {
    nonisolated static let bandCount = playbackSpectrumBandCount

    @Published private(set) var frames: [[Float]] = []
    @Published private(set) var duration: TimeInterval = 0
    private var requestedURL: URL?

    func load(url: URL?) async {
        requestedURL = url?.standardizedFileURL
        // Never leave the previous sound frozen in the player while a new (possibly long)
        // source is being analyzed. Clearing is cheap and makes cancellation visually honest.
        frames = []
        duration = 0
        guard let url else { return }
        let normalizedURL = url.standardizedFileURL
        do {
            let result = try await PlaybackSpectrumCache.shared.analyze(url: url)
            guard !Task.isCancelled, requestedURL == normalizedURL else { return }
            frames = result.frames
            duration = result.duration
        } catch is CancellationError {
            return
        } catch {
            frames = []; duration = 0
        }
    }

    func bands(at time: TimeInterval, liveFallback: PlaybackMeterSample? = nil) -> [Float] {
        guard !frames.isEmpty, duration > 0 else {
            return liveFallback.map(Self.liveFallbackBands) ?? Self.silentBands
        }
        let position = min(max(time / duration, 0), 1) * Double(max(0, frames.count - 1))
        // Do not interpolate between adjacent analyzer frames. Linear interpolation visually
        // turns a sharp kick into a soft crossfade. The analysis cadence is high enough that
        // selecting the nearest real FFT frame remains fluid while preserving transients.
        return frames[min(frames.count - 1, Int(position.rounded()))]
    }

    private nonisolated static let silentBands = Array(repeating: Float.zero, count: bandCount)

    /// AVAudioPlayer exposes level/peak data immediately, but not per-frequency data. While the
    /// exact FFT is still opening or decoding a complex file, spread that truthful live energy
    /// over a restrained fixed profile. The moment real frames arrive they replace this fallback.
    private nonisolated static func liveFallbackBands(_ sample: PlaybackMeterSample) -> [Float] {
        let energy = min(max(sample.energy, 0), 1)
        let peak = min(max(sample.peak, 0), 1)
        guard energy > 0.001 || peak > 0.001 else { return silentBands }

        return (0..<bandCount).map { index in
            let position = Float(index) / Float(max(1, bandCount - 1))
            let stereo = sample.left + (sample.right - sample.left) * position
            // A fixed, non-random contour keeps the temporary display lively without suggesting
            // that broadband meter data is already a measured frequency spectrum.
            let contour = 0.58
                + 0.18 * sin(position * .pi * 3.0)
                + 0.10 * sin(position * .pi * 11.0)
            let transient = peak * (0.08 + 0.10 * sin(position * .pi))
            return min(max(stereo * contour + energy * 0.18 + transient, 0), 1)
        }
    }
}

private struct PlaybackSpectrumResult: Sendable { let frames: [[Float]]; let duration: TimeInterval }

private actor PlaybackSpectrumCache {
    static let shared = PlaybackSpectrumCache()
    private var cache: [PlaybackSpectrumKey: PlaybackSpectrumResult] = [:]

    func analyze(url: URL) throws -> PlaybackSpectrumResult {
        let key = PlaybackSpectrumKey(url: url)
        if let cached = cache[key] { return cached }
        let result = try PlaybackSpectrumAnalyzer.analyze(url: url)
        if cache.count >= 12, let first = cache.keys.first { cache.removeValue(forKey: first) }
        cache[key] = result
        return result
    }
}

private struct PlaybackSpectrumKey: Hashable {
    let path: String; let modified: Date?; let size: Int?
    init(url: URL) {
        path = url.standardizedFileURL.path
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        modified = values?.contentModificationDate; size = values?.fileSize
    }
}

private enum PlaybackSpectrumAnalyzer {
    /// 4096 samples resolve bass fundamentals far more accurately than the former 1024-point
    /// overview (about 10.8 Hz per bin at 44.1 kHz instead of about 43 Hz).
    static let fftSize = 4_096
    static let bandCount = playbackSpectrumBandCount
    // The display itself updates at 30 Hz and selects the nearest analyzed frame. Twelve source
    // frames per second remain fluid after the view's ballistics, while bounding a long file to
    // 2,400 frames prevents thousands of seek/read/FFT operations and large main-actor publishes.
    static let analysisFramesPerSecond = 12.0
    static let maximumAnalysisFrames = 2_400

    static func analyze(url: URL) throws -> PlaybackSpectrumResult {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let total = max(Int64(0), file.length)
        guard total > 0, format.sampleRate > 0 else { return .init(frames: [], duration: 0) }
        let duration = Double(total) / format.sampleRate
        let count = max(
            1,
            min(maximumAnalysisFrames, Int((duration * analysisFramesPerSecond).rounded(.up)))
        )
        let hop = max(1, total / Int64(count))
        let fft = FFT(sampleRate: format.sampleRate)
        var frames: [[Float]] = []; frames.reserveCapacity(count)
        for index in 0..<count {
            try Task.checkCancellation()
            file.framePosition = min(max(0, total - Int64(fftSize)), Int64(index) * hop)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(fftSize)) else { continue }
            try file.read(into: buffer, frameCount: AVAudioFrameCount(fftSize))
            frames.append(fft.bands(from: buffer))
        }
        try Task.checkCancellation()
        return .init(frames: temporallySmoothed(frames), duration: duration)
    }

    /// A spectrum analyzer needs independent attack/release behavior. Fast attack preserves
    /// percussion and consonants; slower release makes movement readable without inventing or
    /// horizontally scrolling energy that is not present in the source.
    private static func temporallySmoothed(_ frames: [[Float]]) -> [[Float]] {
        guard let first = frames.first else { return [] }
        var previous = first
        return frames.map { frame in
            let smoothed = zip(previous, frame).map { old, incoming in
                // In this one-pole formula a larger response moves faster in both directions.
                // Attack is effectively immediate; release is deliberately quick enough for a
                // bass hit to fall before the next beat instead of remaining softly suspended.
                let response: Float = incoming >= old ? 1.0 : 0.58
                return old + (incoming - old) * response
            }
            previous = smoothed
            return smoothed
        }
    }

    private final class FFT {
        let sampleRate: Double; let half = fftSize / 2; let log2Size = vDSP_Length(Foundation.log2(Double(fftSize))); let setup: FFTSetup; let window: [Float]
        init(sampleRate: Double) {
            self.sampleRate = sampleRate; setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2))!
            var values = [Float](repeating: 0, count: fftSize); vDSP_hann_window(&values, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM)); window = values
        }
        deinit { vDSP_destroy_fftsetup(setup) }
        func bands(from buffer: AVAudioPCMBuffer) -> [Float] {
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return Array(repeating: 0, count: bandCount) }
            var frame = [Float](repeating: 0, count: fftSize); let length = min(Int(buffer.frameLength), fftSize); let channelCount = max(1, Int(buffer.format.channelCount))
            for i in 0..<length { frame[i] = (0..<channelCount).reduce(0) { $0 + channels[$1][i] } / Float(channelCount) }
            vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(fftSize))
            var real = [Float](repeating: 0, count: half), imaginary = [Float](repeating: 0, count: half), magnitude = [Float](repeating: 0, count: half)
            real.withUnsafeMutableBufferPointer { rp in imaginary.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { input in input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) } }
                vDSP_fft_zrip(setup, &split, 1, log2Size, FFTDirection(FFT_FORWARD)); vDSP_zvmags(&split, 1, &magnitude, 1, vDSP_Length(half))
            }}
            let minHz = 25.0, maxHz = min(20_000.0, sampleRate / 2)
            return (0..<bandCount).map { band in
                let low = minHz * pow(maxHz / minHz, Double(band) / Double(bandCount))
                let high = minHz * pow(maxHz / minHz, Double(band + 1) / Double(bandCount))
                let lower = max(1, min(half - 1, Int((low * Double(fftSize) / sampleRate).rounded(.down))))
                let upper = max(lower + 1, min(half, Int((high * Double(fftSize) / sampleRate).rounded(.up))))
                // vDSP_zvmags returns squared FFT magnitude. Convert it back to amplitude,
                // normalize by the FFT window length, then map real decibels into the UI range.
                // Without the FFT normalization nearly every ambience band appears saturated.
                let bandMagnitudes = magnitude[lower..<upper]
                let meanSquared = bandMagnitudes.reduce(0, +) / Float(max(1, upper - lower))
                let peakSquared = bandMagnitudes.max() ?? 0
                // Hann's coherent gain is approximately 0.5. Compensating for it keeps the
                // resulting value close to dBFS instead of an arbitrary FFT magnitude.
                let rmsAmplitude = sqrt(max(meanSquared, 0)) / (Float(fftSize) * 0.5)
                let peakAmplitude = sqrt(max(peakSquared, 0)) / (Float(fftSize) * 0.5)
                // A narrow bass fundamental or drum transient is easily diluted by the average
                // of a logarithmic band. Preserve part of its real peak while RMS remains the
                // main body of the display.
                let amplitude = max(rmsAmplitude, peakAmplitude * 0.72)
                let decibels = 20 * log10(max(Double(amplitude), 0.000_001))
                // Fixed -90...-18 dBFS display range. It intentionally does not normalize each
                // sound to full height, so quiet sources stay quiet and dynamics remain honest.
                return Float(min(1, max(0, (decibels + 90) / 72)))
            }
        }
    }
}
