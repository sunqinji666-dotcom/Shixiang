import AppKit
import SwiftUI

struct DuplicateReviewView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: AudioPlayerController
    @Environment(\.dismiss) private var dismiss

    let report: LibraryHealthReport

    @State private var query = ""
    @State private var showsIgnored = false
    @State private var visibleLimit = 60
    @State private var keepSoundByFingerprint: [String: UUID] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(ShixiangTheme.hairline)
            controls
            Divider().overlay(ShixiangTheme.hairline)

            if visibleGroups.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "square.on.square.dashed",
                    description: Text(emptyDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(visibleGroups) { group in
                            groupCard(group)
                        }
                        if filteredGroups.count > visibleLimit {
                            Button("再显示 \(min(60, filteredGroups.count - visibleLimit)) 组") {
                                visibleLimit += 60
                            }
                            .buttonStyle(ShixiangCommandButtonStyle())
                            .padding(.vertical, 8)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 820, idealWidth: 930, minHeight: 620, idealHeight: 720)
        .background(ShixiangTheme.workspaceGradient)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ShixiangIconBadge(systemImage: "square.on.square", size: 34, tint: ShixiangTheme.gold)
            VStack(alignment: .leading, spacing: 2) {
                Text("重复音效处理中心")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ShixiangTheme.primaryText)
                Text("比较、试听、忽略或仅从拾响主列表隐藏 · 不删除硬盘文件")
                    .font(.system(size: 10))
                    .foregroundStyle(ShixiangTheme.tertiaryText)
            }
            Spacer()
            metric("待处理", pendingGroups.count)
            metric("已忽略", ignoredGroups.count)
            metric("已隐藏", library.hiddenSoundCount)
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(ShixiangRoundButtonStyle(size: 28))
        }
        .padding(.horizontal, 18)
        .frame(height: 66)
        .background(ShixiangTheme.surface.opacity(0.95))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(ShixiangTheme.tertiaryText)
                TextField("搜索文件名、音效包或原目录", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(ShixiangTheme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .frame(maxWidth: 360)

            Toggle("显示已忽略", isOn: $showsIgnored)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 10, weight: .medium))

            Spacer()
            if library.hiddenSoundCount > 0 {
                Button("恢复全部隐藏项") { library.restoreAllHiddenSounds() }
                    .buttonStyle(ShixiangCommandButtonStyle())
            }
            Text("疑似重复依据：文件大小 + 内容抽样")
                .font(.system(size: 9))
                .foregroundStyle(ShixiangTheme.tertiaryText)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(ShixiangTheme.canvas.opacity(0.78))
    }

    private func groupCard(_ group: LibraryDuplicateGroup) -> some View {
        let isIgnored = library.ignoredDuplicateFingerprints.contains(group.fingerprint)
        let keepID = selectedKeepID(in: group)
        let hiddenCount = group.items.lazy.filter { library.sound(id: $0.id)?.isHidden == true }.count

        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(group.items.count) 个相同内容候选 · 每个 \(formatBytes(group.fileSize))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ShixiangTheme.primaryText)
                    Text(hiddenCount > 0 ? "已从主列表隐藏 \(hiddenCount) 项" : "选择保留项后，其余项只会在拾响中隐藏")
                        .font(.system(size: 9))
                        .foregroundStyle(ShixiangTheme.tertiaryText)
                }
                Spacer()
                if hiddenCount > 0 {
                    Button("恢复本组") { library.restoreDuplicateItems(in: group) }
                        .buttonStyle(ShixiangCommandButtonStyle())
                }
                Button(isIgnored ? "取消忽略" : "忽略本组") {
                    library.setDuplicateGroupIgnored(group.fingerprint, isIgnored: !isIgnored)
                }
                .buttonStyle(ShixiangCommandButtonStyle())
                Button("保留所选，隐藏其余") {
                    library.hideDuplicateItems(in: group, keeping: keepID)
                }
                .buttonStyle(ShixiangCommandButtonStyle(isPrimary: true))
                .disabled(isIgnored)
            }

            VStack(spacing: 5) {
                ForEach(group.items) { item in
                    duplicateItemRow(item, keepID: keepID, group: group)
                }
            }
        }
        .padding(12)
        .background(ShixiangTheme.elevated.opacity(isIgnored ? 0.42 : 0.76))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isIgnored ? ShixiangTheme.hairline : ShixiangTheme.gold.opacity(0.20), lineWidth: 1)
        }
    }

    private func duplicateItemRow(
        _ item: LibraryHealthItem,
        keepID: UUID,
        group: LibraryDuplicateGroup
    ) -> some View {
        let sound = library.sound(id: item.id)
        let url = sound.flatMap { library.url(for: $0) }
        let isHidden = sound?.isHidden == true
        let isPlaying = player.currentItemID == item.id && player.isPlaying

        return HStack(spacing: 9) {
            Button {
                keepSoundByFingerprint[group.fingerprint] = item.id
            } label: {
                Image(systemName: keepID == item.id ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(keepID == item.id ? ShixiangTheme.gold : ShixiangTheme.tertiaryText)
            }
            .buttonStyle(.plain)
            .help("设为本组保留项")

            Button {
                guard let sound, let url else { return }
                player.togglePlayback(item: sound, url: url)
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(url == nil ? ShixiangTheme.tertiaryText : ShixiangTheme.violet)
            .disabled(url == nil)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                    if isHidden {
                        Text("已隐藏")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(ShixiangTheme.gold)
                    }
                }
                Text(item.packName + " / " + item.relativePath)
                    .font(.system(size: 8))
                    .foregroundStyle(ShixiangTheme.tertiaryText)
                    .lineLimit(1)
            }
            Spacer()
            if let sound {
                Text(sound.duration.formatted(.number.precision(.fractionLength(2))) + "s")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(ShixiangTheme.tertiaryText)
            }
            Button {
                guard let url else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(ShixiangTheme.secondaryText)
            .disabled(url == nil)
        }
        .padding(.horizontal, 9)
        .frame(height: 38)
        .background(ShixiangTheme.canvas.opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onDrag {
            guard let url else { return NSItemProvider() }
            return SoundDragProvider.itemProvider(for: url)
        }
    }

    private var pendingGroups: [LibraryDuplicateGroup] {
        report.duplicateGroups.filter {
            !library.ignoredDuplicateFingerprints.contains($0.fingerprint)
        }
    }

    private var ignoredGroups: [LibraryDuplicateGroup] {
        report.duplicateGroups.filter {
            library.ignoredDuplicateFingerprints.contains($0.fingerprint)
        }
    }

    private var filteredGroups: [LibraryDuplicateGroup] {
        let source = showsIgnored ? report.duplicateGroups : pendingGroups
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return source }
        return source.filter { group in
            group.items.contains { item in
                item.displayName.localizedCaseInsensitiveContains(term)
                    || item.packName.localizedCaseInsensitiveContains(term)
                    || item.relativePath.localizedCaseInsensitiveContains(term)
            }
        }
    }

    private var visibleGroups: [LibraryDuplicateGroup] {
        Array(filteredGroups.prefix(visibleLimit))
    }

    private func selectedKeepID(in group: LibraryDuplicateGroup) -> UUID {
        if let selected = keepSoundByFingerprint[group.fingerprint],
           group.items.contains(where: { $0.id == selected }) {
            return selected
        }
        return group.items.first(where: { library.sound(id: $0.id)?.isHidden != true })?.id
            ?? group.items[0].id
    }

    private func metric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value.formatted(.number))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(ShixiangTheme.primaryText)
            Text(title)
                .font(.system(size: 8))
                .foregroundStyle(ShixiangTheme.tertiaryText)
        }
        .frame(minWidth: 54)
    }

    private var emptyTitle: String {
        query.isEmpty ? "没有待处理的重复组" : "没有匹配的重复组"
    }

    private var emptyDescription: String {
        query.isEmpty ? "所有重复组都已忽略，或当前素材库没有疑似重复。" : "换一个文件名、音效包或目录关键词试试。"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
