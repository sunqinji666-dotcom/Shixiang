import Accelerate
import AVFoundation
import Foundation

struct AudioIntelligence: Codable, Hashable, Sendable {
    let bpm: Double?
    let bpmConfidence: Double
    let loudnessLUFS: Double?
    let musicalKey: MusicalKey?
    let keyConfidence: Double
    let acousticFingerprint: AcousticFingerprint?
    let analyzedAt: Date

    init(
        bpm: Double?,
        bpmConfidence: Double,
        loudnessLUFS: Double?,
        musicalKey: MusicalKey?,
        keyConfidence: Double,
        acousticFingerprint: AcousticFingerprint? = nil,
        analyzedAt: Date
    ) {
        self.bpm = bpm
        self.bpmConfidence = bpmConfidence
        self.loudnessLUFS = loudnessLUFS
        self.musicalKey = musicalKey
        self.keyConfidence = keyConfidence
        self.acousticFingerprint = acousticFingerprint
        self.analyzedAt = analyzedAt
    }

    static let empty = AudioIntelligence(
        bpm: nil,
        bpmConfidence: 0,
        loudnessLUFS: nil,
        musicalKey: nil,
        keyConfidence: 0,
        acousticFingerprint: nil,
        analyzedAt: Date()
    )
}

struct AudioIntelligenceAnalyzer: Sendable {
    let keyAnalyzer = KeyAnalyzer()

    func analyze(url: URL) async throws -> AudioIntelligence {
        let keyResult = try? await keyAnalyzer.analyze(url: url)
        let signal = try await Task.detached(priority: .utility) {
            try Self.analyzeSignal(url: url)
        }.value

        return AudioIntelligence(
            bpm: signal.bpm,
            bpmConfidence: signal.bpmConfidence,
            loudnessLUFS: signal.loudnessLUFS,
            musicalKey: keyResult?.key,
            keyConfidence: keyResult?.confidence ?? 0,
            acousticFingerprint: signal.acousticFingerprint,
            analyzedAt: Date()
        )
    }

    /// Fast background path used by the library-scale queue. It reuses existing tonal
    /// metadata and avoids running the more expensive key analyzer for every untouched file.
    func analyzeAcousticsOnly(
        url: URL,
        preserving existing: AudioIntelligence?
    ) async throws -> AudioIntelligence {
        let signal = try await Task.detached(priority: .utility) {
            try Self.analyzeSignal(url: url)
        }.value
        return AudioIntelligence(
            bpm: signal.bpm ?? existing?.bpm,
            bpmConfidence: signal.bpm == nil ? (existing?.bpmConfidence ?? 0) : signal.bpmConfidence,
            loudnessLUFS: signal.loudnessLUFS ?? existing?.loudnessLUFS,
            musicalKey: existing?.musicalKey,
            keyConfidence: existing?.keyConfidence ?? 0,
            acousticFingerprint: signal.acousticFingerprint,
            analyzedAt: Date()
        )
    }

    private static func analyzeSignal(url: URL) throws -> SignalAnalysis {
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate.isFinite, sampleRate > 0, file.length > 0 else {
            return SignalAnalysis(bpm: nil, bpmConfidence: 0, loudnessLUFS: nil, acousticFingerprint: nil)
        }

        let maximumFrames = AVAudioFramePosition(sampleRate * 30)
        let frameCount = min(file.length, maximumFrames)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            return SignalAnalysis(bpm: nil, bpmConfidence: 0, loudnessLUFS: nil, acousticFingerprint: nil)
        }
        try file.read(into: buffer, frameCount: AVAudioFrameCount(frameCount))
        let mono = downmix(buffer)
        guard !mono.isEmpty else {
            return SignalAnalysis(bpm: nil, bpmConfidence: 0, loudnessLUFS: nil, acousticFingerprint: nil)
        }

        var rms: Float = 0
        mono.withUnsafeBufferPointer { pointer in
            if let baseAddress = pointer.baseAddress {
                vDSP_rmsqv(baseAddress, 1, &rms, vDSP_Length(pointer.count))
            }
        }
        let loudness = rms > 0 ? 20 * log10(Double(rms)) : nil
        let bpm = estimateBPM(samples: mono, sampleRate: sampleRate)
        return SignalAnalysis(
            bpm: bpm.value,
            bpmConfidence: bpm.confidence,
            loudnessLUFS: loudness,
            acousticFingerprint: AcousticFingerprintAnalyzer.analyze(
                samples: mono,
                sampleRate: sampleRate
            )
        )
    }

    private static func estimateBPM(samples: [Float], sampleRate: Double) -> (value: Double?, confidence: Double) {
        let bucketSize = max(1, Int(sampleRate * 0.01))
        let bucketCount = samples.count / bucketSize
        guard bucketCount > 40 else { return (nil, 0) }

        var envelope = [Double](repeating: 0, count: bucketCount)
        for bucket in 0..<bucketCount {
            let start = bucket * bucketSize
            let end = min(start + bucketSize, samples.count)
            var energy = 0.0
            for index in start..<end {
                let value = Double(samples[index])
                energy += value * value
            }
            envelope[bucket] = sqrt(energy / Double(max(1, end - start)))
        }

        let mean = envelope.reduce(0, +) / Double(envelope.count)
        envelope = envelope.map { max(0, $0 - mean) }
        let minimumLag = max(1, Int((60.0 / 240.0) / 0.01))
        let maximumLag = min(envelope.count / 2, Int((60.0 / 45.0) / 0.01))
        guard maximumLag > minimumLag else { return (nil, 0) }

        var scores: [(bpm: Double, score: Double)] = []
        scores.reserveCapacity(maximumLag - minimumLag)
        for lag in minimumLag...maximumLag {
            var correlation = 0.0
            var energy = 0.0
            for index in lag..<envelope.count {
                correlation += envelope[index] * envelope[index - lag]
                energy += envelope[index] * envelope[index]
            }
            guard energy > 0 else { continue }
            scores.append((60.0 / (Double(lag) * 0.01), correlation / energy))
        }
        let ranked = scores.sorted { $0.score > $1.score }
        guard let best = ranked.first else { return (nil, 0) }
        let runnerUp = ranked.dropFirst().first?.score ?? 0
        let confidence = min(max((best.score - runnerUp) * 5, 0), 1)
        guard confidence >= 0.12, best.score > 0.015 else { return (nil, confidence) }
        return (min(max(best.bpm.rounded(), 40), 240), confidence)
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
}

private struct SignalAnalysis: Sendable {
    let bpm: Double?
    let bpmConfidence: Double
    let loudnessLUFS: Double?
    let acousticFingerprint: AcousticFingerprint?
}
