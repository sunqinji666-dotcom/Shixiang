import AVFoundation
import Foundation
import Testing
@testable import Shixiang

struct KeyAnalyzerTests {
    @Test func musicalKeySemitoneMathWrapsInTheShortestDirection() {
        let cMajor = MusicalKey(root: .c, mode: .major)
        let bMajor = MusicalKey(root: .b, mode: .major)
        let fSharpMinor = MusicalKey(root: .fSharp, mode: .minor)

        #expect(cMajor.ascendingSemitones(to: bMajor) == 11)
        #expect(cMajor.shortestSemitoneOffset(to: bMajor) == -1)
        #expect(cMajor.shortestSemitoneOffset(to: fSharpMinor) == 6)
        #expect(cMajor.transposed(by: -1).root == .b)
        #expect(MusicalKey(root: .eFlat, mode: .minor).chineseDisplayName == "降E 小调")
    }

    @Test func recognizesSyntheticCMajorTriad() async throws {
        let url = try makeAudio(kind: .chord([261.6256, 329.6276, 391.9954]), duration: 4)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await KeyAnalyzer().analyze(url: url)
        #expect(result.status == .stable)
        #expect(result.key == MusicalKey(root: .c, mode: .major))
        #expect(result.confidence >= 0.46)
    }

    @Test func recognizesSyntheticAMinorTriad() async throws {
        let url = try makeAudio(kind: .chord([220.0000, 261.6256, 329.6276]), duration: 4)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await KeyAnalyzer().analyze(url: url)
        #expect(result.status == .stable)
        #expect(result.key == MusicalKey(root: .a, mode: .minor))
    }

    @Test func refusesToGuessForShortAudio() async throws {
        let url = try makeAudio(kind: .chord([261.6256, 329.6276, 391.9954]), duration: 0.45)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await KeyAnalyzer().analyze(url: url)
        #expect(result.key == nil)
        #expect(result.status == .tooShort)
    }

    @Test func refusesToGuessForDeterministicNoise() async throws {
        let url = try makeAudio(kind: .noise, duration: 4)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await KeyAnalyzer().analyze(url: url)
        #expect(result.key == nil)
        #expect(result.status != .stable)
    }

    private enum AudioKind {
        case chord([Double])
        case noise
    }

    private func makeAudio(kind: AudioKind, duration: Double) throws -> URL {
        let sampleRate = 44_100.0
        let frameCount = Int(sampleRate * duration)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shixiang-key-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        )!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let output = buffer.floatChannelData![0]

        switch kind {
        case let .chord(frequencies):
            for frame in 0..<frameCount {
                let time = Double(frame) / sampleRate
                let attack = min(1, time / 0.05)
                let release = min(1, (duration - time) / 0.08)
                let envelope = max(0, min(attack, release))
                let value = frequencies.reduce(0.0) { sum, frequency in
                    sum + sin(2 * .pi * frequency * time)
                } / Double(frequencies.count)
                output[frame] = Float(value * envelope * 0.72)
            }
        case .noise:
            var state: UInt64 = 0x1234_5678_9ABC_DEF0
            for frame in 0..<frameCount {
                state = state &* 6_364_136_223_846_793_005 &+ 1
                let unit = Double((state >> 32) & 0xFFFF_FFFF) / Double(UInt32.max)
                output[frame] = Float((unit * 2 - 1) * 0.35)
            }
        }

        try file.write(from: buffer)
        return url
    }
}
