import Foundation
import SwiftUI
@preconcurrency import AVFoundation

/// Pure coordinate mapping shared by the waveform gesture and its tests.
/// Audio scrubbing is deliberately linear: pointer movement maps one-to-one to time.
enum WaveformScrubbing {
    static func progress(locationX: CGFloat, width: CGFloat) -> Double {
        guard width.isFinite, width > 0, locationX.isFinite else { return 0 }
        return min(max(Double(locationX / width), 0), 1)
    }

    static func time(progress: Double, duration: TimeInterval) -> TimeInterval {
        guard progress.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return min(max(progress, 0), 1) * duration
    }
}

/// A compact waveform with an optional, continuously updated playback reveal.
/// The complete waveform stays grey; the played portion is clipped from the same path,
/// so progress never changes layout or triggers a second audio decode.
struct WaveformView: View {
    let fileURL: URL?
    let progress: Double?
    let playedColor: Color
    let unplayedColor: Color
    private let loadIdentity: String
    private let rendersAsynchronously: Bool

    init(
        fileURL: URL?,
        cacheIdentity: String? = nil,
        progress: Double? = nil,
        playedColor: Color = Color(red: 0.46, green: 0.40, blue: 1.0),
        unplayedColor: Color = Color.secondary.opacity(0.34),
        rendersAsynchronously: Bool? = nil
    ) {
        self.fileURL = fileURL
        self.progress = progress
        self.playedColor = playedColor
        self.unplayedColor = unplayedColor
        // Static waveforms and the live playback reveal are both safe to draw off the
        // main thread. Gesture-driven previews explicitly opt out below so the pointer
        // remains 1:1 with the canvas instead of waiting for an async render pass.
        self.rendersAsynchronously = rendersAsynchronously ?? (progress == nil)
        loadIdentity = cacheIdentity ?? fileURL?.standardizedFileURL.path ?? "no-file"
    }

    var body: some View {
        WaveformSamplesHost(fileURL: fileURL, loadIdentity: loadIdentity) {
            samples,
            loadFailed in
            WaveformCanvas(
                samples: samples,
                loadIdentity: loadIdentity,
                progress: progress,
                playedColor: playedColor,
                unplayedColor: unplayedColor,
                loadFailed: loadFailed,
                rendersAsynchronously: rendersAsynchronously
            )
        }
    }
}

/// Only the currently loaded sound observes the high-frequency playback clock.
/// Every other row keeps a static waveform and therefore stays idle during playback.
struct PlaybackWaveformView: View {
    let fileURL: URL?
    let cacheIdentity: String?
    @ObservedObject var clock: PlaybackClock
    @Environment(\.isWindowLiveResizing) private var isWindowLiveResizing

    init(fileURL: URL?, cacheIdentity: String? = nil, clock: PlaybackClock) {
        self.fileURL = fileURL
        self.cacheIdentity = cacheIdentity
        self.clock = clock
    }

    var body: some View {
        let loadIdentity = cacheIdentity ?? fileURL?.standardizedFileURL.path ?? "no-file"
        WaveformSamplesHost(fileURL: fileURL, loadIdentity: loadIdentity) {
            samples,
            loadFailed in
            if isWindowLiveResizing {
                WaveformCanvas(
                    samples: [],
                    loadIdentity: loadIdentity,
                    progress: nil,
                    playedColor: ShixiangTheme.violet,
                    unplayedColor: ShixiangTheme.secondaryText.opacity(0.32),
                    loadFailed: loadFailed,
                    rendersAsynchronously: true
                )
            } else {
                ZStack {
                // The grey waveform is immutable during playback. Keeping it outside the
                // TimelineView prevents 60 redundant full-path strokes every second.
                WaveformCanvas(
                    samples: samples,
                    loadIdentity: loadIdentity,
                    progress: nil,
                    playedColor: ShixiangTheme.violet,
                    unplayedColor: ShixiangTheme.secondaryText.opacity(0.32),
                    loadFailed: loadFailed,
                    rendersAsynchronously: true,
                    drawsPlayedLayer: false
                )

                TimelineView(
                    .animation(minimumInterval: 1.0 / 60.0, paused: !clock.isAdvancing)
                ) { timeline in
                    WaveformCanvas(
                        samples: samples,
                        loadIdentity: loadIdentity,
                        progress: clock.progress(at: timeline.date),
                        playedColor: ShixiangTheme.violet,
                        unplayedColor: .clear,
                        loadFailed: false,
                        rendersAsynchronously: true,
                        drawsUnplayedLayer: false,
                        drawsPlaceholder: false
                    )
                    .accessibilityHidden(true)
                }
            }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Owns waveform loading independently from playback progress. A live TimelineView can redraw
/// only its clipped highlight without re-running hot-cache lookup, task setup, or load state.
private struct WaveformSamplesHost<Content: View>: View {
    let fileURL: URL?
    let loadIdentity: String
    @ViewBuilder let content: ([Float], Bool) -> Content

    @State private var samples: [Float]
    @State private var loadFailed = false
    @State private var loadedIdentity: String?

    init(
        fileURL: URL?,
        loadIdentity: String,
        @ViewBuilder content: @escaping ([Float], Bool) -> Content
    ) {
        self.fileURL = fileURL
        self.loadIdentity = loadIdentity
        self.content = content
        let hotSamples = WaveformHotCache.shared.samples(for: loadIdentity)
        _samples = State(initialValue: hotSamples ?? [])
        _loadedIdentity = State(initialValue: hotSamples == nil ? nil : loadIdentity)
    }

    var body: some View {
        content(samples, loadFailed)
            .task(id: loadIdentity) {
                await loadWaveform()
            }
    }

    @MainActor
    private func loadWaveform() async {
        guard let fileURL else {
            samples = []
            loadFailed = false
            loadedIdentity = loadIdentity
            return
        }

        if loadedIdentity == loadIdentity, !samples.isEmpty {
            return
        }
        if let hotSamples = WaveformHotCache.shared.samples(for: loadIdentity) {
            samples = hotSamples
            loadFailed = false
            loadedIdentity = loadIdentity
            return
        }

        samples = []
        loadFailed = false
        do {
            // A row crossed during a fast fling usually lives for only a few milliseconds.
            // Waiting briefly prevents transient rows from starting file I/O and decoding.
            try await Task.sleep(for: .milliseconds(48))
            try Task.checkCancellation()
            let loaded = try await WaveformSampleCache.shared.samples(for: fileURL)
            guard !Task.isCancelled else { return }
            WaveformHotCache.shared.store(loaded, for: loadIdentity)
            samples = loaded
            loadedIdentity = loadIdentity
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            samples = []
            loadFailed = true
            loadedIdentity = loadIdentity
        }
    }
}

/// Pure drawing surface. Live playback composes one static base surface with one clipped dynamic
/// surface, while scrub gestures can still render both layers together for exact pointer tracking.
private struct WaveformCanvas: View {
    let samples: [Float]
    let loadIdentity: String
    let progress: Double?
    let playedColor: Color
    let unplayedColor: Color
    let loadFailed: Bool
    let rendersAsynchronously: Bool
    var drawsUnplayedLayer = true
    var drawsPlayedLayer = true
    var drawsPlaceholder = true
    @Environment(\.isWindowLiveResizing) private var isWindowLiveResizing

    var body: some View {
        if isWindowLiveResizing {
            GeometryReader { geometry in
                Rectangle()
                    .fill(unplayedColor.opacity(0.42))
                    .frame(height: 1)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    .accessibilityHidden(true)
            }
        } else {
        Canvas(opaque: false, rendersAsynchronously: rendersAsynchronously) { context, size in
            guard !samples.isEmpty else {
                if drawsPlaceholder {
                    drawPlaceholder(in: &context, size: size)
                }
                return
            }

            let path = waveformPath(in: size)

            let lineWidth = waveformLineWidth(for: size)

            if drawsUnplayedLayer {
                context.stroke(path, with: .color(unplayedColor), lineWidth: lineWidth)
            }

            guard drawsPlayedLayer, let progress else { return }
            let clampedProgress = min(max(progress, 0), 1)
            guard clampedProgress > 0 else { return }
            let playedWidth = size.width * clampedProgress

            context.drawLayer { playedLayer in
                playedLayer.clip(
                    to: Path(CGRect(x: 0, y: 0, width: playedWidth, height: size.height))
                )
                playedLayer.stroke(
                    path,
                    with: .linearGradient(
                        Gradient(colors: [
                            playedColor.opacity(0.78),
                            playedColor,
                            ShixiangTheme.gold.opacity(0.92)
                        ]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: max(playedWidth, 1), y: 0)
                    ),
                    lineWidth: lineWidth
                )
            }

            if clampedProgress < 1 {
                let marker = CGRect(
                    x: max(0, playedWidth - 0.5),
                    y: 2,
                    width: 1,
                    height: max(0, size.height - 4)
                )
                context.fill(Path(marker), with: .color(playedColor.opacity(0.72)))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        }
    }

    private var accessibilityDescription: String {
        if loadFailed { return "波形不可用" }
        guard let progress else { return "音频波形" }
        return "音频波形，已播放 \(Int(min(max(progress, 0), 1) * 100))%"
    }

    private func waveformPath(in size: CGSize) -> Path {
        let cacheKey = "\(loadIdentity)|\(Int((size.width * 2).rounded()))x\(Int((size.height * 2).rounded()))"
        if let cached = WaveformPathCache.shared.path(for: cacheKey) {
            return cached
        }

        let midY = size.height / 2
        let count = samples.count
        let step = count > 1 ? size.width / CGFloat(count - 1) : size.width
        let maxHalfHeight = max(1, (size.height / 2) - 1)
        var path = Path()

        for (index, sample) in samples.enumerated() {
            let x = CGFloat(index) * step
            let halfHeight = max(1, CGFloat(sample) * maxHalfHeight)
            path.move(to: CGPoint(x: x, y: midY - halfHeight))
            path.addLine(to: CGPoint(x: x, y: midY + halfHeight))
        }
        WaveformPathCache.shared.store(path, for: cacheKey)
        return path
    }

    private func waveformLineWidth(for size: CGSize) -> CGFloat {
        guard samples.count > 1 else { return 1 }
        let step = size.width / CGFloat(samples.count - 1)
        return max(1, min(1.6, step * 0.55))
    }

    private func drawPlaceholder(in context: inout GraphicsContext, size: CGSize) {
        let y = size.height / 2
        var path = Path()
        path.move(to: CGPoint(x: 0, y: y))
        path.addLine(to: CGPoint(x: size.width, y: y))
        context.stroke(
            path,
            with: .color(loadFailed ? Color.secondary.opacity(0.18) : unplayedColor.opacity(0.65)),
            style: StrokeStyle(lineWidth: 1, dash: loadFailed ? [3, 3] : [])
        )
    }
}

/// NSCache is thread-safe and gives newly recycled list rows an immediate waveform without
/// scheduling actor work or touching the filesystem on the scrolling thread.
private final class WaveformHotCache: @unchecked Sendable {
    static let shared = WaveformHotCache()

    private let cache = NSCache<NSString, WaveformSamplesBox>()

    private init() {
        cache.countLimit = 800
    }

    func samples(for identity: String) -> [Float]? {
        cache.object(forKey: identity as NSString)?.samples
    }

    func store(_ samples: [Float], for identity: String) {
        guard !samples.isEmpty else { return }
        cache.setObject(WaveformSamplesBox(samples), forKey: identity as NSString)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

private final class WaveformPathCache: @unchecked Sendable {
    static let shared = WaveformPathCache()

    private let cache = NSCache<NSString, WaveformPathBox>()

    private init() {
        cache.countLimit = 640
    }

    func path(for key: String) -> Path? {
        cache.object(forKey: key as NSString)?.path
    }

    func store(_ path: Path, for key: String) {
        cache.setObject(WaveformPathBox(path), forKey: key as NSString)
    }
}

private final class WaveformPathBox: NSObject {
    let path: Path

    init(_ path: Path) {
        self.path = path
    }
}

private final class WaveformSamplesBox: NSObject {
    let samples: [Float]

    init(_ samples: [Float]) {
        self.samples = samples
    }
}

extension SoundItem {
    /// Scanner metadata changes when a source file is replaced, invalidating the hot thumbnail.
    var waveformCacheIdentity: String {
        "\(id.uuidString)|\(duration)|\(sampleRate ?? 0)|\(channelCount ?? 0)|\(sourceFileSize ?? -1)|\(sourceModificationDate?.timeIntervalSince1970 ?? 0)"
    }
}

private actor WaveformSampleCache {
    static let shared = WaveformSampleCache()

    private var values: [WaveformCacheKey: [Float]] = [:]
    private let maximumMemoryEntries = 400
    private let cacheDirectory: URL
    private var maintenanceScheduled = false

    init() {
        cacheDirectory = WaveformCacheMaintenance.directoryURL
    }

    func samples(for url: URL) async throws -> [Float] {
        try Task.checkCancellation()
        if !maintenanceScheduled {
            maintenanceScheduled = true
            WaveformCacheMaintenance.scheduleBackgroundMaintenanceIfNeeded()
        }
        let key = WaveformCacheKey(url: url, bucketCount: 180)
        if let cached = values[key] {
            return cached
        }
        try Task.checkCancellation()
        if let cached = readFromDisk(for: key) {
            remember(cached, for: key)
            return cached
        }

        try Task.checkCancellation()
        let samples = try WaveformSampler.sample(url: url, bucketCount: key.bucketCount)
        try Task.checkCancellation()
        remember(samples, for: key)
        writeToDisk(samples, for: key)
        return samples
    }

    func clearMemory() {
        values.removeAll(keepingCapacity: false)
    }

    private func remember(_ samples: [Float], for key: WaveformCacheKey) {
        if values.count >= maximumMemoryEntries, let firstKey = values.keys.first {
            values.removeValue(forKey: firstKey)
        }
        values[key] = samples
    }

    private func readFromDisk(for key: WaveformCacheKey) -> [Float]? {
        let fileURL = cacheDirectory.appendingPathComponent(key.cacheFileName)
        guard let data = try? Data(contentsOf: fileURL),
              data.count == key.bucketCount * MemoryLayout<Float>.size else {
            return nil
        }
        var samples = Array(repeating: Float.zero, count: key.bucketCount)
        _ = samples.withUnsafeMutableBytes { destination in
            data.copyBytes(to: destination)
        }
        return samples
    }

    private func writeToDisk(_ samples: [Float], for key: WaveformCacheKey) {
        guard !samples.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
            let data = samples.withUnsafeBufferPointer { buffer in
                Data(
                    bytes: buffer.baseAddress!,
                    count: buffer.count * MemoryLayout<Float>.size
                )
            }
            try data.write(
                to: cacheDirectory.appendingPathComponent(key.cacheFileName),
                options: .atomic
            )
        } catch {
            // A cache failure must never make a usable sound disappear from the library.
        }
    }
}

struct WaveformCachePolicy: Sendable, Equatable {
    /// A waveform uses 180 Float32 buckets (720 bytes) plus filesystem overhead. 256 MB is
    /// enough for very large libraries while still preventing an abandoned cache from growing
    /// without bound.
    let maximumBytes: Int64
    let maximumAge: TimeInterval

    static let `default` = Self(
        maximumBytes: 256 * 1_024 * 1_024,
        maximumAge: 90 * 24 * 60 * 60
    )
}

struct WaveformCacheMaintenanceReport: Sendable, Equatable {
    let scannedFiles: Int
    let removedFiles: Int
    let removedBytes: Int64
    let remainingBytes: Int64
}

enum WaveformCacheMaintenance {
    static var directoryURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("Shixiang", isDirectory: true)
            .appendingPathComponent("Waveforms", isDirectory: true)
    }

    static func sizeInBytes(in directory: URL = directoryURL) async -> Int64 {
        await Task.detached(priority: .utility) {
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { return 0 }
            var total: Int64 = 0
            while let url = enumerator.nextObject() as? URL {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            return total
        }.value
    }

    /// Schedules a low-priority sweep without making the caller await filesystem work. The
    /// sample cache calls this once per process after the first waveform request.
    static func scheduleBackgroundMaintenanceIfNeeded() {
        Task.detached(priority: .utility) {
            _ = await Self.pruneIfNeeded()
        }
    }

    /// Removes expired entries first, then oldest entries until the configured byte budget is
    /// met. Enumeration, stat calls and deletes all happen on a utility task, never on the UI
    /// actor. The optional directory/policy parameters make this deterministic to test and leave
    /// room for a future user-facing cache setting.
    static func pruneIfNeeded(
        in directory: URL = directoryURL,
        policy: WaveformCachePolicy = .default,
        now: Date = Date()
    ) async -> WaveformCacheMaintenanceReport {
        await Task.detached(priority: .utility) {
            pruneSynchronously(in: directory, policy: policy, now: now)
        }.value
    }

    /// Fire-and-forget cache reset for UI actions. The caller gets a task immediately and can
    /// update its own progress state without blocking pointer tracking or scrolling.
    @discardableResult
    static func clearInBackground(
        in directory: URL = directoryURL
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            await Self.clear(in: directory)
        }
    }

    static func clear(in directory: URL = directoryURL) async {
        WaveformHotCache.shared.removeAll()
        await WaveformSampleCache.shared.clearMemory()
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }.value
    }

    private struct DiskEntry: Sendable {
        let url: URL
        let size: Int64
        let modifiedAt: Date
    }

    private static func pruneSynchronously(
        in directory: URL,
        policy: WaveformCachePolicy,
        now: Date
    ) -> WaveformCacheMaintenanceReport {
        let fileManager = FileManager.default
        guard policy.maximumBytes >= 0,
              let enumerator = fileManager.enumerator(
                  at: directory,
                  includingPropertiesForKeys: [
                      .fileSizeKey,
                      .contentModificationDateKey,
                      .isRegularFileKey
                  ],
                  options: [.skipsHiddenFiles]
              ) else {
            return WaveformCacheMaintenanceReport(
                scannedFiles: 0,
                removedFiles: 0,
                removedBytes: 0,
                remainingBytes: 0
            )
        }

        var entries: [DiskEntry] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension.caseInsensitiveCompare("waveform") == .orderedSame,
                  let values = try? url.resourceValues(
                      forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true else {
                continue
            }
            entries.append(
                DiskEntry(
                    url: url,
                    size: Int64(max(0, values.fileSize ?? 0)),
                    modifiedAt: values.contentModificationDate ?? .distantPast
                )
            )
        }

        let cutoff = now.addingTimeInterval(-max(0, policy.maximumAge))
        var remainingBytes = entries.reduce(Int64.zero) { $0 + $1.size }
        var removedFiles = 0
        var removedBytes: Int64 = 0

        func remove(_ entry: DiskEntry) {
            guard fileManager.fileExists(atPath: entry.url.path),
                  (try? fileManager.removeItem(at: entry.url)) != nil else {
                return
            }
            removedFiles += 1
            removedBytes += entry.size
            remainingBytes = max(0, remainingBytes - entry.size)
        }

        let expiredURLs = Set(
            entries
                .filter { $0.modifiedAt < cutoff }
                .map(\.url)
        )
        for entry in entries where expiredURLs.contains(entry.url) {
            remove(entry)
        }
        let remaining = entries.filter { !expiredURLs.contains($0.url) }

        if remainingBytes > policy.maximumBytes {
            let oldestFirst = remaining.sorted { lhs, rhs in
                if lhs.modifiedAt == rhs.modifiedAt { return lhs.url.path < rhs.url.path }
                return lhs.modifiedAt < rhs.modifiedAt
            }
            for entry in oldestFirst where remainingBytes > policy.maximumBytes {
                remove(entry)
            }
        }

        return WaveformCacheMaintenanceReport(
            scannedFiles: entries.count,
            removedFiles: removedFiles,
            removedBytes: removedBytes,
            remainingBytes: remainingBytes
        )
    }
}

private struct WaveformCacheKey: Hashable {
    let path: String
    let modificationDate: Date?
    let fileSize: Int?
    let bucketCount: Int

    init(url: URL, bucketCount: Int) {
        path = url.standardizedFileURL.path
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        modificationDate = values?.contentModificationDate
        fileSize = values?.fileSize
        self.bucketCount = bucketCount
    }

    var fingerprint: String {
        "\(path)|\(modificationDate?.timeIntervalSinceReferenceDate ?? 0)|\(fileSize ?? 0)|\(bucketCount)"
    }

    var cacheFileName: String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in fingerprint.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx.waveform", hash)
    }
}

private enum WaveformSampler {
    /// Short sounds receive an exact full scan. Long recordings use a fixed decode budget,
    /// so a one-hour ambience file does not consume sixty times the work of a one-minute file.
    private static let maximumFullyScannedFrames: Int64 = 3_000_000
    private static let longFileWindowFrames: AVAudioFrameCount = 4_096

    static func sample(url: URL, bucketCount: Int) throws -> [Float] {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let audioFile = try AVAudioFile(forReading: url)
        let totalFrames = max(0, audioFile.length)
        guard totalFrames > 0 else { return [] }

        let safeBucketCount = max(24, bucketCount)
        let peaks: [Float]
        if totalFrames <= maximumFullyScannedFrames {
            peaks = try exactPeaks(
                audioFile: audioFile,
                totalFrames: totalFrames,
                bucketCount: safeBucketCount
            )
        } else {
            peaks = try sampledPeaks(
                audioFile: audioFile,
                totalFrames: totalFrames,
                bucketCount: safeBucketCount
            )
        }
        return normalized(peaks)
    }

    private static func exactPeaks(
        audioFile: AVAudioFile,
        totalFrames: Int64,
        bucketCount: Int
    ) throws -> [Float] {
        let format = audioFile.processingFormat
        let framesPerBucket = max(1, Int64(ceil(Double(totalFrames) / Double(bucketCount))))
        var peaks = Array(repeating: Float.zero, count: bucketCount)
        var framesRead: Int64 = 0

        while framesRead < totalFrames {
            try Task.checkCancellation()
            let requestedFrames = AVAudioFrameCount(min(8_192, totalFrames - framesRead))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: requestedFrames) else {
                throw WaveformSamplingError.couldNotAllocateBuffer
            }
            try audioFile.read(into: buffer, frameCount: requestedFrames)
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { break }
            guard let channelData = buffer.floatChannelData else {
                throw WaveformSamplingError.unsupportedPCMLayout
            }

            let channelCount = max(1, Int(format.channelCount))
            for frame in 0..<frameLength {
                var peak: Float = 0
                for channel in 0..<channelCount {
                    peak = max(peak, abs(channelData[channel][frame]))
                }
                let bucket = min(
                    bucketCount - 1,
                    Int((framesRead + Int64(frame)) / framesPerBucket)
                )
                peaks[bucket] = max(peaks[bucket], peak)
            }
            framesRead += Int64(frameLength)
        }
        return peaks
    }

    private static func sampledPeaks(
        audioFile: AVAudioFile,
        totalFrames: Int64,
        bucketCount: Int
    ) throws -> [Float] {
        let format = audioFile.processingFormat
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: longFileWindowFrames
        ) else {
            throw WaveformSamplingError.couldNotAllocateBuffer
        }

        let framesPerBucket = Double(totalFrames) / Double(bucketCount)
        var peaks = Array(repeating: Float.zero, count: bucketCount)
        for bucket in 0..<bucketCount {
            try Task.checkCancellation()
            let segmentStart = Int64(Double(bucket) * framesPerBucket)
            let segmentEnd = min(totalFrames, Int64(Double(bucket + 1) * framesPerBucket))
            let segmentLength = max(1, segmentEnd - segmentStart)
            let requested = AVAudioFrameCount(min(Int64(longFileWindowFrames), segmentLength))
            let start = segmentStart + max(0, (segmentLength - Int64(requested)) / 2)

            audioFile.framePosition = start
            try audioFile.read(into: buffer, frameCount: requested)
            peaks[bucket] = try peak(in: buffer, channelCount: Int(format.channelCount))
        }
        return peaks
    }

    private static func peak(in buffer: AVAudioPCMBuffer, channelCount: Int) throws -> Float {
        guard let channelData = buffer.floatChannelData else {
            throw WaveformSamplingError.unsupportedPCMLayout
        }
        var result: Float = 0
        for channel in 0..<max(1, channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                result = max(result, abs(channelData[channel][frame]))
            }
        }
        return result
    }

    private static func normalized(_ peaks: [Float]) -> [Float] {
        let maximum = peaks.max() ?? 0
        guard maximum > 0 else { return peaks }
        return peaks.map { min(1, $0 / maximum) }
    }
}

private enum WaveformSamplingError: LocalizedError {
    case couldNotAllocateBuffer
    case unsupportedPCMLayout

    var errorDescription: String? {
        switch self {
        case .couldNotAllocateBuffer:
            return "无法创建波形缓冲区。"
        case .unsupportedPCMLayout:
            return "暂不支持此音频的采样格式。"
        }
    }
}
