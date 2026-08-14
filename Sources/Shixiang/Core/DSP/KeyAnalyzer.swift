import Accelerate
import AVFoundation
import Foundation

struct KeyAnalyzer: Sendable {
    struct Configuration: Hashable, Sendable {
        var minimumDuration: TimeInterval = 1.5
        var maximumAnalysisDuration: TimeInterval = 32
        var maximumWindows: Int = 192
        var minimumFrequency: Double = 55
        var maximumFrequency: Double = 5_000

        static let `default` = Configuration()
    }

    private let configuration: Configuration

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// Analyzes a local file without modifying it. Results are cached in-process by
    /// standardized path, file size, modification time and analysis configuration.
    func analyze(url: URL) async throws -> KeyAnalysisResult {
        let fingerprint = try FileFingerprint(url: url)
        let cacheKey = AnalysisCacheKey(fingerprint: fingerprint, configuration: configuration)
        if let cached = await KeyAnalysisMemoryCache.shared.value(for: cacheKey) {
            return cached
        }

        let result = try await Task.detached(priority: .userInitiated) {
            try Self.analyzeSynchronously(url: url, configuration: configuration)
        }.value
        await KeyAnalysisMemoryCache.shared.insert(result, for: cacheKey)
        return result
    }

    private static func analyzeSynchronously(
        url: URL,
        configuration: Configuration
    ) throws -> KeyAnalysisResult {
        guard url.isFileURL else { throw KeyAnalyzerError.notLocalFile }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw KeyAnalyzerError.cannotDecode(error.localizedDescription)
        }

        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate.isFinite, sampleRate > 0, file.length > 0 else {
            return .noStableKey(status: .insufficientSignal)
        }

        let duration = Double(file.length) / sampleRate
        guard duration >= configuration.minimumDuration else {
            return .noStableKey(status: .tooShort)
        }

        let ranges = analysisRanges(
            totalFrames: file.length,
            sampleRate: sampleRate,
            maximumDuration: configuration.maximumAnalysisDuration
        )
        let fftSize = preferredFFTSize(sampleRate: sampleRate)
        guard let chromaAnalyzer = FFTChromaAccumulator(
            fftSize: fftSize,
            sampleRate: sampleRate,
            minimumFrequency: configuration.minimumFrequency,
            maximumFrequency: configuration.maximumFrequency
        ) else {
            throw KeyAnalyzerError.analysisUnavailable
        }

        var chroma = [Double](repeating: 0, count: 12)
        var analyzedWindows = 0
        var energySum = 0.0
        var analyzedSamples = 0
        let windowsPerRange = max(1, configuration.maximumWindows / max(1, ranges.count))

        for range in ranges {
            try Task.checkCancellation()
            file.framePosition = range.start
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(range.count)
            ) else { continue }

            do {
                try file.read(into: buffer, frameCount: AVAudioFrameCount(range.count))
            } catch {
                throw KeyAnalyzerError.cannotDecode(error.localizedDescription)
            }
            let mono = downmix(buffer)
            guard !mono.isEmpty else { continue }

            var rms: Float = 0
            mono.withUnsafeBufferPointer { pointer in
                if let baseAddress = pointer.baseAddress {
                    vDSP_rmsqv(baseAddress, 1, &rms, vDSP_Length(pointer.count))
                }
            }
            energySum += Double(rms * rms) * Double(mono.count)
            analyzedSamples += mono.count

            let contribution = chromaAnalyzer.analyze(
                samples: mono,
                maximumWindows: windowsPerRange
            )
            analyzedWindows += contribution.windowCount
            for pitchClass in 0..<12 {
                chroma[pitchClass] += contribution.chroma[pitchClass]
            }
        }

        guard analyzedSamples > 0,
              analyzedWindows > 0,
              sqrt(energySum / Double(analyzedSamples)) >= 0.000_05 else {
            return .noStableKey(status: .insufficientSignal)
        }

        return classify(chroma: chroma)
    }

    private static func classify(chroma: [Double]) -> KeyAnalysisResult {
        let sum = chroma.reduce(0, +)
        guard sum > 0 else { return .noStableKey(status: .insufficientSignal) }
        let normalized = chroma.map { $0 / sum }
        let maximum = normalized.max() ?? 0
        let activePitchClasses = normalized.filter { $0 >= maximum * 0.18 }.count
        let entropy = -normalized.reduce(0) { partial, value in
            value > 0 ? partial + value * log(value) : partial
        } / log(12)
        let tonalConcentration = min(max(1 - entropy, 0), 1)

        guard tonalConcentration >= 0.105,
              activePitchClasses >= 2,
              activePitchClasses <= 9 else {
            return .noStableKey(status: .noStableTonalCenter)
        }

        let scored = MusicalKey.allCases.map { key in
            (key: key, correlation: profileCorrelation(chroma: normalized, key: key))
        }.sorted { $0.correlation > $1.correlation }

        guard let top = scored.first else {
            return .noStableKey(status: .noStableTonalCenter)
        }
        let runnerUp = scored.dropFirst().first?.correlation ?? -1
        let margin = max(0, top.correlation - runnerUp)
        let fit = max(0, top.correlation)
        let confidence = min(max(
            0.50 * fit
                + 0.25 * min(1, margin / 0.16)
                + 0.25 * min(1, tonalConcentration / 0.45),
            0
        ), 1)

        func candidate(_ value: (key: MusicalKey, correlation: Double)) -> KeyAnalysisResult.Candidate {
            .init(key: value.key, confidence: min(max((value.correlation + 1) / 2, 0), 1))
        }

        guard fit >= 0.28 else {
            return .noStableKey(status: .noStableTonalCenter)
        }
        guard margin >= 0.018, confidence >= 0.46 else {
            return .noStableKey(
                status: .lowConfidence,
                confidence: confidence,
                alternatives: Array(scored.prefix(3).map(candidate))
            )
        }

        return KeyAnalysisResult(
            key: top.key,
            confidence: confidence,
            alternatives: Array(scored.dropFirst().prefix(3).map(candidate)),
            status: .stable
        )
    }

    private static func profileCorrelation(chroma: [Double], key: MusicalKey) -> Double {
        let major = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
        let minor = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
        let base = key.mode == .major ? major : minor
        let profile = (0..<12).map { pitchClass in
            base[(pitchClass - key.root.rawValue + 12) % 12]
        }
        let chromaMean = chroma.reduce(0, +) / 12
        let profileMean = profile.reduce(0, +) / 12
        var numerator = 0.0
        var chromaEnergy = 0.0
        var profileEnergy = 0.0
        for index in 0..<12 {
            let x = chroma[index] - chromaMean
            let y = profile[index] - profileMean
            numerator += x * y
            chromaEnergy += x * x
            profileEnergy += y * y
        }
        let denominator = sqrt(chromaEnergy * profileEnergy)
        return denominator > 0 ? numerator / denominator : 0
    }

    private static func downmix(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channels = buffer.floatChannelData else { return [] }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return [] }
        var mono = [Float](repeating: 0, count: frameCount)
        let scale = 1 / Float(channelCount)
        for frame in 0..<frameCount {
            var value: Float = 0
            for channel in 0..<channelCount { value += channels[channel][frame] }
            mono[frame] = value * scale
        }
        return mono
    }

    private static func preferredFFTSize(sampleRate: Double) -> Int {
        let desired = max(4_096, Int(ceil(sampleRate / 3.2)))
        var size = 1
        while size < desired { size <<= 1 }
        return min(max(size, 8_192), 65_536)
    }

    private static func analysisRanges(
        totalFrames: AVAudioFramePosition,
        sampleRate: Double,
        maximumDuration: TimeInterval
    ) -> [(start: AVAudioFramePosition, count: Int)] {
        let budget = min(totalFrames, AVAudioFramePosition(sampleRate * maximumDuration))
        guard budget < totalFrames else { return [(0, Int(totalFrames))] }

        let segmentCount = 4
        let segmentLength = max(1, budget / AVAudioFramePosition(segmentCount))
        let fractions = [0.10, 0.36, 0.64, 0.90]
        return fractions.map { fraction in
            let center = AVAudioFramePosition(Double(totalFrames) * fraction)
            let maximumStart = max(0, totalFrames - segmentLength)
            let start = min(max(0, center - segmentLength / 2), maximumStart)
            return (start, Int(segmentLength))
        }
    }
}

enum KeyAnalyzerError: LocalizedError {
    case notLocalFile
    case fileUnavailable
    case cannotDecode(String)
    case analysisUnavailable

    var errorDescription: String? {
        switch self {
        case .notLocalFile: return "调性分析仅支持本地音频文件。"
        case .fileUnavailable: return "音频文件不存在或不可读取。"
        case let .cannotDecode(reason): return "无法读取音频：\(reason)"
        case .analysisUnavailable: return "无法初始化本地调性分析引擎。"
        }
    }
}

private final class FFTChromaAccumulator {
    private let fftSize: Int
    private let halfSize: Int
    private let log2Size: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private let binMappings: [(pitchClass: Int, weight: Double)?]

    init?(
        fftSize: Int,
        sampleRate: Double,
        minimumFrequency: Double,
        maximumFrequency: Double
    ) {
        self.fftSize = fftSize
        halfSize = fftSize / 2
        log2Size = vDSP_Length(log2(Double(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2)) else { return nil }
        self.setup = setup
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        self.window = window

        let nyquist = sampleRate / 2
        binMappings = (0..<halfSize).map { bin in
            let frequency = Double(bin) * sampleRate / Double(fftSize)
            guard frequency >= minimumFrequency,
                  frequency <= min(maximumFrequency, nyquist) else { return nil }
            let midi = 69 + 12 * log2(frequency / 440)
            let pitchClass = ((Int(midi.rounded()) % 12) + 12) % 12
            let weight = min(max(sqrt(440 / frequency), 0.30), 2.8)
            return (pitchClass, weight)
        }
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func analyze(samples: [Float], maximumWindows: Int) -> (chroma: [Double], windowCount: Int) {
        guard !samples.isEmpty, maximumWindows > 0 else {
            return ([Double](repeating: 0, count: 12), 0)
        }
        let hopSize = fftSize / 2
        let availableCount = samples.count >= fftSize
            ? 1 + (samples.count - fftSize) / hopSize
            : 1
        let selectedCount = min(availableCount, maximumWindows)
        let selectionStride = max(1, availableCount / selectedCount)
        var result = [Double](repeating: 0, count: 12)
        var processed = 0

        for windowIndex in Swift.stride(from: 0, to: availableCount, by: selectionStride) {
            guard processed < selectedCount else { break }
            let start = min(windowIndex * hopSize, max(0, samples.count - fftSize))
            var frame = [Float](repeating: 0, count: fftSize)
            let copyCount = min(fftSize, samples.count - start)
            if copyCount > 0 { frame.replaceSubrange(0..<copyCount, with: samples[start..<(start + copyCount)]) }

            var mean: Float = 0
            vDSP_meanv(frame, 1, &mean, vDSP_Length(fftSize))
            var negativeMean = -mean
            vDSP_vsadd(frame, 1, &negativeMean, &frame, 1, vDSP_Length(fftSize))
            vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(fftSize))
            let frameChroma = spectrumChroma(frame)
            let frameSum = frameChroma.reduce(0, +)
            if frameSum > 0 {
                for index in 0..<12 { result[index] += frameChroma[index] / frameSum }
                processed += 1
            }
        }
        return (result, processed)
    }

    private func spectrumChroma(_ frame: [Float]) -> [Double] {
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

        guard let maximum = magnitudes.max(), maximum > 0 else {
            return [Double](repeating: 0, count: 12)
        }
        let threshold = maximum * 0.000_1
        var chroma = [Double](repeating: 0, count: 12)
        guard halfSize > 2 else { return chroma }
        for bin in 1..<(halfSize - 1) {
            guard let mapping = binMappings[bin],
                  magnitudes[bin] >= threshold,
                  magnitudes[bin] > magnitudes[bin - 1],
                  magnitudes[bin] >= magnitudes[bin + 1] else { continue }
            chroma[mapping.pitchClass] += sqrt(Double(magnitudes[bin])) * mapping.weight
        }
        return chroma
    }
}

private struct FileFingerprint: Hashable, Sendable {
    let path: String
    let fileSize: Int
    let modificationTime: TimeInterval

    init(url: URL) throws {
        guard url.isFileURL else { throw KeyAnalyzerError.notLocalFile }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        } catch {
            throw KeyAnalyzerError.fileUnavailable
        }
        guard values.isRegularFile == true else { throw KeyAnalyzerError.fileUnavailable }
        path = url.standardizedFileURL.path
        fileSize = values.fileSize ?? 0
        modificationTime = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
    }
}

private struct AnalysisCacheKey: Hashable, Sendable {
    let fingerprint: FileFingerprint
    let configuration: KeyAnalyzer.Configuration
    let analysisVersion = 1
}

private actor KeyAnalysisMemoryCache {
    static let shared = KeyAnalysisMemoryCache()
    private let capacity = 256
    private var values: [AnalysisCacheKey: KeyAnalysisResult] = [:]
    private var insertionOrder: [AnalysisCacheKey] = []

    func value(for key: AnalysisCacheKey) -> KeyAnalysisResult? { values[key] }

    func insert(_ result: KeyAnalysisResult, for key: AnalysisCacheKey) {
        if values[key] == nil { insertionOrder.append(key) }
        values[key] = result
        while insertionOrder.count > capacity {
            let expired = insertionOrder.removeFirst()
            values[expired] = nil
        }
    }
}
