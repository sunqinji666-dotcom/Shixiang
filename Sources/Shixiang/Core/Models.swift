import Foundation

struct SoundItem: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let packageID: UUID
    let relativePath: String
    let fileName: String
    let folderPath: String
    let fileExtension: String
    let duration: Double
    let sampleRate: Double?
    let channelCount: Int?
    let sourceFileSize: Int64?
    let sourceModificationDate: Date?
    let sourceContentSignature: UInt64?
    var isFavorite: Bool
    /// A Shixiang-only visibility flag used by duplicate review. It never changes the source.
    var isHidden: Bool
    /// User-facing metadata owned by Shixiang. Neither field is written back to the source.
    var customName: String?
    var tags: [String]

    init(
        id: UUID = UUID(),
        packageID: UUID,
        relativePath: String,
        fileName: String,
        folderPath: String,
        fileExtension: String,
        duration: Double = 0,
        sampleRate: Double? = nil,
        channelCount: Int? = nil,
        sourceFileSize: Int64? = nil,
        sourceModificationDate: Date? = nil,
        sourceContentSignature: UInt64? = nil,
        isFavorite: Bool = false,
        isHidden: Bool = false,
        customName: String? = nil,
        tags: [String] = []
    ) {
        self.id = id
        self.packageID = packageID
        self.relativePath = relativePath
        self.fileName = fileName
        self.folderPath = folderPath
        self.fileExtension = fileExtension
        self.duration = duration
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.sourceFileSize = sourceFileSize
        self.sourceModificationDate = sourceModificationDate
        self.sourceContentSignature = sourceContentSignature
        self.isFavorite = isFavorite
        self.isHidden = isHidden
        self.customName = customName?.trimmedNonEmpty
        self.tags = Self.normalizedTags(tags)
    }

    var displayName: String { customName?.trimmedNonEmpty ?? fileName }

    var searchableText: String {
        ([displayName, fileName, relativePath, fileExtension] + tags).joined(separator: " ")
    }

    static func normalizedTags(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            guard let tag = value.trimmedNonEmpty else { return nil }
            let key = tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(key).inserted else { return nil }
            return tag
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, packageID, relativePath, fileName, folderPath, fileExtension
        case duration, sampleRate, channelCount, isFavorite, isHidden, customName, tags
        case sourceFileSize, sourceModificationDate, sourceContentSignature
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        packageID = try container.decode(UUID.self, forKey: .packageID)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        fileName = try container.decode(String.self, forKey: .fileName)
        folderPath = try container.decode(String.self, forKey: .folderPath)
        fileExtension = try container.decode(String.self, forKey: .fileExtension)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        sampleRate = try container.decodeIfPresent(Double.self, forKey: .sampleRate)
        channelCount = try container.decodeIfPresent(Int.self, forKey: .channelCount)
        sourceFileSize = try container.decodeIfPresent(Int64.self, forKey: .sourceFileSize)
        sourceModificationDate = try container.decodeIfPresent(Date.self, forKey: .sourceModificationDate)
        sourceContentSignature = try container.decodeIfPresent(UInt64.self, forKey: .sourceContentSignature)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        customName = try container.decodeIfPresent(String.self, forKey: .customName)?.trimmedNonEmpty
        tags = Self.normalizedTags(try container.decodeIfPresent([String].self, forKey: .tags) ?? [])
    }
}

struct SoundSourceFingerprint: Hashable, Sendable {
    let fileSize: Int64
    let modificationSecond: Int64
    let contentSignature: UInt64?

    init?(fileSize: Int64?, modificationDate: Date?, contentSignature: UInt64?) {
        guard let fileSize,
              fileSize >= 0,
              let modificationDate,
              modificationDate.timeIntervalSince1970.isFinite else {
            return nil
        }
        self.fileSize = fileSize
        modificationSecond = Int64(modificationDate.timeIntervalSince1970.rounded())
        self.contentSignature = contentSignature
    }

    func safelyMatches(_ other: Self) -> Bool {
        guard fileSize == other.fileSize, modificationSecond == other.modificationSecond else {
            return false
        }
        guard let contentSignature, let otherSignature = other.contentSignature else {
            return false
        }
        return contentSignature == otherSignature
    }
}

/// SQLite persists source dates as Unix-epoch doubles while Foundation internally represents
/// `Date` relative to 2001. That epoch conversion can introduce a sub-microsecond difference
/// even when the file did not change. Keep the tolerance narrowly above the observed numeric
/// drift so a real source edit still invalidates cached metadata.
enum SourceModificationDatePolicy {
    static let maximumRoundTripDrift: TimeInterval = 0.000_001

    static func matches(_ previous: Date?, _ current: Date?) -> Bool {
        guard let previous, let current else { return false }
        let difference = abs(
            previous.timeIntervalSinceReferenceDate - current.timeIntervalSinceReferenceDate
        )
        return difference.isFinite && difference <= maximumRoundTripDrift
    }
}

extension SoundItem {
    var sourceFingerprint: SoundSourceFingerprint? {
        SoundSourceFingerprint(
            fileSize: sourceFileSize,
            modificationDate: sourceModificationDate,
            contentSignature: sourceContentSignature
        )
    }
}

/// One Shixiang-owned metadata write. Source audio metadata is deliberately absent so a bulk
/// edit cannot be extended accidentally into changing files on disk.
struct LibraryMetadataUpdate: Sendable {
    let soundID: UUID
    let customName: String?
    let tags: [String]
}

enum SavedCollectionScope: Codable, Hashable, Sendable {
    case all
    case recent
    case favorites
    case pack(UUID)
    case folder(packID: UUID, path: String)
    case smart(SmartCollection)
    case smartDetail(SmartSubcollection)
    case smartLeaf(SmartLeafCollection)
    case smartUnknownDuration(SmartDurationBand)
}

/// Whether a saved collection can still resolve the local scope it captured.
/// This is derived at runtime and is intentionally not persisted: the source library may
/// change between launches while the saved query itself remains useful and editable.
enum SavedCollectionAvailability: Hashable, Sendable {
    case available
    case missingPack
    case missingFolder

    var isAvailable: Bool { self == .available }

    var title: String {
        switch self {
        case .available: return "可用"
        case .missingPack: return "音效包不可用"
        case .missingFolder: return "文件夹不可用"
        }
    }

    var systemImage: String {
        switch self {
        case .available: return "checkmark.circle.fill"
        case .missingPack: return "shippingbox.badge.exclamationmark"
        case .missingFolder: return "folder.badge.questionmark"
        }
    }
}

struct SavedCollection: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var scope: SavedCollectionScope
    var query: String
    var fileExtension: String?
    var minimumDuration: Double?
    var maximumDuration: Double?
    var favoritesOnly: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        scope: SavedCollectionScope = .all,
        query: String = "",
        fileExtension: String? = nil,
        minimumDuration: Double? = nil,
        maximumDuration: Double? = nil,
        favoritesOnly: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.scope = scope
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fileExtension = fileExtension?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.minimumDuration = minimumDuration
        self.maximumDuration = maximumDuration
        self.favoritesOnly = favoritesOnly
        self.createdAt = createdAt
    }
}

/// A versioned, JSON-safe recovery image for the local database. The original audio files are
/// never copied here; only Shixiang-owned index and metadata are preserved.
struct LibraryRecoverySnapshot: Codable, Hashable, Sendable {
    let packs: [SoundPack]
    let savedCollections: [SavedCollection]
    let intelligenceByID: [UUID: AudioIntelligence]
    let ignoredDuplicateFingerprints: Set<String>
    let namingProfile: JacksunNamingProfile

    init(
        packs: [SoundPack],
        savedCollections: [SavedCollection] = [],
        intelligenceByID: [UUID: AudioIntelligence] = [:],
        ignoredDuplicateFingerprints: Set<String> = [],
        namingProfile: JacksunNamingProfile = .default
    ) {
        self.packs = packs
        self.savedCollections = savedCollections
        self.intelligenceByID = intelligenceByID
        self.ignoredDuplicateFingerprints = ignoredDuplicateFingerprints
        self.namingProfile = namingProfile
    }

    private enum CodingKeys: String, CodingKey {
        case packs, savedCollections, intelligenceByID, ignoredDuplicateFingerprints, namingProfile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        packs = try container.decode([SoundPack].self, forKey: .packs)
        savedCollections = try container.decodeIfPresent([SavedCollection].self, forKey: .savedCollections) ?? []
        intelligenceByID = try container.decodeIfPresent(
            [UUID: AudioIntelligence].self,
            forKey: .intelligenceByID
        ) ?? [:]
        ignoredDuplicateFingerprints = try container.decodeIfPresent(
            Set<String>.self,
            forKey: .ignoredDuplicateFingerprints
        ) ?? []
        namingProfile = try container.decodeIfPresent(
            JacksunNamingProfile.self,
            forKey: .namingProfile
        ) ?? .default
    }
}

enum SmartCollection: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case transition, ambience, impact, foley, voice, music, technology, untagged

    var id: String { rawValue }
}

struct SoundMetadataSuggestion: Sendable {
    let displayName: String
    let tags: [String]
    let confidence: Double
    let reasons: [String]

    static func make(for item: SoundItem) -> Self {
        SoundSemanticEngine.metadataSuggestion(for: item)
    }

    static func make(for item: SoundItem, namingProfile: JacksunNamingProfile) -> Self {
        SoundSemanticEngine.metadataSuggestion(for: item, namingProfile: namingProfile)
    }

    static func numberConflicts(
        in candidates: [MetadataSuggestionCandidate],
        using namingProfile: JacksunNamingProfile
    ) -> [MetadataSuggestionCandidate] {
        guard namingProfile.numbersConflicts else { return candidates }
        let grouped = Dictionary(grouping: candidates) {
            $0.suggestion.displayName.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
        }
        var replacements: [UUID: SoundMetadataSuggestion] = [:]
        for group in grouped.values where group.count > 1 {
            let ordered = group.sorted {
                $0.item.relativePath.localizedStandardCompare($1.item.relativePath) == .orderedAscending
            }
            let digits = max(2, String(ordered.count).count)
            for (offset, candidate) in ordered.enumerated() {
                let suffix = String(format: "%0*d", digits, offset + 1)
                replacements[candidate.id] = SoundMetadataSuggestion(
                    displayName: candidate.suggestion.displayName
                        + namingProfile.effectiveSeparator + suffix,
                    tags: candidate.suggestion.tags,
                    confidence: candidate.suggestion.confidence,
                    reasons: candidate.suggestion.reasons + ["同名建议自动编号"]
                )
            }
        }
        return candidates.map { candidate in
            guard let suggestion = replacements[candidate.id] else { return candidate }
            return MetadataSuggestionCandidate(item: candidate.item, suggestion: suggestion)
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

struct SoundPack: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var rootPath: String
    var bookmarkData: Data?
    var importedAt: Date
    var lastScannedAt: Date
    var items: [SoundItem]

    init(
        id: UUID = UUID(),
        name: String,
        rootPath: String,
        bookmarkData: Data? = nil,
        importedAt: Date = Date(),
        lastScannedAt: Date = Date(),
        items: [SoundItem] = []
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.bookmarkData = bookmarkData
        self.importedAt = importedAt
        self.lastScannedAt = lastScannedAt
        self.items = items
    }
}

/// A folder tree derived entirely from the audio files' preserved relative paths.
struct FolderNode: Identifiable, Hashable, Sendable {
    /// The relative folder path is stable inside one sound pack and doubles as the tree ID.
    let relativePath: String
    let name: String
    let itemCount: Int
    let children: [FolderNode]

    var id: String { relativePath }
    var path: String { relativePath }

    static func make(from items: [SoundItem]) -> [FolderNode] {
        let root = MutableFolder(name: "", relativePath: "")

        for item in items where !item.folderPath.isEmpty {
            let components = item.folderPath.split(separator: "/").map(String.init)
            var cursor = root
            var accumulated: [String] = []

            for component in components {
                accumulated.append(component)
                if let child = cursor.children[component] {
                    cursor = child
                } else {
                    let child = MutableFolder(
                        name: component,
                        relativePath: accumulated.joined(separator: "/")
                    )
                    cursor.children[component] = child
                    cursor = child
                }
                cursor.directAndDescendantItemCount += 1
            }
        }

        return root.children.values
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map(\.immutableNode)
    }

    static func derive(from items: [SoundItem]) -> [FolderNode] {
        make(from: items)
    }
}

private final class MutableFolder {
    let name: String
    let relativePath: String
    var directAndDescendantItemCount = 0
    var children: [String: MutableFolder] = [:]

    init(name: String, relativePath: String) {
        self.name = name
        self.relativePath = relativePath
    }

    var immutableNode: FolderNode {
        FolderNode(
            relativePath: relativePath,
            name: name,
            itemCount: directAndDescendantItemCount,
            children: children.values
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map(\.immutableNode)
        )
    }
}
