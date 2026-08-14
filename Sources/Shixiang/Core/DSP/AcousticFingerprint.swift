import Accelerate
import Foundation

struct AcousticAnalysisProgress: Identifiable, Equatable, Sendable {
    let id: UUID
    let completed: Int
    let total: Int
    let failed: Int
    let currentName: String?

    var fraction: Double? {
        guard total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

/// A compact, completely local description of how a sound behaves. The vector contains
/// no recoverable audio samples; it is small enough to compare tens of thousands of rows
/// in memory without touching the source files again.
struct AcousticFingerprint: Codable, Hashable, Sendable {
    static let currentVersion = 1

    let version: Int
    let spectralBands: [Float]
    let spectralCentroid: Float
    let spectralRolloff: Float
    let spectralFlatness: Float
    let zeroCrossingRate: Float
    let crestFactor: Float
    let transientDensity: Float
    let dynamicRange: Float
    let analyzedDuration: TimeInterval

    init(
        version: Int = currentVersion,
        spectralBands: [Float],
        spectralCentroid: Float,
        spectralRolloff: Float,
        spectralFlatness: Float,
        zeroCrossingRate: Float,
        crestFactor: Float,
        transientDensity: Float,
        dynamicRange: Float,
        analyzedDuration: TimeInterval
    ) {
        self.version = version
        self.spectralBands = Array(spectralBands.prefix(12))
            + Array(repeating: 0, count: max(0, 12 - spectralBands.count))
        self.spectralCentroid = spectralCentroid
        self.spectralRolloff = spectralRolloff
        self.spectralFlatness = spectralFlatness
        self.zeroCrossingRate = zeroCrossingRate
        self.crestFactor = crestFactor
        self.transientDensity = transientDensity
        self.dynamicRange = dynamicRange
        self.analyzedDuration = analyzedDuration
    }

    /// Perceptual similarity in 0...1. Spectral shape carries most of the weight while
    /// transient and dynamic behavior keep a click from matching a sustained pad merely
    /// because both are bright.
    func similarity(to other: Self) -> Double {
        guard version == other.version else { return 0 }
        let bandCount = min(spectralBands.count, other.spectralBands.count)
        guard bandCount > 0 else { return 0 }

        var bandDistance = 0.0
        for index in 0..<bandCount {
            let difference = Double(spectralBands[index] - other.spectralBands[index])
            bandDistance += difference * difference
        }
        bandDistance = sqrt(bandDistance / Double(bandCount))

        func distance(_ lhs: Float, _ rhs: Float, scale: Double = 1) -> Double {
            min(1, abs(Double(lhs - rhs)) / max(scale, 0.000_1))
        }

        let weightedDistance = min(1,
            0.48 * min(1, bandDistance / 0.28)
                + 0.13 * distance(spectralCentroid, other.spectralCentroid, scale: 0.32)
                + 0.08 * distance(spectralRolloff, other.spectralRolloff, scale: 0.35)
                + 0.07 * distance(spectralFlatness, other.spectralFlatness, scale: 0.45)
                + 0.07 * distance(zeroCrossingRate, other.zeroCrossingRate, scale: 0.16)
                + 0.07 * distance(crestFactor, other.crestFactor, scale: 0.45)
                + 0.06 * distance(transientDensity, other.transientDensity, scale: 0.35)
                + 0.04 * distance(dynamicRange, other.dynamicRange, scale: 0.45)
        )
        return max(0, 1 - weightedDistance)
    }

    func similarityReasons(to other: Self) -> [String] {
        var reasons: [(String, Double)] = []
        let bandSimilarity = zip(spectralBands, other.spectralBands)
            .map { 1 - min(1, abs(Double($0 - $1)) / 0.32) }
            .reduce(0, +) / Double(max(1, min(spectralBands.count, other.spectralBands.count)))
        reasons.append(("频段接近", bandSimilarity))
        reasons.append(("明暗接近", 1 - min(1, abs(Double(spectralCentroid - other.spectralCentroid)) / 0.32)))
        reasons.append(("瞬态接近", 1 - min(1, abs(Double(transientDensity - other.transientDensity)) / 0.35)))
        reasons.append(("动态接近", 1 - min(1, abs(Double(dynamicRange - other.dynamicRange)) / 0.45)))
        return reasons
            .filter { $0.1 >= 0.66 }
            .sorted { $0.1 > $1.1 }
            .prefix(2)
            .map(\.0)
    }
}

enum AcousticFingerprintAnalyzer {
    private static let fftSize = 2_048
    private static let bandEdges: [Double] = [
        30, 70, 120, 220, 400, 700, 1_200, 2_000, 3_200, 5_000, 8_000, 12_000, 17_000
    ]

    static func analyze(samples: [Float], sampleRate: Double) -> AcousticFingerprint? {
        guard samples.count >= 128, sampleRate > 0, sampleRate.isFinite else { return nil }
        let duration = Double(samples.count) / sampleRate
        let spectrum = CoarseSpectrum(sampleRate: sampleRate)
        let spectral = spectrum?.analyze(samples: samples) ?? SpectralSummary.empty
        let envelope = envelopeSummary(samples: samples, sampleRate: sampleRate)
        return AcousticFingerprint(
            spectralBands: spectral.bands,
            spectralCentroid: spectral.centroid,
            spectralRolloff: spectral.rolloff,
            spectralFlatness: spectral.flatness,
            zeroCrossingRate: zeroCrossingRate(samples),
            crestFactor: envelope.crestFactor,
            transientDensity: envelope.transientDensity,
            dynamicRange: envelope.dynamicRange,
            analyzedDuration: duration
        )
    }

    private static func zeroCrossingRate(_ samples: [Float]) -> Float {
        guard samples.count > 1 else { return 0 }
        var crossings = 0
        var previous = samples[0]
        let stride = max(1, samples.count / 200_000)
        for index in Swift.stride(from: stride, to: samples.count, by: stride) {
            let value = samples[index]
            if (previous < 0 && value >= 0) || (previous >= 0 && value < 0) { crossings += 1 }
            previous = value
        }
        let compared = max(1, (samples.count - 1) / stride)
        return min(1, Float(crossings) / Float(compared))
    }

    private static func envelopeSummary(
        samples: [Float],
        sampleRate: Double
    ) -> (crestFactor: Float, transientDensity: Float, dynamicRange: Float) {
        let bucketSize = max(32, Int(sampleRate * 0.01))
        let bucketCount = max(1, samples.count / bucketSize)
        var levels = [Float]()
        levels.reserveCapacity(bucketCount)
        var peak: Float = 0

        for bucket in 0..<bucketCount {
            let start = bucket * bucketSize
            let end = min(start + bucketSize, samples.count)
            guard end > start else { continue }
            var energy: Float = 0
            var localPeak: Float = 0
            for index in start..<end {
                let value = samples[index]
                energy += value * value
                localPeak = max(localPeak, abs(value))
            }
            levels.append(sqrt(energy / Float(end - start)))
            peak = max(peak, localPeak)
        }
        guard !levels.isEmpty else { return (0, 0, 0) }
        let rms = sqrt(levels.reduce(0) { $0 + $1 * $1 } / Float(levels.count))
        let crest = rms > 0 ? min(1, max(0, (peak / rms - 1) / 12)) : 0
        let sorted = levels.sorted()
        let low = sorted[Int(Double(sorted.count - 1) * 0.15)]
        let high = sorted[Int(Double(sorted.count - 1) * 0.90)]
        let dynamic = high > 0 ? min(1, max(0, log10(max(high / max(low, 0.000_001), 1)) / 3)) : 0

        let mean = levels.reduce(0, +) / Float(levels.count)
        var transients = 0
        if levels.count > 2 {
            for index in 1..<levels.count where levels[index] > max(mean * 1.65, levels[index - 1] * 1.8) {
                transients += 1
            }
        }
        let density = min(1, Float(transients) / Float(max(1, levels.count)) * 8)
        return (crest, density, dynamic)
    }

    private struct SpectralSummary {
        let bands: [Float]
        let centroid: Float
        let rolloff: Float
        let flatness: Float

        static let empty = SpectralSummary(
            bands: [Float](repeating: 0, count: 12),
            centroid: 0,
            rolloff: 0,
            flatness: 0
        )
    }

    private final class CoarseSpectrum {
        private let sampleRate: Double
        private let halfSize = fftSize / 2
        private let log2Size = vDSP_Length(log2(Double(fftSize)))
        private let setup: FFTSetup
        private let window: [Float]

        init?(sampleRate: Double) {
            self.sampleRate = sampleRate
            guard let setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2)) else { return nil }
            self.setup = setup
            var window = [Float](repeating: 0, count: fftSize)
            vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
            self.window = window
        }

        deinit { vDSP_destroy_fftsetup(setup) }

        func analyze(samples: [Float]) -> SpectralSummary {
            let available = max(1, 1 + max(0, samples.count - fftSize) / max(1, fftSize / 2))
            let windowCount = min(40, available)
            let step = max(1, available / windowCount)
            var bands = [Double](repeating: 0, count: 12)
            var centroid = 0.0
            var rolloff = 0.0
            var flatness = 0.0
            var processed = 0

            for windowIndex in Swift.stride(from: 0, to: available, by: step) {
                guard processed < windowCount else { break }
                let start = min(windowIndex * (fftSize / 2), max(0, samples.count - fftSize))
                var frame = [Float](repeating: 0, count: fftSize)
                let copyCount = min(fftSize, samples.count - start)
                if copyCount > 0 {
                    frame.replaceSubrange(0..<copyCount, with: samples[start..<(start + copyCount)])
                }
                vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(fftSize))
                let magnitudes = spectrum(frame)
                let total = magnitudes.dropFirst().reduce(0) {
                    $0 + sqrt(max(0, Double($1)))
                }
                guard total > 0.000_000_1 else { continue }

                var weightedFrequency = 0.0
                var logSum = 0.0
                var arithmeticSum = 0.0
                var cumulative = 0.0
                var frameRolloff = 0.0
                for bin in 1..<halfSize {
                    let frequency = Double(bin) * sampleRate / Double(fftSize)
                    let magnitude = sqrt(max(0, Double(magnitudes[bin])))
                    weightedFrequency += frequency * magnitude
                    arithmeticSum += magnitude
                    logSum += log(max(magnitude, 0.000_000_001))
                    cumulative += magnitude
                    if frameRolloff == 0, cumulative >= total * 0.85 {
                        frameRolloff = frequency
                    }
                    if let band = Self.bandIndex(for: frequency) { bands[band] += magnitude }
                }
                let nyquist = sampleRate / 2
                centroid += min(1, weightedFrequency / max(arithmeticSum * nyquist, 0.000_001))
                rolloff += min(1, frameRolloff / max(nyquist, 1))
                let binCount = Double(max(1, halfSize - 1))
                let geometric = exp(logSum / binCount)
                flatness += min(1, geometric / max(arithmeticSum / binCount, 0.000_001))
                processed += 1
            }
            guard processed > 0 else { return .empty }
            let compressedBands = bands.map(log1p)
            let bandTotal = compressedBands.reduce(0, +)
            let normalized = compressedBands.map { Float($0 / max(bandTotal, 0.000_001)) }
            return SpectralSummary(
                bands: normalized,
                centroid: Float(centroid / Double(processed)),
                rolloff: Float(rolloff / Double(processed)),
                flatness: Float(flatness / Double(processed))
            )
        }

        private func spectrum(_ frame: [Float]) -> [Float] {
            var real = [Float](repeating: 0, count: halfSize)
            var imaginary = [Float](repeating: 0, count: halfSize)
            var magnitudes = [Float](repeating: 0, count: halfSize)
            real.withUnsafeMutableBufferPointer { realPointer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                    var split = DSPSplitComplex(
                        realp: realPointer.baseAddress!,
                        imagp: imaginaryPointer.baseAddress!
                    )
                    frame.withUnsafeBufferPointer { framePointer in
                        framePointer.baseAddress!.withMemoryRebound(
                            to: DSPComplex.self,
                            capacity: halfSize
                        ) { complexPointer in
                            vDSP_ctoz(complexPointer, 2, &split, 1, vDSP_Length(halfSize))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2Size, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(halfSize))
                }
            }
            return magnitudes
        }

        private static func bandIndex(for frequency: Double) -> Int? {
            guard frequency >= bandEdges[0] else { return nil }
            for index in 0..<12 where frequency < bandEdges[index + 1] { return index }
            return nil
        }
    }
}

enum AcousticSimilarityIndex {
    static func nearest(
        to source: AcousticFingerprint,
        sourceID: UUID,
        in intelligenceByID: [UUID: AudioIntelligence],
        limit: Int = 180,
        minimumSimilarity: Double = 0.54
    ) -> [(soundID: UUID, similarity: Double)] {
        guard limit > 0 else { return [] }
        var values: [(UUID, Double)] = []
        values.reserveCapacity(min(limit * 2, intelligenceByID.count))
        for (soundID, intelligence) in intelligenceByID where soundID != sourceID {
            guard let fingerprint = intelligence.acousticFingerprint else { continue }
            let similarity = source.similarity(to: fingerprint)
            if similarity >= minimumSimilarity { values.append((soundID, similarity)) }
        }
        values.sort {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.uuidString < $1.0.uuidString
        }
        return Array(values.prefix(limit)).map { (soundID: $0.0, similarity: $0.1) }
    }
}
