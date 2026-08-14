import AppKit
import Combine
import Foundation

enum AcousticAnalysisQueueBuilder {
    static func candidates(
        in items: [SoundItem],
        intelligenceByID: [UUID: AudioIntelligence]
    ) throws -> [SoundItem] {
        var result: [SoundItem] = []
        result.reserveCapacity(max(0, items.count - intelligenceByID.count))
        for (index, item) in items.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            if !item.isHidden, intelligenceByID[item.id]?.acousticFingerprint == nil {
                result.append(item)
            }
        }
        return result
    }

    static func candidates(
        in packs: [SoundPack],
        intelligenceByID: [UUID: AudioIntelligence]
    ) throws -> [SoundItem] {
        let total = packs.reduce(0) { $0 + $1.items.count }
        var result: [SoundItem] = []
        result.reserveCapacity(max(0, total - intelligenceByID.count))
        var visited = 0
        for pack in packs {
            try Task.checkCancellation()
            for item in pack.items {
                if visited.isMultiple(of: 256) { try Task.checkCancellation() }
                if !item.isHidden, intelligenceByID[item.id]?.acousticFingerprint == nil {
                    result.append(item)
                }
                visited += 1
            }
        }
        return result
    }
}

private enum AcousticAnalysisQueueSource: Sendable {
    case items([SoundItem])
    case packs([SoundPack])

    var upperBound: Int {
        switch self {
        case let .items(items): items.count
        case let .packs(packs): packs.reduce(0) { $0 + $1.items.count }
        }
    }

    func candidates(intelligenceByID: [UUID: AudioIntelligence]) throws -> [SoundItem] {
        switch self {
        case let .items(items):
            try AcousticAnalysisQueueBuilder.candidates(
                in: items,
                intelligenceByID: intelligenceByID
            )
        case let .packs(packs):
            try AcousticAnalysisQueueBuilder.candidates(
                in: packs,
                intelligenceByID: intelligenceByID
            )
        }
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    private struct PersistedStartupState: Sendable {
        let packs: [SoundPack]
        let savedCollections: [SavedCollection]
        let intelligenceByID: [UUID: AudioIntelligence]
        let namingProfile: JacksunNamingProfile
        let ignoredDuplicateFingerprints: Set<String>
        let lastMetadataUndoBatch: MetadataUndoBatch?
    }

    @Published private(set) var packs: [SoundPack]
    @Published private(set) var savedCollections: [SavedCollection]
    @Published private(set) var intelligenceByID: [UUID: AudioIntelligence]
    @Published private(set) var acousticFingerprintCount = 0
    @Published private(set) var namingProfile: JacksunNamingProfile
    @Published private(set) var ignoredDuplicateFingerprints: Set<String> = []
    @Published var selectedPackID: UUID?
    @Published var selectedFolderPath: String?
    @Published var query = ""
    @Published private(set) var isIndexing = false
    @Published private(set) var indexingProgress: Double?
    @Published private(set) var indexingStatus: String?
    @Published var alertMessage: String?
    /// Changes only when indexed structure or source metadata changes, not when playback
    /// selection, a favorite, an alias, or a tag changes. Fine-grained revisions below keep
    /// a 36k-item result set from rebuilding for edits that can be patched in place.
    @Published private(set) var libraryRevision: UInt64 = 0
    /// Favorite changes have their own revision and exact affected IDs, so ordinary scopes can
    /// repaint only the changed stars while favorite-dependent scopes rebuild their membership.
    @Published private(set) var favoriteRevision: UInt64 = 0
    @Published private(set) var favoriteCount = 0
    /// Exact indexed sound total, rebuilt only when the library structure changes. Views read
    /// this O(1) value instead of reducing every pack during playback or progress repaints.
    @Published private(set) var soundCount = 0
    @Published private(set) var hiddenSoundCount = 0
    /// Alias and tag edits identify their exact rows so ordinary duration/folder/format views
    /// can patch in place instead of sorting the complete creator library again.
    @Published private(set) var metadataRevision: UInt64 = 0
    @Published private(set) var classificationRevision: UInt64 = 0
    @Published private(set) var visibilityRevision: UInt64 = 0
    @Published private(set) var batchOperationProgress: LibraryBatchOperationProgress?
    @Published private(set) var batchOperationResult: LibraryBatchOperationResult?
    @Published private(set) var semanticIndexProgress: SemanticIndexProgress?
    @Published private(set) var lastSemanticSearchMatchCount = 0
    @Published private(set) var lastSemanticConceptTitles: [String] = []
    @Published private(set) var lastMetadataUndoBatch: MetadataUndoBatch?
    @Published private(set) var acousticAnalysisProgress: AcousticAnalysisProgress?
    @Published private(set) var unavailablePackIDs: Set<UUID> = []
    @Published private(set) var autoRefreshingPackIDs: Set<UUID> = []
    @Published private(set) var isFolderMonitoringEnabled: Bool
    @Published private(set) var requestedRevealSoundID: UUID?
    @Published private(set) var isRecoveryTransferInProgress = false
    @Published private(set) var isDeferredStartupLoading = false
    @Published private(set) var isInitialLoadComplete = true
    @Published private(set) var deferredStartupProgress: Double?
    @Published private(set) var deferredStartupStatus: String?
    private(set) var lastFavoriteChangedIDs: [UUID] = []
    private(set) var lastMetadataChangedIDs: [UUID] = []
    /// The most recent successful scan, including any source rename/move records.
    /// It is intentionally in-memory only; the indexed paths remain the durable source of truth.
    @Published private(set) var lastScanResult: LibraryScanReport?
    let selection = LibrarySelection()

    private let scanner: LibraryScanner
    private let persistence: LibraryPersistence
    private let persistenceWriter: LibraryPersistenceWriter
    private var persistenceTask: Task<Void, Never>?
    private var recoveryBackupTask: Task<Void, Never>?
    private var scopedRootURLs: [UUID: URL] = [:]
    private var packIndexByID: [UUID: Int] = [:]
    private var soundLocationByID: [UUID: SoundLocation] = [:]
    /// Keeps the rare hidden subset directly addressable. Restoring hidden duplicates therefore
    /// scales with the hidden subset instead of flattening and filtering the complete library.
    private var hiddenSoundIDs: Set<UUID> = []
    private var activeScanToken: UUID?
    private var activeIndexingTask: Task<Void, Never>?
    private var activeBatchOperationTask: Task<Void, Never>?
    private var semanticOperationToken: UUID?
    private var acousticAnalysisTask: Task<Void, Never>?
    private var recoveryTransferTask: Task<Void, Never>?
    private let folderMonitor = LibraryFolderMonitor()
    private var automaticRefreshDebounceTasks: [UUID: Task<Void, Never>] = [:]
    private var availabilityMonitorTask: Task<Void, Never>?
    private var deferredStartupTask: Task<Void, Never>?
    private var deferredInitialLoadPending = false

    init(
        scanner: LibraryScanner = LibraryScanner(),
        persistence: LibraryPersistence = LibraryPersistence(),
        deferInitialLoad: Bool = false
    ) {
        self.scanner = scanner
        self.persistence = persistence
        persistenceWriter = LibraryPersistenceWriter(persistence: persistence)
        isFolderMonitoringEnabled = UserDefaults.standard.object(
            forKey: "shixiang.library.automaticFolderMonitoring"
        ) == nil || UserDefaults.standard.bool(
            forKey: "shixiang.library.automaticFolderMonitoring"
        )

        if deferInitialLoad {
            packs = []
            savedCollections = []
            intelligenceByID = [:]
            namingProfile = .default
            ignoredDuplicateFingerprints = []
            lastMetadataUndoBatch = nil
            deferredInitialLoadPending = true
            isInitialLoadComplete = false
        } else {
            do {
                packs = try persistence.load()
                savedCollections = (try? persistence.loadSavedCollections()) ?? []
                intelligenceByID = (try? persistence.loadAudioIntelligence()) ?? [:]
                namingProfile = (try? persistence.loadNamingProfile()) ?? .default
                ignoredDuplicateFingerprints = (try? persistence.loadIgnoredDuplicateFingerprints()) ?? []
                lastMetadataUndoBatch = try? persistence.loadLatestMetadataUndoBatch()
            } catch {
                packs = []
                savedCollections = []
                intelligenceByID = [:]
                namingProfile = .default
                ignoredDuplicateFingerprints = []
                lastMetadataUndoBatch = nil
                alertMessage = "本地音效索引读取失败：\(error.localizedDescription)"
            }
        }

        if !deferInitialLoad {
            restoreSecurityScopedAccess()
            rebuildIndexes()
        }
        selectedPackID = packs.first?.id
        if !deferInitialLoad {
            refreshPackAvailability()
            configureFolderMonitoring()
            startAvailabilityMonitor()
        }
    }

    /// Production startup uses this after the branded launch surface is visible. The durable
    /// index is already loaded by the initializer, so this task only refreshes availability and
    /// the derived folders/counts away from the first interactive frame. It intentionally does
    /// not scan or replace the user's existing sound rows.
    func startDeferredStartupWork() {
        guard deferredStartupTask == nil, !isDeferredStartupLoading else { return }
        deferredStartupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            isDeferredStartupLoading = true
            deferredStartupProgress = 0
            deferredStartupStatus = deferredInitialLoadPending ? "正在读取本地音效库…" : "正在准备本地音效库…"
            defer {
                isDeferredStartupLoading = false
                deferredStartupProgress = nil
                deferredStartupStatus = nil
                deferredStartupTask = nil
            }

            // Yield several times so the first window frames, input handling, and the initial
            // SwiftUI layout get priority over derived library bookkeeping.
            await Task.yield()
            if deferredInitialLoadPending {
                let persistence = self.persistence
                do {
                    let state = try await Task.detached(priority: .utility) {
                        PersistedStartupState(
                            packs: try persistence.load(),
                            savedCollections: (try? persistence.loadSavedCollections()) ?? [],
                            intelligenceByID: (try? persistence.loadAudioIntelligence()) ?? [:],
                            namingProfile: (try? persistence.loadNamingProfile()) ?? .default,
                            ignoredDuplicateFingerprints: (try? persistence.loadIgnoredDuplicateFingerprints()) ?? [],
                            lastMetadataUndoBatch: try? persistence.loadLatestMetadataUndoBatch()
                        )
                    }.value
                    guard !Task.isCancelled else { return }
                    packs = state.packs
                    savedCollections = state.savedCollections
                    intelligenceByID = state.intelligenceByID
                    namingProfile = state.namingProfile
                    ignoredDuplicateFingerprints = state.ignoredDuplicateFingerprints
                    lastMetadataUndoBatch = state.lastMetadataUndoBatch
                    restoreSecurityScopedAccess()
                    rebuildIndexes()
                    selectedPackID = packs.first?.id
                    configureFolderMonitoring()
                    startAvailabilityMonitor()
                    libraryRevision &+= 1
                    classificationRevision &+= 1
                    deferredInitialLoadPending = false
                    isInitialLoadComplete = true
                } catch {
                    alertMessage = "本地音效索引读取失败：\(error.localizedDescription)"
                    return
                }
            }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            deferredStartupStatus = "正在检查音效包状态…"
            refreshPackAvailability()
            deferredStartupProgress = 0.45
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            deferredStartupStatus = "正在准备搜索与分类…"
            deferredStartupProgress = 0.78
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            deferredStartupProgress = 1
            deferredStartupStatus = "本地音效库已就绪"
        }
    }

    var selectedPack: SoundPack? {
        guard let selectedPackID, let index = packIndexByID[selectedPackID] else { return nil }
        return packs[index]
    }

    var selectedSound: SoundItem? {
        sound(id: selection.soundID)
    }

    var selectedSoundID: UUID? { selection.soundID }

    private var cachedVocabulary: LibraryVocabulary?
    private var cachedVocabularyRevision: UInt64?

    /// 库真实词汇表：懒构建，按结构 revision 失效。只在 MainActor 上下文调用
    /// （该函数读取 `packs` 与 `libraryRevision`）。库结构变化后首次访问会重建。
    func libraryVocabulary() -> LibraryVocabulary {
        if let cachedVocabulary, cachedVocabularyRevision == libraryRevision {
            return cachedVocabulary
        }
        let vocabulary = LibraryVocabulary.build(from: packs)
        cachedVocabulary = vocabulary
        cachedVocabularyRevision = libraryRevision
        return vocabulary
    }

    var databaseDirectoryURL: URL {
        persistence.databaseURL.deletingLastPathComponent()
    }

    func sound(id: UUID?) -> SoundItem? {
        guard let id, let location = soundLocationByID[id] else {
            return nil
        }
        return packs[location.packIndex].items[location.itemIndex]
    }

    func selectSound(_ id: UUID?) {
        selection.select(id)
    }

    func selectAndRevealSound(_ id: UUID) {
        selection.select(id)
        requestedRevealSoundID = id
    }

    /// Resolves a saved collection against the current local index without touching source files.
    /// Smart, all, recent, and favorites scopes are library-independent; pack/folder scopes can
    /// become stale after a package is removed, moved, or rescanned.
    func savedCollectionAvailability(_ collection: SavedCollection) -> SavedCollectionAvailability {
        switch collection.scope {
        case .all, .recent, .favorites, .smart, .smartDetail, .smartLeaf, .smartUnknownDuration:
            return .available
        case let .pack(packID):
            return packs.contains { $0.id == packID } ? .available : .missingPack
        case let .folder(packID, path):
            guard let pack = packs.first(where: { $0.id == packID }) else {
                return .missingPack
            }
            let hasDescendant = pack.items.contains {
                $0.folderPath == path || $0.folderPath.hasPrefix(path + "/")
            }
            return hasDescendant ? .available : .missingFolder
        }
    }

    /// Renames only Shixiang's saved-collection record. Original audio paths and metadata are
    /// never touched. The same collection ID is retained so existing menu references remain
    /// stable across the edit.
    @discardableResult
    func renameSavedCollection(_ collection: SavedCollection, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            alertMessage = "集合名称不能为空。"
            return false
        }
        guard savedCollections.contains(where: { $0.id == collection.id }) else {
            alertMessage = "这个集合已经不存在。"
            return false
        }
        var renamed = collection
        renamed.name = trimmed
        upsertSavedCollection(renamed)
        return true
    }

    func upsertSavedCollection(_ collection: SavedCollection) {
        if let index = savedCollections.firstIndex(where: { $0.id == collection.id }) {
            savedCollections[index] = collection
        } else {
            savedCollections.append(collection)
        }
        savedCollections.sort { $0.createdAt < $1.createdAt }
        Task {
            do {
                try await persistenceWriter.saveSavedCollection(collection)
            } catch {
                alertMessage = "保存自定义集合失败：\(error.localizedDescription)"
            }
        }
        scheduleRecoveryBackup()
    }

    /// Invalidates any in-flight semantic search or similarity lookup before the result set
    /// changes. A cleared query must be able to silence an older SQLite search immediately;
    /// otherwise its delayed progress callback can repaint the new, unrelated workspace.
    @discardableResult
    func invalidateSemanticOperation() -> UUID {
        let token = UUID()
        semanticOperationToken = token
        semanticIndexProgress = nil
        lastSemanticSearchMatchCount = 0
        lastSemanticConceptTitles = []
        return token
    }

    func removeSavedCollection(_ collection: SavedCollection) {
        savedCollections.removeAll { $0.id == collection.id }
        Task {
            do {
                try await persistenceWriter.deleteSavedCollection(id: collection.id)
            } catch {
                alertMessage = "删除自定义集合失败：\(error.localizedDescription)"
            }
        }
        scheduleRecoveryBackup()
    }

    func indexedSoundMatches(
        matching query: String,
        mode: LibrarySearchMode,
        operationToken: UUID? = nil
    ) async -> LibrarySearchMatches? {
        let token = operationToken ?? beginSemanticOperation()
        guard semanticOperationToken == token else { return nil }
        do {
            let matches = try await persistenceWriter.searchSoundMatches(
                matching: query,
                mode: mode
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.semanticOperationToken == token else { return }
                    self.semanticIndexProgress = progress
                }
            }
            guard semanticOperationToken == token else { return matches }
            semanticIndexProgress = nil
            lastSemanticSearchMatchCount = matches.semanticMatchCount
            lastSemanticConceptTitles = matches.conceptTitles
            return matches
        } catch {
            if semanticOperationToken == token {
                semanticIndexProgress = nil
                lastSemanticSearchMatchCount = 0
                lastSemanticConceptTitles = []
            }
            return nil
        }
    }

    func indexedSoundIDs(matching query: String) async -> Set<UUID>? {
        await indexedSoundMatches(matching: query, mode: .literal)?.ids
    }

    func similarSounds(to item: SoundItem) async -> [SoundSimilarityMatch] {
        let token = beginSemanticOperation()
        do {
            let semanticCandidates = try await persistenceWriter.similarityCandidates(
                for: item.id
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.semanticOperationToken == token else { return }
                    self.semanticIndexProgress = progress
                }
            }
            if semanticOperationToken == token { semanticIndexProgress = nil }

            let sourceIntelligence: AudioIntelligence?
            if intelligenceByID[item.id]?.acousticFingerprint == nil {
                sourceIntelligence = await analyzeAcoustics(for: item)
            } else {
                sourceIntelligence = intelligenceByID[item.id]
            }

            let acousticScores: [UUID: Double]
            if let sourceFingerprint = sourceIntelligence?.acousticFingerprint {
                let intelligenceSnapshot = intelligenceByID
                let nearest = await Task.detached(priority: .userInitiated) {
                    AcousticSimilarityIndex.nearest(
                        to: sourceFingerprint,
                        sourceID: item.id,
                        in: intelligenceSnapshot
                    )
                }.value
                acousticScores = Dictionary(uniqueKeysWithValues: nearest.map { ($0.soundID, $0.similarity) })
            } else {
                acousticScores = [:]
            }
            var candidatesByID = Dictionary(uniqueKeysWithValues: semanticCandidates.map { ($0.soundID, $0) })
            for soundID in acousticScores.keys where candidatesByID[soundID] == nil {
                candidatesByID[soundID] = SoundSimilarityIndexCandidate(
                    soundID: soundID,
                    semanticScore: 0,
                    sharedConceptIDs: [],
                    isSameFamily: false
                )
            }

            return candidatesByID.values.compactMap { candidate -> SoundSimilarityMatch? in
                guard let related = sound(id: candidate.soundID), !related.isHidden else { return nil }
                var score = min(48, candidate.semanticScore * 17)
                var reasons: [String] = []
                if candidate.isSameFamily {
                    score += 36
                    reasons.append("同一套命名变体")
                }
                let durationBase = max(max(item.duration, related.duration), 0.01)
                let durationDistance = abs(item.duration - related.duration) / durationBase
                if durationDistance < 0.6 {
                    score += max(0, 18 * (1 - durationDistance / 0.6))
                    reasons.append("时长接近")
                }
                let conceptReasons = candidate.sharedConceptIDs
                    .compactMap(SoundSemanticEngine.conceptTitle)
                    .filter { !reasons.contains($0) }
                    .prefix(3)
                reasons.append(contentsOf: conceptReasons)

                if let acousticSimilarity = acousticScores[related.id],
                   let sourceFingerprint = sourceIntelligence?.acousticFingerprint,
                   let relatedFingerprint = intelligenceByID[related.id]?.acousticFingerprint {
                    score += max(0, (acousticSimilarity - 0.34) / 0.66) * 58
                    if acousticSimilarity >= 0.58 {
                        reasons.insert("音色接近", at: 0)
                        reasons.insert(
                            contentsOf: sourceFingerprint.similarityReasons(to: relatedFingerprint),
                            at: min(1, reasons.count)
                        )
                    }
                }

                if let sourceBPM = sourceIntelligence?.bpm,
                   let relatedBPM = intelligenceByID[related.id]?.bpm,
                   abs(sourceBPM - relatedBPM) <= 6 {
                    score += 6
                    reasons.append("节奏接近")
                }
                if let sourceKey = sourceIntelligence?.musicalKey,
                   sourceKey == intelligenceByID[related.id]?.musicalKey {
                    score += 4
                    reasons.append("调性相同")
                }
                return SoundSimilarityMatch(
                    item: related,
                    score: min(100, score),
                    reasons: Array(reasons.prefix(4)),
                    isSameFamily: candidate.isSameFamily
                )
            }
            .filter { $0.score >= 20 || $0.isSameFamily }
            .sorted {
                if $0.isSameFamily != $1.isSameFamily { return $0.isSameFamily }
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.item.relativePath.localizedStandardCompare($1.item.relativePath)
                    == .orderedAscending
            }
        } catch {
            if semanticOperationToken == token { semanticIndexProgress = nil }
            return []
        }
    }

    func intelligence(for soundID: UUID) -> AudioIntelligence? {
        intelligenceByID[soundID]
    }

    func updateNamingProfile(_ profile: JacksunNamingProfile) {
        namingProfile = profile
        Task {
            do {
                try await persistenceWriter.saveNamingProfile(profile)
                scheduleRecoveryBackup()
            } catch {
                alertMessage = "Jacksun 命名字典保存失败：\(error.localizedDescription)"
            }
        }
    }

    func analyzeIntelligence(for item: SoundItem, force: Bool = false) async -> AudioIntelligence? {
        if !force, let cached = intelligenceByID[item.id] {
            return cached
        }
        guard let url = url(for: item) else { return nil }
        do {
            let result = try await AudioIntelligenceAnalyzer().analyze(url: url)
            setIntelligence(result, for: item.id)
            try? await persistenceWriter.saveAudioIntelligence(soundID: item.id, intelligence: result)
            scheduleRecoveryBackup()
            return result
        } catch {
            return nil
        }
    }

    /// Computes only the compact timbre fingerprint and signal-level metadata. This is the
    /// path used by large queues so key detection never competes with normal playback.
    func analyzeAcoustics(for item: SoundItem, force: Bool = false) async -> AudioIntelligence? {
        if !force,
           let cached = intelligenceByID[item.id],
           cached.acousticFingerprint != nil {
            return cached
        }
        guard let url = url(for: item) else { return nil }
        do {
            let result = try await AudioIntelligenceAnalyzer().analyzeAcousticsOnly(
                url: url,
                preserving: intelligenceByID[item.id]
            )
            setIntelligence(result, for: item.id)
            try? await persistenceWriter.saveAudioIntelligence(soundID: item.id, intelligence: result)
            scheduleRecoveryBackup()
            return result
        } catch {
            return nil
        }
    }

    func acousticFingerprintCount(in items: [SoundItem]) async -> Int {
        let intelligenceByID = intelligenceByID
        return await Task.detached(priority: .utility) {
            var count = 0
            for (index, item) in items.enumerated() {
                if index.isMultiple(of: 512), Task.isCancelled { break }
                if intelligenceByID[item.id]?.acousticFingerprint != nil { count += 1 }
            }
            return count
        }.value
    }

    func startAcousticAnalysis(items: [SoundItem]) {
        startAcousticAnalysis(source: .items(items))
    }

    func startAcousticAnalysisForEntireLibrary() {
        startAcousticAnalysis(source: .packs(packs))
    }

    private func startAcousticAnalysis(source: AcousticAnalysisQueueSource) {
        guard acousticAnalysisTask == nil else { return }
        let operationID = UUID()
        acousticAnalysisProgress = AcousticAnalysisProgress(
            id: operationID,
            completed: 0,
            total: source.upperBound,
            failed: 0,
            currentName: "正在后台准备分析队列…"
        )
        let intelligenceSnapshot = intelligenceByID
        acousticAnalysisTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let preparation = Task.detached(priority: .utility) {
                try source.candidates(intelligenceByID: intelligenceSnapshot)
            }
            let candidates: [SoundItem]
            do {
                candidates = try await withTaskCancellationHandler {
                    try await preparation.value
                } onCancel: {
                    preparation.cancel()
                }
            } catch {
                self.acousticAnalysisTask = nil
                self.acousticAnalysisProgress = nil
                return
            }
            guard !Task.isCancelled else {
                self.acousticAnalysisTask = nil
                self.acousticAnalysisProgress = nil
                return
            }
            guard !candidates.isEmpty else {
                self.acousticAnalysisTask = nil
                self.acousticAnalysisProgress = nil
                self.alertMessage = "当前范围的声音指纹已经建立完成。"
                return
            }
            self.acousticAnalysisProgress = AcousticAnalysisProgress(
                id: operationID,
                completed: 0,
                total: candidates.count,
                failed: 0,
                currentName: nil
            )
            var failed = 0
            var staged: [UUID: AudioIntelligence] = [:]
            for (index, item) in candidates.enumerated() {
                guard !Task.isCancelled else { break }
                self.acousticAnalysisProgress = AcousticAnalysisProgress(
                    id: operationID,
                    completed: index,
                    total: candidates.count,
                    failed: failed,
                    currentName: item.displayName
                )
                guard let url = self.url(for: item) else {
                    failed += 1
                    continue
                }
                do {
                    let result = try await AudioIntelligenceAnalyzer().analyzeAcousticsOnly(
                        url: url,
                        preserving: self.intelligenceByID[item.id]
                    )
                    staged[item.id] = result
                    try? await self.persistenceWriter.saveAudioIntelligence(
                        soundID: item.id,
                        intelligence: result
                    )
                    // Publish in small groups. One dictionary mutation per file would otherwise
                    // invalidate the visible list thousands of times during an overnight run.
                    if staged.count >= 12 || index == candidates.count - 1 {
                        self.mergeIntelligence(staged)
                        staged.removeAll(keepingCapacity: true)
                    }
                } catch {
                    failed += 1
                }
                self.acousticAnalysisProgress = AcousticAnalysisProgress(
                    id: operationID,
                    completed: index + 1,
                    total: candidates.count,
                    failed: failed,
                    currentName: item.displayName
                )
                await Task.yield()
            }
            if !staged.isEmpty { self.mergeIntelligence(staged) }
            let wasCancelled = Task.isCancelled
            self.acousticAnalysisTask = nil
            self.acousticAnalysisProgress = nil
            self.scheduleRecoveryBackup()
            if !wasCancelled {
                self.batchOperationResult = LibraryBatchOperationResult(
                    message: failed == 0
                        ? "声音指纹分析完成"
                        : "声音指纹分析完成，\(failed) 条无法读取"
                )
            }
        }
    }

    func cancelAcousticAnalysis() {
        acousticAnalysisTask?.cancel()
    }

    func importPackWithPanel() {
        let panel = NSOpenPanel()
        panel.title = "导入音效包"
        panel.message = "选择一个音效包文件夹。拾响只建立索引，不会移动、改名或复制原文件。"
        panel.prompt = "导入音效包"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        startAddPack(from: url)
    }

    /// Starts an import in a retained task so a long scan can be cancelled from the overlay.
    /// The source folder is only read; cancelling leaves the existing index untouched.
    func startAddPack(from url: URL) {
        guard activeIndexingTask == nil else { return }
        activeIndexingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.addPack(from: url)
            self.activeIndexingTask = nil
        }
    }

    func cancelIndexing() {
        guard isIndexing else { return }
        indexingStatus = "正在取消扫描…"
        activeIndexingTask?.cancel()
    }

    func addPack(from url: URL) async {
        guard !isIndexing else { return }
        let rootURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            alertMessage = "请选择一个有效的音效包文件夹。"
            return
        }

        let scanToken = beginIndexing(status: "正在扫描音效包…")
        defer { finishIndexing(scanToken) }

        let existingIndex = packs.firstIndex {
            URL(fileURLWithPath: $0.rootPath).standardizedFileURL == rootURL
        }
        let packageID = existingIndex.map { packs[$0].id } ?? UUID()
        let previousItems = existingIndex.map { packs[$0].items } ?? []
        let didStartAccess = rootURL.startAccessingSecurityScopedResource()
        if didStartAccess { scopedRootURLs[packageID] = rootURL }

        do {
            let scanResult = try await scanner.scanResult(
                rootURL: rootURL,
                packageID: packageID,
                existingItems: previousItems,
                progress: scanProgressHandler(for: scanToken)
            )
            try Task.checkCancellation()
            let items = scanResult.items
            if existingIndex != nil, !scanResult.requiresIndexUpdate {
                lastScanResult = scanResult.report
                unavailablePackIDs.remove(packageID)
                return
            }
            invalidateChangedIntelligence(previousItems: previousItems, newItems: items)
            let now = Date()
            let bookmark = makeBookmark(for: rootURL)

            if let existingIndex {
                packs[existingIndex].name = rootURL.lastPathComponent
                packs[existingIndex].rootPath = rootURL.path
                packs[existingIndex].bookmarkData = bookmark ?? packs[existingIndex].bookmarkData
                packs[existingIndex].lastScannedAt = now
                packs[existingIndex].items = items
            } else {
                packs.append(
                    SoundPack(
                        id: packageID,
                        name: rootURL.lastPathComponent,
                        rootPath: rootURL.path,
                        bookmarkData: bookmark,
                        importedAt: now,
                        lastScannedAt: now,
                        items: items
                    )
                )
            }

            packs.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            rebuildIndexes()
            libraryRevision &+= 1
            classificationRevision &+= 1
            selectedPackID = packageID
            selectedFolderPath = nil
            selection.select(items.first?.id)
            lastScanResult = scanResult.report
            persistPack(packageID)
            refreshPackAvailability()
            configureFolderMonitoring()
        } catch is CancellationError {
            return
        } catch {
            if didStartAccess {
                rootURL.stopAccessingSecurityScopedResource()
                scopedRootURLs[packageID] = nil
            }
            alertMessage = error.localizedDescription
        }
    }

    func refreshSelectedPack() async {
        guard let selectedPack, let rootURL = resolvedRootURL(for: selectedPack) else {
            alertMessage = "音效包原始文件夹已不可访问，请重新导入。"
            return
        }
        await addPack(from: rootURL)
    }

    func startRefreshSelectedPack() {
        guard activeIndexingTask == nil else { return }
        activeIndexingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshSelectedPack()
            self.activeIndexingTask = nil
        }
    }

    func startRefreshPack(_ packID: UUID) {
        guard activeIndexingTask == nil else { return }
        guard let packIndex = packIndexByID[packID],
              let rootURL = resolvedRootURL(for: packs[packIndex]) else {
            alertMessage = "音效包原始文件夹已不可访问，请先重新定位。"
            return
        }
        activeIndexingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.addPack(from: rootURL)
            self.activeIndexingTask = nil
        }
    }

    /// Rebuilds every Shixiang-owned index from the source folders without changing the source
    /// files. The complete result is staged first, so cancellation leaves the current library
    /// index untouched rather than committing a half-scanned library.
    func startFullLibraryRebuild() {
        guard activeIndexingTask == nil else { return }
        guard !packs.isEmpty else {
            alertMessage = "还没有导入音效包，无法重建资料库索引。"
            return
        }
        activeIndexingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.rebuildEntireLibraryIndex()
            self.activeIndexingTask = nil
        }
    }

    private func rebuildEntireLibraryIndex() async {
        let originalPacks = packs
        var sources: [(pack: SoundPack, rootURL: URL)] = []
        sources.reserveCapacity(originalPacks.count)
        for pack in originalPacks {
            guard let rootURL = resolvedRootURL(for: pack) else {
                alertMessage = "音效包“\(pack.name)”无法访问，请重新定位后再彻底重建。"
                refreshPackAvailability()
                return
            }
            sources.append((pack, rootURL))
        }

        let scanToken = beginIndexing(status: "正在准备彻底重建资料库索引…")
        defer { finishIndexing(scanToken) }
        var stagedResults: [UUID: LibraryScanResult] = [:]
        stagedResults.reserveCapacity(sources.count)

        do {
            for (packOffset, source) in sources.enumerated() {
                try Task.checkCancellation()
                let result = try await scanner.scanResult(
                    rootURL: source.rootURL,
                    packageID: source.pack.id,
                    existingItems: source.pack.items,
                    forceAudioMetadataRefresh: true,
                    progress: { [weak self] completed, total in
                        Task { @MainActor [weak self] in
                            guard let self, self.activeScanToken == scanToken else { return }
                            let fraction = total > 0
                                ? min(max(Double(completed) / Double(total), 0), 1)
                                : 1
                            self.indexingProgress = (Double(packOffset) + fraction) / Double(sources.count)
                            self.indexingStatus = total > 0
                                ? "正在彻底扫描 \(source.pack.name) · \(completed.formatted(.number)) / \(total.formatted(.number))"
                                : "正在彻底扫描 \(source.pack.name)…"
                        }
                    }
                )
                stagedResults[source.pack.id] = result
            }
            try Task.checkCancellation()

            for source in sources {
                guard let packIndex = packIndexByID[source.pack.id],
                      let scanResult = stagedResults[source.pack.id] else {
                    continue
                }
                let previousItems = packs[packIndex].items
                invalidateChangedIntelligence(previousItems: previousItems, newItems: scanResult.items)
                packs[packIndex].items = scanResult.items
                packs[packIndex].lastScannedAt = scanResult.completedAt
                lastScanResult = scanResult.report
            }
            rebuildIndexes()
            libraryRevision &+= 1
            classificationRevision &+= 1
            refreshPackAvailability()
            configureFolderMonitoring()
            persist()

            let soundTotal = packs.reduce(0) { $0 + $1.items.count }
            batchOperationResult = LibraryBatchOperationResult(
                message: "已彻底重建 \(sources.count) 个音效包的索引 · \(soundTotal.formatted(.number)) 个声音"
            )
        } catch is CancellationError {
            return
        } catch {
            alertMessage = "彻底重建索引失败：\(error.localizedDescription)"
        }
    }

    func setFolderMonitoringEnabled(_ enabled: Bool) {
        isFolderMonitoringEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "shixiang.library.automaticFolderMonitoring")
        if enabled {
            refreshPackAvailability()
            configureFolderMonitoring()
        } else {
            folderMonitor.stop()
            automaticRefreshDebounceTasks.values.forEach { $0.cancel() }
            automaticRefreshDebounceTasks.removeAll()
        }
    }

    func refreshPackAvailability() {
        var unavailable = Set<UUID>()
        for pack in packs {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: pack.rootPath, isDirectory: &isDirectory)
            if !exists || !isDirectory.boolValue || !FileManager.default.isReadableFile(atPath: pack.rootPath) {
                unavailable.insert(pack.id)
            }
        }
        unavailablePackIDs = unavailable
    }

    func removeSelectedPack() {
        guard let selectedPackID,
              let index = packs.firstIndex(where: { $0.id == selectedPackID }) else { return }

        if let scopedURL = scopedRootURLs.removeValue(forKey: selectedPackID) {
            scopedURL.stopAccessingSecurityScopedResource()
        }
        packs.remove(at: index)
        rebuildIndexes()
        libraryRevision &+= 1
        classificationRevision &+= 1
        self.selectedPackID = packs.first?.id
        selectedFolderPath = nil
        selection.select(nil)
        persist()
        refreshPackAvailability()
        configureFolderMonitoring()
    }

    func toggleFavorite(_ item: SoundItem) {
        guard batchOperationProgress == nil else {
            alertMessage = "批量操作完成后再修改单个收藏状态。"
            return
        }
        guard let location = soundLocationByID[item.id],
              packs[location.packIndex].id == item.packageID else {
            return
        }
        packs[location.packIndex].items[location.itemIndex].isFavorite.toggle()
        let isFavorite = packs[location.packIndex].items[location.itemIndex].isFavorite
        favoriteCount += isFavorite ? 1 : -1
        publishFavoriteChange([item.id])
        Task {
            do {
                try await persistenceWriter.updateFavorite(soundID: item.id, isFavorite: isFavorite)
                scheduleRecoveryBackup()
            } catch {
                if let currentLocation = soundLocationByID[item.id],
                   packs[currentLocation.packIndex].items[currentLocation.itemIndex].isFavorite == isFavorite {
                    packs[currentLocation.packIndex].items[currentLocation.itemIndex].isFavorite.toggle()
                    favoriteCount += isFavorite ? -1 : 1
                    publishFavoriteChange([item.id])
                }
                alertMessage = "收藏状态保存失败：\(error.localizedDescription)"
            }
        }
    }

    @discardableResult
    func setFavorite(for soundIDs: Set<UUID>, isFavorite: Bool) -> Int {
        var changedIDs: [UUID] = []
        changedIDs.reserveCapacity(soundIDs.count)
        for soundID in soundIDs {
            guard let location = soundLocationByID[soundID],
                  packs[location.packIndex].items[location.itemIndex].isFavorite != isFavorite else {
                continue
            }
            packs[location.packIndex].items[location.itemIndex].isFavorite = isFavorite
            changedIDs.append(soundID)
        }
        guard !changedIDs.isEmpty else { return 0 }
        favoriteCount += isFavorite ? changedIDs.count : -changedIDs.count
        publishFavoriteChange(changedIDs)
        Task {
            do {
                try await persistenceWriter.updateFavorites(
                    soundIDs: changedIDs,
                    isFavorite: isFavorite
                )
                scheduleRecoveryBackup()
            } catch {
                var rolledBackIDs: [UUID] = []
                rolledBackIDs.reserveCapacity(changedIDs.count)
                for soundID in changedIDs {
                    guard let location = soundLocationByID[soundID],
                          packs[location.packIndex].items[location.itemIndex].isFavorite == isFavorite else {
                        continue
                    }
                    packs[location.packIndex].items[location.itemIndex].isFavorite.toggle()
                    rolledBackIDs.append(soundID)
                }
                if !rolledBackIDs.isEmpty {
                    favoriteCount += isFavorite ? -rolledBackIDs.count : rolledBackIDs.count
                    publishFavoriteChange(rolledBackIDs)
                }
                alertMessage = "批量收藏状态保存失败：\(error.localizedDescription)"
            }
        }
        return changedIDs.count
    }

    @discardableResult
    func addTags(_ tags: [String], to soundIDs: Set<UUID>) -> Int {
        let normalizedTags = SoundItem.normalizedTags(tags)
        guard !normalizedTags.isEmpty else {
            alertMessage = "请输入至少一个标签。"
            return 0
        }

        var updates: [LibraryMetadataUpdate] = []
        var previousUpdates: [LibraryMetadataUpdate] = []
        updates.reserveCapacity(soundIDs.count)
        previousUpdates.reserveCapacity(soundIDs.count)
        for soundID in soundIDs {
            guard let location = soundLocationByID[soundID] else { continue }
            let item = packs[location.packIndex].items[location.itemIndex]
            let mergedTags = SoundItem.normalizedTags(item.tags + normalizedTags)
            guard mergedTags != item.tags else { continue }
            packs[location.packIndex].items[location.itemIndex].tags = mergedTags
            previousUpdates.append(
                LibraryMetadataUpdate(
                    soundID: soundID,
                    customName: item.customName,
                    tags: item.tags
                )
            )
            updates.append(
                LibraryMetadataUpdate(
                    soundID: soundID,
                    customName: item.customName,
                    tags: mergedTags
                )
            )
        }
        guard !updates.isEmpty else { return 0 }
        publishMetadataChange(updates.map(\.soundID))
        classificationRevision &+= 1
        Task {
            do {
                try await persistenceWriter.updateMetadata(updates)
                scheduleRecoveryBackup()
            } catch {
                var rolledBackIDs: [UUID] = []
                for (failedUpdate, previousUpdate) in zip(updates, previousUpdates) {
                    guard let location = soundLocationByID[failedUpdate.soundID],
                          packs[location.packIndex].items[location.itemIndex].customName
                            == failedUpdate.customName,
                          packs[location.packIndex].items[location.itemIndex].tags
                            == failedUpdate.tags else {
                        continue
                    }
                    packs[location.packIndex].items[location.itemIndex].customName
                        = previousUpdate.customName
                    packs[location.packIndex].items[location.itemIndex].tags
                        = previousUpdate.tags
                    rolledBackIDs.append(failedUpdate.soundID)
                }
                if !rolledBackIDs.isEmpty {
                    publishMetadataChange(rolledBackIDs)
                    classificationRevision &+= 1
                }
                alertMessage = "批量标签保存失败：\(error.localizedDescription)"
            }
        }
        return updates.count
    }

    func startBatchFavorite(for soundIDs: Set<UUID>, isFavorite: Bool) {
        guard activeBatchOperationTask == nil, !soundIDs.isEmpty else { return }
        let operationID = UUID()
        let actionTitle = isFavorite ? "批量收藏" : "批量取消收藏"
        batchOperationProgress = LibraryBatchOperationProgress(
            id: operationID,
            actionTitle: actionTitle,
            phase: .preparing,
            completed: 0,
            total: soundIDs.count
        )
        activeBatchOperationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var changedIDs: [UUID] = []
                changedIDs.reserveCapacity(soundIDs.count)
                for (index, soundID) in soundIDs.enumerated() {
                    try Task.checkCancellation()
                    if let location = self.soundLocationByID[soundID],
                       self.packs[location.packIndex].items[location.itemIndex].isFavorite != isFavorite {
                        changedIDs.append(soundID)
                    }
                    if (index + 1).isMultiple(of: 512) {
                        self.updateBatchProgress(
                            operationID: operationID,
                            actionTitle: actionTitle,
                            phase: .preparing,
                            completed: index + 1,
                            total: soundIDs.count
                        )
                        await Task.yield()
                    }
                }

                guard !changedIDs.isEmpty else {
                    self.finishBatchOperation(
                        operationID: operationID,
                        message: "所选声音的收藏状态没有变化"
                    )
                    return
                }
                self.updateBatchProgress(
                    operationID: operationID,
                    actionTitle: actionTitle,
                    phase: .saving,
                    completed: 0,
                    total: changedIDs.count
                )
                try await self.persistenceWriter.updateFavorites(
                    soundIDs: changedIDs,
                    isFavorite: isFavorite
                ) { [weak self] completed, total in
                    Task { @MainActor [weak self] in
                        self?.updateBatchProgress(
                            operationID: operationID,
                            actionTitle: actionTitle,
                            phase: .saving,
                            completed: completed,
                            total: total
                        )
                    }
                }

                self.updateBatchProgress(
                    operationID: operationID,
                    actionTitle: actionTitle,
                    phase: .applying,
                    completed: changedIDs.count,
                    total: changedIDs.count
                )
                for soundID in changedIDs {
                    guard let location = self.soundLocationByID[soundID] else { continue }
                    self.packs[location.packIndex].items[location.itemIndex].isFavorite = isFavorite
                }
                self.favoriteCount += isFavorite ? changedIDs.count : -changedIDs.count
                self.publishFavoriteChange(changedIDs)
                self.scheduleRecoveryBackup()
                let action = isFavorite ? "设为收藏" : "取消收藏"
                self.finishBatchOperation(
                    operationID: operationID,
                    message: "已为 \(changedIDs.count.formatted(.number)) 个声音\(action)"
                )
            } catch is CancellationError {
                self.finishBatchOperation(
                    operationID: operationID,
                    message: "批量操作已取消，资料库没有改变"
                )
            } catch {
                self.finishBatchOperation(
                    operationID: operationID,
                    message: "批量收藏失败：\(error.localizedDescription)"
                )
            }
        }
    }

    func startBatchAddTags(_ tags: [String], to soundIDs: Set<UUID>) {
        guard activeBatchOperationTask == nil, !soundIDs.isEmpty else { return }
        let normalizedTags = SoundItem.normalizedTags(tags)
        guard !normalizedTags.isEmpty else {
            batchOperationResult = LibraryBatchOperationResult(message: "请输入至少一个标签")
            return
        }

        let operationID = UUID()
        let actionTitle = "批量添加标签"
        batchOperationProgress = LibraryBatchOperationProgress(
            id: operationID,
            actionTitle: actionTitle,
            phase: .preparing,
            completed: 0,
            total: soundIDs.count
        )
        activeBatchOperationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var updates: [LibraryMetadataUpdate] = []
                updates.reserveCapacity(soundIDs.count)
                for (index, soundID) in soundIDs.enumerated() {
                    try Task.checkCancellation()
                    if let location = self.soundLocationByID[soundID] {
                        let item = self.packs[location.packIndex].items[location.itemIndex]
                        let mergedTags = SoundItem.normalizedTags(item.tags + normalizedTags)
                        if mergedTags != item.tags {
                            updates.append(
                                LibraryMetadataUpdate(
                                    soundID: soundID,
                                    customName: item.customName,
                                    tags: mergedTags
                                )
                            )
                        }
                    }
                    if (index + 1).isMultiple(of: 512) {
                        self.updateBatchProgress(
                            operationID: operationID,
                            actionTitle: actionTitle,
                            phase: .preparing,
                            completed: index + 1,
                            total: soundIDs.count
                        )
                        await Task.yield()
                    }
                }

                guard !updates.isEmpty else {
                    self.finishBatchOperation(
                        operationID: operationID,
                        message: "这些标签已经存在于所选声音中"
                    )
                    return
                }
                self.updateBatchProgress(
                    operationID: operationID,
                    actionTitle: actionTitle,
                    phase: .saving,
                    completed: 0,
                    total: updates.count
                )
                try await self.persistenceWriter.updateMetadata(updates) { [weak self] completed, total in
                    Task { @MainActor [weak self] in
                        self?.updateBatchProgress(
                            operationID: operationID,
                            actionTitle: actionTitle,
                            phase: .saving,
                            completed: completed,
                            total: total
                        )
                    }
                }

                self.updateBatchProgress(
                    operationID: operationID,
                    actionTitle: actionTitle,
                    phase: .applying,
                    completed: updates.count,
                    total: updates.count
                )
                for update in updates {
                    guard let location = self.soundLocationByID[update.soundID] else { continue }
                    self.packs[location.packIndex].items[location.itemIndex].tags = update.tags
                }
                self.publishMetadataChange(updates.map(\.soundID))
                self.classificationRevision &+= 1
                self.scheduleRecoveryBackup()
                self.finishBatchOperation(
                    operationID: operationID,
                    message: "已为 \(updates.count.formatted(.number)) 个声音添加标签"
                )
            } catch is CancellationError {
                self.finishBatchOperation(
                    operationID: operationID,
                    message: "批量操作已取消，资料库没有改变"
                )
            } catch {
                self.finishBatchOperation(
                    operationID: operationID,
                    message: "批量标签失败：\(error.localizedDescription)"
                )
            }
        }
    }

    func startApplyMetadataSuggestions(
        _ candidates: [MetadataSuggestionCandidate],
        selectedIDs: Set<UUID>
    ) {
        guard activeBatchOperationTask == nil, !selectedIDs.isEmpty else { return }
        let selected = candidates.filter { selectedIDs.contains($0.id) && $0.hasChanges }
        let changes = selected.map { candidate in
            let appliedTags = SoundItem.normalizedTags(candidate.item.tags + candidate.suggestion.tags)
            return MetadataUndoChange(
                soundID: candidate.id,
                previousName: candidate.item.customName,
                previousTags: candidate.item.tags,
                appliedName: candidate.suggestion.displayName,
                appliedTags: appliedTags
            )
        }
        guard !changes.isEmpty else {
            batchOperationResult = LibraryBatchOperationResult(message: "所选声音没有需要应用的建议")
            return
        }

        let operationID = UUID()
        let actionTitle = "智能中文命名"
        let undoBatch = MetadataUndoBatch(changes: changes)
        let updates = changes.map {
            LibraryMetadataUpdate(
                soundID: $0.soundID,
                customName: $0.appliedName,
                tags: $0.appliedTags
            )
        }
        batchOperationProgress = LibraryBatchOperationProgress(
            id: operationID,
            actionTitle: actionTitle,
            phase: .saving,
            completed: 0,
            total: updates.count
        )
        activeBatchOperationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var savedUndo = false
            do {
                try await self.persistenceWriter.saveMetadataUndoBatch(undoBatch)
                savedUndo = true
                try await self.persistenceWriter.updateMetadata(updates) { [weak self] completed, total in
                    Task { @MainActor [weak self] in
                        self?.updateBatchProgress(
                            operationID: operationID,
                            actionTitle: actionTitle,
                            phase: .saving,
                            completed: completed,
                            total: total
                        )
                    }
                }
                self.updateBatchProgress(
                    operationID: operationID,
                    actionTitle: actionTitle,
                    phase: .applying,
                    completed: updates.count,
                    total: updates.count
                )
                for update in updates {
                    guard let location = self.soundLocationByID[update.soundID] else { continue }
                    self.packs[location.packIndex].items[location.itemIndex].customName = update.customName
                    self.packs[location.packIndex].items[location.itemIndex].tags = update.tags
                }
                self.lastMetadataUndoBatch = undoBatch
                self.publishMetadataChange(updates.map(\.soundID))
                self.classificationRevision &+= 1
                self.scheduleRecoveryBackup()
                self.finishBatchOperation(
                    operationID: operationID,
                    message: "已为 \(updates.count.formatted(.number)) 个声音应用中文别名与标签"
                )
            } catch is CancellationError {
                if savedUndo {
                    try? await self.persistenceWriter.deleteMetadataUndoBatch(id: undoBatch.id)
                }
                self.finishBatchOperation(
                    operationID: operationID,
                    message: "智能命名已取消，资料库没有改变"
                )
            } catch {
                if savedUndo {
                    try? await self.persistenceWriter.deleteMetadataUndoBatch(id: undoBatch.id)
                }
                self.finishBatchOperation(
                    operationID: operationID,
                    message: "智能命名失败：\(error.localizedDescription)"
                )
            }
        }
    }

    func startUndoLastMetadataSuggestions() {
        guard activeBatchOperationTask == nil, let batch = lastMetadataUndoBatch else { return }
        let applicable = batch.changes.filter { change in
            guard let current = sound(id: change.soundID) else { return false }
            return current.customName == change.appliedName && current.tags == change.appliedTags
        }
        guard !applicable.isEmpty else {
            Task {
                try? await persistenceWriter.deleteMetadataUndoBatch(id: batch.id)
                lastMetadataUndoBatch = try? await persistenceWriter.loadLatestMetadataUndoBatch()
            }
            batchOperationResult = LibraryBatchOperationResult(
                message: "上次智能命名已被手动修改，没有安全可撤销的项目"
            )
            return
        }

        let operationID = UUID()
        let actionTitle = "撤销智能命名"
        let updates = applicable.map {
            LibraryMetadataUpdate(
                soundID: $0.soundID,
                customName: $0.previousName,
                tags: $0.previousTags
            )
        }
        batchOperationProgress = LibraryBatchOperationProgress(
            id: operationID,
            actionTitle: actionTitle,
            phase: .saving,
            completed: 0,
            total: updates.count
        )
        activeBatchOperationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.persistenceWriter.updateMetadata(updates) { [weak self] completed, total in
                    Task { @MainActor [weak self] in
                        self?.updateBatchProgress(
                            operationID: operationID,
                            actionTitle: actionTitle,
                            phase: .saving,
                            completed: completed,
                            total: total
                        )
                    }
                }
                try await self.persistenceWriter.deleteMetadataUndoBatch(id: batch.id)
                self.updateBatchProgress(
                    operationID: operationID,
                    actionTitle: actionTitle,
                    phase: .applying,
                    completed: updates.count,
                    total: updates.count
                )
                for update in updates {
                    guard let location = self.soundLocationByID[update.soundID] else { continue }
                    self.packs[location.packIndex].items[location.itemIndex].customName = update.customName
                    self.packs[location.packIndex].items[location.itemIndex].tags = update.tags
                }
                self.lastMetadataUndoBatch = try? await self.persistenceWriter.loadLatestMetadataUndoBatch()
                self.publishMetadataChange(updates.map(\.soundID))
                self.classificationRevision &+= 1
                self.scheduleRecoveryBackup()
                self.finishBatchOperation(
                    operationID: operationID,
                    message: "已撤销 \(updates.count.formatted(.number)) 个声音的智能命名"
                )
            } catch is CancellationError {
                self.finishBatchOperation(
                    operationID: operationID,
                    message: "撤销已取消，资料库没有改变"
                )
            } catch {
                self.finishBatchOperation(
                    operationID: operationID,
                    message: "撤销智能命名失败：\(error.localizedDescription)"
                )
            }
        }
    }

    func cancelBatchOperation() {
        guard let progress = batchOperationProgress, progress.phase.canCancel else { return }
        batchOperationProgress = LibraryBatchOperationProgress(
            id: progress.id,
            actionTitle: progress.actionTitle,
            phase: .cancelling,
            completed: progress.completed,
            total: progress.total
        )
        activeBatchOperationTask?.cancel()
    }

    @discardableResult
    func setSoundsHidden(_ soundIDs: Set<UUID>, isHidden: Bool) -> Int {
        var changedIDs: [UUID] = []
        for soundID in soundIDs {
            guard let location = soundLocationByID[soundID],
                  packs[location.packIndex].items[location.itemIndex].isHidden != isHidden else {
                continue
            }
            packs[location.packIndex].items[location.itemIndex].isHidden = isHidden
            changedIDs.append(soundID)
        }
        guard !changedIDs.isEmpty else { return 0 }
        if isHidden {
            hiddenSoundIDs.formUnion(changedIDs)
        } else {
            hiddenSoundIDs.subtract(changedIDs)
        }
        hiddenSoundCount = hiddenSoundIDs.count
        visibilityRevision &+= 1
        Task {
            do {
                try await persistenceWriter.updateHidden(soundIDs: changedIDs, isHidden: isHidden)
                scheduleRecoveryBackup()
            } catch {
                for soundID in changedIDs {
                    guard let location = soundLocationByID[soundID],
                          packs[location.packIndex].items[location.itemIndex].isHidden == isHidden else {
                        continue
                    }
                    packs[location.packIndex].items[location.itemIndex].isHidden = !isHidden
                    if isHidden {
                        hiddenSoundIDs.remove(soundID)
                    } else {
                        hiddenSoundIDs.insert(soundID)
                    }
                }
                hiddenSoundCount = hiddenSoundIDs.count
                visibilityRevision &+= 1
                alertMessage = "重复项可见性保存失败：\(error.localizedDescription)"
            }
        }
        return changedIDs.count
    }

    func hideDuplicateItems(in group: LibraryDuplicateGroup, keeping soundID: UUID) {
        let otherIDs = Set(group.items.lazy.map(\.id).filter { $0 != soundID })
        _ = setSoundsHidden([soundID], isHidden: false)
        let changed = setSoundsHidden(otherIDs, isHidden: true)
        batchOperationResult = LibraryBatchOperationResult(
            message: changed > 0
                ? "已保留 1 项，并从主列表隐藏 \(changed.formatted(.number)) 项"
                : "这一组已经按当前选择整理完成"
        )
    }

    func restoreDuplicateItems(in group: LibraryDuplicateGroup) {
        let changed = setSoundsHidden(Set(group.items.map(\.id)), isHidden: false)
        batchOperationResult = LibraryBatchOperationResult(
            message: changed > 0 ? "已恢复 \(changed.formatted(.number)) 个声音" : "这一组没有隐藏项"
        )
    }

    func restoreAllHiddenSounds() {
        let hiddenIDs = hiddenSoundIDs
        let changed = setSoundsHidden(hiddenIDs, isHidden: false)
        batchOperationResult = LibraryBatchOperationResult(
            message: changed > 0 ? "已恢复 \(changed.formatted(.number)) 个隐藏声音" : "没有需要恢复的声音"
        )
    }

    func setDuplicateGroupIgnored(_ fingerprint: String, isIgnored: Bool) {
        guard !fingerprint.isEmpty else { return }
        let wasIgnored = ignoredDuplicateFingerprints.contains(fingerprint)
        guard wasIgnored != isIgnored else { return }
        if isIgnored {
            ignoredDuplicateFingerprints.insert(fingerprint)
        } else {
            ignoredDuplicateFingerprints.remove(fingerprint)
        }
        Task {
            do {
                try await persistenceWriter.setDuplicateGroupIgnored(
                    fingerprint: fingerprint,
                    isIgnored: isIgnored
                )
                scheduleRecoveryBackup()
            } catch {
                guard ignoredDuplicateFingerprints.contains(fingerprint) == isIgnored else { return }
                if wasIgnored {
                    ignoredDuplicateFingerprints.insert(fingerprint)
                } else {
                    ignoredDuplicateFingerprints.remove(fingerprint)
                }
                alertMessage = "重复组状态保存失败：\(error.localizedDescription)"
            }
        }
    }

    func updateMetadata(for itemID: UUID, customName: String?, tags: [String]) {
        guard batchOperationProgress == nil else {
            alertMessage = "批量操作完成后再修改单个声音的别名或标签。"
            return
        }
        guard let location = soundLocationByID[itemID] else { return }
        let normalizedName = customName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveName = normalizedName?.isEmpty == false ? normalizedName : nil
        let normalizedTags = SoundItem.normalizedTags(tags)
        let previousItem = packs[location.packIndex].items[location.itemIndex]
        guard previousItem.customName != effectiveName || previousItem.tags != normalizedTags else {
            return
        }
        packs[location.packIndex].items[location.itemIndex].customName = effectiveName
        packs[location.packIndex].items[location.itemIndex].tags = normalizedTags
        publishMetadataChange([itemID])
        classificationRevision &+= 1

        Task {
            do {
                try await persistenceWriter.updateMetadata(
                    soundID: itemID,
                    customName: effectiveName,
                    tags: normalizedTags
                )
                scheduleRecoveryBackup()
            } catch {
                if let currentLocation = soundLocationByID[itemID],
                   packs[currentLocation.packIndex].items[currentLocation.itemIndex].customName
                    == effectiveName,
                   packs[currentLocation.packIndex].items[currentLocation.itemIndex].tags
                    == normalizedTags {
                    packs[currentLocation.packIndex].items[currentLocation.itemIndex].customName
                        = previousItem.customName
                    packs[currentLocation.packIndex].items[currentLocation.itemIndex].tags
                        = previousItem.tags
                    publishMetadataChange([itemID])
                    classificationRevision &+= 1
                }
                alertMessage = "别名与标签保存失败：\(error.localizedDescription)"
            }
        }
    }

    func url(for item: SoundItem) -> URL? {
        guard let packIndex = packIndexByID[item.packageID],
              let rootURL = resolvedRootURL(for: packs[packIndex]) else { return nil }
        return rootURL.appendingPathComponent(item.relativePath, isDirectory: false)
    }

    func healthSnapshot() async throws -> LibraryHealthSnapshot {
        let packs = packs
        let scopedRootURLs = scopedRootURLs
        let persistence = persistence
        return try await Task.detached(priority: .utility) {
            let databaseBytes = persistence.databaseSize
                + Self.fileSizeOutsideMainActor(
                    at: URL(fileURLWithPath: persistence.databaseURL.path + "-wal")
                )
                + Self.fileSizeOutsideMainActor(
                    at: URL(fileURLWithPath: persistence.databaseURL.path + "-shm")
                )
            return try LibraryHealthSnapshotBuilder.make(
                packs: packs,
                scopedRootURLs: scopedRootURLs,
                databaseBytes: databaseBytes,
                hasRecoveryBackup: persistence.hasRecoveryBackup
            )
        }.value
    }

    func exportRecoverySnapshotWithPanel() {
        guard recoveryTransferTask == nil else {
            alertMessage = "资料库备份正在处理，请稍候。"
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出拾响资料库备份"
        panel.message = "只导出索引、集合和分析结果，不会复制原始音频。"
        panel.prompt = "导出备份"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Shixiang-Library-Backup-\(Self.backupDateStamp()).json"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let snapshot = currentRecoverySnapshot()
        isRecoveryTransferInProgress = true
        recoveryTransferTask = Task { @MainActor [weak self, persistenceWriter] in
            defer {
                self?.isRecoveryTransferInProgress = false
                self?.recoveryTransferTask = nil
            }
            do {
                try await persistenceWriter.exportSnapshot(snapshot, to: url)
                guard !Task.isCancelled, let self else { return }
                self.alertMessage = "资料库备份已导出：\(url.lastPathComponent)"
            } catch is CancellationError {
                return
            } catch {
                self?.alertMessage = "导出资料库备份失败：\(error.localizedDescription)"
            }
        }
    }

    func importRecoverySnapshotWithPanel(player: AudioPlayerController? = nil) {
        guard recoveryTransferTask == nil else {
            alertMessage = "资料库备份正在处理，请稍候。"
            return
        }
        let panel = NSOpenPanel()
        panel.title = "导入拾响资料库备份"
        panel.message = "选择此前导出的 JSON。导入只替换拾响索引，不会移动、改名或删除原始音频。"
        panel.prompt = "选择备份"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        isRecoveryTransferInProgress = true
        recoveryTransferTask = Task { @MainActor [weak self, persistenceWriter] in
            defer {
                self?.isRecoveryTransferInProgress = false
                self?.recoveryTransferTask = nil
            }
            do {
                let snapshot = try await persistenceWriter.importSnapshot(from: url)
                guard !Task.isCancelled, let self else { return }

                let confirmation = NSAlert()
                confirmation.messageText = "导入资料库备份？"
                confirmation.informativeText = "当前索引会先自动备份，然后替换为“\(url.lastPathComponent)”中的内容。原始音频文件不会被移动、改名或删除。"
                confirmation.alertStyle = .warning
                confirmation.addButton(withTitle: "导入并替换")
                confirmation.addButton(withTitle: "取消")
                guard confirmation.runModal() == .alertFirstButtonReturn else { return }

                let currentSnapshot = self.currentRecoverySnapshot()
                try await persistenceWriter.saveRecoveryBackup(currentSnapshot)
                guard !Task.isCancelled else { return }
                player?.resetForLibraryReplacement()
                WaveformCacheMaintenance.clearInBackground()
                self.replaceLibrary(with: snapshot)
                self.alertMessage = "资料库备份已导入：\(url.lastPathComponent)"
            } catch is CancellationError {
                return
            } catch {
                self?.alertMessage = "导入资料库备份失败：\(error.localizedDescription)"
            }
        }
    }

    func relinkPackWithPanel(_ packID: UUID) {
        guard let packIndex = packIndexByID[packID] else { return }
        let pack = packs[packIndex]
        let panel = NSOpenPanel()
        panel.title = "重新定位“\(pack.name)”"
        panel.message = "选择这个音效包现在所在的文件夹。原文件不会被移动或改名。"
        panel.prompt = "重新定位"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: pack.rootPath).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        startRelinkPack(packID, to: url)
    }

    func startRelinkPack(_ packID: UUID, to url: URL) {
        guard activeIndexingTask == nil else { return }
        activeIndexingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.relinkPack(packID, to: url)
            self.activeIndexingTask = nil
        }
    }

    func relinkPack(_ packID: UUID, to newRootURL: URL) async {
        guard !isIndexing, let packIndex = packIndexByID[packID] else { return }
        let rootURL = newRootURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            alertMessage = "请选择有效的音效包文件夹。"
            return
        }

        let scanToken = beginIndexing(status: "正在重新定位音效包…")
        defer { finishIndexing(scanToken) }
        let previousItems = packs[packIndex].items
        let accessed = rootURL.startAccessingSecurityScopedResource()
        do {
            let scanResult = try await scanner.scanResult(
                rootURL: rootURL,
                packageID: packID,
                existingItems: previousItems,
                progress: scanProgressHandler(for: scanToken)
            )
            try Task.checkCancellation()
            let scanned = scanResult.items
            guard previousItems.isEmpty || !scanned.isEmpty else {
                throw LibraryRelinkError.noMatchingAudio(packName: packs[packIndex].name)
            }
            let previousByID = Dictionary(uniqueKeysWithValues: previousItems.map { ($0.id, $0) })
            let hasConfirmedContentMatch = scanned.contains { item in
                guard let previous = previousByID[item.id],
                      previous.sourceFileSize == item.sourceFileSize,
                      let previousSignature = previous.sourceContentSignature,
                      let newSignature = item.sourceContentSignature else { return false }
                return previousSignature == newSignature
            }
            guard previousItems.isEmpty || hasConfirmedContentMatch else {
                throw LibraryRelinkError.noMatchingAudio(packName: packs[packIndex].name)
            }
            invalidateChangedIntelligence(previousItems: previousItems, newItems: scanned)
            if let oldScoped = scopedRootURLs.removeValue(forKey: packID), oldScoped != rootURL {
                oldScoped.stopAccessingSecurityScopedResource()
            }
            if accessed { scopedRootURLs[packID] = rootURL }
            packs[packIndex].name = rootURL.lastPathComponent
            packs[packIndex].rootPath = rootURL.path
            packs[packIndex].bookmarkData = makeBookmark(for: rootURL)
                ?? packs[packIndex].bookmarkData
            packs[packIndex].lastScannedAt = Date()
            packs[packIndex].items = scanned
            rebuildIndexes()
            libraryRevision &+= 1
            classificationRevision &+= 1
            selectedPackID = packID
            selectedFolderPath = nil
            selection.select(scanned.first?.id)
            lastScanResult = scanResult.report
            persistPack(packID)
            refreshPackAvailability()
            configureFolderMonitoring()
        } catch is CancellationError {
            return
        } catch {
            if accessed { rootURL.stopAccessingSecurityScopedResource() }
            alertMessage = "重新定位失败：\(error.localizedDescription)"
        }
    }

    nonisolated private static func fileSizeOutsideMainActor(at url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private func beginIndexing(status: String) -> UUID {
        let token = UUID()
        activeScanToken = token
        isIndexing = true
        indexingProgress = 0
        indexingStatus = status
        return token
    }

    private func finishIndexing(_ token: UUID) {
        guard activeScanToken == token else { return }
        activeScanToken = nil
        isIndexing = false
        indexingProgress = nil
        indexingStatus = nil
    }

    private func scanProgressHandler(for token: UUID) -> @Sendable (Int, Int) -> Void {
        { [weak self] completed, total in
            Task { @MainActor [weak self] in
                guard let self, self.activeScanToken == token else { return }
                self.indexingProgress = total > 0
                    ? min(max(Double(completed) / Double(total), 0), 1)
                    : 1
                self.indexingStatus = total > 0
                    ? "正在读取声音信息 \(completed.formatted(.number)) / \(total.formatted(.number))"
                    : "正在读取声音信息…"
            }
        }
    }

    private func invalidateChangedIntelligence(
        previousItems: [SoundItem],
        newItems: [SoundItem]
    ) {
        let previousByID = Dictionary(uniqueKeysWithValues: previousItems.map { ($0.id, $0) })
        for item in newItems {
            guard let previous = previousByID[item.id] else { continue }
            if previous.sourceFingerprint != item.sourceFingerprint {
                setIntelligence(nil, for: item.id)
            }
        }
    }

    private func updateBatchProgress(
        operationID: UUID,
        actionTitle: String,
        phase: LibraryBatchOperationProgress.Phase,
        completed: Int,
        total: Int
    ) {
        guard let current = batchOperationProgress,
              current.id == operationID,
              current.phase != .cancelling || phase == .applying else {
            return
        }
        batchOperationProgress = LibraryBatchOperationProgress(
            id: operationID,
            actionTitle: actionTitle,
            phase: phase,
            completed: completed,
            total: total
        )
    }

    private func finishBatchOperation(operationID: UUID, message: String) {
        guard batchOperationProgress?.id == operationID else { return }
        batchOperationProgress = nil
        batchOperationResult = LibraryBatchOperationResult(message: message)
        activeBatchOperationTask = nil
    }

    private func rebuildIndexes() {
        packIndexByID.removeAll(keepingCapacity: true)
        soundLocationByID.removeAll(keepingCapacity: true)
        soundCount = packs.reduce(0) { $0 + $1.items.count }
        soundLocationByID.reserveCapacity(soundCount)
        hiddenSoundIDs.removeAll(keepingCapacity: true)
        var rebuiltFavoriteCount = 0

        for (packIndex, pack) in packs.enumerated() {
            packIndexByID[pack.id] = packIndex
            for (itemIndex, item) in pack.items.enumerated() {
                soundLocationByID[item.id] = SoundLocation(
                    packIndex: packIndex,
                    itemIndex: itemIndex
                )
                if item.isFavorite {
                    rebuiltFavoriteCount += 1
                }
                if item.isHidden {
                    hiddenSoundIDs.insert(item.id)
                }
            }
        }
        favoriteCount = rebuiltFavoriteCount
        hiddenSoundCount = hiddenSoundIDs.count
        intelligenceByID = intelligenceByID.filter { soundLocationByID[$0.key] != nil }
        acousticFingerprintCount = intelligenceByID.values.lazy.filter {
            $0.acousticFingerprint != nil
        }.count
    }

    private func setIntelligence(_ intelligence: AudioIntelligence?, for soundID: UUID) {
        let hadFingerprint = intelligenceByID[soundID]?.acousticFingerprint != nil
        let hasFingerprint = intelligence?.acousticFingerprint != nil
        intelligenceByID[soundID] = intelligence
        if hadFingerprint != hasFingerprint {
            acousticFingerprintCount += hasFingerprint ? 1 : -1
        }
    }

    private func mergeIntelligence(_ updates: [UUID: AudioIntelligence]) {
        var fingerprintDelta = 0
        for (soundID, intelligence) in updates {
            let hadFingerprint = intelligenceByID[soundID]?.acousticFingerprint != nil
            let hasFingerprint = intelligence.acousticFingerprint != nil
            if hadFingerprint != hasFingerprint {
                fingerprintDelta += hasFingerprint ? 1 : -1
            }
        }
        intelligenceByID.merge(updates) { _, new in new }
        acousticFingerprintCount += fingerprintDelta
    }

    private func publishFavoriteChange(_ soundIDs: [UUID]) {
        lastFavoriteChangedIDs = soundIDs
        favoriteRevision &+= 1
    }

    private func publishMetadataChange(_ soundIDs: [UUID]) {
        lastMetadataChangedIDs = soundIDs
        metadataRevision &+= 1
    }

    private func beginSemanticOperation() -> UUID {
        let token = UUID()
        semanticOperationToken = token
        semanticIndexProgress = nil
        lastSemanticSearchMatchCount = 0
        lastSemanticConceptTitles = []
        return token
    }

    private func persist() {
        persistenceTask?.cancel()
        persistenceTask = Task {
            do {
                // Collapse rapid structural changes and keep 36k-row SQLite writes entirely
                // away from pointer tracking and scrolling on the main actor.
                try await Task.sleep(for: .milliseconds(180))
                try Task.checkCancellation()
                let snapshot = currentRecoverySnapshot()
                try await persistenceWriter.save(snapshot)
            } catch is CancellationError {
                return
            } catch {
                alertMessage = "音效索引保存失败：\(error.localizedDescription)"
            }
        }
    }

    private func persistPack(_ packID: UUID) {
        persistenceTask?.cancel()
        persistenceTask = Task {
            do {
                // Coalesce repeated file-system events, then update only the pack that changed.
                // The full recovery snapshot is still written after the SQLite transaction.
                try await Task.sleep(for: .milliseconds(180))
                try Task.checkCancellation()
                guard let pack = packs.first(where: { $0.id == packID }) else { return }
                let snapshot = currentRecoverySnapshot()
                try await persistenceWriter.replacePack(
                    pack,
                    intelligenceByID: snapshot.intelligenceByID
                )
                try await persistenceWriter.saveRecoveryBackup(snapshot)
            } catch is CancellationError {
                return
            } catch {
                alertMessage = "音效索引保存失败：\(error.localizedDescription)"
            }
        }
    }

    private func scheduleRecoveryBackup() {
        recoveryBackupTask?.cancel()
        recoveryBackupTask = Task {
            do {
                try await Task.sleep(for: .seconds(2))
                try Task.checkCancellation()
                let snapshot = currentRecoverySnapshot()
                try await persistenceWriter.saveRecoveryBackup(snapshot)
            } catch {
                // The SQLite transaction already contains the edit. Recovery snapshots are
                // best-effort and must never interrupt auditioning or scrolling.
            }
        }
    }

    private func currentRecoverySnapshot() -> LibraryRecoverySnapshot {
        LibraryRecoverySnapshot(
            packs: packs,
            savedCollections: savedCollections,
            intelligenceByID: intelligenceByID,
            ignoredDuplicateFingerprints: ignoredDuplicateFingerprints,
            namingProfile: namingProfile
        )
    }

    private func replaceLibrary(with snapshot: LibraryRecoverySnapshot) {
        for scopedURL in scopedRootURLs.values {
            scopedURL.stopAccessingSecurityScopedResource()
        }
        scopedRootURLs.removeAll(keepingCapacity: true)
        packs = snapshot.packs
        savedCollections = snapshot.savedCollections
        intelligenceByID = snapshot.intelligenceByID
        ignoredDuplicateFingerprints = snapshot.ignoredDuplicateFingerprints
        namingProfile = snapshot.namingProfile
        lastScanResult = nil
        restoreSecurityScopedAccess()
        rebuildIndexes()
        refreshPackAvailability()
        configureFolderMonitoring()
        selectedPackID = packs.first?.id
        selectedFolderPath = nil
        selection.select(packs.first?.items.first?.id)
        libraryRevision &+= 1
        classificationRevision &+= 1
        visibilityRevision &+= 1
        persist()
        scheduleRecoveryBackup()
    }

    private static func backupDateStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func restoreSecurityScopedAccess() {
        for index in packs.indices {
            guard let bookmarkData = packs[index].bookmarkData else { continue }
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { continue }

            if url.startAccessingSecurityScopedResource() {
                scopedRootURLs[packs[index].id] = url
            }
            packs[index].rootPath = url.path
            if isStale, let refreshed = makeBookmark(for: url) {
                packs[index].bookmarkData = refreshed
            }
        }
    }

    private func resolvedRootURL(for pack: SoundPack) -> URL? {
        if let scopedURL = scopedRootURLs[pack.id] {
            return scopedURL
        }

        if let bookmarkData = pack.bookmarkData {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                if url.startAccessingSecurityScopedResource() {
                    scopedRootURLs[pack.id] = url
                }
                return url
            }
        }

        let fallback = URL(fileURLWithPath: pack.rootPath, isDirectory: true)
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    private func configureFolderMonitoring() {
        guard isFolderMonitoringEnabled else {
            folderMonitor.stop()
            return
        }
        let roots = Dictionary(uniqueKeysWithValues: packs.map {
            ($0.id, scopedRootURLs[$0.id] ?? URL(fileURLWithPath: $0.rootPath, isDirectory: true))
        })
        folderMonitor.start(roots: roots) { [weak self] packID, _ in
            Task { @MainActor [weak self] in
                self?.handleObservedFolderChange(packID: packID)
            }
        }
    }

    private func handleObservedFolderChange(packID: UUID) {
        guard isFolderMonitoringEnabled, packIndexByID[packID] != nil else { return }
        refreshPackAvailability()
        automaticRefreshDebounceTasks[packID]?.cancel()
        automaticRefreshDebounceTasks[packID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1_650))
            guard !Task.isCancelled, let self else { return }
            self.automaticRefreshDebounceTasks[packID] = nil
            await self.refreshPackInBackground(packID)
        }
    }

    private func refreshPackInBackground(_ packID: UUID) async {
        guard isFolderMonitoringEnabled,
              activeIndexingTask == nil,
              batchOperationProgress == nil,
              acousticAnalysisProgress == nil,
              autoRefreshingPackIDs.isEmpty,
              let packIndex = packIndexByID[packID] else {
            // Foreground audio and creator-triggered disk work retain priority.
            handleObservedFolderChange(packID: packID)
            return
        }
        let pack = packs[packIndex]
        guard let rootURL = resolvedRootURL(for: pack) else {
            unavailablePackIDs.insert(packID)
            return
        }
        autoRefreshingPackIDs.insert(packID)
        defer { autoRefreshingPackIDs.remove(packID) }
        do {
            let scanResult = try await scanner.scanResult(
                rootURL: rootURL,
                packageID: packID,
                existingItems: pack.items
            )
            try Task.checkCancellation()
            guard let currentIndex = packIndexByID[packID] else { return }
            let previousItems = packs[currentIndex].items
            guard scanResult.requiresIndexUpdate else {
                unavailablePackIDs.remove(packID)
                return
            }
            invalidateChangedIntelligence(previousItems: previousItems, newItems: scanResult.items)
            packs[currentIndex].items = scanResult.items
            packs[currentIndex].lastScannedAt = Date()
            rebuildIndexes()
            libraryRevision &+= 1
            classificationRevision &+= 1
            lastScanResult = scanResult.report
            unavailablePackIDs.remove(packID)
            persistPack(packID)
        } catch is CancellationError {
            return
        } catch {
            // A sleeping external disk receives an offline badge. Explicit refresh continues
            // to surface detailed errors when the creator wants to diagnose it.
            refreshPackAvailability()
        }
    }

    private func startAvailabilityMonitor() {
        availabilityMonitorTask?.cancel()
        availabilityMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                let previouslyUnavailable = self.unavailablePackIDs
                self.refreshPackAvailability()
                if self.isFolderMonitoringEnabled,
                   previouslyUnavailable != self.unavailablePackIDs {
                    self.configureFolderMonitoring()
                    for packID in previouslyUnavailable.subtracting(self.unavailablePackIDs) {
                        self.handleObservedFolderChange(packID: packID)
                    }
                }
            }
        }
    }
}

private actor LibraryPersistenceWriter {
    let persistence: LibraryPersistence

    init(persistence: LibraryPersistence) {
        self.persistence = persistence
    }

    func save(_ snapshot: LibraryRecoverySnapshot) throws {
        try persistence.save(
            snapshot.packs,
            savedCollections: snapshot.savedCollections,
            intelligenceByID: snapshot.intelligenceByID,
            ignoredDuplicateFingerprints: snapshot.ignoredDuplicateFingerprints,
            namingProfile: snapshot.namingProfile
        )
    }

    func replacePack(
        _ pack: SoundPack,
        intelligenceByID: [UUID: AudioIntelligence]
    ) throws {
        try persistence.replacePack(pack, intelligenceByID: intelligenceByID)
    }

    func updateFavorite(soundID: UUID, isFavorite: Bool) throws {
        try persistence.updateFavorite(soundID: soundID, isFavorite: isFavorite)
    }

    func updateMetadata(soundID: UUID, customName: String?, tags: [String]) throws {
        try persistence.updateMetadata(soundID: soundID, customName: customName, tags: tags)
    }

    func updateFavorites(
        soundIDs: [UUID],
        isFavorite: Bool,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws {
        try persistence.updateFavorites(
            soundIDs: soundIDs,
            isFavorite: isFavorite,
            progress: progress
        )
    }

    func updateMetadata(
        _ updates: [LibraryMetadataUpdate],
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws {
        try persistence.updateMetadata(updates, progress: progress)
    }

    func updateHidden(soundIDs: [UUID], isHidden: Bool) throws {
        try persistence.updateHidden(soundIDs: soundIDs, isHidden: isHidden)
    }

    func setDuplicateGroupIgnored(fingerprint: String, isIgnored: Bool) throws {
        try persistence.setDuplicateGroupIgnored(fingerprint: fingerprint, isIgnored: isIgnored)
    }

    func saveSavedCollection(_ collection: SavedCollection) throws {
        try persistence.saveSavedCollection(collection)
    }

    func deleteSavedCollection(id: UUID) throws {
        try persistence.deleteSavedCollection(id: id)
    }

    func searchSoundIDs(matching query: String) throws -> Set<UUID> {
        try persistence.searchSoundIDs(matching: query)
    }

    func searchSoundMatches(
        matching query: String,
        mode: LibrarySearchMode,
        progress: (@Sendable (SemanticIndexProgress) -> Void)? = nil
    ) throws -> LibrarySearchMatches {
        try persistence.searchSoundMatches(
            matching: query,
            mode: mode,
            progress: progress
        )
    }

    func similarityCandidates(
        for soundID: UUID,
        progress: (@Sendable (SemanticIndexProgress) -> Void)? = nil
    ) throws -> [SoundSimilarityIndexCandidate] {
        try persistence.similarityCandidates(for: soundID, progress: progress)
    }

    func saveMetadataUndoBatch(_ batch: MetadataUndoBatch) throws {
        try persistence.saveMetadataUndoBatch(batch)
    }

    func loadLatestMetadataUndoBatch() throws -> MetadataUndoBatch? {
        try persistence.loadLatestMetadataUndoBatch()
    }

    func deleteMetadataUndoBatch(id: UUID) throws {
        try persistence.deleteMetadataUndoBatch(id: id)
    }

    func saveAudioIntelligence(soundID: UUID, intelligence: AudioIntelligence) throws {
        try persistence.saveAudioIntelligence(soundID: soundID, intelligence: intelligence)
    }

    func saveNamingProfile(_ profile: JacksunNamingProfile) throws {
        try persistence.saveNamingProfile(profile)
    }

    func saveRecoveryBackup(_ snapshot: LibraryRecoverySnapshot) throws {
        try persistence.saveRecoveryBackup(snapshot)
    }

    func exportSnapshot(_ snapshot: LibraryRecoverySnapshot, to url: URL) throws {
        try persistence.exportSnapshot(snapshot, to: url)
    }

    func importSnapshot(from url: URL) throws -> LibraryRecoverySnapshot {
        try persistence.importSnapshot(from: url)
    }
}

private struct SoundLocation {
    let packIndex: Int
    let itemIndex: Int
}

private enum LibraryRelinkError: LocalizedError {
    case noMatchingAudio(packName: String)

    var errorDescription: String? {
        switch self {
        case let .noMatchingAudio(packName):
            return "所选文件夹没有匹配到“\(packName)”中的原声音，请选择音效包本身所在的文件夹。当前索引没有改变。"
        }
    }
}

@MainActor
final class LibrarySelection: ObservableObject {
    @Published private(set) var soundID: UUID?

    func select(_ id: UUID?) {
        guard soundID != id else { return }
        soundID = id
    }
}
