import AppKit
import SwiftUI

struct LibrarySidebar: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var scope: LibraryScope
    @Binding var isSponsorPresented: Bool
    @Binding var sponsorCoinClickCount: Int

    @State private var expandedPacks = Set<UUID>()
    // A new session starts with a calm, collapsed library tree. Selecting a scope later still
    // reveals only the branch needed to show that selection.
    @State private var expandedSmartCollections: Set<SmartCollection> = []
    @State private var expandedSmartDetails = Set<SmartSubcollection>()
    /// A change to this value is a command observed by every recursive folder row.
    @State private var expandAllFolders = false
    @State private var folderTrees: [UUID: [FolderNode]] = [:]
    @State private var cachedRecentCount = 0
    @State private var smartCounts: [SmartCollection: Int] = [:]
    @State private var smartDetailCounts: [SmartSubcollection: Int] = [:]
    @State private var smartLeafCounts: [SmartLeafCollection: Int] = [:]
    @State private var smartUnknownDurationCounts: [SmartDurationBand: Int] = [:]
    @State private var hasLoadedSmartCounts = false
    private let smartDurationDrilldownThreshold = 300

    var body: some View {
        VStack(spacing: 0) {
            brandHeader
            libraryContextHeader

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    Button { scope = .all } label: {
                        SidebarLabel(
                            title: "全部声音",
                            icon: "square.stack.3d.up",
                            count: library.soundCount,
                            isSelected: scope == .all
                        )
                    }
                    .buttonStyle(.plain)

                    Button { scope = .favorites } label: {
                        SidebarLabel(
                            title: "收藏",
                            icon: "star",
                            count: library.favoriteCount,
                            isSelected: scope == .favorites
                        )
                    }
                    .buttonStyle(.plain)

                    Button { scope = .recent } label: {
                        SidebarLabel(
                            title: "最近导入",
                            icon: "clock.arrow.circlepath",
                            count: cachedRecentCount,
                            isSelected: scope == .recent
                        )
                    }
                    .buttonStyle(.plain)
 
                    sidebarSectionHeader("智能集合")
                    ForEach(SmartCollection.allCases) { collection in
                        smartTree(collection)
                    }

                    sidebarSectionHeader("音效包")
                    ForEach(library.packs) { pack in
                        packTree(pack)
                    }
                }
                .animation(sidebarExpansionAnimation, value: expandedSmartCollections)
                .animation(sidebarExpansionAnimation, value: expandedSmartDetails)
                .animation(sidebarExpansionAnimation, value: expandedPacks)
            }
            .scrollIndicators(.automatic)
            .contentMargins(.leading, 10, for: .scrollContent)
            .contentMargins(.trailing, 18, for: .scrollContent)
            .contentMargins(.vertical, 4, for: .scrollContent)

            Divider().overlay(ShixiangTheme.hairline)
            storageFooter
        }
        .background(ShixiangTheme.surface)
        // Same hidden-title-bar surface as the detail pane: the brand row is the window chrome.
        // NavigationSplitView keeps its own top safe-area inset for each column even when the
        // outer container ignores it, so the sidebar content must ignore it too, otherwise a
        // title-bar-height strip stays visible above the brand header.
        .ignoresSafeArea(.container, edges: .top)
        .task(id: sidebarStructureIdentity) {
            await rebuildFolderCache()
        }
        .task(id: library.classificationRevision) {
            await rebuildSmartCounts()
        }
        .task {
            reveal(scope)
        }
        .onChange(of: scope) { _, newScope in
            reveal(newScope)
        }
    }

    private var sidebarExpansionAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.92)
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            Link(destination: URL(string: "https://shixiang.jack-sun.com")!) {
                HStack(spacing: 10) {
                    // Keep the mark comfortably inside the 58pt fused title-bar row. 42pt gives
                    // the icon enough presence while leaving breathing room inside the title bar.
                    ShixiangMark(size: 42)

                    Text("拾响")
                        .font(.system(size: 15, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.96),
                                    ShixiangTheme.gold.opacity(0.92),
                                    ShixiangTheme.violet.opacity(0.88)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("打开拾响官方网站")
            .accessibilityLabel("打开拾响官方网站")

            Spacer(minLength: 8)

            Button {
                guard sponsorCoinClickCount < SponsorCoinLifecycle.maximumClicks else { return }
                isSponsorPresented = true
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    sponsorCoinClickCount += 1
                }
            } label: {
                SponsorCoinIcon(size: 29, isInteractive: true)
                    .scaleEffect(SponsorCoinLifecycle.scale(after: sponsorCoinClickCount))
                    .opacity(sponsorCoinClickCount < SponsorCoinLifecycle.maximumClicks ? 1 : 0)
                    .frame(width: 29, height: 29)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SponsorCoinButtonStyle())
            .frame(width: 29, height: 29)
            .contentShape(Rectangle())
            .allowsHitTesting(sponsorCoinClickCount < SponsorCoinLifecycle.maximumClicks)
            .help("赞助拾响")
            .accessibilityLabel("赞助拾响")
            .accessibilityHint("显示微信赞助二维码")
            .accessibilityHidden(sponsorCoinClickCount >= SponsorCoinLifecycle.maximumClicks)
        }
        // The first row shares the native title-bar surface. Reserve the traffic-light zone so
        // the brand stays fully visible while the window controls remain system-native.
        .padding(.leading, 82)
        .padding(.trailing, 14)
        .frame(height: 58)
        .overlay(alignment: .bottom) {
            Divider().overlay(ShixiangTheme.hairline)
        }
    }

    private var isAnyTreeExpanded: Bool {
        !expandedPacks.isEmpty || !expandedSmartCollections.isEmpty || !expandedSmartDetails.isEmpty
    }

    /// This is the sidebar half of the result-title row. Keeping it outside the scroll view
    /// gives the sidebar and detail pane the same second-row height and one shared divider.
    private var libraryContextHeader: some View {
        HStack(spacing: 7) {
            Text("资源库")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
            Rectangle()
                .fill(ShixiangTheme.hairline)
                .frame(height: 1)

            Button(action: toggleAllTreeExpansion) {
                Image(systemName: isAnyTreeExpanded ? "chevron.up.square" : "chevron.down.square")
                    .font(.system(size: 12, weight: .medium))
                    .shixiangHoverIcon(isAnyTreeExpanded ? "chevron.up.square" : "chevron.down.square")
                    .foregroundStyle(ShixiangTheme.secondaryText)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isAnyTreeExpanded ? "一键折叠所有分类" : "一键展开所有分类")
            .accessibilityLabel(isAnyTreeExpanded ? "折叠所有分类" : "展开所有分类")
        }
        .foregroundStyle(ShixiangTheme.tertiaryText)
        .padding(.horizontal, 14)
        .frame(height: 50)
        .overlay(alignment: .bottom) {
            Divider().overlay(ShixiangTheme.hairline)
        }
    }

    private func toggleAllTreeExpansion() {
        withAnimation(sidebarExpansionAnimation) {
            if isAnyTreeExpanded {
                expandedPacks.removeAll()
                expandedSmartCollections.removeAll()
                expandedSmartDetails.removeAll()
                expandAllFolders = false
            } else {
                expandedPacks = Set(library.packs.map(\.id))
                expandedSmartCollections = Set(SmartCollection.allCases)
                expandedSmartDetails = Set(SmartSubcollection.allCases)
                expandAllFolders = true
            }
        }
    }

    private func sidebarSectionHeader(_ title: String) -> some View {
        HStack(spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
            Rectangle()
                .fill(ShixiangTheme.hairline)
                .frame(height: 1)
        }
        .foregroundStyle(ShixiangTheme.tertiaryText)
        .padding(.horizontal, 4)
        .padding(.top, 15)
        .padding(.bottom, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func packTree(_ pack: SoundPack) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { expandedPacks.contains(pack.id) },
                set: { expanded in
                    if expanded { expandedPacks.insert(pack.id) }
                    else { expandedPacks.remove(pack.id) }
                }
            )
        ) {
            // `DisclosureGroup` may ask for its content while collapsed. Keep the recursive
            // folder views out of the hierarchy until this package is visibly open.
            if expandedPacks.contains(pack.id) {
                SidebarBranchGuide {
                    ForEach(folderTrees[pack.id] ?? []) { node in
                        FolderTreeRow(node: node, packID: pack.id, scope: $scope, expandAll: expandAllFolders)
                            .id(expandAllFolders)
                    }
                }
            }
        } label: {
            Button {
                scope = .pack(pack.id)
                if !pack.items.isEmpty {
                    withAnimation(sidebarExpansionAnimation) {
                        if expandedPacks.contains(pack.id) {
                            expandedPacks.remove(pack.id)
                        } else {
                            expandedPacks.insert(pack.id)
                        }
                    }
                }
            } label: {
                SidebarLabel(
                    title: pack.name,
                    icon: "shippingbox",
                    count: pack.items.count,
                    isSelected: scope == .pack(pack.id),
                    isInSelectionPath: isPackActive(pack.id),
                    statusIcon: library.unavailablePackIDs.contains(pack.id)
                        ? "externaldrive.badge.exclamationmark"
                        : (library.autoRefreshingPackIDs.contains(pack.id)
                            ? "arrow.triangle.2.circlepath"
                            : nil),
                    statusHelp: library.unavailablePackIDs.contains(pack.id)
                        ? "原始文件夹当前离线；索引仍可浏览"
                        : (library.autoRefreshingPackIDs.contains(pack.id)
                            ? "检测到变化，正在后台增量刷新"
                            : nil)
                )
            }
            .buttonStyle(.plain)
        }
        .tag(LibraryScope.pack(pack.id))
        .contextMenu {
            Button("刷新") {
                library.selectedPackID = pack.id
                library.startRefreshSelectedPack()
            }
            Button("在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: pack.rootPath)])
            }
            Divider()
            Button("移除音效包", role: .destructive) {
                library.selectedPackID = pack.id
                library.removeSelectedPack()
                scope = .all
            }
        }
    }

    @ViewBuilder
    private func smartTree(_ collection: SmartCollection) -> some View {
        if !hasLoadedSmartCounts {
            SidebarLabel(
                title: collection.title,
                icon: collection.systemImage,
                count: nil,
                isSelected: scope == .smart(collection),
                isInSelectionPath: isSmartParentActive(collection)
            )
            .accessibilityHint("正在计算本地分类数量")
        } else if collection == .untagged,
           smartCounts[collection, default: 0] > smartDurationDrilldownThreshold {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expandedSmartCollections.contains(collection) },
                    set: { expanded in
                        if expanded { expandedSmartCollections.insert(collection) }
                        else { expandedSmartCollections.remove(collection) }
                    }
                )
            ) {
                SidebarBranchGuide {
                    ForEach(SmartDurationBand.allCases.filter { smartUnknownDurationCounts[$0, default: 0] > 0 }) { durationBand in
                        Button {
                            scope = .smartUnknownDuration(durationBand)
                        } label: {
                            SidebarLabel(
                                title: durationBand.title,
                                icon: durationBand.systemImage,
                                count: smartUnknownDurationCounts[durationBand, default: 0],
                                isSelected: scope == .smartUnknownDuration(durationBand),
                                role: .leaf
                            )
                        }
                        .buttonStyle(.plain)
                        .tag(LibraryScope.smartUnknownDuration(durationBand))
                    }
                }
            } label: {
                Button {
                    toggleSmartCollection(collection)
                } label: {
                    SidebarLabel(
                        title: collection.title,
                        icon: collection.systemImage,
                        count: smartCounts[collection, default: 0],
                        isSelected: scope == .smart(collection),
                        isInSelectionPath: isSmartParentActive(collection)
                    )
                }
                .buttonStyle(.plain)
            }
            .tag(LibraryScope.smart(collection))
        } else if collection.children.isEmpty {
            smartParentButton(collection)
        } else {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expandedSmartCollections.contains(collection) },
                    set: { expanded in
                        if expanded { expandedSmartCollections.insert(collection) }
                        else { expandedSmartCollections.remove(collection) }
                    }
                )
            ) {
                SidebarBranchGuide {
                    ForEach(collection.children) { detail in
                        smartDetailTree(detail)
                    }
                }
            } label: {
                Button {
                    toggleSmartCollection(collection)
                } label: {
                    SidebarLabel(
                        title: collection.title,
                        icon: collection.systemImage,
                        count: smartCounts[collection, default: 0],
                        isSelected: scope == .smart(collection),
                        isInSelectionPath: isSmartParentActive(collection)
                    )
                }
                .buttonStyle(.plain)
            }
            .tag(LibraryScope.smart(collection))
        }
    }

    @ViewBuilder
    private func smartDetailTree(_ detail: SmartSubcollection) -> some View {
        if smartDetailCounts[detail, default: 0] > smartDurationDrilldownThreshold {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expandedSmartDetails.contains(detail) },
                    set: { expanded in
                        if expanded { expandedSmartDetails.insert(detail) }
                        else { expandedSmartDetails.remove(detail) }
                    }
                )
            ) {
                SidebarBranchGuide {
                    ForEach(SmartLeafCollection.all(for: detail).filter { smartLeafCounts[$0, default: 0] > 0 }) { leaf in
                        Button {
                            scope = .smartLeaf(leaf)
                        } label: {
                            SidebarLabel(
                                title: leaf.title,
                                icon: leaf.systemImage,
                                count: smartLeafCounts[leaf, default: 0],
                                isSelected: scope == .smartLeaf(leaf),
                                role: .leaf
                            )
                        }
                        .buttonStyle(.plain)
                        .tag(LibraryScope.smartLeaf(leaf))
                    }
                }
            } label: {
                Button {
                    toggleSmartDetail(detail)
                } label: {
                    SidebarLabel(
                        title: detail.title,
                        icon: detail.systemImage,
                        count: smartDetailCounts[detail, default: 0],
                        isSelected: scope == .smartDetail(detail),
                        isInSelectionPath: isSmartDetailActive(detail),
                        role: .branch
                    )
                }
                .buttonStyle(.plain)
            }
            .tag(LibraryScope.smartDetail(detail))
        } else {
            smartDetailButton(detail)
        }
    }

    private func smartDetailButton(_ detail: SmartSubcollection) -> some View {
        Button {
            scope = .smartDetail(detail)
        } label: {
            SidebarLabel(
                title: detail.title,
                icon: detail.systemImage,
                count: smartDetailCounts[detail, default: 0],
                isSelected: scope == .smartDetail(detail),
                role: .branch
            )
        }
        .buttonStyle(.plain)
        .tag(LibraryScope.smartDetail(detail))
    }

    private func toggleSmartCollection(_ collection: SmartCollection) {
        if expandedSmartCollections.contains(collection) {
            expandedSmartCollections.remove(collection)
        } else {
            expandedSmartCollections.insert(collection)
        }
    }

    private func toggleSmartDetail(_ detail: SmartSubcollection) {
        if expandedSmartDetails.contains(detail) {
            expandedSmartDetails.remove(detail)
        } else {
            expandedSmartDetails.insert(detail)
        }
    }

    private func reveal(_ scope: LibraryScope) {
        switch scope {
        case let .smart(collection):
            expandedSmartCollections.insert(collection)
        case let .smartDetail(detail):
            expandedSmartCollections.insert(detail.parent)
        case let .smartLeaf(leaf):
            expandedSmartCollections.insert(leaf.detail.parent)
            expandedSmartDetails.insert(leaf.detail)
        case .smartUnknownDuration:
            expandedSmartCollections.insert(.untagged)
        case let .pack(packID), let .folder(packID, _):
            expandedPacks.insert(packID)
        case .all, .favorites, .recent:
            break
        }
    }

    private func isSmartParentActive(_ collection: SmartCollection) -> Bool {
        switch scope {
        case let .smart(selected): return selected == collection
        case let .smartDetail(detail): return detail.parent == collection
        case let .smartLeaf(leaf): return leaf.detail.parent == collection
        case .smartUnknownDuration: return collection == .untagged
        default: return false
        }
    }

    private func isSmartDetailActive(_ detail: SmartSubcollection) -> Bool {
        switch scope {
        case let .smartDetail(selected): return selected == detail
        case let .smartLeaf(leaf): return leaf.detail == detail
        default: return false
        }
    }

    private func isPackActive(_ packID: UUID) -> Bool {
        switch scope {
        case let .pack(selectedPackID):
            return selectedPackID == packID
        case let .folder(selectedPackID, _):
            return selectedPackID == packID
        default:
            return false
        }
    }

    private func smartParentButton(_ collection: SmartCollection) -> some View {
        Button {
            scope = .smart(collection)
        } label: {
            SidebarLabel(
                title: collection.title,
                icon: collection.systemImage,
                count: smartCounts[collection, default: 0],
                isSelected: scope == .smart(collection)
            )
        }
        .buttonStyle(.plain)
        .tag(LibraryScope.smart(collection))
    }

    private var storageFooter: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("本地素材库", systemImage: "internaldrive")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ShixiangTheme.secondaryText)
                Spacer()
                Text("\(library.packs.count) 包")
                    .font(.system(size: 10))
                    .foregroundStyle(ShixiangTheme.tertiaryText)
            }

            Button {
                library.importPackWithPanel()
            } label: {
                Label("导入音效包", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ShixiangCommandButtonStyle(isPrimary: true))
        }
        .padding(14)
    }

    @MainActor
    private var sidebarStructureIdentity: [SidebarPackIdentity] {
        library.packs.map {
            SidebarPackIdentity(id: $0.id, lastScannedAt: $0.lastScannedAt, itemCount: $0.items.count)
        }
    }

    @MainActor
    private func rebuildFolderCache() async {
        let packs = library.packs
        let snapshot = await Task.detached(priority: .utility) {
            SidebarStructureSnapshot(
                folderTrees: Dictionary(
                    uniqueKeysWithValues: packs.map { ($0.id, FolderNode.make(from: $0.items)) }
                ),
                recentCount: packs
                    .sorted { $0.importedAt > $1.importedAt }
                    .prefix(3)
                    .reduce(0) { $0 + $1.items.count }
            )
        }.value
        guard !Task.isCancelled else { return }
        folderTrees = snapshot.folderTrees
        cachedRecentCount = snapshot.recentCount
    }

    @MainActor
    private func rebuildSmartCounts() async {
        let packs = library.packs
        let revision = library.classificationRevision
        let snapshot = await Task.detached(priority: .utility) {
            let index = SmartTaxonomy.index(for: packs, revision: revision)
            return SmartSidebarCountSnapshot(
                parentCounts: index.parentCounts,
                detailCounts: index.detailCounts,
                leafCounts: index.leafCounts,
                unknownDurationCounts: index.unknownDurationCounts
            )
        }.value
        guard !Task.isCancelled else { return }
        smartCounts = snapshot.parentCounts
        smartDetailCounts = snapshot.detailCounts
        smartLeafCounts = snapshot.leafCounts
        smartUnknownDurationCounts = snapshot.unknownDurationCounts
        hasLoadedSmartCounts = true
    }
}

private struct SidebarBranchGuide<Content: View>: View {
    /// Tree depth should only move the node identity (chevron / icon / title). The count is
    /// an invariant column, so a nested branch reclaims its leading indent on the trailing side.
    /// This keeps every quantity readable as a single vertical scan line.
    private let branchIndent: CGFloat = 14

    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            content
        }
        .overlay(alignment: .leading) {
            Capsule()
                .fill(ShixiangTheme.gold.opacity(0.18))
                .frame(width: 1)
                .padding(.vertical, 4)
                .offset(x: 6)
                .accessibilityHidden(true)
        }
        .padding(.leading, branchIndent)
        .padding(.trailing, -branchIndent)
    }
}

private enum SidebarNodeRole {
    case primary
    case branch
    case leaf

    var rowHeight: CGFloat {
        switch self {
        case .primary: 32
        case .branch: 29
        case .leaf: 27
        }
    }

    var font: Font {
        switch self {
        case .primary: .system(size: 12, weight: .medium)
        case .branch: .system(size: 11.5, weight: .medium)
        case .leaf: .system(size: 11, weight: .regular)
        }
    }

    var iconWidth: CGFloat {
        switch self {
        case .primary: 17
        case .branch: 15
        case .leaf: 14
        }
    }

    var contentInset: CGFloat {
        switch self {
        case .primary: 0
        case .branch: 0
        case .leaf: 12
        }
    }
}

private struct SidebarLabel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    let icon: String
    let count: Int?
    var isSelected = false
    var isInSelectionPath = false
    var statusIcon: String?
    var statusHelp: String?
    var role: SidebarNodeRole = .primary

    var body: some View {
        HStack(spacing: role == .leaf ? 7 : 8) {
            Image(systemName: icon)
                .font(.system(size: role == .primary ? 11 : 10, weight: .medium))
                .frame(width: role.iconWidth)
                .symbolVariant(isSelected ? .fill : .none)
                .shixiangHoverIcon(icon)
                .foregroundStyle(iconColor)
                .accessibilityHidden(true)
            Text(title)
                .font(role.font)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(titleColor)
            if let statusIcon {
                Image(systemName: statusIcon)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(ShixiangTheme.gold)
                    .accessibilityHidden(true)
                    .help(statusHelp ?? "")
            }
            Group {
                if let count {
                    Text(displayedCount(count))
                        .accessibilityLabel("\(count.formatted(.number)) 个声音")
                } else {
                    Text("—")
                        .accessibilityLabel("正在计算")
                }
            }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(countColor)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.leading, 8)
        }
        .padding(.leading, role == .leaf ? 6 : 7)
        .padding(.trailing, 7)
        .frame(
            maxWidth: .infinity,
            minHeight: role.rowHeight,
            maxHeight: role.rowHeight,
            alignment: .leading
        )
        // Keep the entire visual row, including its trailing whitespace, as one generous
        // pointer target. This also makes the label easy to hit beside a disclosure chevron.
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: role == .leaf ? 6 : 8, style: .continuous)
                .fill(selectionBackground)
        }
        .overlay(alignment: .leading) {
            Capsule()
                .fill(ShixiangTheme.gold)
                .frame(width: 2, height: role == .leaf ? 12 : 15)
                .padding(.leading, 1)
                .opacity(isSelected ? 1 : 0)
        }
        .padding(.leading, role.contentInset)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.13), value: isSelected)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.13), value: isInSelectionPath)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint(statusHelp ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var iconColor: Color {
        if isSelected { return ShixiangTheme.gold }
        if isInSelectionPath { return ShixiangTheme.gold.opacity(0.72) }
        return role == .primary ? ShixiangTheme.secondaryText : ShixiangTheme.tertiaryText
    }

    private var titleColor: Color {
        if isSelected { return ShixiangTheme.primaryText }
        if isInSelectionPath { return ShixiangTheme.primaryText.opacity(0.84) }
        return role == .leaf
            ? ShixiangTheme.secondaryText.opacity(0.82)
            : ShixiangTheme.secondaryText
    }

    private var countColor: Color {
        if isSelected { return ShixiangTheme.gold.opacity(0.88) }
        if isInSelectionPath { return ShixiangTheme.gold.opacity(0.58) }
        return ShixiangTheme.tertiaryText
    }

    private var selectionBackground: some ShapeStyle {
        LinearGradient(
            colors: isSelected
                ? [ShixiangTheme.violet.opacity(0.24), ShixiangTheme.elevated.opacity(0.72)]
                : [.clear, .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var accessibilitySummary: String {
        if let count {
            return "\(title)，\(count.formatted(.number)) 个声音"
        }
        return "\(title)，正在计算"
    }

    private func displayedCount(_ count: Int) -> String {
        guard count >= 10_000 else { return count.formatted(.number) }
        let value = Double(count) / 10_000
        return value.formatted(.number.precision(.fractionLength(2))) + "万"
    }
}

private struct FolderTreeRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let node: FolderNode
    let packID: UUID
    let depth: Int
    @Binding var scope: LibraryScope
    let expandAll: Bool
    @State private var isExpanded: Bool

    init(
        node: FolderNode,
        packID: UUID,
        depth: Int = 1,
        scope: Binding<LibraryScope>,
        expandAll: Bool
    ) {
        self.node = node
        self.packID = packID
        self.depth = depth
        _scope = scope
        self.expandAll = expandAll
        _isExpanded = State(
            initialValue: scope.wrappedValue.shouldExpandFolder(
                packID: packID,
                ancestorPath: node.path
            ) || expandAll
        )
    }

    var body: some View {
        if node.children.isEmpty {
            folderButton
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                // Materialize one level at a time. A collapsed branch can represent thousands
                // of descendants, but it contributes only its own row to SwiftUI and VoiceOver.
                if isExpanded {
                    SidebarBranchGuide {
                        ForEach(node.children) { child in
                            FolderTreeRow(
                                node: child,
                                packID: packID,
                                depth: depth + 1,
                                scope: $scope,
                                expandAll: expandAll
                            )
                        }
                    }
                }
            } label: {
                folderButton
            }
            .animation(
                reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.92),
                value: isExpanded
            )
            .onChange(of: scope) { _, newScope in
                if newScope.shouldExpandFolder(packID: packID, ancestorPath: node.path) {
                    isExpanded = true
                }
            }
            .tag(LibraryScope.folder(packID: packID, path: node.path))
        }
    }

    private var folderButton: some View {
        Button {
            scope = .folder(packID: packID, path: node.path)
            if !node.children.isEmpty {
                withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.92)) {
                    isExpanded.toggle()
                }
            }
        } label: {
            SidebarLabel(
                title: node.name,
                icon: "folder",
                count: node.itemCount,
                isSelected: scope == .folder(packID: packID, path: node.path),
                isInSelectionPath: isAncestorOfSelection,
                role: node.children.isEmpty ? .leaf : .branch
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .tag(LibraryScope.folder(packID: packID, path: node.path))
    }

    private var isAncestorOfSelection: Bool {
        guard scope != .folder(packID: packID, path: node.path) else { return false }
        return scope.shouldExpandFolder(packID: packID, ancestorPath: node.path)
    }
}

extension LibraryScope {
    func shouldExpandFolder(packID: UUID, ancestorPath: String) -> Bool {
        guard case let .folder(selectedPackID, selectedPath) = self,
              selectedPackID == packID else { return false }
        return selectedPath == ancestorPath || selectedPath.hasPrefix(ancestorPath + "/")
    }
}

private struct SidebarPackIdentity: Hashable {
    let id: UUID
    let lastScannedAt: Date
    let itemCount: Int
}

private struct SidebarStructureSnapshot: Sendable {
    let folderTrees: [UUID: [FolderNode]]
    let recentCount: Int
}

private struct SmartSidebarCountSnapshot: Sendable {
    let parentCounts: [SmartCollection: Int]
    let detailCounts: [SmartSubcollection: Int]
    let leafCounts: [SmartLeafCollection: Int]
    let unknownDurationCounts: [SmartDurationBand: Int]
}
