import Combine
import Foundation
@preconcurrency import AVFoundation

enum PitchShiftNaming {
    static func suggestedFileName(for source: URL, semitones: Int) -> String {
        let baseName = source.deletingPathExtension().lastPathComponent
        let treatment: String
        if semitones > 0 {
            treatment = "升\(semitones)半音"
        } else if semitones < 0 {
            treatment = "降\(abs(semitones))半音"
        } else {
            treatment = "原音"
        }
        return "\(baseName)_\(treatment).wav"
    }

    static func suggestedDestination(for source: URL, semitones: Int) -> URL {
        source.deletingLastPathComponent()
            .appendingPathComponent(suggestedFileName(for: source, semitones: semitones))
    }
}

enum PitchExportStatus: Equatable, Sendable {
    case idle
    case exporting
    case completed
    case cancelled
    case failed
}

/// Offline, native pitch rendering. The source is opened read-only; samples are first written to
/// a sibling temporary file and moved/replaced only after a complete render.
actor PitchShiftExporter {
    typealias ProgressHandler = @Sendable (Double) async -> Void

    func export(
        source: URL,
        destination: URL,
        semitones: Int,
        progress: ProgressHandler? = nil
    ) async throws -> URL {
        try Task.checkCancellation()
        guard (-12...12).contains(semitones) else {
            throw PitchExportError.semitonesOutOfRange
        }
        guard semitones != 0 else {
            throw PitchExportError.zeroSemitones
        }

        let sourceURL = source.standardizedFileURL.resolvingSymlinksInPath()
        let destinationURL = destination.standardizedFileURL
        guard destinationURL.pathExtension.lowercased() == "wav" else {
            throw PitchExportError.destinationMustBeWAV
        }
        guard sourceURL != destinationURL.resolvingSymlinksInPath() else {
            throw PitchExportError.sourceWouldBeOverwritten
        }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw PitchExportError.sourceMissing
        }

        let destinationDirectory = destinationURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: destinationDirectory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw PitchExportError.destinationFolderMissing
        }

        let sourceAccessed = sourceURL.startAccessingSecurityScopedResource()
        let destinationAccessed = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if sourceAccessed { sourceURL.stopAccessingSecurityScopedResource() }
            if destinationAccessed { destinationURL.stopAccessingSecurityScopedResource() }
        }

        let temporaryURL = destinationDirectory
            .appendingPathComponent(".shixiang-pitch-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        defer {
            if FileManager.default.fileExists(atPath: temporaryURL.path) {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        try await render(
            source: sourceURL,
            temporaryDestination: temporaryURL,
            semitones: semitones,
            progress: progress
        )
        try Task.checkCancellation()
        try commitTemporaryFile(at: temporaryURL, to: destinationURL)
        if let progress { await progress(1) }
        return destinationURL
    }

    private func render(
        source: URL,
        temporaryDestination: URL,
        semitones: Int,
        progress: ProgressHandler?
    ) async throws {
        guard PitchAudioAvailability.isAvailable else {
            throw PitchExportError.audioComponentsUnavailable
        }
        let sourceFile = try AVAudioFile(forReading: source)
        let inputFormat = sourceFile.processingFormat
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0, sourceFile.length > 0 else {
            throw PitchExportError.unsupportedAudioFormat
        }

        let renderFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: inputFormat.channelCount,
            interleaved: false
        )!
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        timePitch.pitch = Float(semitones * 100)
        timePitch.rate = 1

        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: inputFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: renderFormat)
        try engine.enableManualRenderingMode(
            .offline,
            format: renderFormat,
            maximumFrameCount: 4_096
        )
        engine.prepare()
        try engine.start()
        defer {
            player.stop()
            engine.stop()
            engine.disableManualRenderingMode()
        }

        // Use the callback overload explicitly. Newer SDKs also expose an async overload whose
        // `await` completes after playback; that would deadlock an offline render before play().
        player.scheduleFile(
            sourceFile,
            at: nil,
            completionCallbackType: .dataConsumed
        ) { _ in }
        player.play()

        let wavSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: renderFormat.sampleRate,
            AVNumberOfChannelsKey: Int(renderFormat.channelCount),
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        var outputFile: AVAudioFile? = try AVAudioFile(
            forWriting: temporaryDestination,
            settings: wavSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let renderBuffer = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: engine.manualRenderingMaximumFrameCount
        ) else {
            throw PitchExportError.couldNotAllocateBuffer
        }

        let totalFrames = sourceFile.length
        var writtenFrames: AVAudioFramePosition = 0
        if let progress { await progress(0) }

        while writtenFrames < totalFrames {
            try Task.checkCancellation()
            let requested = AVAudioFrameCount(
                min(
                    AVAudioFramePosition(engine.manualRenderingMaximumFrameCount),
                    totalFrames - writtenFrames
                )
            )
            let status = try engine.renderOffline(requested, to: renderBuffer)

            switch status {
            case .success:
                guard renderBuffer.frameLength > 0 else { continue }
                try outputFile?.write(from: renderBuffer)
                writtenFrames += AVAudioFramePosition(renderBuffer.frameLength)
                if let progress {
                    await progress(min(0.999, Double(writtenFrames) / Double(totalFrames)))
                }
            case .insufficientDataFromInputNode:
                await Task.yield()
            case .cannotDoInCurrentContext:
                await Task.yield()
            case .error:
                throw PitchExportError.renderFailed
            @unknown default:
                throw PitchExportError.renderFailed
            }
        }

        // Release AVAudioFile before the atomic move so all WAV headers are flushed.
        outputFile = nil
    }

    private func commitTemporaryFile(at temporaryURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }
}

@MainActor
final class PitchExportController: ObservableObject {
    @Published private(set) var status: PitchExportStatus = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var outputURL: URL?
    @Published private(set) var errorMessage: String?

    var isExporting: Bool { status == .exporting }

    private let exporter: PitchShiftExporter
    private var exportTask: Task<Void, Never>?
    private var generation = UUID()

    init(exporter: PitchShiftExporter = PitchShiftExporter()) {
        self.exporter = exporter
    }

    deinit {
        exportTask?.cancel()
    }

    func startExport(source: URL, destination: URL, semitones: Int) {
        cancel()
        generation = UUID()
        let currentGeneration = generation
        status = .exporting
        progress = 0
        outputURL = nil
        errorMessage = nil

        exportTask = Task { [weak self, exporter] in
            do {
                let output = try await exporter.export(
                    source: source,
                    destination: destination,
                    semitones: semitones
                ) { [weak self] value in
                    await self?.receiveProgress(value, generation: currentGeneration)
                }
                guard !Task.isCancelled else { throw CancellationError() }
                self?.complete(output, generation: currentGeneration)
            } catch is CancellationError {
                self?.finishCancellation(generation: currentGeneration)
            } catch {
                self?.fail(error, generation: currentGeneration)
            }
        }
    }

    func cancel() {
        generation = UUID()
        exportTask?.cancel()
        exportTask = nil
        if status == .exporting {
            status = .cancelled
        }
    }

    func reset() {
        cancel()
        status = .idle
        progress = 0
        outputURL = nil
        errorMessage = nil
    }

    private func receiveProgress(_ value: Double, generation: UUID) {
        guard generation == self.generation, status == .exporting else { return }
        progress = min(max(value, 0), 1)
    }

    private func complete(_ url: URL, generation: UUID) {
        guard generation == self.generation else { return }
        progress = 1
        outputURL = url
        status = .completed
        exportTask = nil
    }

    private func finishCancellation(generation: UUID) {
        guard generation == self.generation else { return }
        status = .cancelled
        exportTask = nil
    }

    private func fail(_ error: Error, generation: UUID) {
        guard generation == self.generation else { return }
        status = .failed
        errorMessage = error.localizedDescription
        exportTask = nil
    }
}

enum PitchExportError: LocalizedError, Equatable {
    case semitonesOutOfRange
    case zeroSemitones
    case sourceWouldBeOverwritten
    case sourceMissing
    case destinationFolderMissing
    case destinationMustBeWAV
    case audioComponentsUnavailable
    case unsupportedAudioFormat
    case couldNotAllocateBuffer
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .semitonesOutOfRange:
            return "变调范围必须在 -12 到 +12 半音之间。"
        case .zeroSemitones:
            return "0 半音与原音相同，无需导出处理副本。"
        case .sourceWouldBeOverwritten:
            return "不能覆盖原始音频，请选择新的 WAV 文件名。"
        case .sourceMissing:
            return "原始音频已不可访问。"
        case .destinationFolderMissing:
            return "导出文件夹不存在。"
        case .destinationMustBeWAV:
            return "处理后的副本必须保存为 WAV。"
        case .audioComponentsUnavailable:
            return "当前系统没有可用的变调音频组件，请在正常 macOS 音频环境中运行。"
        case .unsupportedAudioFormat:
            return "此音频格式无法进行变调处理。"
        case .couldNotAllocateBuffer:
            return "无法创建音频处理缓冲区。"
        case .renderFailed:
            return "变调渲染失败。"
        }
    }
}
