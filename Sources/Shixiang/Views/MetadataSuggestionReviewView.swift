import SwiftUI

struct MetadataSuggestionReviewView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    let items: [SoundItem]

    @StateObject private var selection = SoundBatchSelection()
    @State private var candidates: [MetadataSuggestionCandidate] = []
    @State private var eligibleCandidates: [MetadataSuggestionCandidate] = []
    @State private var isPreparing = true
    @State private var showsLowConfidence = false
    @State private var showsExistingNames = false
    @State private var visibleLimit = 160
    @State private var isNamingDictionaryPresented = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(ShixiangTheme.hairline)
            controls
            Divider().overlay(ShixiangTheme.hairline)

            if isPreparing {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.small).tint(ShixiangTheme.gold)
                    Text("正在本机生成中文别名与标签建议…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ShixiangTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if eligibleCandidates.isEmpty {
                ContentUnavailableView(
                    "当前范围没有新的整理建议",
                    systemImage: "wand.and.stars",
                    description: Text("可以显示低置信建议，或换到更大的声音范围再试。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(visibleCandidates) { candidate in
                            candidateRow(candidate)
                        }
                        if eligibleCandidates.count > visibleLimit {
                            Button("再显示 \(min(160, eligibleCandidates.count - visibleLimit)) 条") {
                                visibleLimit += 160
                            }
                            .buttonStyle(ShixiangCommandButtonStyle())
                            .padding(.vertical, 8)
                        }
                    }
                    .padding(16)
                }
            }

            Divider().overlay(ShixiangTheme.hairline)
            footer
        }
        .frame(minWidth: 900, idealWidth: 1_020, minHeight: 650, idealHeight: 760)
        .background(ShixiangTheme.workspaceGradient)
        .task { await prepareCandidates() }
        .onChange(of: showsLowConfidence) { _, _ in refreshEligibility() }
        .onChange(of: showsExistingNames) { _, _ in refreshEligibility() }
        .onChange(of: library.namingProfile) { _, _ in
            Task { await prepareCandidates() }
        }
        .sheet(isPresented: $isNamingDictionaryPresented) {
            NamingDictionaryView(profile: library.namingProfile)
                .environmentObject(library)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ShixiangIconBadge(systemImage: "character.book.closed.fill", size: 34, tint: ShixiangTheme.gold)
            VStack(alignment: .leading, spacing: 2) {
                Text("智能中文命名")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ShixiangTheme.primaryText)
                Text("先预览、再选择、最后写入拾响索引 · 原文件名保持不变")
                    .font(.system(size: 10))
                    .foregroundStyle(ShixiangTheme.tertiaryText)
            }
            Spacer()
            if !candidates.isEmpty {
                Text("\(candidates.count.formatted(.number)) 条建议")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ShixiangTheme.gold)
            }
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(ShixiangRoundButtonStyle(size: 28))
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
        .background(ShixiangTheme.surface.opacity(0.95))
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Toggle("显示较低置信度", isOn: $showsLowConfidence)
                .toggleStyle(.switch)
                .controlSize(.small)
            Toggle("允许覆盖已有别名", isOn: $showsExistingNames)
                .toggleStyle(.switch)
                .controlSize(.small)
            Spacer()
            Button {
                isNamingDictionaryPresented = true
            } label: {
                Label("Jacksun 词典", systemImage: "text.book.closed")
            }
            .buttonStyle(ShixiangCommandButtonStyle())
            Text("建议来自中英双语声音词典、目录、时长和文件名")
                .font(.system(size: 9))
                .foregroundStyle(ShixiangTheme.tertiaryText)
        }
        .font(.system(size: 10, weight: .medium))
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(ShixiangTheme.canvas.opacity(0.76))
    }

    private func candidateRow(_ candidate: MetadataSuggestionCandidate) -> some View {
        let isSelected = selection.contains(candidate.id)
        return HStack(spacing: 10) {
            Button { selection.toggle(candidate.id) } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? ShixiangTheme.gold : ShixiangTheme.tertiaryText)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.item.displayName)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(ShixiangTheme.secondaryText)
                    .lineLimit(1)
                Text(candidate.item.relativePath)
                    .font(.system(size: 7))
                    .foregroundStyle(ShixiangTheme.tertiaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: 300, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(ShixiangTheme.tertiaryText)

            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.suggestion.displayName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ShixiangTheme.primaryText)
                    .lineLimit(1)
                Text(candidate.suggestion.tags.prefix(5).joined(separator: " · "))
                    .font(.system(size: 7))
                    .foregroundStyle(ShixiangTheme.gold)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 3) {
                Text("\(Int((candidate.suggestion.confidence * 100).rounded()))%")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(candidate.suggestion.confidence >= 0.75
                        ? ShixiangTheme.gold
                        : ShixiangTheme.secondaryText)
                Text(candidate.suggestion.reasons.first ?? "本地整理")
                    .font(.system(size: 7))
                    .foregroundStyle(ShixiangTheme.tertiaryText)
                    .lineLimit(1)
            }
            .frame(width: 130, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(isSelected
            ? ShixiangTheme.selectedSurface.opacity(0.64)
            : ShixiangTheme.elevated.opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isSelected ? ShixiangTheme.violet.opacity(0.32) : ShixiangTheme.hairline)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            let count = selection.selectedCount(total: eligibleCandidates.count)
            Button(selection.selectsAll ? "清空选择" : "选择当前全部") {
                if selection.selectsAll {
                    selection.clear()
                } else {
                    selection.selectAll()
                }
            }
            .buttonStyle(ShixiangCommandButtonStyle())
            Text("已选 \(count.formatted(.number))")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(count > 0 ? ShixiangTheme.gold : ShixiangTheme.tertiaryText)
            Spacer()
            Text("应用后可从“更多”菜单撤销上一次操作")
                .font(.system(size: 8))
                .foregroundStyle(ShixiangTheme.tertiaryText)
            Button("应用选中建议") {
                library.startApplyMetadataSuggestions(
                    eligibleCandidates,
                    selectedIDs: selectedCandidateIDs
                )
                dismiss()
            }
            .buttonStyle(ShixiangCommandButtonStyle(isPrimary: true))
            .disabled(count == 0 || library.batchOperationProgress != nil)
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
        .background(ShixiangTheme.surface.opacity(0.96))
    }

    private var visibleCandidates: [MetadataSuggestionCandidate] {
        Array(eligibleCandidates.prefix(visibleLimit))
    }

    private var selectedCandidateIDs: Set<UUID> {
        if selection.selectsAll {
            return Set(eligibleCandidates.lazy.map(\.id).filter {
                !selection.excludedIDs.contains($0)
            })
        }
        return selection.selectedIDs
    }

    @MainActor
    private func prepareCandidates() async {
        isPreparing = true
        let sourceItems = items
        let namingProfile = library.namingProfile
        let task = Task.detached(priority: .utility) {
            var result: [MetadataSuggestionCandidate] = []
            result.reserveCapacity(min(sourceItems.count, 8_000))
            for (index, item) in sourceItems.enumerated() {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                let candidate = MetadataSuggestionCandidate(
                    item: item,
                    suggestion: SoundMetadataSuggestion.make(
                        for: item,
                        namingProfile: namingProfile
                    )
                )
                if candidate.hasChanges { result.append(candidate) }
            }
            return SoundMetadataSuggestion.numberConflicts(
                in: result,
                using: namingProfile
            ).sorted {
                if $0.suggestion.confidence != $1.suggestion.confidence {
                    return $0.suggestion.confidence > $1.suggestion.confidence
                }
                return $0.item.relativePath.localizedStandardCompare($1.item.relativePath)
                    == .orderedAscending
            }
        }
        do {
            candidates = try await task.value
            refreshEligibility()
        } catch {
            candidates = []
            eligibleCandidates = []
        }
        isPreparing = false
    }

    @MainActor
    private func refreshEligibility() {
        eligibleCandidates = candidates.filter {
            (showsLowConfidence || $0.suggestion.confidence >= 0.60)
                && (showsExistingNames || $0.item.customName == nil)
        }
        visibleLimit = 160
        // Changing the review boundary starts a fresh, predictable selection. This also keeps
        // select-all compressed to one Boolean instead of resolving tens of thousands of IDs.
        selection.selectAll()
    }
}
