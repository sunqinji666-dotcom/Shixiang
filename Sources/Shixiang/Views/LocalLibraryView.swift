import AppKit
import SwiftUI

struct LocalLibraryView: View {
    private let onInitialContentReady: () -> Void
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: AudioPlayerController
    @Environment(\.stopPitchPreview) private var stopPitchPreview

    @State private var scope: LibraryScope = .all
    @State private var sortMode: SoundSortMode = .name
    @State private var selectedFormat: String?
    @State private var minimumDuration: Double?
    @State private var maximumDuration: Double?
    @State private var favoritesOnly = false
    @State private var isWorkbenchPresented = false
    @State private var isHealthPresented = false
    @State private var isSaveCollectionPresented = false
    @State private var isSavedCollectionsPresented = false
    @State private var isOnboardingPresented = false
    @State private var isFirstLibrarySetupPresented = false
    @State private var isSponsorPresented = false
    // A deliberate six-click farewell is permanent for this macOS user. A genuinely fresh
    // installation/user profile has no stored value and starts with the full-size coin again.
    @AppStorage("shixiang.sponsorCoin.clickCount.v1") private var sponsorCoinClickCount = 0
    @State private var isBatchTagPresented = false
    @State private var isFCPDeliveryPresented = false
    @State private var isSimilarityPresented = false
    @State private var isMetadataSuggestionsPresented = false
    @State private var isAcousticAnalysisPresented = false
    @State private var isBatchMode = false
    @StateObject private var batchSelection = SoundBatchSelection()
    @State private var isRemovePackConfirmationPresented = false
    @State private var isFullRebuildConfirmationPresented = false
    @State private var isMigrationReviewPresented = false
    @State private var dismissedMigrationAt: Date?
    @State private var cachedSounds: [SoundItem] = []
    @State private var cachedSoundIndexByID: [UUID: Int] = [:]
    @State private var cachedAISearchFeaturedIDs = Set<UUID>()
    @State private var cachedExactSearchIDs = Set<UUID>()
    @State private var cachedAISearchIntent = AISearchIntent.empty
    @State private var cachedAISearchCreatorIntent = CreatorSearchIntent.empty
    @State private var cachedAIConflictSummary: String?
    @State private var cachedFormats: [String] = []
    @State private var soundDatasetID: UInt64 = 0
    @State private var transientNotice: String?
    @State private var transientNoticeTask: Task<Void, Never>?
    @State private var workspacePersistenceTask: Task<Void, Never>?
    @State private var aiSearchPlan: LocalAISearchPlan?
    @State private var isAISearching = false
    @State private var aiSearchFailure: String?
    @State private var isAIHintVisible = false
    // v2 deliberately uses a fresh key: earlier builds marked the hint as presented before the
    // splash screen had finished, which made the bubble appear to be missing forever.
    @AppStorage("shixiang.library.aiHintPresented.v2") private var hasPresentedAIHint = false
    @State private var searchActivity: SearchActivity?
    @AppStorage("shixiang.firstLibrarySetup.hasPresented.v1") private var hasPresentedFirstLibrarySetup = false
    @AppStorage("shixiang.library.showsHiddenSounds") private var showsHiddenSounds = false
    @AppStorage("shixiang.library.localAISearchEnabled") private var isLocalAISearchEnabled = false
    @AppStorage("shixiang.library.workspaceState") private var workspaceStateJSON = ""
    @State private var hasRestoredWorkspace = false
    @State private var pendingWorkspaceSoundID: UUID?
    @State private var workbenchWidth: CGFloat = 360
    @State private var workbenchHeight: CGFloat = 350
    @State private var workbenchResizeStart: CGFloat?
    @State private var isWindowLiveResizing = false
    @State private var hasReportedInitialContentReady = false
    @State private var hasBuiltInitialResultSnapshot = false
    @FocusState private var isSearchFocused: Bool
    @AppStorage("shixiang.library.workbench.width") private var savedWorkbenchWidth = 360.0
    @AppStorage("shixiang.library.workbench.height") private var savedWorkbenchHeight = 350.0

    init(onInitialContentReady: @escaping () -> Void = {}) {
        self.onInitialContentReady = onInitialContentReady
    }

    /// Live resizing invalidates the entire SwiftUI hierarchy on every pointer event. Replace
    /// the split view, native list and animated player with a cheap static silhouette until the
    /// final window size settles; all real state remains alive in the model and returns intact.
    private var liveResizeShell: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    ShixiangMark(size: 26)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(ShixiangTheme.primaryText.opacity(0.24))
                        .frame(width: 54, height: 7)
                    Spacer()
                }
                .padding(.leading, 82)
                .padding(.trailing, 14)
                .frame(height: 58)

                VStack(spacing: 13) {
                    ForEach(0..<11, id: \.self) { index in
                        HStack(spacing: 9) {
                            Circle()
                                .fill(index == 2 ? ShixiangTheme.violet.opacity(0.72) : ShixiangTheme.secondaryText.opacity(0.16))
                                .frame(width: 8, height: 8)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(ShixiangTheme.secondaryText.opacity(index == 2 ? 0.32 : 0.14))
                                .frame(width: index.isMultiple(of: 3) ? 82 : 112, height: 6)
                            Spacer()
                        }
                    }
                    Spacer()
                }
                .padding(16)
            }
            .frame(width: 248)
            .background(ShixiangTheme.surface)

            Rectangle().fill(ShixiangTheme.hairline).frame(width: 1)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(ShixiangTheme.elevated)
                        .frame(maxWidth: 420, minHeight: 34, maxHeight: 34)
                    Spacer()
                    ForEach(0..<4, id: \.self) { _ in
                        Circle().fill(ShixiangTheme.secondaryText.opacity(0.16)).frame(width: 26, height: 26)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 58)

                Rectangle().fill(ShixiangTheme.hairline).frame(height: 1)

                VStack(spacing: 0) {
                    ForEach(0..<9, id: \.self) { index in
                        HStack(spacing: 14) {
                            Circle().fill(ShixiangTheme.secondaryText.opacity(0.13)).frame(width: 28, height: 28)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(ShixiangTheme.secondaryText.opacity(0.13))
                                .frame(maxWidth: index.isMultiple(of: 2) ? 290 : 230, minHeight: 7, maxHeight: 7)
                            Spacer()
                            RoundedRectangle(cornerRadius: 2)
                                .fill(ShixiangTheme.secondaryText.opacity(0.11))
                                .frame(width: 52, height: 6)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 50)
                        Rectangle().fill(ShixiangTheme.hairline).frame(height: 1)
                    }
                    Spacer(minLength: 0)
                }

                RoundedRectangle(cornerRadius: 10)
                    .fill(ShixiangTheme.surface)
                    .frame(height: 74)
                    .padding(8)
            }
            .background(ShixiangTheme.canvas)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }

    var body: some View {
        let sounds = cachedSounds

        ZStack {
            ShixiangTheme.workspaceGradient.ignoresSafeArea()

            if isWindowLiveResizing {
                liveResizeShell
            } else {
            HSplitView {
                LibrarySidebar(
                    scope: $scope,
                    isSponsorPresented: $isSponsorPresented,
                    sponsorCoinClickCount: $sponsorCoinClickCount
                )
                    .frame(minWidth: 220, idealWidth: 248, maxWidth: 300)

                VStack(spacing: 0) {
                    commandBar
                    if hasActiveFilters {
                        activeFilterBar
                    }
                    libraryHeader(soundCount: sounds.count)
                    if shouldShowSearchDirections {
                        searchDirectionBar
                    }
                    if let scanResult = library.lastScanResult,
                       dismissedMigrationAt != scanResult.completedAt {
                        sourceMigrationBanner(scanResult)
                    }
                    Divider().overlay(ShixiangTheme.hairline)

                    SoundListView(
                        items: sounds,
                        indexByID: cachedSoundIndexByID,
                        aiFeaturedIDs: cachedAISearchFeaturedIDs,
                        exactSearchIDs: cachedExactSearchIDs,
                        aiSearchQuery: library.query,
                        aiSearchIntent: cachedAISearchIntent,
                        aiCreatorIntent: cachedAISearchCreatorIntent,
                        aiConflictSummary: cachedAIConflictSummary,
                        isInitialResultReady: hasBuiltInitialResultSnapshot,
                        datasetID: soundDatasetID,
                        scope: scope,
                        hasActiveFilters: hasActiveFilters,
                        isBatchMode: isBatchMode,
                        batchSelection: batchSelection,
                        clearFilters: clearFilters,
                        showHealth: { isHealthPresented = true }
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider().overlay(ShixiangTheme.hairline)
                    PlayerBar(selection: library.selection)
                }
                .background(ShixiangTheme.canvas)
                // HSplitView does not propagate the outer top safe-area decision into each
                // child. The sidebar already occupies the fused title-bar row; let the detail
                // column do the same so search, result header, and list header move together.
                .ignoresSafeArea(.container, edges: .top)
            }
            .background(ShixiangTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(ShixiangTheme.hairline, lineWidth: 1)
            }
            // The hidden-titlebar window keeps the native traffic lights but reports a titlebar
            // safe area. If the split view respects that inset, its first 58-point row is partly
            // consumed and only the bottom edge remains visible. The row is deliberately the
            // window chrome, so let this one container occupy the top safe area; the sidebar
            // header already reserves the horizontal traffic-light zone.
            .ignoresSafeArea(.container, edges: .top)

            }

            if library.isIndexing {
                indexingOverlay
            }

            if isWorkbenchPresented {
                workbenchOverlay
            }

            if let transientNotice {
                VStack {
                    Spacer()
                    Label(transientNotice, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ShixiangTheme.primaryText)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .overlay { Capsule().stroke(ShixiangTheme.hairline, lineWidth: 1) }
                        .shadow(color: .black.opacity(0.26), radius: 16, y: 6)
                        .padding(.bottom, 92)
                }
                .allowsHitTesting(false)
            }

            if isSponsorPresented {
                Color.black.opacity(0.58)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismissSponsor)
                    .accessibilityHidden(true)
                    .transition(.opacity)
                    .zIndex(90)

                SponsorView(closeAction: dismissSponsor)
                    .transition(.opacity.combined(with: .scale(scale: 0.965)))
                    .zIndex(91)
                    .accessibilityAddTraits(.isModal)
            }
        }
        .environment(\.isWindowLiveResizing, isWindowLiveResizing)
        .modifier(WindowResizeStateModifier(isResizing: $isWindowLiveResizing))
        .background {
            LibraryKeyboardShortcuts(actions: keyboardActions)
                .frame(width: 0, height: 0)
        }
        .sheet(isPresented: $isHealthPresented) {
            LibraryHealthView()
                .environmentObject(library)
                .environmentObject(player)
        }
        .sheet(isPresented: $isOnboardingPresented) {
            CreatorOnboardingView()
                .environmentObject(library)
        }
        .sheet(isPresented: $isFirstLibrarySetupPresented) {
            FirstLibrarySetupView(
                downloadOfficialPack: {
                    isFirstLibrarySetupPresented = false
                    ShixiangDistributionLinks.openOfficialSoundPack()
                },
                importOwnPack: {
                    isFirstLibrarySetupPresented = false
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(220))
                        guard !Task.isCancelled else { return }
                        library.importPackWithPanel()
                    }
                },
                close: {
                    isFirstLibrarySetupPresented = false
                }
            )
        }
        .sheet(isPresented: $isBatchTagPresented) {
            BatchTagSheet(selectionCount: batchSelection.selectedCount(total: cachedSounds.count)) { tags in
                applyBatchTags(tags)
            }
        }
        .sheet(isPresented: $isFCPDeliveryPresented) {
            FinalCutDeliveryCheckView(item: selectedVisibleSound)
                .environmentObject(library)
                .environmentObject(player)
        }
        .sheet(isPresented: $isSimilarityPresented) {
            SimilarSoundsView(item: selectedVisibleSound)
                .environmentObject(library)
                .environmentObject(player)
        }
        .sheet(isPresented: $isMetadataSuggestionsPresented) {
            MetadataSuggestionReviewView(items: cachedSounds)
                .environmentObject(library)
        }
        .sheet(isPresented: $isAcousticAnalysisPresented) {
            AcousticAnalysisView(currentItems: cachedSounds)
                .environmentObject(library)
        }
        .sheet(isPresented: $isSaveCollectionPresented) {
            SavedCollectionNameSheet { name in
                let collection = SavedCollection(
                    name: name,
                    scope: scope.savedCollectionScope,
                    query: library.query,
                    fileExtension: selectedFormat,
                    minimumDuration: minimumDuration,
                    maximumDuration: maximumDuration,
                    favoritesOnly: favoritesOnly
                )
                library.upsertSavedCollection(collection)
            }
        }
        .sheet(isPresented: $isSavedCollectionsPresented) {
            SavedCollectionsManagerView { collection in
                applySavedCollection(collection)
            }
            .environmentObject(library)
        }
        .sheet(isPresented: $isMigrationReviewPresented) {
            if let scanResult = library.lastScanResult {
                SourceMigrationReviewView(result: scanResult)
            }
        }
        .alert(
            "拾响",
            isPresented: alertPresentationBinding
        ) {
            if library.alertMessage?.contains("不可访问") == true
                || library.alertMessage?.contains("重新定位") == true {
                Button("打开资料库体检") {
                    library.alertMessage = nil
                    isHealthPresented = true
                }
            }
            Button("知道了") {
                library.alertMessage = nil
            }
        } message: {
            Text(library.alertMessage ?? "")
        }
        .alert(
            "彻底重建整个资料库索引？",
            isPresented: $isFullRebuildConfirmationPresented
        ) {
            Button("取消", role: .cancel) {}
            Button("开始重建") {
                library.startFullLibraryRebuild()
            }
        } message: {
            Text("将逐个重新扫描所有已导入音效包，并从零重建搜索与语义索引。不会移动、改名、删除或上传原始音频；收藏、标签和别名会保留。")
        }
        .alert("移除音效包？", isPresented: $isRemovePackConfirmationPresented) {
            Button("取消", role: .cancel) {}
            Button("移除索引", role: .destructive) {
                library.removeSelectedPack()
                scope = .all
            }
        } message: {
            Text("只会移除拾响中的索引，不会删除、移动或改名硬盘上的原始音频。")
        }
        .onChange(of: scope) { _, newScope in
            apply(newScope)
            persistWorkspaceStateIfReady()
        }
        .onChange(of: sortMode) { _, _ in
            persistWorkspaceStateIfReady()
        }
        .onReceive(library.selection.$soundID) { _ in
            scheduleWorkspaceStatePersistence()
        }
        .onChange(of: library.favoriteRevision) { _, _ in
            refreshCachedFavoriteStatesIfPossible()
        }
        .onChange(of: library.metadataRevision) { _, _ in
            refreshCachedMetadataIfPossible()
        }
        .task(id: soundResultsRequest) {
            await rebuildSoundCache()
        }
        .task(id: library.libraryRevision) {
            restoreOrValidateWorkspaceState()
        }
        .onChange(of: soundDatasetID) { _, _ in
            player.cancelPendingPreloads()
        }
        .onChange(of: isBatchMode) { _, isEnabled in
            if !isEnabled { batchSelection.clear() }
        }
        .onChange(of: library.batchOperationResult?.id) { _, _ in
            guard let result = library.batchOperationResult else { return }
            showTransientNotice(result.message)
        }
        .onChange(of: isLocalAISearchEnabled) { _, isEnabled in
            aiSearchPlan = nil
            aiSearchFailure = nil
            cachedAISearchFeaturedIDs.removeAll()
            cachedExactSearchIDs.removeAll()
            if !isEnabled { isAISearching = false }
        }
        .task {
            guard !hasPresentedAIHint else { return }
            // The local library is mounted behind the splash surface. Wait until the maximum
            // launch window has elapsed so the bubble is revealed on top of the actual command
            // bar instead of being created underneath the splash screen.
            try? await Task.sleep(for: .seconds(4.6))
            guard !Task.isCancelled,
                  ShixiangSystemCompatibility.current.supportsLocalAI,
                  !hasPresentedAIHint,
                  !library.packs.isEmpty,
                  !isFirstLibrarySetupPresented else { return }
            showAIHint()
        }
        .task {
            // Restore the last settled layout once. Pointer tracking itself stays in @State so
            // a live resize never writes UserDefaults at mouse-sampling frequency.
            workbenchWidth = CGFloat(savedWorkbenchWidth)
            workbenchHeight = CGFloat(savedWorkbenchHeight)
        }
        .task(id: shouldOfferFirstLibrarySetup) {
            guard shouldOfferFirstLibrarySetup else { return }
            // The store must first prove that the durable library is genuinely empty. Waiting
            // one more beat keeps this sheet out of the splash-to-workspace transition.
            try? await Task.sleep(for: .milliseconds(520))
            guard !Task.isCancelled, shouldOfferFirstLibrarySetup else { return }
            isFirstLibrarySetupPresented = true
            hasPresentedFirstLibrarySetup = true
        }
        .onDisappear {
            workspacePersistenceTask?.cancel()
            workspacePersistenceTask = nil
            persistWorkspaceStateIfReady()
        }
    }

    private func dismissSponsor() {
        withAnimation(.easeOut(duration: 0.18)) {
            isSponsorPresented = false
        }
    }

    private var alertPresentationBinding: Binding<Bool> {
        Binding(
            get: { library.alertMessage != nil },
            set: { isPresented in
                guard !isPresented else { return }
                library.alertMessage = nil
            }
        )
    }

    private var shouldOfferFirstLibrarySetup: Bool {
        FirstLibrarySetupPolicy.shouldPresent(
            hasPresented: hasPresentedFirstLibrarySetup,
            isInitialLoadComplete: library.isInitialLoadComplete,
            isDeferredStartupLoading: library.isDeferredStartupLoading,
            packCount: library.packs.count
        )
    }

    private var soundResultsRequest: SoundResultsRequest {
        SoundResultsRequest(
            libraryRevision: library.libraryRevision,
            favoriteRevision: SoundResultsRevisionPolicy.favoriteRevision(
                scope: scope,
                favoritesOnly: favoritesOnly,
                revision: library.favoriteRevision
            ),
            metadataRevision: SoundResultsRevisionPolicy.metadataRevision(
                scope: scope,
                sortMode: sortMode,
                query: library.query,
                revision: library.metadataRevision
            ),
            classificationRevision: SoundResultsRevisionPolicy.classificationRevision(
                scope: scope,
                revision: library.classificationRevision
            ),
            visibilityRevision: library.visibilityRevision,
            scope: scope,
            sortMode: sortMode,
            selectedFormat: selectedFormat,
            minimumDuration: minimumDuration,
            maximumDuration: maximumDuration,
            favoritesOnly: favoritesOnly,
            showsHiddenSounds: showsHiddenSounds,
            query: library.query,
            searchMode: searchMode,
            aiSearchEnabled: effectiveLocalAISearchEnabled
        )
    }

    @MainActor
    private func rebuildSoundCache() async {
        let request = soundResultsRequest
        let semanticOperationToken = library.invalidateSemanticOperation()
        let packs = library.packs
        let activityID = UUID()
        defer {
            if searchActivity?.id == activityID {
                searchActivity = nil
            }
        }

        if !request.query.isEmpty {
            searchActivity = SearchActivity(id: activityID, phase: .preparing)
            try? await Task.sleep(for: .milliseconds(request.aiSearchEnabled ? 360 : 90))
            guard !Task.isCancelled else { return }
        }

        var matchingQuery = request.query
        var matchingMode = request.searchMode
        var originalLiteralIDs = Set<UUID>()
        let exactHitTask: Task<Set<UUID>, Error>? = request.aiSearchEnabled
            && !request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Task.detached(priority: .userInitiated) {
                try LocalAISearchRanking.directPathMatchIDs(in: packs, query: request.query)
            }
            : nil
        if request.aiSearchEnabled,
           !request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            isAISearching = true
            searchActivity = SearchActivity(id: activityID, phase: .understanding)
            aiSearchPlan = nil
            aiSearchFailure = nil
            do {
                let plan = try await LocalAISearchPlanner.plan(for: request.query)
                guard !Task.isCancelled else { return }
                aiSearchPlan = plan
                matchingQuery = plan.expandedQuery(originalQuery: request.query)
            } catch {
                guard !Task.isCancelled else { return }
                aiSearchFailure = error.localizedDescription
                matchingMode = .literal
            }
            isAISearching = false
        } else {
            aiSearchPlan = nil
            aiSearchFailure = nil
            isAISearching = false
        }
        if let exactHitTask {
            originalLiteralIDs = (try? await exactHitTask.value) ?? []
        }

        let queryMatches: LibrarySearchMatches?
        if matchingQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryMatches = nil
        } else {
            searchActivity = SearchActivity(id: activityID, phase: .matching)
            queryMatches = await library.indexedSoundMatches(
                matching: matchingQuery,
                mode: matchingMode,
                operationToken: semanticOperationToken
            )
        }

        let snapshot: SoundResultsSnapshot
        do {
            let intelligenceByID = library.intelligenceByID
            let vocabulary = library.libraryVocabulary()
            let snapshotTask = Task.detached(priority: .userInitiated) {
                try SoundResultsSnapshot.make(
                    packs: packs,
                    request: request,
                    queryMatches: queryMatches,
                    aiExpandedQuery: request.aiSearchEnabled ? matchingQuery : nil,
                    originalLiteralIDs: originalLiteralIDs,
                    intelligenceByID: intelligenceByID,
                    vocabulary: vocabulary
                )
            }
            snapshot = try await withTaskCancellationHandler {
                try await snapshotTask.value
            } onCancel: {
                snapshotTask.cancel()
            }
        } catch is CancellationError {
            return
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        cachedSounds = snapshot.sounds
        cachedSoundIndexByID = snapshot.indexByID
        cachedAISearchFeaturedIDs = snapshot.aiFeaturedIDs
        cachedExactSearchIDs = snapshot.exactSearchIDs
        cachedAISearchIntent = snapshot.aiSearchIntent
        cachedAISearchCreatorIntent = snapshot.aiCreatorIntent
        cachedAIConflictSummary = snapshot.aiConflictSummary
        if isBatchMode {
            batchSelection.retain(availableIDs: Set(snapshot.indexByID.keys))
        }
        soundDatasetID &+= 1
        cachedFormats = snapshot.formats
        if selectedFormat != snapshot.effectiveFormat {
            selectedFormat = snapshot.effectiveFormat
        }
        restorePendingWorkspaceSelection(in: snapshot)
        persistWorkspaceStateIfReady()
        // Do not let the empty-state branch render between deferred library restoration and
        // this first real result snapshot. Once this flag is true, an empty state means the
        // library was genuinely confirmed empty (rather than merely one frame behind).
        if !hasBuiltInitialResultSnapshot,
           library.isInitialLoadComplete,
           !library.isDeferredStartupLoading {
            hasBuiltInitialResultSnapshot = true
        }
        if !hasReportedInitialContentReady {
            hasReportedInitialContentReady = true
            onInitialContentReady()
        }
    }

    private var availableFormats: [String] {
        cachedFormats
    }

    private var searchMode: LibrarySearchMode {
        effectiveLocalAISearchEnabled ? .hybrid : .literal
    }

    private var hasActiveFilters: Bool {
        favoritesOnly || minimumDuration != nil || maximumDuration != nil || selectedFormat != nil
    }

    private var favoriteMembershipAffectsResults: Bool {
        favoritesOnly || scope == .favorites
    }

    private func refreshCachedFavoriteStatesIfPossible() {
        guard !favoriteMembershipAffectsResults else { return }
        for soundID in library.lastFavoriteChangedIDs {
            guard let index = cachedSoundIndexByID[soundID],
                  cachedSounds.indices.contains(index),
                  let current = library.sound(id: soundID) else {
                continue
            }
            cachedSounds[index].isFavorite = current.isFavorite
        }
    }

    private func refreshCachedMetadataIfPossible() {
        let revision = SoundResultsRevisionPolicy.metadataRevision(
            scope: scope,
            sortMode: sortMode,
            query: library.query,
            revision: library.metadataRevision
        )
        guard revision == 0 else { return }
        for soundID in library.lastMetadataChangedIDs {
            guard let index = cachedSoundIndexByID[soundID],
                  cachedSounds.indices.contains(index),
                  let current = library.sound(id: soundID) else {
                continue
            }
            cachedSounds[index] = current
        }
    }

    private var activeFilterBar: some View {
        HStack(spacing: 7) {
            Text("当前筛选")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ShixiangTheme.tertiaryText)

            if favoritesOnly {
                filterChip("收藏", systemImage: "star.fill") {
                    favoritesOnly = false
                }
            }
            if let selectedFormat {
                filterChip(selectedFormat.uppercased(), systemImage: "doc") {
                    self.selectedFormat = nil
                }
            }
            if minimumDuration != nil || maximumDuration != nil {
                filterChip(durationFilterTitle, systemImage: "clock") {
                    setDurationFilter(minimum: nil, maximum: nil)
                }
            }

            Spacer()
            Button("清除") { clearFilters() }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ShixiangTheme.gold)
        }
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(ShixiangTheme.surface.opacity(0.82))
        .overlay(alignment: .bottom) {
            Rectangle().fill(ShixiangTheme.hairline).frame(height: 1)
        }
    }

    private var shouldShowSearchDirections: Bool {
        effectiveLocalAISearchEnabled
            && !library.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && searchActivity == nil
            && !cachedSounds.isEmpty
    }

    private var searchDirectionBar: some View {
        HStack(spacing: 7) {
            Label("继续找", systemImage: "arrow.triangle.branch")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ShixiangTheme.tertiaryText)

            searchDirectionButton("更短", systemImage: "timer") {
                refineSearch(removing: [#"([0-9]+(?:\.[0-9]+)?|一|二|两|三|四|五|六|七|八|九|十)\s*秒(?:左右|以内|以下|内|以上|起)?"#], adding: "3 秒内")
            }
            searchDirectionButton("更轻", systemImage: "speaker.wave.1") {
                refineSearch(removing: ["强烈", "猛烈", "极强", "爆发"], adding: "克制")
            }
            searchDirectionButton("更远", systemImage: "arrow.up.right.and.arrow.down.left.rectangle") {
                refineSearch(removing: ["近处", "贴耳", "由远及近"], adding: "远处")
            }
            searchDirectionButton("更近", systemImage: "arrow.down.left.and.arrow.up.right.rectangle") {
                refineSearch(removing: ["远处", "distant", "由近及远"], adding: "近处")
            }

            Spacer()
            Text("直接修改原查询，可随时撤销")
                .font(.system(size: 9))
                .foregroundStyle(ShixiangTheme.tertiaryText)
        }
        .padding(.horizontal, 20)
        .frame(height: 30)
        .background(ShixiangTheme.surface.opacity(0.82))
        .overlay(alignment: .bottom) {
            Rectangle().fill(ShixiangTheme.hairline).frame(height: 1)
        }
    }

    private func searchDirectionButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(ShixiangTheme.primaryText)
                .padding(.horizontal, 7)
                .frame(height: 21)
                .background(ShixiangTheme.selectedSurface)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func refineSearch(removing patterns: [String], adding term: String) {
        var value = library.query
        for pattern in patterns {
            value = value.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        let cleaned = value
            .replacingOccurrences(of: #"\s*[，,、]\s*[，,、]+"#, with: "，", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "，,、")))
        let normalized = cleaned.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        library.query = normalized.localizedCaseInsensitiveContains(term)
            ? cleaned
            : [cleaned, term].filter { !$0.isEmpty }.joined(separator: "，")
    }

    private var durationFilterTitle: String {
        switch (minimumDuration, maximumDuration) {
        case (nil, let maximum?): return "≤ \(Int(maximum)) 秒"
        case (let minimum?, nil): return "≥ \(Int(minimum)) 秒"
        case (let minimum?, let maximum?): return "\(Int(minimum))–\(Int(maximum)) 秒"
        default: return "时长"
        }
    }

    private func filterChip(_ title: String, systemImage: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ShixiangTheme.primaryText)
                .padding(.horizontal, 8)
                .frame(height: 21)
                .background(ShixiangTheme.selectedSurface)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func setDurationFilter(minimum: Double?, maximum: Double?) {
        minimumDuration = minimum
        maximumDuration = maximum
    }

    private func clearFilters() {
        selectedFormat = nil
        minimumDuration = nil
        maximumDuration = nil
        favoritesOnly = false
    }

    private func applySavedCollection(_ collection: SavedCollection) {
        switch collection.scope {
        case let .pack(packID):
            guard library.packs.contains(where: { $0.id == packID }) else {
                library.alertMessage = "集合“\(collection.name)”所指向的音效包已不可用，请重新导入后再打开。"
                return
            }
        case let .folder(packID, path):
            guard let pack = library.packs.first(where: { $0.id == packID }) else {
                library.alertMessage = "集合“\(collection.name)”所指向的音效包已不可用，请重新导入后再打开。"
                return
            }
            guard pack.items.contains(where: {
                $0.folderPath == path || $0.folderPath.hasPrefix(path + "/")
            }) else {
                library.alertMessage = "集合“\(collection.name)”所指向的文件夹已不可用，请重新扫描或重新导入。"
                return
            }
        default:
            break
        }

        scope = collection.scope.libraryScope
        library.query = collection.query
        selectedFormat = collection.fileExtension
        minimumDuration = collection.minimumDuration
        maximumDuration = collection.maximumDuration
        favoritesOnly = collection.favoritesOnly
        isSavedCollectionsPresented = false
    }

    private var commandBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                ZStack(alignment: .topLeading) {
                    Button {
                        toggleLocalAISearch()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12, weight: .semibold))
                                .shixiangHoverIcon("sparkles")
                            Text("AI")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(effectiveLocalAISearchEnabled
                            ? ShixiangTheme.gold
                            : ShixiangTheme.tertiaryText)
                        .padding(.horizontal, 7)
                        .frame(height: 24)
                        .background((effectiveLocalAISearchEnabled ? ShixiangTheme.gold : ShixiangTheme.violet).opacity(0.12))
                        .clipShape(Capsule())
                        .overlay { Capsule().stroke((effectiveLocalAISearchEnabled ? ShixiangTheme.gold : ShixiangTheme.violet).opacity(0.24), lineWidth: 1) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(aiAccessibilityLabel)
                    .accessibilityHint("点击切换本地 AI 搜索")
                    .help(aiHelpText)

                }

                TextField(
                    effectiveLocalAISearchEnabled
                        ? "描述你想找的声音，例如：克制科技上升，3 秒内"
                        : "搜索声音、文件夹或格式",
                    text: $library.query
                )
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isSearchFocused)

                if let searchActivity {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(ShixiangTheme.gold)
                        .help(searchActivity.title)
                } else if let progress = library.semanticIndexProgress {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .help("正在建立本地语义索引 \(progress.completed) / \(progress.total)")
                } else if effectiveLocalAISearchEnabled,
                          (!cachedAISearchIntent.displayTitles.isEmpty || (aiSearchPlan?.keywords.isEmpty == false)) {
                    let titles = cachedAISearchIntent.displayTitles.isEmpty
                        ? Array(aiSearchPlan?.keywords.prefix(3) ?? [])
                        : cachedAISearchIntent.displayTitles
                    Text("AI · \(titles.prefix(3).joined(separator: " · "))")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(ShixiangTheme.gold)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(ShixiangTheme.gold.opacity(0.10))
                        .clipShape(Capsule())
                        .help("本地 AI 理解为：\(titles.joined(separator: "、"))")
                } else if effectiveLocalAISearchEnabled,
                          let cachedAIConflictSummary {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ShixiangTheme.gold)
                        .help("搜索条件冲突：\(cachedAIConflictSummary)。仍会展示最接近的结果。")
                } else if effectiveLocalAISearchEnabled,
                          let aiSearchFailure {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ShixiangTheme.gold)
                        .help("\(aiSearchFailure) 本次已改用普通搜索。")
                } else if effectiveLocalAISearchEnabled,
                          !library.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("AI · 本地语义")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(ShixiangTheme.gold)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(ShixiangTheme.gold.opacity(0.10))
                        .clipShape(Capsule())
                        .help("短关键词不扩写，直接按本地分类、标签和目录语义排序。")
                } else if searchMode == .hybrid,
                          !library.query.isEmpty,
                          library.lastSemanticSearchMatchCount > 0 {
                    Text("+\(library.lastSemanticSearchMatchCount.formatted(.number)) 语义")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(ShixiangTheme.gold)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(ShixiangTheme.gold.opacity(0.10))
                        .clipShape(Capsule())
                        .help(
                            library.lastSemanticConceptTitles.isEmpty
                                ? "本地语义匹配"
                                : "理解到：" + library.lastSemanticConceptTitles.joined(separator: "、")
                        )
                }

                if !library.query.isEmpty {
                    Button {
                        library.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(ShixiangTheme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .help("清除搜索")
                }
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 180, maxWidth: .infinity, minHeight: 34)
            .background(ShixiangTheme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(ShixiangTheme.hairline, lineWidth: 1)
            }

            // Keep the idle command row quiet. AI state is already expressed by the sparkles
            // toggle and the result subtitle; reserve this slot only for work that needs a
            // live progress explanation.
            if isCommandStatusVisible {
                commandStatusSlot
            }

            if isBatchMode {
                batchActions
            } else {
                // The reference layout keeps the top chrome quiet and icon-led. Labels remain
                // available through accessibility and help, while the search field gets the
                // reclaimed width at every window size.
                commandActions(showsTitles: false)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
        .background(ShixiangTheme.surface.opacity(0.96))
        // The AI coach mark is an overlay, not a child in the command-row layout. Its measured
        // size must never push the filter bar, table header, or list downward. The elevated
        // z-index also keeps it above later siblings when the bubble crosses their bounds.
        .overlay(alignment: .topLeading) {
            if isAIHintVisible {
                AIHintBubble {
                    dismissAIHint()
                    toggleLocalAISearch()
                } onDismiss: {
                    dismissAIHint()
                }
                .offset(x: 30, y: 62)
                .transition(.scale(scale: 0.86, anchor: .topLeading).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ShixiangTheme.hairline)
                .frame(height: 1)
        }
        .zIndex(isAIHintVisible ? 20 : 0)
    }

    private func showAIHint() {
        NSSound(named: "Pop")?.play()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
            isAIHintVisible = true
        }
    }

    private var effectiveLocalAISearchEnabled: Bool {
        isLocalAISearchEnabled && ShixiangSystemCompatibility.current.supportsLocalAI
    }

    private var aiAccessibilityLabel: String {
        guard ShixiangSystemCompatibility.current.supportsLocalAI else {
            return "本地 AI 搜索：需要 macOS 26.2 或更高版本"
        }
        return effectiveLocalAISearchEnabled ? "本地 AI 搜索：已开启" : "本地 AI 搜索：已关闭"
    }

    private var aiHelpText: String {
        guard ShixiangSystemCompatibility.current.supportsLocalAI else {
            return "本地 AI 搜索需要 macOS 26.2 或更高版本；普通搜索仍可使用"
        }
        return effectiveLocalAISearchEnabled ? "本地 AI 搜索已开启：再次点击关闭" : "开启本地 AI 搜索"
    }

    private func toggleLocalAISearch() {
        guard ShixiangSystemCompatibility.current.supportsLocalAI else {
            isLocalAISearchEnabled = false
            library.alertMessage = ShixiangSystemCompatibility.localAIUnavailableMessage
            return
        }
        isLocalAISearchEnabled.toggle()
        if isLocalAISearchEnabled { dismissAIHint() }
    }

    private func dismissAIHint() {
        // Closing the onboarding bubble is an explicit user choice. Persist it so the same
        // hint does not return after a relaunch or when the view is rebuilt.
        hasPresentedAIHint = true
        withAnimation(.easeOut(duration: 0.18)) {
            isAIHintVisible = false
        }
    }

    private var isCommandStatusVisible: Bool {
        isAISearching
            || searchActivity != nil
            || library.semanticIndexProgress != nil
            || library.batchOperationProgress != nil
            || aiSearchFailure != nil
    }

    /// A fixed-width status slot keeps the command row stable while search, indexing, or batch
    /// work changes. The slot is always present, so progress never pushes the library downward.
    private var commandStatusSlot: some View {
        let batchProgress = library.batchOperationProgress
        let isBusy = isAISearching || searchActivity != nil || library.semanticIndexProgress != nil || batchProgress != nil
        let title: String = {
            if let batchProgress { return batchProgress.statusTitle }
            if let searchActivity { return searchActivity.title }
            if library.semanticIndexProgress != nil { return "建立语义索引" }
            if isAISearching { return "理解搜索意图" }
            return effectiveLocalAISearchEnabled ? "AI 搜索已开启" : "搜索已就绪"
        }()
        let detail: String = {
            if let batchProgress {
                return batchProgress.total > 0
                    ? "\(batchProgress.completed.formatted(.number))/\(batchProgress.total.formatted(.number))"
                    : "后台处理"
            }
            if let progress = library.semanticIndexProgress {
                return "\(progress.completed.formatted(.number))/\(progress.total.formatted(.number))"
            }
            if isBusy { return "本地处理，不影响当前列表" }
            return effectiveLocalAISearchEnabled ? "目录、文件名与语义参与排序" : "文件名、目录与标签匹配"
        }()

        return HStack(spacing: 7) {
            Image(systemName: isBusy ? "sparkles" : (effectiveLocalAISearchEnabled ? "sparkles" : "checkmark.circle"))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isBusy || effectiveLocalAISearchEnabled ? ShixiangTheme.gold : ShixiangTheme.tertiaryText)
                .shixiangHoverIcon(isBusy ? "sparkles" : "checkmark.circle")

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ShixiangTheme.primaryText)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 8))
                    .foregroundStyle(ShixiangTheme.tertiaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 2)

            if let progress = library.semanticIndexProgress {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 38)
                    .tint(ShixiangTheme.gold)
            } else if let batchProgress {
                ProgressView(value: batchProgress.fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 38)
                    .tint(ShixiangTheme.gold)
            } else if isBusy {
                ProgressView()
                    .controlSize(.mini)
                    .tint(ShixiangTheme.gold)
            }
        }
        .padding(.horizontal, 9)
        .frame(width: 205, height: 34, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isBusy ? ShixiangTheme.violet.opacity(0.14) : ShixiangTheme.elevated.opacity(0.72))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isBusy ? ShixiangTheme.violet.opacity(0.34) : ShixiangTheme.hairline, lineWidth: 1)
        }
        .opacity(isBusy || effectiveLocalAISearchEnabled || !library.query.isEmpty ? 1 : 0.72)
        .animation(.easeOut(duration: 0.18), value: title)
        .animation(.easeOut(duration: 0.18), value: isBusy)
    }

    private func commandActions(showsTitles: Bool) -> some View {
        HStack(spacing: 7) {
            Menu {
                Button("清除筛选") { clearFilters() }
                    .disabled(!hasActiveFilters)
                Divider()
                Toggle("仅显示收藏", isOn: $favoritesOnly)
                Divider()
                Section("按时长") {
                    Button("全部时长") { setDurationFilter(minimum: nil, maximum: nil) }
                    Button("瞬时 · 0–2 秒") { setDurationFilter(minimum: nil, maximum: 2) }
                    Button("短音效 · 2–5 秒") { setDurationFilter(minimum: 2, maximum: 5) }
                    Button("中短 · 5–10 秒") { setDurationFilter(minimum: 5, maximum: 10) }
                    Button("长音效 · 10–30 秒") { setDurationFilter(minimum: 10, maximum: 30) }
                    Button("超长 · 30 秒以上") { setDurationFilter(minimum: 30, maximum: nil) }
                }
                Divider()
                Section("格式") {
                    Button {
                        selectedFormat = nil
                    } label: {
                        Label("全部格式", systemImage: selectedFormat == nil ? "checkmark" : "waveform")
                    }
                    ForEach(availableFormats, id: \.self) { format in
                        Button {
                            selectedFormat = format
                        } label: {
                            Label(
                                format.uppercased(),
                                systemImage: selectedFormat == format ? "checkmark" : "doc"
                            )
                        }
                    }
                }
                Divider()
                Section("我的集合") {
                    Button("管理我的集合…") {
                        isSavedCollectionsPresented = true
                    }
                    Button("保存当前筛选…") {
                        isSaveCollectionPresented = true
                    }
                }
            } label: {
                commandLabel(
                    showsTitles ? (hasActiveFilters ? "筛选中" : "筛选") : nil,
                    systemImage: hasActiveFilters
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease"
                )
            }
            .menuIndicator(.hidden)
            .buttonStyle(ShixiangCommandButtonStyle(isActive: hasActiveFilters))
            .accessibilityLabel(hasActiveFilters ? "组合筛选：已启用" : "组合筛选")
            .help("组合筛选与保存自定义集合")

            Menu {
                Picker("排序方式", selection: $sortMode) {
                    ForEach(SoundSortMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
            } label: {
                commandLabel(showsTitles ? sortMode.title : nil, systemImage: "arrow.up.arrow.down")
            }
            .menuIndicator(.hidden)
            .buttonStyle(ShixiangCommandButtonStyle())
            .accessibilityLabel("排序方式：\(sortMode.title)")
            .help("排序声音")

            Menu {
                Button("增量刷新当前音效包") {
                    library.startRefreshSelectedPack()
                }
                .disabled(library.selectedPack == nil)
                Divider()
                Button("彻底重建整个资料库索引…") {
                    isFullRebuildConfirmationPresented = true
                }
                .disabled(library.packs.isEmpty)
            } label: {
                commandLabel(showsTitles ? "刷新" : nil, systemImage: "arrow.clockwise")
            }
            .menuIndicator(.hidden)
            .buttonStyle(ShixiangCommandButtonStyle())
            .disabled(library.batchOperationProgress != nil)
            .disabled(library.isIndexing)
            .accessibilityLabel("刷新或重建资料库索引")
            .help("增量刷新当前音效包，或彻底重建整个资料库索引")

            Button {
                beginBatchMode()
            } label: {
                commandLabel(showsTitles ? "批量" : nil, systemImage: "checklist")
            }
            .buttonStyle(ShixiangCommandButtonStyle())
            .disabled(cachedSounds.isEmpty)
            .accessibilityLabel("批量选择")
            .help("选择多个声音后批量收藏或添加标签")

            Button {
                library.importPackWithPanel()
            } label: {
                commandLabel(showsTitles ? "导入" : nil, systemImage: "folder.badge.plus")
            }
            .buttonStyle(ShixiangCommandButtonStyle(isPrimary: true))
            .keyboardShortcut("i", modifiers: [.command])
            .accessibilityLabel("导入音效包")
            .help("选择一个完整音效包文件夹")

            Button {
                isWorkbenchPresented.toggle()
            } label: {
                commandLabel(showsTitles ? "工作台" : nil, systemImage: "sidebar.right")
            }
            .buttonStyle(ShixiangCommandButtonStyle(isActive: isWorkbenchPresented))
            .disabled(cachedSounds.isEmpty && !isWorkbenchPresented)
            .accessibilityLabel("声音工作台")
            .help(isWorkbenchPresented ? "关闭声音工作台" : "打开声音工作台")

            Menu {
                Section("键盘高速试听") {
                    Text("↑ ↓ 选择声音")
                    Text("Space / K 播放或暂停")
                    Text("J / L 后退或前进 5 秒")
                    Text("F 收藏 · ⌘F 搜索")
                    Text("⌘R 增量刷新 · ⌘⇧H 资料库体检")
                }
                Divider()
                Button("使用引导与快捷键…") {
                    isOnboardingPresented = true
                }
                Button("Final Cut Pro 交付诊断…") {
                    isFCPDeliveryPresented = true
                }
                .disabled(selectedVisibleSound == nil)
                Button("相似声音与变体…") {
                    isSimilarityPresented = true
                }
                .disabled(selectedVisibleSound == nil)
                Divider()
                Button("智能中文命名…") {
                    isMetadataSuggestionsPresented = true
                }
                .disabled(cachedSounds.isEmpty || library.batchOperationProgress != nil)
                Button("声音理解中心…") {
                    isAcousticAnalysisPresented = true
                }
                .disabled(cachedSounds.isEmpty)
                if library.lastMetadataUndoBatch != nil {
                    Button("撤销上次智能命名") {
                        library.startUndoLastMetadataSuggestions()
                    }
                    .disabled(library.batchOperationProgress != nil)
                }
                Toggle("显示已隐藏的重复项", isOn: $showsHiddenSounds)
                if library.hiddenSoundCount > 0 {
                    Button("恢复全部隐藏声音") {
                        library.restoreAllHiddenSounds()
                    }
                }
                Divider()
                Button("资料库体检…") {
                    isHealthPresented = true
                }
                Divider()
                Button("移除当前音效包", role: .destructive) {
                    isRemovePackConfirmationPresented = true
                }
                .disabled(library.selectedPack == nil)
            } label: {
                commandLabel(nil, systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            .buttonStyle(ShixiangCommandButtonStyle())
            .accessibilityLabel("更多操作")
            .help("更多音效包操作")
        }
    }

    private var batchActions: some View {
        let selectedCount = batchSelection.selectedCount(total: cachedSounds.count)
        return HStack(spacing: 7) {
            Label("已选 \(selectedCount.formatted(.number))", systemImage: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(selectedCount == 0 ? ShixiangTheme.tertiaryText : ShixiangTheme.gold)
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(ShixiangTheme.elevated)
                .clipShape(Capsule())

            Button(selectedCount == cachedSounds.count ? "清空选择" : "选择全部结果") {
                if selectedCount == cachedSounds.count {
                    batchSelection.clear()
                } else {
                    batchSelection.selectAll()
                }
            }
            .buttonStyle(ShixiangCommandButtonStyle())
            .disabled(library.batchOperationProgress != nil)

            Menu {
                Button("设为收藏") {
                    applyBatchFavorite(true)
                }
                Button("取消收藏") {
                    applyBatchFavorite(false)
                }
            } label: {
                Label("收藏", systemImage: "star")
            }
            .menuIndicator(.hidden)
            .buttonStyle(ShixiangCommandButtonStyle())
            .disabled(selectedCount == 0 || library.batchOperationProgress != nil)

            Button {
                isBatchTagPresented = true
            } label: {
                Label("添加标签", systemImage: "tag")
            }
            .buttonStyle(ShixiangCommandButtonStyle(isPrimary: true))
            .disabled(selectedCount == 0 || library.batchOperationProgress != nil)

            Button {
                isBatchMode = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(ShixiangRoundButtonStyle(size: 28))
            .help("退出批量模式")
        }
    }

    @ViewBuilder
    private func commandLabel(_ title: String?, systemImage: String) -> some View {
        if let title {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
                    .shixiangHoverIcon(systemImage)
            }
                .lineLimit(1)
        } else {
            Image(systemName: systemImage)
                .frame(width: 15)
                .shixiangHoverIcon(systemImage)
        }
    }

    private func libraryHeader(soundCount: Int) -> some View {
        HStack(spacing: 12) {
            ShixiangIconBadge(
                systemImage: scope.systemImage,
                size: 32,
                tint: scope == .favorites ? ShixiangTheme.gold : ShixiangTheme.violet
            )
            .accessibilityHidden(true)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(effectiveLocalAISearchEnabled && !library.query.isEmpty
                    ? "全库智能搜索"
                    : scope.title(in: library.packs))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ShixiangTheme.primaryText)
                    .contentTransition(.opacity)

                Text(libraryHeaderSubtitle(soundCount: soundCount))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ShixiangTheme.secondaryText)
                    .contentTransition(.numericText())
                    .lineLimit(1)
            }

            Spacer()

            if case let .folder(packID, path) = scope,
               let pack = library.packs.first(where: { $0.id == packID }) {
                Label(pack.name + " / " + path, systemImage: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(ShixiangTheme.secondaryText)
                    .lineLimit(1)
            }

        }
        .padding(.horizontal, 20)
        .frame(height: 50)
        .animation(.easeOut(duration: 0.16), value: scope)
        .animation(.easeOut(duration: 0.16), value: soundCount)
    }

    private func sourceMigrationBanner(_ result: LibraryScanReport) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ShixiangTheme.gold)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.statistics.summary)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ShixiangTheme.primaryText)
                Text(scanResultDetail(result))
                    .font(.system(size: 9))
                    .foregroundStyle(ShixiangTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if result.hasMigrations {
                Button("查看 \(result.migrationCount.formatted(.number)) 条路径变化") {
                    isMigrationReviewPresented = true
                }
                .buttonStyle(ShixiangCommandButtonStyle(isPrimary: true))
            }

            Button {
                dismissedMigrationAt = result.completedAt
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(ShixiangRoundButtonStyle(size: 24))
            .help("隐藏这次提示")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
        .background(ShixiangTheme.gold.opacity(0.10))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ShixiangTheme.gold.opacity(0.22))
                .frame(height: 1)
        }
    }

    private func searchResultSummary(soundCount: Int) -> String {
        guard !cachedExactSearchIDs.isEmpty || !cachedAISearchFeaturedIDs.isEmpty else {
            return "\(soundCount.formatted(.number)) 个声音"
        }
        var parts: [String] = []
        if !cachedExactSearchIDs.isEmpty {
            parts.append("精确命中 \(cachedExactSearchIDs.count) 条")
        }
        if !cachedAISearchFeaturedIDs.isEmpty {
            parts.append("AI 精选 \(cachedAISearchFeaturedIDs.count) 条")
        }
        if soundCount > cachedExactSearchIDs.count + cachedAISearchFeaturedIDs.count {
            parts.append("其余为关联命中")
        }
        return parts.joined(separator: " · ")
    }

    private func libraryHeaderSubtitle(soundCount: Int) -> String {
        let result = searchResultSummary(soundCount: soundCount)
        if effectiveLocalAISearchEnabled,
           library.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "AI 搜索已开启"
        }
        return result
    }

    private func scanResultDetail(_ result: LibraryScanReport) -> String {
        let statistics = result.statistics
        if result.hasMigrations {
            return "保留了 \(result.migrationCount.formatted(.number)) 个声音的收藏、别名和标签；原文件未改动。"
        }
        return "复用 \(statistics.reusedCount.formatted(.number)) 条已有信息，只读取 \(statistics.analyzedCount.formatted(.number)) 个新增或变化文件。"
    }

    private var workbenchOverlay: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.width < 1_180

            if isCompact {
                // 在窄窗口中，底部抽屉比右侧栏更能保留波形和文件名的横向可读性。
                VStack(spacing: 0) {
                    Spacer(minLength: 0)

                    SelectedSoundWorkbenchContent(
                        selection: library.selection,
                        close: { isWorkbenchPresented = false }
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: min(max(300, workbenchHeight), min(520, geometry.size.height * 0.70)))
                    .background(ShixiangTheme.canvas.opacity(0.98))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(ShixiangTheme.hairline, lineWidth: 1)
                    }
                    .overlay(alignment: .top) {
                        workbenchHeightHandle(maxHeight: geometry.size.height * 0.70)
                            .offset(y: -6)
                    }
                    .shadow(color: .black.opacity(0.38), radius: 24, x: 0, y: -8)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            } else {
                let maxPanelWidth = min(520, max(300, geometry.size.width * 0.46))
                let panelWidth = min(max(300, workbenchWidth), maxPanelWidth)

                HStack(spacing: 0) {
                    Spacer(minLength: 0)

                    SelectedSoundWorkbenchContent(
                        selection: library.selection,
                        close: { isWorkbenchPresented = false }
                    )
                    .frame(width: panelWidth, height: geometry.size.height)
                    .background(ShixiangTheme.canvas.opacity(0.98))
                    .overlay(alignment: .leading) {
                        Divider()
                            .overlay(ShixiangTheme.hairline)
                    }
                    .overlay(alignment: .leading) {
                        workbenchWidthHandle(maxWidth: maxPanelWidth)
                            .offset(x: -6)
                    }
                    .shadow(color: .black.opacity(0.34), radius: 24, x: -8, y: 0)
                }
            }
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
        .animation(.easeOut(duration: 0.20), value: isWorkbenchPresented)
        .transaction { transaction in
            if workbenchResizeStart != nil {
                transaction.animation = nil
            }
        }
        .zIndex(10)
    }

    private func workbenchWidthHandle(maxWidth: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 14)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let start = workbenchResizeStart ?? workbenchWidth
                        if workbenchResizeStart == nil {
                            workbenchResizeStart = start
                        }
                        workbenchWidth = min(max(300, start - value.translation.width), maxWidth)
                    }
                    .onEnded { _ in
                        workbenchResizeStart = nil
                        savedWorkbenchWidth = Double(workbenchWidth)
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("调整声音工作台宽度")
            .accessibilityHint("左右拖动调整宽度")
    }

    private func workbenchHeightHandle(maxHeight: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 14)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let start = workbenchResizeStart ?? workbenchHeight
                        if workbenchResizeStart == nil {
                            workbenchResizeStart = start
                        }
                        workbenchHeight = min(max(300, start - value.translation.height), maxHeight)
                    }
                    .onEnded { _ in
                        workbenchResizeStart = nil
                        savedWorkbenchHeight = Double(workbenchHeight)
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("调整声音工作台高度")
            .accessibilityHint("上下拖动调整高度")
    }

    private var indexingOverlay: some View {
        VStack(spacing: 12) {
            if let progress = library.indexingProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 230)
                    .tint(ShixiangTheme.gold)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(ShixiangTheme.gold)
            }
            Text(library.indexingStatus ?? "正在读取声音信息…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ShixiangTheme.secondaryText)
            Text("原文件不会被移动或改名")
                .font(.system(size: 10))
                .foregroundStyle(ShixiangTheme.tertiaryText)
            Button("取消扫描") {
                library.cancelIndexing()
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(ShixiangTheme.gold)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ShixiangTheme.hairline, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.32), radius: 24, y: 10)
    }

    private func apply(_ newScope: LibraryScope) {
        switch newScope {
        case .all, .favorites, .recent, .smart, .smartDetail, .smartLeaf, .smartUnknownDuration:
            library.selectedPackID = nil
            library.selectedFolderPath = nil
        case let .pack(packID):
            library.selectedPackID = packID
            library.selectedFolderPath = nil
        case let .folder(packID, path):
            library.selectedPackID = packID
            library.selectedFolderPath = path
        }

    }

    private func restoreOrValidateWorkspaceState() {
        if !hasRestoredWorkspace {
            hasRestoredWorkspace = true
            // Each fresh app launch starts from the complete library. Keep the saved workspace
            // JSON for other preferences, but do not restore its old folder/category selection.
            // This gives a new session a predictable first impression without changing indexing
            // or the user's actual sound data.
            scope = .all
            library.selectedPackID = nil
            library.selectedFolderPath = nil
            pendingWorkspaceSoundID = nil
            library.selectSound(nil)
            persistWorkspaceStateIfReady()
            return
        }

        let resolvedScope = LibraryWorkspaceState(
            scope: scope,
            sortMode: sortMode
        ).resolvedScope(in: library.packs)
        if resolvedScope != scope {
            scope = resolvedScope
            apply(resolvedScope)
        }
        persistWorkspaceStateIfReady()
    }

    private func persistWorkspaceStateIfReady() {
        guard hasRestoredWorkspace else { return }
        let visibleSelectedSoundID = library.selectedSoundID.flatMap {
            cachedSoundIndexByID[$0] == nil ? nil : $0
        }
        let state = LibraryWorkspaceState(
            scope: scope,
            sortMode: sortMode,
            selectedSoundID: pendingWorkspaceSoundID ?? visibleSelectedSoundID
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        workspaceStateJSON = String(decoding: data, as: UTF8.self)
    }

    /// Rapid audition can move selection several times in a fraction of a second. Selection and
    /// playback remain immediate, while the tiny recovery record is coalesced after the gesture
    /// settles instead of JSON-encoding and writing UserDefaults for every click.
    private func scheduleWorkspaceStatePersistence() {
        workspacePersistenceTask?.cancel()
        workspacePersistenceTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(280))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            persistWorkspaceStateIfReady()
            workspacePersistenceTask = nil
        }
    }

    private func restorePendingWorkspaceSelection(in snapshot: SoundResultsSnapshot) {
        guard let soundID = pendingWorkspaceSoundID else { return }
        pendingWorkspaceSoundID = nil
        guard snapshot.indexByID[soundID] != nil else { return }
        library.selectAndRevealSound(soundID)
    }

    private var keyboardActions: LibraryKeyboardActions {
        LibraryKeyboardActions(
            moveUp: { moveSelection(by: -1) },
            moveDown: { moveSelection(by: 1) },
            togglePlayback: toggleSelectedPlayback,
            toggleFavorite: toggleSelectedFavorite,
            skipBackward: { player.skip(seconds: -5) },
            skipForward: { player.skip(seconds: 5) },
            focusSearch: { isSearchFocused = true },
            refreshLibrary: { library.startRefreshSelectedPack() },
            showHealth: { isHealthPresented = true },
            showHelp: { isOnboardingPresented = true }
        )
    }

    private func beginBatchMode() {
        isBatchMode = true
        batchSelection.selectOnly(selectedVisibleSound?.id)
    }

    private func applyBatchFavorite(_ isFavorite: Bool) {
        let soundIDs = batchSelection.resolvedIDs(from: cachedSounds)
        library.startBatchFavorite(for: soundIDs, isFavorite: isFavorite)
    }

    private func applyBatchTags(_ tags: [String]) {
        let soundIDs = batchSelection.resolvedIDs(from: cachedSounds)
        library.startBatchAddTags(tags, to: soundIDs)
    }

    private func batchOperationStrip(_ progress: LibraryBatchOperationProgress) -> some View {
        HStack(spacing: 10) {
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .tint(ShixiangTheme.gold)
                .frame(width: 150)
            VStack(alignment: .leading, spacing: 2) {
                Text(progress.statusTitle)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ShixiangTheme.primaryText)
                if progress.total > 0 {
                    Text("\(progress.completed.formatted(.number)) / \(progress.total.formatted(.number))")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(ShixiangTheme.tertiaryText)
                }
            }
            Spacer()
            Text("写入只发生在拾响索引中")
                .font(.system(size: 9))
                .foregroundStyle(ShixiangTheme.tertiaryText)
            if progress.phase.canCancel {
                Button("取消") { library.cancelBatchOperation() }
                    .buttonStyle(ShixiangCommandButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(ShixiangTheme.gold.opacity(0.07))
        .overlay(alignment: .bottom) {
            Rectangle().fill(ShixiangTheme.hairline).frame(height: 1)
        }
    }

    private func showTransientNotice(_ message: String) {
        transientNoticeTask?.cancel()
        transientNotice = message
        transientNoticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            transientNotice = nil
        }
    }

    private func moveSelection(by offset: Int) {
        guard !cachedSounds.isEmpty else { return }
        let targetIndex: Int
        if let selected = library.selectedSoundID,
           let currentIndex = cachedSoundIndexByID[selected] {
            targetIndex = min(max(currentIndex + offset, 0), cachedSounds.count - 1)
        } else {
            targetIndex = offset < 0 ? cachedSounds.count - 1 : 0
        }
        library.selectAndRevealSound(cachedSounds[targetIndex].id)
    }

    private func toggleSelectedPlayback() {
        guard let sound = selectedVisibleSound, let url = library.url(for: sound) else { return }
        stopPitchPreview()
        player.togglePlayback(item: sound, url: url)
    }

    private func toggleSelectedFavorite() {
        guard let sound = selectedVisibleSound else { return }
        library.toggleFavorite(sound)
    }

    private var selectedVisibleSound: SoundItem? {
        if let selectedID = library.selectedSoundID,
           let index = cachedSoundIndexByID[selectedID],
           cachedSounds.indices.contains(index) {
            return cachedSounds[index]
        }
        return cachedSounds.first
    }
}

private struct AIHintBubble: View {
    let onEnable: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color(red: 0.35, green: 0.26, blue: 0.82))
                Text("这里是 AI 搜索")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.82))
                Spacer(minLength: 4)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.46))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
            }
            Text("打开后，用一句话描述你想找的声音")
                .font(.system(size: 9))
                .foregroundStyle(Color.black.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)
            Button("打开 AI") { onEnable() }
                .font(.system(size: 9, weight: .bold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.white)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Color(red: 0.35, green: 0.26, blue: 0.82))
                .clipShape(Capsule())
        }
        .padding(10)
        .frame(width: 184, alignment: .leading)
        .background(Color.white.opacity(0.98))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.black.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.32), radius: 16, y: 7)
    }
}

private struct SearchStatusStrip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isEnabled: Bool
    let isSearching: Bool
    let activity: SearchActivity?
    let semanticProgress: SemanticIndexProgress?
    let disable: () -> Void

    private var taskTitle: String? {
        if let activity { return activity.title }
        if isSearching { return "正在理解搜索意图" }
        if semanticProgress != nil { return "正在建立本地语义索引" }
        return nil
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSearching ? "sparkles" : "magnifyingglass")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(ShixiangTheme.primaryText)
                .frame(width: 25, height: 25)
                .background {
                    Circle().fill(
                        LinearGradient(
                            colors: [ShixiangTheme.violet, ShixiangTheme.gold],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(taskTitle ?? (isEnabled ? "AI 搜索已开启" : "搜索已就绪"))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [ShixiangTheme.primaryText, ShixiangTheme.gold],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .contentTransition(.opacity)
                Text(isEnabled
                    ? "目录、文件名与本地语义参与排序"
                    : "文件名、目录与标签匹配")
                    .font(.system(size: 9))
                    .foregroundStyle(ShixiangTheme.secondaryText)
            }

            if let taskTitle {
                Divider().frame(height: 20).overlay(ShixiangTheme.hairline)
                ProgressView()
                    .controlSize(.small)
                Text(taskTitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ShixiangTheme.secondaryText)
                    .lineLimit(1)
                if let progress = semanticProgress {
                    Text("\(progress.completed)/\(progress.total)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(ShixiangTheme.secondaryText)
                    ProgressView(value: progress.fraction)
                        .frame(width: 90)
                        .tint(ShixiangTheme.gold)
                }
            } else {
                Spacer(minLength: 4)
                Text("空闲，可随时关闭")
                    .font(.system(size: 10))
                    .foregroundStyle(ShixiangTheme.secondaryText)
            }

            if isEnabled {
                Button(action: disable) {
                    Image(systemName: "power")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ShixiangTheme.secondaryText)
                .help("关闭本地 AI 搜索")
                .accessibilityLabel("关闭本地 AI 搜索")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    ShixiangTheme.violet.opacity(0.14),
                                    ShixiangTheme.gold.opacity(0.08),
                                    ShixiangTheme.canvas.opacity(0.12)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(ShixiangTheme.violet.opacity(0.28), lineWidth: 1)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: taskTitle)
    }
}

private struct AIStatusOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isEnabled: Bool
    let isSearching: Bool
    let activity: SearchActivity?
    let semanticProgress: SemanticIndexProgress?
    let disable: () -> Void

    private var taskTitle: String? {
        if let activity { return activity.title }
        if isSearching { return "正在理解搜索意图" }
        if semanticProgress != nil { return "正在建立本地语义索引" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(ShixiangTheme.gold)
                    .frame(width: 28, height: 28)
                    .background {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [ShixiangTheme.violet, ShixiangTheme.gold],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .opacity(0.26)
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(isEnabled ? "AI 搜索已开启" : "正在搜索")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [ShixiangTheme.primaryText, ShixiangTheme.gold],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .contentTransition(.opacity)
                    Text(isEnabled
                        ? "目录、文件名与本地语义参与排序"
                        : "正在匹配文件名、目录与标签")
                        .font(.system(size: 10))
                        .foregroundStyle(ShixiangTheme.secondaryText)
                }
                Spacer(minLength: 6)
                if isEnabled {
                    Button(action: disable) {
                        Image(systemName: "power")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ShixiangTheme.secondaryText)
                    .help("关闭本地 AI 搜索")
                    .accessibilityLabel("关闭本地 AI 搜索")
                }
            }

            if let taskTitle {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text(taskTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .contentTransition(.opacity)
                    if let progress = semanticProgress {
                        Text("\(progress.completed)/\(progress.total)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(ShixiangTheme.secondaryText)
                    }
                }
                if let fraction = semanticProgress?.fraction {
                    ProgressView(value: fraction)
                        .tint(ShixiangTheme.gold)
                }
            } else {
                Label("空闲，可随时关闭", systemImage: "checkmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(ShixiangTheme.secondaryText)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(width: 294, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    ShixiangTheme.violet.opacity(0.18),
                                    ShixiangTheme.gold.opacity(0.10),
                                    ShixiangTheme.canvas.opacity(0.18)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ShixiangTheme.gold.opacity(0.36), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: taskTitle)
    }
}

private struct SearchActivity: Equatable {
    enum Phase: Equatable {
        case preparing
        case understanding
        case matching
    }

    let id: UUID
    let phase: Phase

    var title: String {
        switch phase {
        case .preparing: return "正在准备搜索"
        case .understanding: return "正在由本地 AI 理解需求"
        case .matching: return "正在匹配文件名、目录与标签"
        }
    }
}

private struct WindowResizeStateModifier: ViewModifier {
    @Binding var isResizing: Bool

    func body(content: Content) -> some View {
        content.background {
            WindowLiveResizeMonitor { value in
                guard value != isResizing else { return }
                isResizing = value
            }
            // A non-zero host view makes the window notifications reliable even when SwiftUI
            // prunes zero-sized backgrounds during a live resize.
            .frame(width: 1, height: 1)
            .opacity(0.001)
            .allowsHitTesting(false)
        }
    }
}

private struct SourceMigrationReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let result: LibraryScanReport

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("路径迁移记录")
                        .font(.system(size: 18, weight: .semibold))
                    Text("这些变化只发生在拾响的本地索引中，硬盘上的原始音频保持不变。")
                        .font(.system(size: 11))
                        .foregroundStyle(ShixiangTheme.secondaryText)
                }
                Spacer()
                Button("完成") { dismiss() }
            }
            .padding(20)

            Divider().overlay(ShixiangTheme.hairline)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(result.migrations.prefix(200)) { migration in
                        migrationRow(migration)
                    }
                    if result.migrations.count > 200 {
                        Text("另有 \((result.migrations.count - 200).formatted(.number)) 条记录未展开显示。")
                            .font(.system(size: 10))
                            .foregroundStyle(ShixiangTheme.tertiaryText)
                            .padding(.vertical, 8)
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 430, idealHeight: 560)
        .background(ShixiangTheme.workspaceGradient)
    }

    private func migrationRow(_ migration: SourceMigrationRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: migrationIcon(for: migration.kind))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ShixiangTheme.gold)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(migration.kind.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ShixiangTheme.gold)
                Text(migration.fromRelativePath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(ShixiangTheme.secondaryText)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 8, weight: .bold))
                    Text(migration.toRelativePath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(ShixiangTheme.primaryText)
                        .lineLimit(1)
                }
                .foregroundStyle(ShixiangTheme.violet)
            }

            Spacer(minLength: 8)
            Text(migration.detectedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 9))
                .foregroundStyle(ShixiangTheme.tertiaryText)
        }
        .padding(11)
        .background(ShixiangTheme.elevated.opacity(0.70))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(ShixiangTheme.hairline, lineWidth: 1)
        }
    }

    private func migrationIcon(for kind: SourceMigrationKind) -> String {
        switch kind {
        case .rename: return "pencil"
        case .move: return "folder"
        case .renameAndMove: return "arrow.up.right.and.arrow.down.left"
        }
    }
}

private struct SelectedSoundWorkbenchContent: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject var selection: LibrarySelection
    let close: () -> Void

    var body: some View {
        Group {
            if let sound = library.sound(id: selection.soundID) {
                SoundWorkbenchView(
                    item: sound,
                    fileURL: library.url(for: sound),
                    close: close
                )
                .id(sound.id)
            } else {
                ContentUnavailableView(
                    "未选择声音",
                    systemImage: "waveform",
                    description: Text("请先在列表中选择一个声音。")
                )
            }
        }
    }
}

enum LibraryScope: Hashable, Sendable {
    case all
    case favorites
    case recent
    case smart(SmartCollection)
    case smartDetail(SmartSubcollection)
    case smartLeaf(SmartLeafCollection)
    case smartUnknownDuration(SmartDurationBand)
    case pack(UUID)
    case folder(packID: UUID, path: String)

    func title(in packs: [SoundPack]) -> String {
        switch self {
        case .all:
            return "全部声音"
        case .favorites:
            return "收藏"
        case .recent:
            return "最近导入"
        case let .smart(collection):
            return collection.title
        case let .smartDetail(collection):
            return collection.title
        case let .smartLeaf(collection):
            return "\(collection.detail.title) · \(collection.title)"
        case let .smartUnknownDuration(durationBand):
            return "未识别 · \(durationBand.title)"
        case let .pack(packID):
            return packs.first(where: { $0.id == packID })?.name ?? "音效包"
        case let .folder(_, path):
            return path.split(separator: "/").last.map(String.init) ?? "文件夹"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "square.stack.3d.up.fill"
        case .favorites: return "star.fill"
        case .recent: return "clock.arrow.circlepath"
        case let .smart(collection): return collection.systemImage
        case let .smartDetail(collection): return collection.systemImage
        case let .smartLeaf(collection): return collection.systemImage
        case let .smartUnknownDuration(durationBand): return durationBand.systemImage
        case .pack: return "shippingbox.fill"
        case .folder: return "folder.fill"
        }
    }
}

enum SoundSortMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case name
    case duration
    case folder
    case format

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "文件名"
        case .duration: return "时长"
        case .folder: return "原目录"
        case .format: return "音频格式"
        }
    }

    var systemImage: String {
        switch self {
        case .name: return "textformat"
        case .duration: return "clock"
        case .folder: return "folder"
        case .format: return "waveform.badge.plus"
        }
    }

    func areInIncreasingOrder(_ lhs: SoundItem, _ rhs: SoundItem) -> Bool {
        switch self {
        case .name:
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        case .duration:
            if lhs.duration == rhs.duration {
                return lhs.fileName.localizedStandardCompare(rhs.fileName) == .orderedAscending
            }
            return lhs.duration < rhs.duration
        case .folder:
            if lhs.folderPath == rhs.folderPath {
                return lhs.fileName.localizedStandardCompare(rhs.fileName) == .orderedAscending
            }
            return lhs.folderPath.localizedStandardCompare(rhs.folderPath) == .orderedAscending
        case .format:
            if lhs.fileExtension == rhs.fileExtension {
                return lhs.fileName.localizedStandardCompare(rhs.fileName) == .orderedAscending
            }
            return lhs.fileExtension.localizedStandardCompare(rhs.fileExtension) == .orderedAscending
        }
    }
}

struct LibraryWorkspaceState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let storedScope: StoredScope
    let sortMode: SoundSortMode
    let selectedSoundID: UUID?

    init(
        schemaVersion: Int = LibraryWorkspaceState.currentSchemaVersion,
        scope: LibraryScope,
        sortMode: SoundSortMode,
        selectedSoundID: UUID? = nil
    ) {
        self.schemaVersion = schemaVersion
        storedScope = StoredScope(scope)
        self.sortMode = sortMode
        self.selectedSoundID = selectedSoundID
    }

    func resolvedScope(in packs: [SoundPack]) -> LibraryScope {
        storedScope.resolvedScope(in: packs)
    }

    enum StoredScope: Codable, Equatable, Sendable {
        case all
        case favorites
        case recent
        case smart(SmartCollection)
        case smartDetail(SmartSubcollection)
        case smartLeaf(SmartLeafCollection)
        case smartUnknownDuration(SmartDurationBand)
        case pack(UUID)
        case folder(packID: UUID, path: String)

        init(_ scope: LibraryScope) {
            switch scope {
            case .all: self = .all
            case .favorites: self = .favorites
            case .recent: self = .recent
            case let .smart(collection): self = .smart(collection)
            case let .smartDetail(collection): self = .smartDetail(collection)
            case let .smartLeaf(collection): self = .smartLeaf(collection)
            case let .smartUnknownDuration(durationBand): self = .smartUnknownDuration(durationBand)
            case let .pack(packID): self = .pack(packID)
            case let .folder(packID, path): self = .folder(packID: packID, path: path)
            }
        }

        func resolvedScope(in packs: [SoundPack]) -> LibraryScope {
            switch self {
            case .all:
                return .all
            case .favorites:
                return .favorites
            case .recent:
                return .recent
            case let .smart(collection):
                return .smart(collection)
            case let .smartDetail(collection):
                return .smartDetail(collection)
            case let .smartLeaf(collection):
                return .smartLeaf(collection)
            case let .smartUnknownDuration(durationBand):
                return .smartUnknownDuration(durationBand)
            case let .pack(packID):
                guard packs.contains(where: { $0.id == packID }) else { return .all }
                return .pack(packID)
            case let .folder(packID, path):
                guard let pack = packs.first(where: { $0.id == packID }) else { return .all }
                let hasFolder = pack.items.contains {
                    $0.folderPath == path || $0.folderPath.hasPrefix(path + "/")
                }
                return hasFolder ? .folder(packID: packID, path: path) : .all
            }
        }
    }
}

enum SoundResultsRevisionPolicy {
    static func favoriteRevision(
        scope: LibraryScope,
        favoritesOnly: Bool,
        revision: UInt64
    ) -> UInt64 {
        favoritesOnly || scope == .favorites ? revision : 0
    }

    static func classificationRevision(scope: LibraryScope, revision: UInt64) -> UInt64 {
        switch scope {
        case .smart, .smartDetail, .smartLeaf, .smartUnknownDuration:
            return revision
        case .all, .favorites, .recent, .pack, .folder:
            return 0
        }
    }

    static func metadataRevision(
        scope: LibraryScope,
        sortMode: SoundSortMode,
        query: String,
        revision: UInt64
    ) -> UInt64 {
        let hasQuery = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let classificationDependent: Bool
        switch scope {
        case .smart, .smartDetail, .smartLeaf, .smartUnknownDuration:
            classificationDependent = true
        case .all, .favorites, .recent, .pack, .folder:
            classificationDependent = false
        }
        return classificationDependent || sortMode == .name || hasQuery ? revision : 0
    }
}

struct SoundResultsRequest: Hashable, Sendable {
    let libraryRevision: UInt64
    let favoriteRevision: UInt64
    let metadataRevision: UInt64
    let classificationRevision: UInt64
    let visibilityRevision: UInt64
    let scope: LibraryScope
    let sortMode: SoundSortMode
    let selectedFormat: String?
    let minimumDuration: Double?
    let maximumDuration: Double?
    let favoritesOnly: Bool
    let showsHiddenSounds: Bool
    let query: String
    let searchMode: LibrarySearchMode
    let aiSearchEnabled: Bool
}

struct SoundResultsSnapshot: Sendable {
    let sounds: [SoundItem]
    let indexByID: [UUID: Int]
    let aiFeaturedIDs: Set<UUID>
    let exactSearchIDs: Set<UUID>
    let aiSearchIntent: AISearchIntent
    let aiCreatorIntent: CreatorSearchIntent
    let aiConflictSummary: String?
    let formats: [String]
    let effectiveFormat: String?

    static func make(
        packs: [SoundPack],
        request: SoundResultsRequest,
        queryMatches: LibrarySearchMatches? = nil,
        aiExpandedQuery: String? = nil,
        originalLiteralIDs: Set<UUID> = [],
        intelligenceByID: [UUID: AudioIntelligence] = [:],
        vocabulary: LibraryVocabulary? = nil
    ) throws -> Self {
        try Task.checkCancellation()
        var scoped: [SoundItem]
        let effectiveScope: LibraryScope = request.aiSearchEnabled
            && !request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .all
            : request.scope
        switch effectiveScope {
        case .all:
            scoped = try flattenItems(in: packs)
        case .favorites:
            scoped = try cancellableFilter(flattenItems(in: packs)) { $0.isFavorite }
        case .recent:
            scoped = packs
                .sorted { $0.importedAt > $1.importedAt }
                .prefix(3)
                .reduce(into: [SoundItem]()) { result, pack in
                    result.append(contentsOf: pack.items)
                }
        case let .smart(collection):
            let index = SmartTaxonomy.index(for: packs, revision: request.classificationRevision)
            scoped = try cancellableFilter(flattenItems(in: packs)) {
                index.contains($0.id, in: collection)
            }
        case let .smartDetail(collection):
            let index = SmartTaxonomy.index(for: packs, revision: request.classificationRevision)
            scoped = try cancellableFilter(flattenItems(in: packs)) {
                index.contains($0.id, in: collection)
            }
        case let .smartLeaf(collection):
            let index = SmartTaxonomy.index(for: packs, revision: request.classificationRevision)
            scoped = try cancellableFilter(flattenItems(in: packs)) {
                index.contains($0.id, in: collection)
            }
        case let .smartUnknownDuration(durationBand):
            let index = SmartTaxonomy.index(for: packs, revision: request.classificationRevision)
            scoped = try cancellableFilter(flattenItems(in: packs)) {
                index.contains($0.id, in: durationBand)
            }
        case let .pack(packID):
            scoped = packs.first(where: { $0.id == packID })?.items ?? []
        case let .folder(packID, path):
            if let pack = packs.first(where: { $0.id == packID }) {
                scoped = try cancellableFilter(pack.items) {
                    $0.folderPath == path || $0.folderPath.hasPrefix(path + "/")
                }
            } else {
                scoped = []
            }
        }

        try Task.checkCancellation()
        if !request.showsHiddenSounds {
            scoped = try cancellableFilter(scoped) { !$0.isHidden }
        }
        var formatSet = Set<String>()
        for (index, item) in scoped.enumerated() {
            if index.isMultiple(of: 512) { try Task.checkCancellation() }
            formatSet.insert(item.fileExtension)
        }
        let formats = formatSet.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        let effectiveFormat = request.selectedFormat.flatMap { formats.contains($0) ? $0 : nil }

        var filtered = scoped
        if let effectiveFormat {
            filtered = try cancellableFilter(filtered) { $0.fileExtension == effectiveFormat }
        }

        if let minimumDuration = request.minimumDuration {
            filtered = try cancellableFilter(filtered) { $0.duration >= minimumDuration }
        }
        if let maximumDuration = request.maximumDuration {
            filtered = try cancellableFilter(filtered) {
                $0.duration < maximumDuration || $0.duration == maximumDuration
            }
        }
        if request.favoritesOnly {
            filtered = try cancellableFilter(filtered) { $0.isFavorite }
        }

        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            if let queryMatches {
                if !(queryMatches.creatorIntent.hasExplicitDuration
                    && queryMatches.ids.isEmpty
                    && originalLiteralIDs.isEmpty) {
                    let matchIDs = queryMatches.ids.union(originalLiteralIDs)
                    filtered = try cancellableFilter(filtered) { matchIDs.contains($0.id) }
                }
            } else {
                filtered = try cancellableFilter(filtered) { item in
                    item.searchableText.localizedCaseInsensitiveContains(query)
                }
            }
        }

        if let intent = queryMatches?.creatorIntent, intent.hasExplicitDuration {
            if let minimum = intent.minimumDuration {
                filtered = try cancellableFilter(filtered) { $0.duration >= minimum }
            }
            if let maximum = intent.maximumDuration {
                filtered = try cancellableFilter(filtered) { $0.duration <= maximum }
            }
        }

        // Explicit negative language is a real search constraint. Keep a small fallback only
        // when applying it would erase every candidate; otherwise remove files whose visible
        // name, path, or tags contain the excluded term.
        if let intent = queryMatches?.intent, !intent.excludedTerms.isEmpty {
            let excluded = intent.excludedTerms.flatMap(AISearchIntentParser.searchAliases)
                .map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased() }
            let withoutExcluded = filtered.filter { item in
                let haystack = ([item.displayName, item.fileName, item.folderPath] + item.tags)
                    .joined(separator: " ")
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .lowercased()
                return !excluded.contains(where: { haystack.contains($0) })
            }
            if !withoutExcluded.isEmpty { filtered = withoutExcluded }
        }

        // A concrete sound object (雷声、脚步、咖啡馆等) must have direct evidence in the
        // filename, alias, or tag when such evidence exists in the candidate set. Parent-folder
        // semantics alone are too broad and can otherwise let unrelated “远处” sounds through.
        if let intent = queryMatches?.intent, !intent.soundTypes.isEmpty {
            let anchored = filtered.filter {
                LocalAISearchRanking.hasDirectSoundTypeEvidence($0, intent: intent)
            }
            if !anchored.isEmpty { filtered = anchored }
        }

        try Task.checkCancellation()
        let sorted: [SoundItem]
        let aiFeaturedIDs: Set<UUID>
        let exactSearchIDs: Set<UUID>
        if request.aiSearchEnabled,
           !query.isEmpty,
           let aiExpandedQuery,
           let queryMatches {
            exactSearchIDs = Set(filtered.lazy.map(\.id)).intersection(originalLiteralIDs)
            let exactHits = filtered
                .filter { exactSearchIDs.contains($0.id) }
                .sorted {
                    let lhsScore = LocalAISearchRanking.directPathMatchScore($0, query: query)
                    let rhsScore = LocalAISearchRanking.directPathMatchScore($1, query: query)
                    if lhsScore != rhsScore { return lhsScore > rhsScore }
                    return request.sortMode.areInIncreasingOrder($0, $1)
                }
            let featuredOrder = LocalAISearchRanking.featuredIDs(
                in: filtered.filter { !exactSearchIDs.contains($0.id) },
                expandedQuery: aiExpandedQuery,
                matches: queryMatches,
                intelligenceByID: intelligenceByID,
                vocabulary: vocabulary
            )
            aiFeaturedIDs = Set(featuredOrder)
            let featuredByID = Dictionary(uniqueKeysWithValues: filtered.map { ($0.id, $0) })
            let featured = featuredOrder.compactMap { featuredByID[$0] }
            let literalTail = filtered
                .filter {
                    !exactSearchIDs.contains($0.id)
                        && !aiFeaturedIDs.contains($0.id)
                        && queryMatches.literalIDs.contains($0.id)
                }
                .sorted(by: request.sortMode.areInIncreasingOrder)
            // AI remains a compact discovery shelf. The creator's direct filename/path hits
            // always follow it in full, so turning AI on can never make exact results vanish.
            sorted = featured + exactHits + literalTail
        } else if !query.isEmpty, request.searchMode == .hybrid, let relevance = queryMatches?.relevanceByID {
            aiFeaturedIDs = []
            exactSearchIDs = []
            sorted = filtered.sorted { lhs, rhs in
                let lhsScore = relevance[lhs.id] ?? 0
                let rhsScore = relevance[rhs.id] ?? 0
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                return request.sortMode.areInIncreasingOrder(lhs, rhs)
            }
        } else if !query.isEmpty, queryMatches != nil {
            aiFeaturedIDs = []
            exactSearchIDs = []
            sorted = filtered.sorted {
                let lhsScore = LocalAISearchRanking.directPathMatchScore($0, query: query)
                let rhsScore = LocalAISearchRanking.directPathMatchScore($1, query: query)
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                return request.sortMode.areInIncreasingOrder($0, $1)
            }
        } else {
            aiFeaturedIDs = []
            exactSearchIDs = []
            sorted = filtered.sorted(by: request.sortMode.areInIncreasingOrder)
        }
        try Task.checkCancellation()
        let indexByID = try SoundResultIndexBuilder.make(for: sorted)
        return Self(
            sounds: sorted,
            indexByID: indexByID,
            aiFeaturedIDs: aiFeaturedIDs,
            exactSearchIDs: exactSearchIDs,
            aiSearchIntent: queryMatches?.intent ?? .empty,
            aiCreatorIntent: queryMatches?.creatorIntent ?? .empty,
            aiConflictSummary: queryMatches?.intent.conflicts.isEmpty == false
                ? queryMatches?.intent.conflicts.joined(separator: "；")
                : nil,
            formats: formats,
            effectiveFormat: effectiveFormat
        )
    }

    private static func flattenItems(in packs: [SoundPack]) throws -> [SoundItem] {
        let capacity = packs.reduce(0) { $0 + $1.items.count }
        var result: [SoundItem] = []
        result.reserveCapacity(capacity)
        var itemCount = 0
        for pack in packs {
            try Task.checkCancellation()
            result.append(contentsOf: pack.items)
            itemCount += pack.items.count
            if itemCount.isMultiple(of: 2_048) {
                try Task.checkCancellation()
            }
        }
        return result
    }

    private static func cancellableFilter(
        _ items: [SoundItem],
        where predicate: (SoundItem) -> Bool
    ) throws -> [SoundItem] {
        var result: [SoundItem] = []
        result.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            if predicate(item) { result.append(item) }
        }
        return result
    }
}

enum SoundResultIndexBuilder {
    static func make(for sounds: [SoundItem]) throws -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        result.reserveCapacity(sounds.count)
        for (index, sound) in sounds.enumerated() {
            if index.isMultiple(of: 512) { try Task.checkCancellation() }
            result[sound.id] = index
        }
        return result
    }
}

private extension SavedCollectionScope {
    var libraryScope: LibraryScope {
        switch self {
        case .all: return .all
        case .recent: return .recent
        case .favorites: return .favorites
        case let .pack(packID): return .pack(packID)
        case let .folder(packID, path): return .folder(packID: packID, path: path)
        case let .smart(collection): return .smart(collection)
        case let .smartDetail(detail): return .smartDetail(detail)
        case let .smartLeaf(leaf): return .smartLeaf(leaf)
        case let .smartUnknownDuration(durationBand): return .smartUnknownDuration(durationBand)
        }
    }
}

private extension LibraryScope {
    var savedCollectionScope: SavedCollectionScope {
        switch self {
        case .all: return .all
        case .recent: return .recent
        case let .pack(packID): return .pack(packID)
        case let .folder(packID, path): return .folder(packID: packID, path: path)
        case .favorites: return .favorites
        case let .smart(collection): return .smart(collection)
        case let .smartDetail(detail): return .smartDetail(detail)
        case let .smartLeaf(leaf): return .smartLeaf(leaf)
        case let .smartUnknownDuration(durationBand): return .smartUnknownDuration(durationBand)
        }
    }
}

private struct SavedCollectionNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let message: String
    let placeholder: String
    let confirmTitle: String
    @State private var name: String
    let save: (String) -> Void

    init(
        title: String = "保存自定义集合",
        message: String = "把当前搜索和筛选条件保存下来，以后可以一键打开。",
        placeholder: String = "例如：我的低频转场",
        confirmTitle: String = "保存",
        initialName: String = "",
        save: @escaping (String) -> Void
    ) {
        self.title = title
        self.message = message
        self.placeholder = placeholder
        self.confirmTitle = confirmTitle
        self.save = save
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(ShixiangTheme.secondaryText)

            TextField(placeholder, text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit() }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button(confirmTitle) { commit() }
                    .buttonStyle(ShixiangCommandButtonStyle(isPrimary: true))
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 390)
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        save(trimmed)
        dismiss()
    }
}

private struct SavedCollectionsManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    let open: (SavedCollection) -> Void
    @State private var collectionToRename: SavedCollection?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("我的集合")
                        .font(.system(size: 18, weight: .semibold))
                    Text("可重命名、删除；失效范围会明确标记，原始音频不会被改动。")
                        .font(.system(size: 11))
                        .foregroundStyle(ShixiangTheme.secondaryText)
                }
                Spacer()
                Button("完成") { dismiss() }
            }
            .padding(20)

            Divider().overlay(ShixiangTheme.hairline)

            if library.savedCollections.isEmpty {
                ContentUnavailableView(
                    "还没有自定义集合",
                    systemImage: "rectangle.stack.badge.plus",
                    description: Text("在筛选菜单中保存一个常用搜索。")
                )
            } else {
                List {
                    ForEach(library.savedCollections) { collection in
                        savedCollectionRow(collection)
                            .contextMenu { collectionActions(for: collection) }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            library.removeSavedCollection(library.savedCollections[index])
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .sheet(item: $collectionToRename) { collection in
            SavedCollectionNameSheet(
                title: "重命名集合",
                message: "只会修改拾响里的集合名称，不会改动任何原始音频。",
                placeholder: "集合名称",
                confirmTitle: "保存",
                initialName: collection.name
            ) { newName in
                library.renameSavedCollection(collection, to: newName)
            }
        }
        .frame(minWidth: 460, minHeight: 320)
    }

    private func savedCollectionRow(_ collection: SavedCollection) -> some View {
        let availability = library.savedCollectionAvailability(collection)
        return HStack(spacing: 8) {
            Button { open(collection) } label: {
                HStack(spacing: 10) {
                    Image(
                        systemName: availability.isAvailable
                            ? "rectangle.stack"
                            : availability.systemImage
                    )
                    .foregroundStyle(
                        availability.isAvailable
                            ? ShixiangTheme.violet
                            : ShixiangTheme.gold
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(collection.name)
                            .foregroundStyle(ShixiangTheme.primaryText)
                        Text(collectionSummary(collection))
                            .font(.system(size: 10))
                            .foregroundStyle(ShixiangTheme.tertiaryText)
                        if !availability.isAvailable {
                            Text(availability.title + " · 重新导入或重新定位后可恢复")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(ShixiangTheme.gold)
                        }
                    }

                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ShixiangTheme.tertiaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                collectionActions(for: collection)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ShixiangTheme.tertiaryText)
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.plain)
            .help("集合操作")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func collectionActions(for collection: SavedCollection) -> some View {
        Button("重命名…") {
            collectionToRename = collection
        }
        Button("删除集合", role: .destructive) {
            library.removeSavedCollection(collection)
        }
    }

    private func collectionSummary(_ collection: SavedCollection) -> String {
        var parts: [String] = [scopeSummary(collection.scope)]
        if !collection.query.isEmpty { parts.append("搜索：\(collection.query)") }
        if let fileExtension = collection.fileExtension { parts.append(fileExtension.uppercased()) }
        if collection.favoritesOnly { parts.append("收藏") }
        if collection.minimumDuration != nil || collection.maximumDuration != nil {
            parts.append("时长筛选")
        }
        return parts.joined(separator: " · ")
    }

    private func scopeSummary(_ scope: SavedCollectionScope) -> String {
        switch scope {
        case .all: return "全部声音"
        case .recent: return "最近导入"
        case .favorites: return "收藏"
        case let .smart(collection): return collection.title
        case let .smartDetail(detail): return detail.title
        case let .smartLeaf(leaf): return "\(leaf.detail.title) / \(leaf.title)"
        case let .smartUnknownDuration(durationBand): return "未识别 / \(durationBand.title)"
        case let .pack(packID):
            return library.packs.first(where: { $0.id == packID }).map { "音效包：\($0.name)" }
                ?? "音效包：已移除"
        case let .folder(packID, path):
            let packName = library.packs.first(where: { $0.id == packID })?.name ?? "音效包已移除"
            return "\(packName) / \(path)"
        }
    }
}
