import Foundation
@preconcurrency import AVFoundation

struct LibraryScanner: Sendable {
    static let supportedExtensions: Set<String> = [
        "wav", "wave", "aiff", "aif", "mp3", "m4a", "caf", "flac"
    ]

    func scan(
        rootURL: URL,
        packageID: UUID,
        existingItems: [SoundItem] = [],
        forceAudioMetadataRefresh: Bool = false
    ) async throws -> [SoundItem] {
        try await scanResult(
            rootURL: rootURL,
            packageID: packageID,
            existingItems: existingItems,
            forceAudioMetadataRefresh: forceAudioMetadataRefresh
        ).items
    }

    /// Scans a package and reports any source identities retained across a path change.
    /// The legacy `scan` method remains available for callers that only need the item array.
    func scanResult(
        rootURL: URL,
        packageID: UUID,
        existingItems: [SoundItem] = [],
        forceAudioMetadataRefresh: Bool = false,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> LibraryScanResult {
        let scanTask = Task.detached(priority: .userInitiated) {
            try await Self.scanInBackground(
                rootURL: rootURL,
                packageID: packageID,
                existingItems: existingItems,
                forceAudioMetadataRefresh: forceAudioMetadataRefresh,
                progress: progress
            )
        }
        return try await withTaskCancellationHandler {
            try await scanTask.value
        } onCancel: {
            scanTask.cancel()
        }
    }

    static func isSupportedAudioFile(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func relativePath(for fileURL: URL, under rootURL: URL) -> String? {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let fileComponents = fileURL.standardizedFileURL.pathComponents

        guard fileComponents.count > rootComponents.count,
              Array(fileComponents.prefix(rootComponents.count)) == rootComponents else {
            return nil
        }

        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    static func folderPath(forRelativePath relativePath: String) -> String {
        let value = (relativePath as NSString).deletingLastPathComponent
        return value == "." ? "" : value
    }

    private static func scanInBackground(
        rootURL: URL,
        packageID: UUID,
        existingItems: [SoundItem],
        forceAudioMetadataRefresh: Bool,
        progress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> LibraryScanResult {
        let candidates = try collectCandidates(
            rootURL: rootURL,
            existingItems: existingItems,
            forceAudioMetadataRefresh: forceAudioMetadataRefresh
        )

        if entirelyReusesExistingSnapshot(candidates, existingItems: existingItems) {
            progress?(0, candidates.count)
            if !candidates.isEmpty {
                progress?(candidates.count, candidates.count)
            }
            return LibraryScanResult(
                packageID: packageID,
                items: existingItems,
                migrations: [],
                statistics: LibraryScanStatistics(
                    discoveredCount: candidates.count,
                    reusedCount: candidates.count,
                    analyzedCount: 0,
                    addedCount: 0,
                    removedCount: 0,
                    updatedCount: 0
                ),
                completedAt: Date()
            )
        }

        var iterator = candidates.makeIterator()
        var scanned: [SoundItem] = []
        scanned.reserveCapacity(candidates.count)
        let workerCount = min(4, max(1, candidates.count))
        let progressStep = max(1, candidates.count / 100)
        progress?(0, candidates.count)

        try await withThrowingTaskGroup(of: SoundItem.self) { group in
            func enqueue(_ candidate: ScanCandidate) {
                group.addTask(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let previousItem = candidate.previousIndex.map { existingItems[$0] }
                    let metadata = candidate.reusesAudioMetadata
                        ? AudioMetadata(previousItem: previousItem)
                        : (audioMetadata(at: candidate.fileURL)
                            ?? AudioMetadata(previousItem: previousItem))
                    return SoundItem(
                        id: previousItem?.id ?? UUID(),
                        packageID: packageID,
                        relativePath: candidate.relativePath,
                        fileName: candidate.fileURL.lastPathComponent,
                        folderPath: folderPath(forRelativePath: candidate.relativePath),
                        fileExtension: candidate.fileURL.pathExtension.lowercased(),
                        duration: metadata.duration,
                        sampleRate: metadata.sampleRate,
                        channelCount: metadata.channelCount,
                        sourceFileSize: candidate.fileSize,
                        sourceModificationDate: candidate.modificationDate,
                        sourceContentSignature: candidate.contentSignature,
                        isFavorite: previousItem?.isFavorite ?? false,
                        isHidden: previousItem?.isHidden ?? false,
                        customName: previousItem?.customName,
                        tags: previousItem?.tags ?? []
                    )
                }
            }

            for _ in 0..<workerCount {
                if let candidate = iterator.next() {
                    enqueue(candidate)
                }
            }

            while let item = try await group.next() {
                scanned.append(item)
                if scanned.count == candidates.count || scanned.count.isMultiple(of: progressStep) {
                    progress?(scanned.count, candidates.count)
                }
                if let candidate = iterator.next() {
                    enqueue(candidate)
                }
            }
        }

        let completedAt = Date()
        let migrations = candidates.compactMap { candidate -> SourceMigrationRecord? in
            guard let previousIndex = candidate.previousIndex else { return nil }
            let previousItem = existingItems[previousIndex]
            guard previousItem.relativePath != candidate.relativePath else {
                return nil
            }
            return SourceMigrationRecord(
                soundID: previousItem.id,
                packageID: packageID,
                fromRelativePath: previousItem.relativePath,
                toRelativePath: candidate.relativePath,
                detectedAt: completedAt
            )
        }
        let sortedItems = scanned.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        let previousIDs = Set(existingItems.map(\.id))
        let scannedIDs = Set(sortedItems.map(\.id))
        let addedCount = scannedIDs.subtracting(previousIDs).count
        let removedCount = previousIDs.subtracting(scannedIDs).count
        let updatedCount = candidates.reduce(into: 0) { count, candidate in
            guard let previousIndex = candidate.previousIndex else { return }
            let previous = existingItems[previousIndex]
            guard previous.relativePath == candidate.relativePath,
                  !candidate.reusesAudioMetadata else { return }
            count += 1
        }
        let reusedCount = candidates.lazy.filter(\.reusesAudioMetadata).count
        return LibraryScanResult(
            packageID: packageID,
            items: sortedItems,
            migrations: migrations.sorted {
                $0.toRelativePath.localizedStandardCompare($1.toRelativePath) == .orderedAscending
            },
            statistics: LibraryScanStatistics(
                discoveredCount: sortedItems.count,
                reusedCount: reusedCount,
                analyzedCount: max(0, sortedItems.count - reusedCount),
                addedCount: addedCount,
                removedCount: removedCount,
                updatedCount: updatedCount
            ),
            completedAt: completedAt
        )
    }

    private static func entirelyReusesExistingSnapshot(
        _ candidates: [ScanCandidate],
        existingItems: [SoundItem]
    ) -> Bool {
        guard !existingItems.isEmpty, candidates.count == existingItems.count else {
            return false
        }
        for candidate in candidates {
            guard candidate.reusesAudioMetadata,
                  let previousIndex = candidate.previousIndex,
                  existingItems.indices.contains(previousIndex),
                  existingItems[previousIndex].relativePath == candidate.relativePath else {
                return false
            }
        }
        return true
    }

    private static func collectCandidates(
        rootURL: URL,
        existingItems: [SoundItem],
        forceAudioMetadataRefresh: Bool
    ) throws -> [ScanCandidate] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isHiddenKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        var enumerationError: (url: URL, error: Error)?
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                if enumerationError == nil {
                    enumerationError = (url, error)
                }
                return false
            }
        ) else {
            throw LibraryScannerError.cannotEnumerate(rootURL)
        }

        var previousIndexByPath: [String: Int] = [:]
        previousIndexByPath.reserveCapacity(existingItems.count)
        for (index, item) in existingItems.enumerated() {
            previousIndexByPath[item.relativePath] = index
        }
        var candidates: [ScanCandidate] = []
        candidates.reserveCapacity(existingItems.count)

        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()
            guard isSupportedAudioFile(fileURL),
                  let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let relativePath = relativePath(for: fileURL, under: rootURL) else {
                continue
            }

            let fileSize = values.fileSize.map(Int64.init)
            let modificationDate = values.contentModificationDate
            let previousIndex = previousIndexByPath[relativePath]
            let reusesAudioMetadata = !forceAudioMetadataRefresh && (previousIndex.map {
                sourceFactsMatch(
                    previous: existingItems[$0],
                    fileSize: fileSize,
                    modificationDate: modificationDate
                )
            } ?? false)
            let previousSignature = previousIndex.flatMap {
                existingItems[$0].sourceContentSignature
            }

            candidates.append(
                ScanCandidate(
                    fileURL: fileURL,
                    relativePath: relativePath,
                    fileSize: fileSize,
                    modificationDate: modificationDate,
                    contentSignature: reusesAudioMetadata && previousSignature != nil
                        ? previousSignature
                        : fastContentSignature(at: fileURL),
                    previousIndex: previousIndex,
                    reusesAudioMetadata: reusesAudioMetadata
                )
            )
        }

        if let enumerationError {
            throw LibraryScannerError.enumerationFailed(
                rootURL,
                "\(enumerationError.url.lastPathComponent)：\(enumerationError.error.localizedDescription)"
            )
        }

        // A stable refresh has no unmatched paths, so it must not pay for a second full-library
        // fingerprint dictionary. Resolve fingerprints only when a new path can actually be a
        // rename, and only for fingerprints requested by those unmatched candidates.
        var fingerprintCandidates: [SoundSourceFingerprint: [Int]] = [:]
        for (index, candidate) in candidates.enumerated() {
            guard candidate.previousIndex == nil,
                  let fingerprint = candidate.sourceFingerprint else {
                continue
            }
            fingerprintCandidates[fingerprint, default: []].append(index)
        }
        guard !fingerprintCandidates.isEmpty else {
            return candidates
        }

        // Claim every unchanged relative path first. Filtering those claimed identities out of
        // the rename lookup lets one member of an otherwise duplicate pair move while the other
        // remains at its original path, without making the moved identity ambiguous.
        let pathMatchedIndices = Set(candidates.compactMap(\.previousIndex))
        let requestedFingerprints = Set(fingerprintCandidates.keys)
        var previousIndicesByFingerprint: [SoundSourceFingerprint: [Int]] = [:]
        previousIndicesByFingerprint.reserveCapacity(requestedFingerprints.count)
        for (index, item) in existingItems.enumerated() where !pathMatchedIndices.contains(index) {
            guard item.sourceContentSignature != nil,
                  let fingerprint = item.sourceFingerprint,
                  requestedFingerprints.contains(fingerprint) else {
                continue
            }
            previousIndicesByFingerprint[fingerprint, default: []].append(index)
        }

        for index in candidates.indices {
            let candidate = candidates[index]
            guard candidate.previousIndex == nil,
                  let fingerprint = candidate.sourceFingerprint,
                  fingerprintCandidates[fingerprint]?.count == 1,
                  let matches = previousIndicesByFingerprint[fingerprint],
                  matches.count == 1 else {
                continue
            }
            candidates[index].previousIndex = matches[0]
            candidates[index].reusesAudioMetadata = true
        }
        return candidates
    }

    private static func sourceFactsMatch(
        previous: SoundItem,
        fileSize: Int64?,
        modificationDate: Date?
    ) -> Bool {
        guard previous.sourceFileSize == fileSize,
              SourceModificationDatePolicy.matches(
                previous.sourceModificationDate,
                modificationDate
              ) else { return false }
        return true
    }

    private static func fastContentSignature(at url: URL) -> UInt64? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let sampleSize = 4_096
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize,
              fileSize > 0 else {
            return nil
        }

        var hash: UInt64 = 14_695_981_039_346_656_037
        func absorb(_ data: Data) {
            for byte in data {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
        }

        guard let head = try? handle.read(upToCount: min(sampleSize, fileSize)) else {
            return nil
        }
        absorb(head)
        if fileSize > sampleSize {
            guard (try? handle.seek(toOffset: UInt64(fileSize - sampleSize))) != nil,
                  let tail = try? handle.read(upToCount: sampleSize) else {
                return nil
            }
            absorb(tail)
        }
        return hash
    }

    private static func audioMetadata(at url: URL) -> AudioMetadata? {
        let playableURL = AudioPlaybackCompatibility.resolvedURL(for: url)
        guard let file = try? AVAudioFile(forReading: playableURL) else {
            return nil
        }

        let sampleRate = file.fileFormat.sampleRate
        let duration = sampleRate > 0 ? Double(file.length) / sampleRate : 0
        return AudioMetadata(
            duration: duration.isFinite ? max(0, duration) : 0,
            sampleRate: sampleRate.isFinite && sampleRate > 0 ? sampleRate : nil,
            channelCount: file.fileFormat.channelCount > 0
                ? Int(file.fileFormat.channelCount)
                : nil
        )
    }
}

private struct ScanCandidate: Sendable {
    let fileURL: URL
    let relativePath: String
    let fileSize: Int64?
    let modificationDate: Date?
    let contentSignature: UInt64?
    /// Refers into the one shared `existingItems` snapshot. Keeping an integer here avoids
    /// copying long paths, names and tag arrays into every scan candidate and lookup table.
    var previousIndex: Int?
    var reusesAudioMetadata: Bool

    var sourceFingerprint: SoundSourceFingerprint? {
        SoundSourceFingerprint(
            fileSize: fileSize,
            modificationDate: modificationDate,
            contentSignature: contentSignature
        )
    }
}

enum LibraryScannerError: LocalizedError {
    case cannotEnumerate(URL)
    case enumerationFailed(URL, String)

    var errorDescription: String? {
        switch self {
        case let .cannotEnumerate(url):
            return "无法读取音效包：\(url.lastPathComponent)"
        case let .enumerationFailed(url, detail):
            return "扫描音效包不完整：\(url.lastPathComponent)（\(detail)）"
        }
    }
}

private struct AudioMetadata: Sendable {
    let duration: Double
    let sampleRate: Double?
    let channelCount: Int?

    init(duration: Double, sampleRate: Double?, channelCount: Int?) {
        self.duration = duration
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    init(previousItem: SoundItem?) {
        duration = previousItem?.duration ?? 0
        sampleRate = previousItem?.sampleRate
        channelCount = previousItem?.channelCount
    }
}
