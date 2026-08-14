import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SoundPaging {
    static let pageSize = 240
    static let maximumWindowSize = pageSize * 3

    static func initialRange(total: Int) -> Range<Int> {
        0..<min(max(total, 0), pageSize)
    }

    static func window(total: Int, around index: Int) -> Range<Int> {
        let safeTotal = max(total, 0)
        guard safeTotal > 0 else { return 0..<0 }
        let target = min(max(index, 0), safeTotal - 1)
        let upper = min(safeTotal, target + pageSize / 2 + 1)
        let lower = max(0, upper - min(pageSize, safeTotal))
        return lower..<upper
    }

    static func loadingNext(current: Range<Int>, total: Int) -> Range<Int> {
        let safeTotal = max(total, 0)
        let safeCurrent = clamped(current, total: safeTotal)
        guard safeCurrent.upperBound < safeTotal else { return safeCurrent }
        let desiredCount = min(maximumWindowSize, safeCurrent.count + pageSize)
        let upper = min(safeTotal, safeCurrent.upperBound + pageSize)
        let lower = max(0, upper - desiredCount)
        return lower..<upper
    }

    static func loadingPrevious(current: Range<Int>, total: Int) -> Range<Int> {
        let safeTotal = max(total, 0)
        let safeCurrent = clamped(current, total: safeTotal)
        guard safeCurrent.lowerBound > 0 else { return safeCurrent }
        let desiredCount = min(maximumWindowSize, safeCurrent.count + pageSize)
        let lower = max(0, safeCurrent.lowerBound - pageSize)
        let upper = min(safeTotal, lower + desiredCount)
        return lower..<upper
    }

    static func clamped(_ range: Range<Int>, total: Int) -> Range<Int> {
        let safeTotal = max(total, 0)
        let lower = min(max(range.lowerBound, 0), safeTotal)
        let upper = min(max(range.upperBound, lower), safeTotal)
        return lower..<upper
    }
}

struct SoundListView: View {
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("shixiang.library.localAISearchEnabled") private var localAISearchEnabled = false
    let items: [SoundItem]
    let indexByID: [UUID: Int]
    let aiFeaturedIDs: Set<UUID>
    let exactSearchIDs: Set<UUID>
    let aiSearchQuery: String
    let aiSearchIntent: AISearchIntent
    let aiCreatorIntent: CreatorSearchIntent
    let aiConflictSummary: String?
    let isInitialResultReady: Bool
    let datasetID: UInt64
    let scope: LibraryScope
    let hasActiveFilters: Bool
    let isBatchMode: Bool
    @ObservedObject var batchSelection: SoundBatchSelection
    let clearFilters: () -> Void
    let showHealth: () -> Void
    var body: some View {
        Group {
            // The production store starts with an empty placeholder while SQLite is read in the
            // background. That placeholder is not an empty library and must never pass through
            // the no-results branch for one frame.
            if !library.isInitialLoadComplete || library.isDeferredStartupLoading || !isInitialResultReady {
                deferredLibraryLoading
            } else if library.packs.isEmpty {
                FirstImportView()
            } else if items.isEmpty {
                noResults
            } else {
                soundList
            }
        }
        .background(ShixiangTheme.canvas)
    }

    private var deferredLibraryLoading: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(ShixiangTheme.violet)
                .symbolEffect(.pulse, options: .repeating, isActive: true)

            Text(library.deferredStartupStatus ?? "正在准备本地音效库…")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ShixiangTheme.primaryText)

            if let progress = library.deferredStartupProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 280)
                    .tint(ShixiangTheme.violet)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(ShixiangTheme.violet)
            }

            Text("准备完成后会在这里显示你的音效列表")
                .font(.system(size: 11))
                .foregroundStyle(ShixiangTheme.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(ShixiangTheme.secondaryText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(library.deferredStartupStatus ?? "正在准备本地音效库")
    }

    private var soundList: some View {
        GeometryReader { geometry in
            let waveformWidth = adaptiveWaveformWidth(for: geometry.size.width)

            VStack(spacing: 0) {
                SoundListHeader(waveformWidth: waveformWidth, isBatchMode: isBatchMode)

                PagedSoundList(
                    items: items,
                    indexByID: indexByID,
                    aiFeaturedIDs: aiFeaturedIDs,
                    exactSearchIDs: exactSearchIDs,
                    aiSearchQuery: aiSearchQuery,
                    aiSearchIntent: aiSearchIntent,
                    aiCreatorIntent: aiCreatorIntent,
                    aiConflictSummary: aiConflictSummary,
                    waveformWidth: waveformWidth,
                    datasetID: datasetID,
                    isBatchMode: isBatchMode,
                    batchSelection: batchSelection
                )
            }
        }
    }

    private var noResults: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: emptySystemImage)
        } description: {
            Text((aiConflictSummary.map { "搜索条件冲突：\($0)。\n" } ?? "") + emptyDescription)
        } actions: {
            if !library.query.isEmpty {
                Button("清除搜索") { library.query = "" }
                    .buttonStyle(.bordered)
                if aiSearchIntent.excludedTerms.isEmpty == false {
                    Button("移除排除条件") {
                        library.query = aiSearchIntent.requiredTerms.joined(separator: " ")
                    }
                    .buttonStyle(.bordered)
                }
                if aiCreatorIntent.hasExplicitDuration {
                    Button("放宽时长") {
                        library.query = aiSearchIntent.requiredTerms.joined(separator: " ")
                    }
                    .buttonStyle(.bordered)
                }
                if aiConflictSummary != nil {
                    Button("放宽冲突条件") {
                        library.query = aiSearchIntent.soundTypes.map(\.term).joined(separator: " ")
                    }
                    .buttonStyle(.bordered)
                }
                Button("仅匹配原名") {
                    localAISearchEnabled = false
                }
            }
            if hasActiveFilters {
                Button("清除全部筛选", action: clearFilters)
                    .buttonStyle(.bordered)
            }
            if library.query.isEmpty && !hasActiveFilters {
                if library.selectedPack != nil {
                    Button("增量刷新") { library.startRefreshSelectedPack() }
                        .buttonStyle(.borderedProminent)
                        .tint(ShixiangTheme.violet)
                }
                Button("打开资料库体检", action: showHealth)
                    .buttonStyle(.bordered)
            }
        }
        .foregroundStyle(ShixiangTheme.secondaryText)
    }

    private var emptyTitle: String {
        if !library.query.isEmpty { return "没有找到声音" }
        if hasActiveFilters { return "当前筛选没有结果" }
        if scope == .favorites { return "还没有收藏" }
        return "这里还没有声音"
    }

    private var emptySystemImage: String {
        if !library.query.isEmpty { return "waveform.badge.magnifyingglass" }
        if hasActiveFilters { return "line.3.horizontal.decrease.circle" }
        if scope == .favorites { return "star" }
        return "waveform.badge.exclamationmark"
    }

    private var emptyDescription: String {
        if !library.query.isEmpty {
            if !aiSearchIntent.excludedTerms.isEmpty { return "没有完全满足全部条件的声音；可以移除排除条件，或放宽时长。" }
            if aiCreatorIntent.hasExplicitDuration { return "没有完全满足当前时长的声音；可以放宽时长，或清除搜索。" }
            return "试试更短的关键词，或清除搜索。"
        }
        if hasActiveFilters { return "格式、时长和收藏条件叠加后没有匹配项。" }
        if scope == .favorites { return "选中声音后按 F，或点击星标，把常用声音留在这里。" }
        return "可以增量刷新当前音效包，或通过资料库体检检查路径。"
    }
}

/// The result set remains complete for counts, search and keyboard navigation, while AppKit
/// only receives a bounded window of row identities. Forward scrolling slides that window
/// after three pages, while an arbitrary reveal opens one page around its target instead of
/// materializing every preceding row in a 36k-item library.
private struct PagedSoundList: View {
    @EnvironmentObject private var library: LibraryStore

    let items: [SoundItem]
    let indexByID: [UUID: Int]
    let aiFeaturedIDs: Set<UUID>
    let exactSearchIDs: Set<UUID>
    let aiSearchQuery: String
    let aiSearchIntent: AISearchIntent
    let aiCreatorIntent: CreatorSearchIntent
    let aiConflictSummary: String?
    let waveformWidth: CGFloat
    let datasetID: UInt64
    let isBatchMode: Bool
    @ObservedObject var batchSelection: SoundBatchSelection

    @State private var renderedRange: Range<Int>

    init(
        items: [SoundItem],
        indexByID: [UUID: Int],
        aiFeaturedIDs: Set<UUID>,
        exactSearchIDs: Set<UUID>,
        aiSearchQuery: String,
        aiSearchIntent: AISearchIntent,
        aiCreatorIntent: CreatorSearchIntent,
        aiConflictSummary: String?,
        waveformWidth: CGFloat,
        datasetID: UInt64,
        isBatchMode: Bool,
        batchSelection: SoundBatchSelection
    ) {
        self.items = items
        self.indexByID = indexByID
        self.aiFeaturedIDs = aiFeaturedIDs
        self.exactSearchIDs = exactSearchIDs
        self.aiSearchQuery = aiSearchQuery
        self.aiSearchIntent = aiSearchIntent
        self.aiCreatorIntent = aiCreatorIntent
        self.aiConflictSummary = aiConflictSummary
        self.waveformWidth = waveformWidth
        self.datasetID = datasetID
        self.isBatchMode = isBatchMode
        self.batchSelection = batchSelection
        _renderedRange = State(initialValue: SoundPaging.initialRange(total: items.count))
    }

    var body: some View {
        let visibleItems = Array(items[safeRenderedRange])

        ScrollViewReader { proxy in
            List {
                if safeRenderedRange.lowerBound > 0 {
                    SoundPageLoader(
                        title: "载入前面的 \(safeRenderedRange.lowerBound.formatted(.number)) 条",
                        loadsAutomatically: false,
                        load: { loadPreviousPage(using: proxy) }
                    )
                    .id("previous-\(safeRenderedRange.lowerBound)")
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }

                ForEach(Array(visibleItems.enumerated()), id: \.element.id) { offset, item in
                    let band = resultBand(for: item)
                    Group {
                        if hasSearchBands && (offset == 0 || resultBand(for: visibleItems[offset - 1]) != band) {
                            ResultBandHeader(band: band)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }

                        SoundRow(
                            selection: library.selection,
                            item: item,
                            isAIFeatured: aiFeaturedIDs.contains(item.id),
                            isExactMatch: exactSearchIDs.contains(item.id),
                            aiSearchQuery: aiSearchQuery,
                            aiSearchIntent: aiSearchIntent,
                            aiCreatorIntent: aiCreatorIntent,
                            aiConflictSummary: aiConflictSummary,
                            waveformWidth: waveformWidth,
                            isBatchMode: isBatchMode,
                            batchSelection: batchSelection
                        )
                        .id(item.id)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }

                if safeRenderedRange.upperBound < items.count {
                    SoundPageLoader(
                        title: "继续载入余下 \((items.count - safeRenderedRange.upperBound).formatted(.number)) 条",
                        loadsAutomatically: true,
                        load: { loadNextPage(using: proxy) }
                    )
                    .id("next-\(safeRenderedRange.upperBound)")
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 50)
            .onChange(of: datasetID) { _, _ in
                // Keep the native List alive so a favorite/search update diffs only changed
                // rows. The result set itself is new, so start that dataset at its first page.
                renderedRange = SoundPaging.initialRange(total: items.count)
            }
            .onChange(of: library.requestedRevealSoundID) { _, soundID in
                guard let soundID else { return }
                reveal(soundID, using: proxy)
            }
            .task(id: datasetID) {
                // A workspace selection can be restored before the native List exists.
                // Reconcile the retained reveal request once this exact dataset is mounted.
                await Task.yield()
                guard !Task.isCancelled,
                      let soundID = library.requestedRevealSoundID,
                      let targetIndex = indexByID[soundID] else { return }
                if !safeRenderedRange.contains(targetIndex) {
                    renderedRange = SoundPaging.window(total: items.count, around: targetIndex)
                    await Task.yield()
                }
                guard !Task.isCancelled else { return }
                scroll(to: soundID, using: proxy)
            }
        }
    }

    private var safeRenderedRange: Range<Int> {
        SoundPaging.clamped(renderedRange, total: items.count)
    }

    private func loadNextPage(using proxy: ScrollViewProxy) {
        let current = safeRenderedRange
        let next = SoundPaging.loadingNext(current: current, total: items.count)
        guard next != current else { return }
        let anchorID = next.lowerBound > current.lowerBound && !current.isEmpty
            ? items[current.upperBound - 1].id
            : nil
        renderedRange = next
        guard let anchorID else { return }
        Task { @MainActor in
            await Task.yield()
            scroll(to: anchorID, using: proxy)
        }
    }

    private func loadPreviousPage(using proxy: ScrollViewProxy) {
        let current = safeRenderedRange
        let previous = SoundPaging.loadingPrevious(current: current, total: items.count)
        guard previous != current else { return }
        let anchorID = previous.upperBound < current.upperBound && !current.isEmpty
            ? items[current.lowerBound].id
            : nil
        renderedRange = previous
        guard let anchorID else { return }
        Task { @MainActor in
            await Task.yield()
            scroll(to: anchorID, using: proxy)
        }
    }

    private func reveal(_ soundID: UUID, using proxy: ScrollViewProxy) {
        guard let targetIndex = indexByID[soundID] else { return }
        if !safeRenderedRange.contains(targetIndex) {
            renderedRange = SoundPaging.window(total: items.count, around: targetIndex)
            Task { @MainActor in
                await Task.yield()
                scroll(to: soundID, using: proxy)
            }
        } else {
            scroll(to: soundID, using: proxy)
        }
    }

    private func scroll(to soundID: UUID, using proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            proxy.scrollTo(soundID, anchor: .center)
        }
    }

    private var hasSearchBands: Bool {
        !aiFeaturedIDs.isEmpty || !exactSearchIDs.isEmpty
    }

    private func resultBand(for item: SoundItem) -> ResultBand {
        if aiFeaturedIDs.contains(item.id) { return .ai }
        if exactSearchIDs.contains(item.id) { return .exact }
        return .related
    }

}

private enum ResultBand: Equatable {
    case ai
    case exact
    case related

    var title: String {
        switch self {
        case .ai: return "AI 精选"
        case .exact: return "精确命中"
        case .related: return "关联命中"
        }
    }

    var icon: String {
        switch self {
        case .ai: return "sparkles"
        case .exact: return "scope"
        case .related: return "link"
        }
    }

    var tint: Color {
        switch self {
        case .ai: return ShixiangTheme.violet
        case .exact: return Color(red: 0.33, green: 0.58, blue: 1.0)
        case .related: return ShixiangTheme.gold
        }
    }
}

private struct ResultBandHeader: View {
    let band: ResultBand

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: band.icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(band.tint)
                .shixiangHoverIcon(band.icon)
            Text(band.title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(band.tint)
            Rectangle()
                .fill(band.tint.opacity(0.18))
                .frame(height: 1)
        }
        // Native List reserves a narrow trailing scrollbar lane. Matching that lane here keeps
        // the flexible file-name column and the fixed duration/format columns aligned to rows.
        .padding(.leading, 14)
        .padding(.trailing, 26)
        .frame(height: 28, alignment: .center)
        .background(ShixiangTheme.surface.opacity(0.72))
    }
}

private struct SoundPageLoader: View {
    let title: String
    let loadsAutomatically: Bool
    let load: () -> Void

    @ViewBuilder
    var body: some View {
        if loadsAutomatically {
            label
                .onAppear(perform: load)
        } else {
            Button(action: load) {
                label
            }
            .buttonStyle(.plain)
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            Image(systemName: "ellipsis")
            Text(title)
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(ShixiangTheme.tertiaryText)
        .frame(maxWidth: .infinity, minHeight: 34)
    }
}

private struct FirstImportView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(ShixiangTheme.elevated)
                    .frame(width: 74, height: 74)
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(ShixiangTheme.gold)
            }

            VStack(spacing: 7) {
                Text("导入你的第一个音效包")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(ShixiangTheme.primaryText)
                Text("选择整个文件夹。拾响会保留原目录和文件名，只在本地建立索引。")
                    .font(.system(size: 12))
                    .foregroundStyle(ShixiangTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 410)
                    .lineSpacing(3)
            }

            Button {
                library.importPackWithPanel()
            } label: {
                Label("选择音效包文件夹", systemImage: "folder")
                    .padding(.horizontal, 7)
            }
            .buttonStyle(.borderedProminent)
            .tint(ShixiangTheme.violet)
            .controlSize(.large)

            Button {
                ShixiangDistributionLinks.openOfficialSoundPack()
            } label: {
                Label("前往官网领取 5 万+ 附加音效库", systemImage: "safari")
            }
            .buttonStyle(.bordered)

            Text("多年从公开互联网资源与自行购买素材中收集、筛选和整理；具体授权以包内说明为准。")
                .font(.system(size: 9))
                .foregroundStyle(ShixiangTheme.tertiaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            Text("支持 WAV · AIFF · MP3 · M4A · CAF · FLAC")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ShixiangTheme.tertiaryText)
            Text("也可以把音效包文件夹直接拖到这里")
                .font(.system(size: 10))
                .foregroundStyle(isDropTargeted ? ShixiangTheme.gold : ShixiangTheme.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .contentShape(Rectangle())
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    isDropTargeted ? ShixiangTheme.gold.opacity(0.62) : Color.clear,
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )
                .padding(18)
                .allowsHitTesting(false)
        }
        .onDrop(
            of: [UTType.fileURL.identifier],
            isTargeted: $isDropTargeted,
            perform: importDroppedPack
        )
    }

    private func importDroppedPack(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            guard let data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in
                library.startAddPack(from: url)
            }
        }
        return true
    }
}

private struct SoundListHeader: View {
    let waveformWidth: CGFloat
    let isBatchMode: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isBatchMode ? "checkmark.circle" : "line.3.horizontal")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 26)
                .accessibilityHidden(true)
            Text("")
                .frame(width: 32)
            SoundListColumnTitle(title: "波形", icon: "waveform")
                .frame(width: waveformWidth, alignment: .leading)
            SoundListColumnTitle(title: "文件名", icon: "doc.text")
                .frame(maxWidth: .infinity, alignment: .leading)
            SoundListColumnTitle(title: "时长", icon: "clock")
                .frame(width: 62, alignment: .trailing)
            SoundListColumnTitle(title: "格式", icon: "waveform.badge.plus")
                .frame(width: 70, alignment: .leading)
            Text("")
                .frame(width: 30)
        }
        // Native List reserves a narrow trailing scrollbar lane. Matching that lane here keeps
        // the flexible file-name column and the fixed duration/format columns aligned to rows.
        .padding(.leading, 14)
        .padding(.trailing, 26)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(ShixiangTheme.tertiaryText)
        .frame(height: 30)
        .background(ShixiangTheme.surface.opacity(0.97))
        .overlay(alignment: .bottom) {
            Divider().overlay(ShixiangTheme.hairline)
        }
    }
}

private struct SoundListColumnTitle: View {
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
    }
}

private struct SoundRow: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: AudioPlayerController
    @Environment(\.stopPitchPreview) private var stopPitchPreview
    @ObservedObject var selection: LibrarySelection

    let item: SoundItem
    let isAIFeatured: Bool
    let isExactMatch: Bool
    let aiSearchQuery: String
    let aiSearchIntent: AISearchIntent
    let aiCreatorIntent: CreatorSearchIntent
    let aiConflictSummary: String?
    let waveformWidth: CGFloat
    let isBatchMode: Bool
    @ObservedObject var batchSelection: SoundBatchSelection

    private var fileURL: URL? { library.url(for: item) }
    private var aiIntelligence: AudioIntelligence? { library.intelligence(for: item.id) }
    private var isBatchSelected: Bool { batchSelection.contains(item.id) }
    private var isSelected: Bool {
        isBatchMode ? isBatchSelected : selection.soundID == item.id
    }
    private var isCurrent: Bool { player.currentItemID == item.id }

    var body: some View {
        rowContent(waveformWidth: waveformWidth)
        .frame(minHeight: 50)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [ShixiangTheme.gold, ShixiangTheme.violet],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isBatchMode {
                batchSelection.toggle(item.id)
            } else {
                library.selectSound(item.id)
            }
        }
        .onDrag {
            guard !isBatchMode, let fileURL else { return NSItemProvider() }
            return SoundDragProvider.itemProvider(for: fileURL)
        }
        .contextMenu {
            Button(isCurrent && player.isPlaying ? "暂停" : "试听") { togglePlayback() }
            Button("加入试听队列") {
                guard let fileURL else { return }
                player.enqueue(item: item, url: fileURL)
            }
            Button(item.isFavorite ? "取消收藏" : "收藏") { library.toggleFavorite(item) }
            Divider()
            Button("在访达中显示") {
                guard let fileURL else { return }
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
            Button("复制文件路径") {
                guard let fileURL else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fileURL.path, forType: .string)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.displayName)，时长 \(item.duration.shixiangTimecode)")
        .help(rowHelp)
        .task(id: preloadTaskKey) {
            // Native List only creates this task for visible rows. A short delay avoids
            // opening decoders for cells that merely flash past during a fast fling.
            // Start warming visible rows soon after they settle. 45ms still filters cells that
            // only flash through during a fling, while making an immediate first play much more
            // likely to take an already prepared decoder instead of opening one on the click.
            try? await Task.sleep(for: .milliseconds(45))
            guard !Task.isCancelled, let fileURL else { return }
            player.preload(item: item, url: fileURL)
        }
        .overlay(alignment: .bottom) {
            Divider()
                .overlay(ShixiangTheme.hairline)
                .padding(.leading, 47)
        }
    }

    /// Dataset identity is part of the task key so a fast search/scroll cannot reuse a stale
    /// decoder task for a row ID that has re-entered the viewport with a different source URL.
    private var preloadTaskKey: String {
        "\(item.id.uuidString)-\(item.sourceContentSignature ?? 0)-\(item.sourceFileSize ?? 0)"
    }

    private func rowContent(waveformWidth: CGFloat) -> some View {
        HStack(spacing: 12) {
            if isBatchMode {
                Button {
                    batchSelection.toggle(item.id)
                } label: {
                    Image(systemName: isBatchSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isBatchSelected ? ShixiangTheme.gold : ShixiangTheme.tertiaryText)
                        .frame(width: 26, height: 30)
                }
                .buttonStyle(.plain)
                .help(isBatchSelected ? "取消选择" : "选择声音")
            } else {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isSelected ? ShixiangTheme.gold : ShixiangTheme.tertiaryText)
                    .opacity(isSelected ? 1 : 0.46)
                    .frame(width: 26, height: 30)
                    .help("拖动音频到 Final Cut Pro")
            }

            Button(action: togglePlayback) {
                Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                    .offset(x: isCurrent && player.isPlaying ? 0 : 0.5)
            }
            .buttonStyle(ShixiangRoundButtonStyle(isPrimary: isCurrent, size: 30))
            .help(isCurrent && player.isPlaying ? "暂停" : "试听")

            ScrubbableSoundWaveform(
                item: item,
                fileURL: fileURL,
                isCurrent: isCurrent
            )
            .frame(width: waveformWidth, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(item.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ShixiangTheme.primaryText)
                        .lineLimit(1)
                    if isExactMatch {
                        Label("精确命中", systemImage: "text.magnifyingglass")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(ShixiangTheme.violet)
                            .lineLimit(1)
                    } else if isAIFeatured {
                        Label("AI 精选", systemImage: "sparkles")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(ShixiangTheme.gold)
                            .lineLimit(1)
                    }
                }
                Text(rowSubtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(ShixiangTheme.tertiaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.duration.shixiangTimecode)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(ShixiangTheme.secondaryText)
                .frame(width: 62, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileExtension.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(isCurrent ? ShixiangTheme.gold : ShixiangTheme.secondaryText)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        (isCurrent ? ShixiangTheme.gold : ShixiangTheme.secondaryText)
                            .opacity(0.10)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                if let sampleRate = item.sampleRate {
                    Text(sampleRate.shixiangSampleRate)
                        .font(.system(size: 8))
                        .foregroundStyle(ShixiangTheme.tertiaryText)
                }
            }
            .frame(width: 70, alignment: .leading)

            Button {
                library.toggleFavorite(item)
            } label: {
                Image(systemName: item.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(item.isFavorite ? ShixiangTheme.gold : ShixiangTheme.tertiaryText)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .help(item.isFavorite ? "取消收藏" : "收藏")
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
    }

    private var rowBackground: Color {
        if isSelected { return ShixiangTheme.selectedSurface.opacity(0.82) }
        return .clear
    }

    private var rowHelp: String {
        if fileURL == nil { return "原文件不可用" }
        if isBatchMode { return isBatchSelected ? "已选择，点击取消" : "点击加入批量选择" }
        return "拖动这一行可放入 Final Cut Pro"
    }

    private var rowSubtitle: String {
        if isAIFeatured {
            let evidence = LocalAISearchRanking.explanation(
                for: item,
                query: aiSearchQuery,
                intent: aiSearchIntent,
                creatorIntent: aiCreatorIntent
                , intelligence: aiIntelligence
            )
            if !evidence.isEmpty { return "AI依据：" + evidence.joined(separator: " · ") }
            if let aiConflictSummary {
                return "AI提示：\(aiConflictSummary)"
            }
        }
        if item.customName != nil {
            let tags = item.tags.prefix(3).map { "#\($0)" }.joined(separator: "  ")
            return tags.isEmpty ? "原文件：\(item.fileName)" : "原文件：\(item.fileName)  ·  \(tags)"
        }
        if !item.tags.isEmpty {
            return item.tags.prefix(4).map { "#\($0)" }.joined(separator: "  ")
        }
        return item.folderPath.isEmpty ? "音效包根目录" : item.folderPath
    }

    private func togglePlayback() {
        library.selectSound(item.id)
        guard let fileURL else { return }
        stopPitchPreview()
        player.togglePlayback(item: item, url: fileURL)
    }

}

/// The thumbnail is also the transport surface. Only this small view observes pointer
/// movement; the rest of the row and every off-screen sound remain idle while scrubbing.
private struct ScrubbableSoundWaveform: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: AudioPlayerController
    @Environment(\.stopPitchPreview) private var stopPitchPreview

    let item: SoundItem
    let fileURL: URL?
    let isCurrent: Bool

    @GestureState private var gestureProgress: Double?
    @GestureState private var isPointerActive = false
    @State private var isDragging = false
    @State private var isGesturePrepared = false
    @State private var wasPlayingBeforeDrag = false
    @State private var startedNewItemOnPress = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let gestureProgress {
                    WaveformView(
                        fileURL: fileURL,
                        cacheIdentity: item.waveformCacheIdentity,
                        progress: gestureProgress,
                        playedColor: ShixiangTheme.violet,
                        unplayedColor: ShixiangTheme.secondaryText.opacity(0.32),
                        rendersAsynchronously: false
                    )
                } else if showsPlaybackProgress {
                    PlaybackWaveformView(
                        fileURL: fileURL,
                        cacheIdentity: item.waveformCacheIdentity,
                        clock: player.clock
                    )
                } else {
                    WaveformView(
                        fileURL: fileURL,
                        cacheIdentity: item.waveformCacheIdentity,
                        unplayedColor: ShixiangTheme.secondaryText.opacity(0.32)
                    )
                }

                if let progress = gestureProgress {
                    scrubIndicator(
                        progress: progress,
                        size: geometry.size
                    )
                }
            }
            .contentShape(Rectangle())
            .highPriorityGesture(scrubGesture(width: geometry.size.width))
        }
        .transaction { transaction in
            // Seeking must follow the pointer exactly; no spring or interpolation.
            transaction.animation = nil
        }
        .onChange(of: isPointerActive) { _, isActive in
            if !isActive {
                resetGestureState()
            }
        }
        .onChange(of: player.currentItemID) { _, currentID in
            if currentID != item.id {
                resetGestureState()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("波形播放进度")
        .accessibilityValue(accessibilityProgress)
        .accessibilityHint(fileURL == nil ? "原文件不可用" : "单击定位，按住并左右拖动调整进度")
        .accessibilityAdjustableAction { direction in
            guard fileURL != nil else { return }
            let base = isCurrent ? player.progress : 0
            switch direction {
            case .increment:
                commitScrub(to: min(1, base + 0.05), resumePlayback: false)
            case .decrement:
                commitScrub(to: max(0, base - 0.05), resumePlayback: false)
            @unknown default:
                break
            }
        }
        .help(fileURL == nil ? "原文件不可用" : "单击定位 · 左右拖动调整播放进度")
    }

    private var accessibilityProgress: String {
        guard isCurrent else { return "尚未播放" }
        // A completed or explicitly stopped preview rewinds the transport to zero.
        // Report that idle state consistently instead of leaving a misleading 0% row.
        guard player.isPlaying || player.currentTime > 0 else { return "尚未播放" }
        return "\(Int(player.progress * 100))%"
    }

    private var showsPlaybackProgress: Bool {
        guard isCurrent else { return false }
        if player.isPlaying { return true }
        return player.currentTime > 0 && player.currentTime < player.duration
    }

    private func scrubIndicator(progress: Double, size: CGSize) -> some View {
        let x = size.width * progress
        let color = isDragging ? ShixiangTheme.gold : ShixiangTheme.violet

        return ZStack {
            Rectangle()
                .fill(color)
                .frame(width: isDragging ? 2 : 1, height: size.height)
                .position(x: x, y: size.height / 2)

            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
                .position(x: x, y: size.height - 2.5)
        }
        .allowsHitTesting(false)
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($gestureProgress) { value, progress, _ in
                progress = WaveformScrubbing.progress(
                    locationX: value.location.x,
                    width: width
                )
            }
            .updating($isPointerActive) { _, isActive, _ in
                isActive = true
            }
            .onChanged { value in
                let progress = WaveformScrubbing.progress(
                    locationX: value.location.x,
                    width: width
                )

                if !isGesturePrepared {
                    isGesturePrepared = true
                    library.selectSound(item.id)

                    if player.currentItemID != item.id, let fileURL {
                        // Start on mouse-down, not mouse-up. Rapidly auditioning adjacent
                        // sounds must cut the previous preview at the first pointer event.
                        stopPitchPreview()
                        player.play(
                            item: item,
                            url: fileURL,
                            startingProgress: progress
                        )
                        startedNewItemOnPress = player.currentItemID == item.id
                        wasPlayingBeforeDrag = player.isPlaying
                    } else {
                        wasPlayingBeforeDrag = player.isPlaying
                    }
                }

                let distance = hypot(value.translation.width, value.translation.height)
                if distance >= 3, !isDragging {
                    isDragging = true
                    if player.currentItemID == item.id, player.isPlaying {
                        player.pause()
                    }
                }
            }
            .onEnded { value in
                let progress = WaveformScrubbing.progress(
                    locationX: value.location.x,
                    width: width
                )
                if isDragging || !startedNewItemOnPress || player.currentItemID != item.id {
                    commitScrub(
                        to: progress,
                        resumePlayback: isDragging && wasPlayingBeforeDrag
                    )
                }
                resetGestureState()
            }
    }

    private func resetGestureState() {
        isDragging = false
        isGesturePrepared = false
        wasPlayingBeforeDrag = false
        startedNewItemOnPress = false
    }

    @MainActor
    private func commitScrub(to progress: Double, resumePlayback: Bool) {
        library.selectSound(item.id)
        guard let fileURL else { return }

        if player.currentItemID == item.id {
            let time = WaveformScrubbing.time(
                progress: progress,
                duration: player.duration
            )
            player.finishScrubbing(to: time, resumePlayback: resumePlayback)
        } else {
            stopPitchPreview()
            player.play(item: item, url: fileURL, startingProgress: progress)
        }
    }
}

private func adaptiveWaveformWidth(for availableWidth: CGFloat) -> CGFloat {
    min(300, max(140, availableWidth * 0.26))
}

extension Double {
    var shixiangTimecode: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let roundedSeconds = Int(self.rounded(.down))
        let hours = roundedSeconds / 3_600
        let minutes = (roundedSeconds % 3_600) / 60
        let seconds = roundedSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    var shixiangSampleRate: String {
        guard self > 0 else { return "—" }
        let kiloHertz = self / 1_000
        if kiloHertz.rounded() == kiloHertz {
            return String(format: "%.0f kHz", kiloHertz)
        }
        return String(format: "%.1f kHz", kiloHertz)
    }
}
