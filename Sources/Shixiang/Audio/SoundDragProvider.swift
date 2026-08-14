import AppKit
import UniformTypeIdentifiers
@preconcurrency import AVFoundation

/// Produces an in-place file provider so professional editors receive the original audio URL.
enum SoundDragProvider {
    private static let dragClipRetention: TimeInterval = 7 * 24 * 60 * 60
    private static let maximumDragClipFiles = 128
    private static let cleanupLock = NSLock()
    private static var lastCleanupDate = Date.distantPast

    static func itemProvider(for url: URL) -> NSItemProvider {
        itemProvider(for: url, timeRange: nil)
    }

    static func itemProvider(
        for url: URL,
        timeRange: ClosedRange<TimeInterval>?
    ) -> NSItemProvider {
        if let timeRange, timeRange.upperBound > timeRange.lowerBound + 0.05 {
            return trimmedItemProvider(for: url, timeRange: timeRange)
        }

        // Let Launch Services advertise the concrete file type first (for example public.wav).
        // The explicit registrations below keep the drag useful even when the file is offline or
        // its extension is unknown while the provider is being created.
        // Start from an empty provider so Launch Services cannot insert a competing default
        // representation that wins the negotiation before our explicit public.file-url path.
        let provider = NSItemProvider()
        provider.suggestedName = url.lastPathComponent

        // Final Cut Pro and Finder both recognise a public.file-url representation.
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier,
            visibility: .all
        ) { completion in
            completion(url.dataRepresentation, nil)
            return nil
        }

        // Some macOS/Xcode combinations resolve an extension-only URL to a dynamic UTI.
        // Use stable public identifiers for the formats supported by 拾响 so professional
        // editors can recognise the exact media type during the drag negotiation.
        let contentType = contentType(for: url.pathExtension)
        provider.registerFileRepresentation(
            forTypeIdentifier: contentType.identifier,
            fileOptions: [.openInPlace],
            visibility: .all
        ) { completion in
            completion(url, true, nil)
            return nil
        }

        return provider
    }

    static func advertisedTypeIdentifiers(
        for url: URL,
        timeRange: ClosedRange<TimeInterval>? = nil
    ) -> [String] {
        if let timeRange, timeRange.upperBound > timeRange.lowerBound + 0.05 {
            return [UTType.mpeg4Audio.identifier, UTType.fileURL.identifier]
        }
        return [UTType.fileURL.identifier, contentType(for: url.pathExtension).identifier]
    }

    private static func trimmedItemProvider(
        for url: URL,
        timeRange: ClosedRange<TimeInterval>
    ) -> NSItemProvider {
        let provider = NSItemProvider()
        let exportBox = DragClipExportBox(sourceURL: url, timeRange: timeRange)
        provider.suggestedName = "\(url.deletingPathExtension().lastPathComponent)-clip.m4a"
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.mpeg4Audio.identifier,
            fileOptions: [.openInPlace],
            visibility: .all
        ) { completion in
            Task {
                do {
                    let outputURL = try await exportBox.outputURL()
                    completion(outputURL, true, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        // Final Cut Pro may negotiate a public.file-url representation before asking for the
        // concrete audio UTI. Generate the same non-destructive clip for that path as well.
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier,
            visibility: .all
        ) { completion in
            Task {
                do {
                    let outputURL = try await exportBox.outputURL()
                    completion(outputURL.dataRepresentation, nil)
                } catch {
                    completion(nil, error)
                }
            }
            return nil
        }
        return provider
    }

    fileprivate static func exportClip(
        sourceURL: URL,
        timeRange: ClosedRange<TimeInterval>
    ) async throws -> URL {
        let asset = AVAsset(url: sourceURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw SoundDragError.invalidDuration
        }

        let start = min(max(timeRange.lowerBound, 0), duration)
        let end = min(max(timeRange.upperBound, start), duration)
        guard end > start + 0.05 else {
            throw SoundDragError.invalidRange
        }
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw SoundDragError.exportUnavailable
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Shixiang/DragClips", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanupExpiredDragClipsIfNeeded(in: directory)
        let outputURL = directory.appendingPathComponent(
            dragClipFileName(for: sourceURL)
        )
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )

        let exporterBox = ExportSessionBox(exporter)
        do {
            try await withCheckedThrowingContinuation { continuation in
                exporterBox.session.exportAsynchronously { [exporterBox] in
                    switch exporterBox.session.status {
                    case .completed:
                        continuation.resume(returning: ())
                    case .failed, .cancelled:
                        continuation.resume(
                            throwing: exporterBox.session.error ?? SoundDragError.exportFailed
                        )
                    default:
                        continuation.resume(throwing: SoundDragError.exportFailed)
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        return outputURL
    }

    /// Final Cut Pro uses the real temporary file name instead of `suggestedName` when it
    /// imports a promised file. Keep the source identity readable while retaining a short,
    /// collision-resistant suffix for concurrent drags.
    static func dragClipFileName(
        for sourceURL: URL,
        identifier: UUID = UUID()
    ) -> String {
        let rawBaseName = sourceURL.deletingPathExtension().lastPathComponent
            .precomposedStringWithCanonicalMapping
        let forbidden = CharacterSet.controlCharacters.union(
            CharacterSet(charactersIn: "/:\\?%*|\"<>")
        )
        let sanitizedScalars = rawBaseName.unicodeScalars.map { scalar -> Character in
            forbidden.contains(scalar) ? "_" : Character(String(scalar))
        }
        let sanitized = String(sanitizedScalars)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let readableBase = sanitized.isEmpty ? "Shixiang-Sound" : String(sanitized.prefix(88))
        let shortIdentifier = identifier.uuidString.prefix(8).uppercased()
        return "\(readableBase)-clip-\(shortIdentifier).m4a"
    }

    /// Keeps the app-owned temporary drag directory bounded. This never scans or removes source
    /// audio; it only touches files created by the A/B drag exporter itself.
    static func cleanupExpiredDragClips(
        in directory: URL,
        now: Date = Date()
    ) {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let clips = urls.compactMap { url -> (url: URL, modifiedAt: Date)? in
            guard url.pathExtension.caseInsensitiveCompare("m4a") == .orderedSame,
                  let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true else {
                return nil
            }
            return (url, values.contentModificationDate ?? .distantPast)
        }
        guard !clips.isEmpty else { return }

        let cutoff = now.addingTimeInterval(-dragClipRetention)
        var remaining = clips
        for clip in clips where clip.modifiedAt < cutoff {
            try? fileManager.removeItem(at: clip.url)
            remaining.removeAll { $0.url == clip.url }
        }

        if remaining.count > maximumDragClipFiles {
            let overflow = remaining
                .sorted { $0.modifiedAt < $1.modifiedAt }
                .prefix(remaining.count - maximumDragClipFiles)
            for clip in overflow {
                try? fileManager.removeItem(at: clip.url)
            }
        }
    }

    private static func cleanupExpiredDragClipsIfNeeded(in directory: URL) {
        cleanupLock.lock()
        let now = Date()
        let shouldRun = now.timeIntervalSince(lastCleanupDate) >= 30
        if shouldRun { lastCleanupDate = now }
        cleanupLock.unlock()
        guard shouldRun else { return }
        cleanupExpiredDragClips(in: directory, now: now)
    }

    static func contentType(for pathExtension: String) -> UTType {
        switch pathExtension.lowercased() {
        case "wav", "wave":
            return .wav
        case "aiff", "aif":
            return .aiff
        case "mp3":
            return .mp3
        case "m4a":
            return .mpeg4Audio
        case "caf":
            return UTType("com.apple.coreaudio-format") ?? .audio
        case "flac":
            return UTType("org.xiph.flac") ?? .audio
        default:
            return UTType(filenameExtension: pathExtension, conformingTo: .audio) ?? .audio
        }
    }

    static func isSupportedAudioExtension(_ pathExtension: String) -> Bool {
        LibraryScanner.supportedExtensions.contains(pathExtension.lowercased())
    }
}

private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}

/// Both drag representations share one lazy export. Final Cut Pro can ask for a concrete
/// audio UTI and a file URL during the same negotiation; exporting once avoids duplicate
/// temporary clips and keeps the app-owned drag directory quiet.
final class DragClipExportBox: @unchecked Sendable {
    private let sourceURL: URL
    private let timeRange: ClosedRange<TimeInterval>
    private let factory: (@Sendable () async throws -> URL)?
    private let lock = NSLock()
    private var task: Task<URL, Error>?

    init(sourceURL: URL, timeRange: ClosedRange<TimeInterval>) {
        self.sourceURL = sourceURL
        self.timeRange = timeRange
        factory = nil
    }

    init(factory: @escaping @Sendable () async throws -> URL) {
        sourceURL = URL(fileURLWithPath: "/")
        timeRange = 0...0
        self.factory = factory
    }

    func outputURL() async throws -> URL {
        try await taskForOutput().value
    }

    private func taskForOutput() -> Task<URL, Error> {
        lock.lock()
        defer { lock.unlock() }
        if let task {
            return task
        }
        let created = Task {
            if let factory {
                return try await factory()
            }
            return try await SoundDragProvider.exportClip(sourceURL: sourceURL, timeRange: timeRange)
        }
        task = created
        return created
    }
}

private enum SoundDragError: LocalizedError {
    case invalidDuration
    case invalidRange
    case exportUnavailable
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .invalidDuration: return "无法读取音频时长。"
        case .invalidRange: return "拖出的片段范围无效。"
        case .exportUnavailable: return "当前系统不支持生成拖出片段。"
        case .exportFailed: return "拖出片段生成失败。"
        }
    }
}
