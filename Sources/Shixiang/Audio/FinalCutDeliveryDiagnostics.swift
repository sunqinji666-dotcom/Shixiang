import Foundation
import UniformTypeIdentifiers
@preconcurrency import AVFoundation

struct FinalCutDeliveryCheck: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case passed
        case warning
        case failed
    }

    let id: String
    let title: String
    let detail: String
    let state: State
}

struct FinalCutDeliveryReport: Equatable, Sendable {
    let checkedAt: Date
    let duration: TimeInterval
    let sampleRate: Double
    let channelCount: Int
    let advertisedTypeIdentifiers: [String]
    let checks: [FinalCutDeliveryCheck]

    var isReady: Bool {
        !checks.contains { $0.state == .failed }
    }
}

enum FinalCutDeliveryDiagnostics {
    static func inspect(url: URL) throws -> FinalCutDeliveryReport {
        let fileManager = FileManager.default
        let standardizedURL = url.standardizedFileURL
        _ = try standardizedURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        var isDirectory: ObjCBool = false
        let isReadable = fileManager.fileExists(
            atPath: standardizedURL.path,
            isDirectory: &isDirectory
        ) && !isDirectory.boolValue
            && fileManager.isReadableFile(atPath: standardizedURL.path)
        let type = SoundDragProvider.contentType(for: standardizedURL.pathExtension)
        // Some macOS/Xcode combinations resolve a concrete type such as WAV without
        // preserving its public.audio conformance. The app's explicit import allowlist
        // is stable across those environments; AVAudioFile below still verifies that the
        // media is genuinely readable before the report can succeed.
        let isAudioType = SoundDragProvider.isSupportedAudioExtension(
            standardizedURL.pathExtension
        )

        let audioFile = try AVAudioFile(forReading: standardizedURL)
        let sampleRate = audioFile.processingFormat.sampleRate
        let channelCount = Int(audioFile.processingFormat.channelCount)
        let duration = sampleRate > 0 ? Double(audioFile.length) / sampleRate : 0
        let identifiers = SoundDragProvider.advertisedTypeIdentifiers(for: standardizedURL)

        var checks: [FinalCutDeliveryCheck] = [
            FinalCutDeliveryCheck(
                id: "readable",
                title: "源文件可读取",
                detail: isReadable ? "拾响将原文件以只读方式原位交付。" : "文件不存在、不是普通文件或当前不可读取。",
                state: isReadable ? .passed : .failed
            ),
            FinalCutDeliveryCheck(
                id: "type",
                title: "音频类型可识别",
                detail: type.identifier,
                state: isAudioType ? .passed : .failed
            ),
            FinalCutDeliveryCheck(
                id: "duration",
                title: "时长有效",
                detail: duration > 0 ? duration.formatted(.number.precision(.fractionLength(2))) + " 秒" : "音频时长为 0 或无法读取",
                state: duration > 0 ? .passed : .failed
            ),
            FinalCutDeliveryCheck(
                id: "format",
                title: "声道与采样率",
                detail: "\(Int(sampleRate).formatted(.number)) Hz · \(channelCount) 声道",
                state: sampleRate > 0 && channelCount > 0 ? .passed : .failed
            ),
            FinalCutDeliveryCheck(
                id: "provider",
                title: "拖拽表示完整",
                detail: identifiers.joined(separator: " · "),
                state: identifiers.contains(UTType.fileURL.identifier) && identifiers.count >= 2
                    ? .passed
                    : .failed
            )
        ]

        if sampleRate != 48_000 {
            checks.append(
                FinalCutDeliveryCheck(
                    id: "sample-rate-note",
                    title: "项目采样率提示",
                    detail: "当前为 \(Int(sampleRate).formatted(.number)) Hz；FCP 可以导入，电影项目通常使用 48,000 Hz。",
                    state: .warning
                )
            )
        }

        return FinalCutDeliveryReport(
            checkedAt: Date(),
            duration: duration,
            sampleRate: sampleRate,
            channelCount: channelCount,
            advertisedTypeIdentifiers: identifiers,
            checks: checks
        )
    }
}
