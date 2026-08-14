import XCTest
@preconcurrency import AVFoundation
@testable import Shixiang

final class PitchShiftTests: XCTestCase {
    func testSuggestedNamesAreClearAndPreserveSourceBaseName() {
        let source = URL(fileURLWithPath: "/素材/雨夜.wav")

        XCTAssertEqual(
            PitchShiftNaming.suggestedFileName(for: source, semitones: 2),
            "雨夜_升2半音.wav"
        )
        XCTAssertEqual(
            PitchShiftNaming.suggestedFileName(for: source, semitones: -3),
            "雨夜_降3半音.wav"
        )
    }

    func testPreviewSemitonesAndVolumeAreClamped() async {
        await MainActor.run {
            let preview = PitchPreviewController()
            preview.semitones = 20
            XCTAssertEqual(preview.semitones, 12)
            preview.semitones = -40
            XCTAssertEqual(preview.semitones, -12)

            preview.volume = 2
            XCTAssertEqual(preview.volume, 1)
            preview.volume = -1
            XCTAssertEqual(preview.volume, 0)
            XCTAssertEqual(preview.mode, .processed)
            if !PitchAudioAvailability.isAvailable {
                XCTAssertFalse(preview.isAvailable)
                XCTAssertNotNil(preview.errorMessage)
            }
        }
    }

    func testPitchPreviewErrorIsScopedToItsSourceURL() {
        let failedURL = URL(fileURLWithPath: "/tmp/失败声音.wav")
        let otherURL = URL(fileURLWithPath: "/tmp/另一条声音.wav")
        let message = "无法试听变调。"

        XCTAssertEqual(
            PitchPreviewErrorPolicy.displayedMessage(
                issueURL: failedURL,
                displayedURL: failedURL,
                message: message,
                isAvailable: true
            ),
            message
        )
        XCTAssertNil(
            PitchPreviewErrorPolicy.displayedMessage(
                issueURL: failedURL,
                displayedURL: otherURL,
                message: message,
                isAvailable: true
            )
        )
        XCTAssertEqual(
            PitchPreviewErrorPolicy.displayedMessage(
                issueURL: nil,
                displayedURL: otherURL,
                message: "系统音频组件不可用。",
                isAvailable: false
            ),
            "系统音频组件不可用。"
        )
    }

    func testPitchPreviewResetsPerSoundStateButKeepsVolumePreference() async {
        await MainActor.run {
            let preview = PitchPreviewController()
            preview.semitones = 7
            preview.mode = .original
            preview.volume = 0.42

            preview.prepareForNewSound()

            XCTAssertEqual(preview.semitones, 0)
            XCTAssertEqual(preview.mode, .processed)
            XCTAssertEqual(preview.volume, 0.42, accuracy: 0.001)
            XCTAssertNil(preview.currentURL)
        }
    }

    func testPitchExportReportsUnavailableComponentsWithoutCreatingOutput() async throws {
        guard !PitchAudioAvailability.isAvailable else {
            throw XCTSkip("当前系统具备变调组件；此用例只覆盖组件缺失环境。")
        }

        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.wav")
        let destination = folder.appendingPathComponent("source_升2半音.wav")
        try makeSineWave(at: source, frequency: 220, duration: 0.1)

        do {
            _ = try await PitchShiftExporter().export(
                source: source,
                destination: destination,
                semitones: 2
            )
            XCTFail("缺少音频组件时不应伪装成导出成功")
        } catch let error as PitchExportError {
            XCTAssertEqual(error, .audioComponentsUnavailable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testPreviewLoadsOriginalInPlaceAndCanSwitchModes() async throws {
        try requirePitchAudioComponents()
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("preview.wav")
        try makeSineWave(at: source, frequency: 440, duration: 0.2)
        let originalBytes = try Data(contentsOf: source)

        try await MainActor.run {
            let preview = PitchPreviewController()
            try preview.load(url: source)
            XCTAssertEqual(preview.currentURL, source.standardizedFileURL)
            XCTAssertEqual(preview.duration, 0.2, accuracy: 1.0 / 1_000)
            XCTAssertFalse(preview.isPlaying)

            preview.semitones = 5
            preview.setMode(.original)
            XCTAssertEqual(preview.mode, .original)
            preview.setMode(.processed)
            XCTAssertEqual(preview.mode, .processed)
            preview.stop()
            preview.unload()
            XCTAssertNil(preview.currentURL)
        }
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
    }

    func testOfflineExportPreservesDurationAndNeverChangesSource() async throws {
        try requirePitchAudioComponents()
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("源声音.wav")
        let destination = folder.appendingPathComponent("源声音_升7半音.wav")
        try makeSineWave(at: source, frequency: 220, duration: 0.6)
        let originalBytes = try Data(contentsOf: source)
        let sourceFile = try AVAudioFile(forReading: source)
        let sourceDuration = Double(sourceFile.length) / sourceFile.processingFormat.sampleRate
        let progress = ProgressRecorder()

        let result = try await PitchShiftExporter().export(
            source: source,
            destination: destination,
            semitones: 7
        ) { value in
            await progress.append(value)
        }

        XCTAssertEqual(result, destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: source), originalBytes, "原始音频不得被修改")

        let exportedFile = try AVAudioFile(forReading: destination)
        let exportedDuration = Double(exportedFile.length) / exportedFile.processingFormat.sampleRate
        XCTAssertEqual(exportedDuration, sourceDuration, accuracy: 1.0 / 1_000)
        XCTAssertEqual(destination.pathExtension.lowercased(), "wav")
        let measuredFrequency = try estimateFrequency(in: exportedFile)
        let expectedFrequency = 220 * pow(2, 7.0 / 12.0)
        XCTAssertEqual(measuredFrequency, expectedFrequency, accuracy: 18)

        let values = await progress.snapshot()
        XCTAssertEqual(values.first ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(values.last ?? -1, 1, accuracy: 0.0001)
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
    }

    func testExportAtomicallyReplacesAnExistingDestination() async throws {
        try requirePitchAudioComponents()
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("impact.wav")
        let destination = folder.appendingPathComponent("impact_降4半音.wav")
        try makeSineWave(at: source, frequency: 330, duration: 0.25)
        try Data("旧文件".utf8).write(to: destination)

        _ = try await PitchShiftExporter().export(
            source: source,
            destination: destination,
            semitones: -4
        )

        XCTAssertNoThrow(try AVAudioFile(forReading: destination))
        let temporaryFiles = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".shixiang-pitch-") }
        XCTAssertTrue(temporaryFiles.isEmpty, "成功后不应遗留中间文件")
    }

    func testExportRejectsZeroShiftAndSourceOverwrite() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("original.wav")
        let destination = folder.appendingPathComponent("copy.wav")
        try makeSineWave(at: source, frequency: 220, duration: 0.1)

        do {
            _ = try await PitchShiftExporter().export(
                source: source,
                destination: destination,
                semitones: 0
            )
            XCTFail("0 半音应被阻止")
        } catch let error as PitchExportError {
            XCTAssertEqual(error, .zeroSemitones)
        }

        do {
            _ = try await PitchShiftExporter().export(
                source: source,
                destination: source,
                semitones: 2
            )
            XCTFail("不得覆盖源文件")
        } catch let error as PitchExportError {
            XCTAssertEqual(error, .sourceWouldBeOverwritten)
        }
    }

    func testAlreadyCancelledExportCreatesNoOutput() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("long.wav")
        let destination = folder.appendingPathComponent("long_升5半音.wav")
        try makeSineWave(at: source, frequency: 110, duration: 0.2)
        let exporter = PitchShiftExporter()

        let task = Task { () throws -> URL in
            withUnsafeCurrentTask { currentTask in
                currentTask?.cancel()
            }
            return try await exporter.export(
                source: source,
                destination: destination,
                semitones: 5
            )
        }

        do {
            _ = try await task.value
            XCTFail("取消的任务不应完成导出")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    private func makeTemporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("shixiang-pitch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func requirePitchAudioComponents() throws {
        guard PitchAudioAvailability.isAvailable else {
            throw XCTSkip("当前执行环境没有可用的变调音频组件；请在正常 macOS 音频环境复核此用例。")
        }
    }

    private func makeSineWave(
        at url: URL,
        frequency: Double,
        duration: Double,
        sampleRate: Double = 44_100
    ) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let frameCount = AVAudioFrameCount((duration * sampleRate).rounded())
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0] else {
            throw PitchTestFixtureError.couldNotAllocateBuffer
        }
        buffer.frameLength = frameCount
        for frame in 0..<Int(frameCount) {
            let phase = 2 * Double.pi * frequency * Double(frame) / sampleRate
            channel[frame] = Float(sin(phase) * 0.5)
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    private func estimateFrequency(in file: AVAudioFile) throws -> Double {
        file.framePosition = 0
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: frameCount
        ), let channel = buffer.floatChannelData?[0] else {
            throw PitchTestFixtureError.couldNotAllocateBuffer
        }
        try file.read(into: buffer)

        // Ignore the phase-vocoder's short onset and release regions, then count positive-going
        // zero crossings in the stable centre of the generated sine wave.
        let length = Int(buffer.frameLength)
        let start = length / 4
        let end = length * 3 / 4
        guard end > start + 1 else { throw PitchTestFixtureError.insufficientSamples }
        var crossings = 0
        for frame in (start + 1)..<end where channel[frame - 1] <= 0 && channel[frame] > 0 {
            crossings += 1
        }
        let windowDuration = Double(end - start) / file.processingFormat.sampleRate
        return Double(crossings) / windowDuration
    }
}

private actor ProgressRecorder {
    private var values: [Double] = []

    func append(_ value: Double) {
        values.append(value)
    }

    func snapshot() -> [Double] {
        values
    }
}

private enum PitchTestFixtureError: Error {
    case couldNotAllocateBuffer
    case insufficientSamples
}
