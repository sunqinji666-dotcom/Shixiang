import SwiftUI

struct SimilarSoundsView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: AudioPlayerController
    @Environment(\.dismiss) private var dismiss

    let item: SoundItem?

    @State private var matches: [SoundSimilarityMatch] = []
    @State private var isLoading = false
    @State private var visibleLimit = 120
    @State private var isComparePresented = false
    @State private var isAcousticAnalysisPresented = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(ShixiangTheme.hairline)

            if let item {
                if isLoading {
                    loadingView
                } else if matches.isEmpty {
                    ContentUnavailableView(
                        "暂时没有可靠的相关声音",
                        systemImage: "waveform.badge.magnifyingglass",
                        description: Text("拾响只显示达到本地特征阈值的结果，避免用大量弱相关声音淹没你。")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            sourceCard(item)
                            matchSection(
                                title: "同系列变体",
                                subtitle: "根据同目录基础命名、编号、远近和强弱识别",
                                values: visibleMatches.filter(\.isSameFamily)
                            )
                            matchSection(
                                title: "相关声音",
                                subtitle: "结合真实音色、中英语义、时长、节奏与调性排序",
                                values: visibleMatches.filter { !$0.isSameFamily }
                            )
                            if matches.count > visibleLimit {
                                Button("再显示 \(min(120, matches.count - visibleLimit)) 个") {
                                    visibleLimit += 120
                                }
                                .buttonStyle(ShixiangCommandButtonStyle())
                                .padding(.vertical, 8)
                            }
                        }
                        .padding(16)
                    }
                }
            } else {
                ContentUnavailableView(
                    "先选择一个声音",
                    systemImage: "waveform",
                    description: Text("回到列表选择声音后，再打开相似声音与变体。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 820, idealWidth: 920, minHeight: 620, idealHeight: 720)
        .background(ShixiangTheme.workspaceGradient)
        .task(id: item?.id) { await loadMatches() }
        .sheet(isPresented: $isComparePresented) {
            AuditionCompareView(items: Array(matches.prefix(5).map(\.item)))
                .environmentObject(library)
                .environmentObject(player)
        }
        .sheet(isPresented: $isAcousticAnalysisPresented) {
            AcousticAnalysisView(currentItems: Array(matches.prefix(120).map(\.item)))
                .environmentObject(library)
        }
        .onChange(of: library.acousticAnalysisProgress?.id) { oldValue, newValue in
            if oldValue != nil, newValue == nil {
                Task { await loadMatches() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ShixiangIconBadge(systemImage: "waveform.path.ecg", size: 34, tint: ShixiangTheme.violet)
            VStack(alignment: .leading, spacing: 2) {
                Text("相似声音与变体")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ShixiangTheme.primaryText)
                Text("同系列、语义与真实音色共同排序")
                    .font(.system(size: 10))
                    .foregroundStyle(ShixiangTheme.tertiaryText)
            }
            Spacer()
            if !matches.isEmpty {
                Button {
                    isAcousticAnalysisPresented = true
                } label: {
                    Label("音色指纹", systemImage: "waveform.path.ecg")
                }
                .buttonStyle(ShixiangCommandButtonStyle())
                .help("为当前候选建立本地音色指纹")
                Button {
                    isComparePresented = true
                } label: {
                    Label("快速对比", systemImage: "rectangle.3.group.bubble")
                }
                .buttonStyle(ShixiangCommandButtonStyle(isPrimary: true))
            }
            if !matches.isEmpty {
                Text("\(matches.count.formatted(.number)) 个候选")
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

    private var loadingView: some View {
        VStack(spacing: 13) {
            ProgressView(value: library.semanticIndexProgress?.fraction)
                .controlSize(.small)
                .tint(ShixiangTheme.gold)
            Text(library.semanticIndexProgress.map {
                "正在建立本地声音索引 \($0.completed.formatted(.number)) / \($0.total.formatted(.number))"
            } ?? "正在比较声音特征…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ShixiangTheme.secondaryText)
            Text("只读取拾响已有索引，不上传音频。")
                .font(.system(size: 9))
                .foregroundStyle(ShixiangTheme.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sourceCard(_ item: SoundItem) -> some View {
        HStack(spacing: 11) {
            ShixiangIconBadge(systemImage: "scope", size: 34, tint: ShixiangTheme.gold)
            VStack(alignment: .leading, spacing: 3) {
                Text("以此声音为中心")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(ShixiangTheme.tertiaryText)
                Text(item.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(item.relativePath)
                    .font(.system(size: 8))
                    .foregroundStyle(ShixiangTheme.tertiaryText)
                    .lineLimit(1)
            }
            Spacer()
        }
        .semanticCardStyle()
    }

    @ViewBuilder
    private func matchSection(
        title: String,
        subtitle: String,
        values: [SoundSimilarityMatch]
    ) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                        Text(subtitle)
                            .font(.system(size: 8))
                            .foregroundStyle(ShixiangTheme.tertiaryText)
                    }
                    Spacer()
                    Text(values.count.formatted(.number))
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(ShixiangTheme.secondaryText)
                }
                ForEach(values) { match in
                    matchRow(match)
                }
            }
            .semanticCardStyle()
        }
    }

    private func matchRow(_ match: SoundSimilarityMatch) -> some View {
        let url = library.url(for: match.item)
        let isPlaying = player.currentItemID == match.id && player.isPlaying
        return HStack(spacing: 10) {
            Button {
                guard let url else { return }
                player.togglePlayback(item: match.item, url: url)
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(ShixiangTheme.violet)
            .disabled(url == nil)

            VStack(alignment: .leading, spacing: 3) {
                Text(match.item.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    ForEach(match.reasons, id: \.self) { reason in
                        Text(reason)
                            .font(.system(size: 7, weight: .medium))
                            .foregroundStyle(ShixiangTheme.secondaryText)
                            .padding(.horizontal, 5)
                            .frame(height: 16)
                            .background(ShixiangTheme.elevated)
                            .clipShape(Capsule())
                    }
                }
            }
            Spacer()
            Text("\(Int(match.score.rounded()))%")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(match.isSameFamily ? ShixiangTheme.gold : ShixiangTheme.secondaryText)
                .frame(width: 34, alignment: .trailing)
            Text(match.item.duration.formatted(.number.precision(.fractionLength(2))) + "s")
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(ShixiangTheme.tertiaryText)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 9)
        .frame(height: 42)
        .background(ShixiangTheme.canvas.opacity(0.46))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onDrag {
            guard let url else { return NSItemProvider() }
            return SoundDragProvider.itemProvider(for: url)
        }
    }

    private var visibleMatches: [SoundSimilarityMatch] {
        Array(matches.prefix(visibleLimit))
    }

    @MainActor
    private func loadMatches() async {
        guard let item else {
            matches = []
            return
        }
        isLoading = true
        matches = await library.similarSounds(to: item)
        guard !Task.isCancelled else { return }
        isLoading = false
    }
}

private extension View {
    func semanticCardStyle() -> some View {
        padding(12)
            .background(ShixiangTheme.elevated.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(ShixiangTheme.hairline, lineWidth: 1)
            }
    }
}
