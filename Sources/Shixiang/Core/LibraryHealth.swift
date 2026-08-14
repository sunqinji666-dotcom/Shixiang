import Foundation

struct LibraryHealthSnapshot: Sendable {
    let packs: [LibraryHealthPack]
    let items: [LibraryHealthItem]
    let databaseBytes: Int64
    let hasRecoveryBackup: Bool
}

enum LibraryHealthSnapshotBuilder {
    static func make(
        packs: [SoundPack],
        scopedRootURLs: [UUID: URL],
        databaseBytes: Int64,
        hasRecoveryBackup: Bool
    ) throws -> LibraryHealthSnapshot {
        var healthPacks: [LibraryHealthPack] = []
        healthPacks.reserveCapacity(packs.count)
        var healthItems: [LibraryHealthItem] = []
        healthItems.reserveCapacity(packs.reduce(0) { $0 + $1.items.count })

        for pack in packs {
            try Task.checkCancellation()
            let rootURL = scopedRootURLs[pack.id]
                ?? URL(fileURLWithPath: pack.rootPath, isDirectory: true).standardizedFileURL
            healthPacks.append(LibraryHealthPack(id: pack.id, name: pack.name, rootURL: rootURL))
            for (index, item) in pack.items.enumerated() {
                if index.isMultiple(of: 512) { try Task.checkCancellation() }
                healthItems.append(
                    LibraryHealthItem(
                        id: item.id,
                        packID: pack.id,
                        packName: pack.name,
                        displayName: item.displayName,
                        relativePath: item.relativePath,
                        url: rootURL.appendingPathComponent(item.relativePath, isDirectory: false),
                        sourceFileSize: item.sourceFileSize,
                        sourceModificationDate: item.sourceModificationDate,
                        sourceContentSignature: item.sourceContentSignature,
                        isHidden: item.isHidden
                    )
                )
            }
        }

        return LibraryHealthSnapshot(
            packs: healthPacks,
            items: healthItems,
            databaseBytes: databaseBytes,
            hasRecoveryBackup: hasRecoveryBackup
        )
    }
}

struct LibraryHealthPack: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let rootURL: URL
}

struct LibraryHealthItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let packID: UUID
    let packName: String
    let displayName: String
    let relativePath: String
    let url: URL
    let sourceFileSize: Int64?
    let sourceModificationDate: Date?
    let sourceContentSignature: UInt64?
    let isHidden: Bool

    init(
        id: UUID,
        packID: UUID,
        packName: String,
        displayName: String,
        relativePath: String,
        url: URL,
        sourceFileSize: Int64? = nil,
        sourceModificationDate: Date? = nil,
        sourceContentSignature: UInt64? = nil,
        isHidden: Bool = false
    ) {
        self.id = id
        self.packID = packID
        self.packName = packName
        self.displayName = displayName
        self.relativePath = relativePath
        self.url = url
        self.sourceFileSize = sourceFileSize
        self.sourceModificationDate = sourceModificationDate
        self.sourceContentSignature = sourceContentSignature
        self.isHidden = isHidden
    }
}

struct LibraryDuplicateGroup: Identifiable, Hashable, Sendable {
    let fingerprint: String
    let fileSize: Int64
    let items: [LibraryHealthItem]
    var id: String { fingerprint }
}

struct LibraryHealthReport: Sendable {
    let checkedAt: Date
    let totalCount: Int
    let missingItems: [LibraryHealthItem]
    let inaccessiblePacks: [LibraryHealthPack]
    let duplicateGroups: [LibraryDuplicateGroup]
    let databaseBytes: Int64
    let waveformCacheBytes: Int64
    let hasRecoveryBackup: Bool
    let reusedFingerprintCount: Int

    var probableDuplicateCount: Int {
        duplicateGroups.reduce(0) { $0 + max(0, $1.items.count - 1) }
    }
}

struct LibraryHealthProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case files
        case duplicates
        case finishing

        var title: String {
            switch self {
            case .files: return "正在核对素材路径"
            case .duplicates: return "正在识别疑似重复"
            case .finishing: return "正在整理体检结果"
            }
        }
    }

    let phase: Phase
    let completed: Int
    let total: Int

    var fraction: Double? {
        guard total > 0 else { return nil }
        return min(max(Double(completed) / Double(total), 0), 1)
    }
}

enum LibraryHealthService {
    private static let fingerprintCache = DuplicateFingerprintCache()

    static func inspect(
        _ snapshot: LibraryHealthSnapshot,
        progress: (@Sendable (LibraryHealthProgress) -> Void)? = nil
    ) async throws -> LibraryHealthReport {
        let waveformBytes = await WaveformCacheMaintenance.sizeInBytes()
        return try await Task.detached(priority: .utility) {
            try inspectSynchronously(
                snapshot,
                waveformBytes: waveformBytes,
                progress: progress
            )
        }.value
    }

    private static func inspectSynchronously(
        _ snapshot: LibraryHealthSnapshot,
        waveformBytes: Int64,
        progress: (@Sendable (LibraryHealthProgress) -> Void)?
    ) throws -> LibraryHealthReport {
        let fileManager = FileManager.default
        let inaccessiblePacks = snapshot.packs.filter {
            var directory: ObjCBool = false
            return !fileManager.fileExists(atPath: $0.rootURL.path, isDirectory: &directory)
                || !directory.boolValue
                || !fileManager.isReadableFile(atPath: $0.rootURL.path)
        }

        var missing: [LibraryHealthItem] = []
        var candidatesBySize: [Int64: [DuplicateCandidate]] = [:]
        missing.reserveCapacity(64)

        let fileProgressStep = max(1, snapshot.items.count / 100)
        progress?(LibraryHealthProgress(phase: .files, completed: 0, total: snapshot.items.count))
        for (index, item) in snapshot.items.enumerated() {
            try Task.checkCancellation()
            if let values = try? item.url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            ),
               values.isRegularFile == true,
               fileManager.isReadableFile(atPath: item.url.path) {
                let size = Int64(values.fileSize ?? 0)
                if size > 0 {
                    let cachedFingerprint: String?
                    if item.sourceFileSize == size,
                       SourceModificationDatePolicy.matches(
                           item.sourceModificationDate,
                           values.contentModificationDate
                       ),
                       let signature = item.sourceContentSignature {
                        cachedFingerprint = fingerprint(fileSize: size, signature: signature)
                    } else {
                        cachedFingerprint = nil
                    }
                    let cacheKey = DuplicateFingerprintCache.Key(
                        path: item.url.standardizedFileURL.path,
                        fileSize: size,
                        modificationDate: values.contentModificationDate
                    )
                    candidatesBySize[size, default: []].append(
                        DuplicateCandidate(
                            item: item,
                            cachedFingerprint: cachedFingerprint,
                            cacheKey: cacheKey
                        )
                    )
                }
            } else {
                missing.append(item)
            }
            let completed = index + 1
            if completed == snapshot.items.count || completed.isMultiple(of: fileProgressStep) {
                progress?(LibraryHealthProgress(
                    phase: .files,
                    completed: completed,
                    total: snapshot.items.count
                ))
            }
        }

        var duplicateGroups: [LibraryDuplicateGroup] = []
        var reusedFingerprintCount = 0
        let duplicateCandidates = candidatesBySize.filter { $0.value.count > 1 }
        progress?(LibraryHealthProgress(
            phase: .duplicates,
            completed: 0,
            total: duplicateCandidates.count
        ))
        for (groupIndex, entry) in duplicateCandidates.enumerated() {
            try Task.checkCancellation()
            let (size, sameSizeItems) = entry
            var byFingerprint: [String: [LibraryHealthItem]] = [:]
            for candidate in sameSizeItems {
                try Task.checkCancellation()
                let fingerprint: String?
                if let cached = candidate.cachedFingerprint {
                    fingerprint = cached
                    reusedFingerprintCount += 1
                } else if let cached = fingerprintCache.fingerprint(for: candidate.cacheKey) {
                    fingerprint = cached
                    reusedFingerprintCount += 1
                } else {
                    fingerprint = sampledFingerprint(for: candidate.item.url, fileSize: size)
                    if let fingerprint {
                        fingerprintCache.store(fingerprint, for: candidate.cacheKey)
                    }
                }
                if let fingerprint {
                    byFingerprint[fingerprint, default: []].append(candidate.item)
                }
            }
            duplicateGroups.append(contentsOf: byFingerprint.compactMap { fingerprint, items in
                guard items.count > 1 else { return nil }
                return LibraryDuplicateGroup(
                    fingerprint: fingerprint,
                    fileSize: size,
                    items: items.sorted {
                        $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
                    }
                )
            })
            progress?(LibraryHealthProgress(
                phase: .duplicates,
                completed: groupIndex + 1,
                total: duplicateCandidates.count
            ))
        }

        duplicateGroups.sort {
            if $0.items.count == $1.items.count { return $0.fileSize > $1.fileSize }
            return $0.items.count > $1.items.count
        }
        missing.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        progress?(LibraryHealthProgress(phase: .finishing, completed: 1, total: 1))

        return LibraryHealthReport(
            checkedAt: Date(),
            totalCount: snapshot.items.count,
            missingItems: missing,
            inaccessiblePacks: inaccessiblePacks,
            duplicateGroups: duplicateGroups,
            databaseBytes: snapshot.databaseBytes,
            waveformCacheBytes: waveformBytes,
            hasRecoveryBackup: snapshot.hasRecoveryBackup,
            reusedFingerprintCount: reusedFingerprintCount
        )
    }

    /// A size plus head/tail signature is intentionally reported as "probable duplicate".
    /// This is the same signature used by incremental scanning, so ignored group identities
    /// remain stable before and after a refresh. The operation never changes either source.
    private static func sampledFingerprint(for url: URL, fileSize: Int64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let sampleLength = 4_096
        var signature: UInt64 = 14_695_981_039_346_656_037
        func absorb(_ data: Data) {
            for byte in data {
                signature ^= UInt64(byte)
                signature &*= 1_099_511_628_211
            }
        }

        guard let head = try? handle.read(upToCount: min(sampleLength, Int(fileSize))) else {
            return nil
        }
        absorb(head)
        if fileSize > Int64(sampleLength) {
            guard (try? handle.seek(toOffset: UInt64(fileSize - Int64(sampleLength)))) != nil,
                  let tail = try? handle.read(upToCount: sampleLength) else {
                return nil
            }
            absorb(tail)
        }
        return fingerprint(fileSize: fileSize, signature: signature)
    }

    private static func fingerprint(fileSize: Int64, signature: UInt64) -> String {
        "sample-v1:\(fileSize):\(signature)"
    }
}

private struct DuplicateCandidate {
    let item: LibraryHealthItem
    let cachedFingerprint: String?
    let cacheKey: DuplicateFingerprintCache.Key
}

private final class DuplicateFingerprintCache: @unchecked Sendable {
    struct Key: Hashable {
        let path: String
        let fileSize: Int64
        let modificationDate: Date?
    }

    private let lock = NSLock()
    private var values: [Key: String] = [:]
    private let maximumEntries = 100_000

    func fingerprint(for key: Key) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func store(_ fingerprint: String, for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        if values.count >= maximumEntries, values[key] == nil {
            values.removeAll(keepingCapacity: true)
        }
        values[key] = fingerprint
    }
}
