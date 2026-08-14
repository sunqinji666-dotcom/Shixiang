import SwiftUI

struct AcousticAnalysisView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    let currentItems: [SoundItem]
    @State private var currentIndexedCount: Int?

    private var allItemCount: Int {
        library.soundCount
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(ShixiangTheme.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    explanation
                    coverageCard
                    if let progress = library.acousticAnalysisProgress {
                        progressCard(progress)
                    } else {
                        actionCard
                    }
                }
                .padding(18)
            }
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 500, idealHeight: 570)
        .background(ShixiangTheme.workspaceGradient)
        .task { await refreshCurrentCoverage() }
        .onChange(of: library.acousticAnalysisProgress?.id) { oldValue, newValue in
            guard oldValue != nil, newValue == nil else { return }
            Task { await refreshCurrentCoverage() }
        }
        .onChange(of: library.acousticFingerprintCount) { _, _ in
            guard library.acousticAnalysisProgress == nil else { return }
            Task { await refreshCurrentCoverage() }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ShixiangIconBadge(systemImage: "waveform.path.ecg", size: 34, tint: ShixiangTheme.violet)
            VStack(alignment: .leading, spacing: 2) {
                Text("声音理解中心")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ShixiangTheme.primaryText)
                Text("为声音建立不可逆还原的本地音色指纹")
                    .font(.system(size: 10))
                    .foregroundStyle(ShixiangTheme.tertiaryText)
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(ShixiangRoundButtonStyle(size: 28))
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
        .background(ShixiangTheme.surface.opacity(0.95))
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("真正按声音本身寻找相似项", systemImage: "ear.and.waveform")
                .font(.system(size: 13, weight: .semibold))
            Text("拾响会读取频段、明暗、瞬态与动态轮廓，只保存很小的数字向量。不会复制、改名或上传音频。分析以低优先级逐条运行，可随时取消，下次从未完成处继续。")
                .font(.system(size: 10))
                .foregroundStyle(ShixiangTheme.secondaryText)
                .lineSpacing(3)
        }
        .semanticCardStyle()
    }

    private var coverageCard: some View {
        HStack(spacing: 16) {
            coverageValue(
                "全部资料库",
                indexed: library.acousticFingerprintCount,
                total: allItemCount
            )
            Divider().frame(height: 36).overlay(ShixiangTheme.hairline)
            coverageValue("当前结果", indexed: currentIndexedCount, total: currentItems.count)
            Spacer()
        }
        .semanticCardStyle()
    }

    private func coverageValue(_ title: String, indexed: Int?, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(ShixiangTheme.tertiaryText)
            Text(indexed.map { "\($0.formatted(.number)) / \(total.formatted(.number))" } ?? "正在计算")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(ShixiangTheme.gold)
        }
        .frame(minWidth: 130, alignment: .leading)
    }

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择分析范围")
                .font(.system(size: 12, weight: .semibold))
            HStack(spacing: 9) {
                Button {
                    library.startAcousticAnalysis(items: currentItems)
                } label: {
                    Label("分析当前 \(currentItems.count.formatted(.number)) 条", systemImage: "rectangle.stack.badge.play")
                }
                .buttonStyle(ShixiangCommandButtonStyle(isPrimary: true))
                .disabled(currentItems.isEmpty || currentIndexedCount == currentItems.count)

                Button {
                    library.startAcousticAnalysisForEntireLibrary()
                } label: {
                    Label("分析全部资料库", systemImage: "square.stack.3d.up")
                }
                .buttonStyle(ShixiangCommandButtonStyle())
                .disabled(allItemCount == 0 || library.acousticFingerprintCount == allItemCount)
            }
            Text("大资料库建议让拾响在空闲时运行。播放和滚动始终优先，完成的结果会即时保存。")
                .font(.system(size: 9))
                .foregroundStyle(ShixiangTheme.tertiaryText)
        }
        .semanticCardStyle()
    }

    private func progressCard(_ progress: AcousticAnalysisProgress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("正在理解声音")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(progress.completed.formatted(.number)) / \(progress.total.formatted(.number))")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(ShixiangTheme.gold)
            }
            ProgressView(value: progress.fraction)
                .tint(ShixiangTheme.violet)
            Text(progress.currentName ?? "正在准备…")
                .font(.system(size: 9))
                .foregroundStyle(ShixiangTheme.secondaryText)
                .lineLimit(1)
            HStack {
                if progress.failed > 0 {
                    Text("\(progress.failed) 条无法读取")
                        .font(.system(size: 9))
                        .foregroundStyle(ShixiangTheme.tertiaryText)
                }
                Spacer()
                Button("停止并保留已完成结果") { library.cancelAcousticAnalysis() }
                    .buttonStyle(ShixiangCommandButtonStyle())
            }
        }
        .semanticCardStyle()
    }

    @MainActor
    private func refreshCurrentCoverage() async {
        currentIndexedCount = await library.acousticFingerprintCount(in: currentItems)
    }
}

struct AuditionCompareView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: AudioPlayerController
    @Environment(\.dismiss) private var dismiss

    let items: [SoundItem]
    @State private var activeIndex = 0
    @State private var rejectedIDs = Set<UUID>()
    @State private var keptID: UUID?
    @State private var matchesLoudness = true

    private var candidates: [SoundItem] { Array(items.prefix(5)) }
    private var activeItem: SoundItem? {
        guard candidates.indices.contains(activeIndex) else { return nil }
        return candidates[activeIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ShixiangIconBadge(systemImage: "rectangle.3.group.bubble", size: 34, tint: ShixiangTheme.gold)
                VStack(alignment: .leading, spacing: 2) {
                    Text("快速对比试听")
                        .font(.system(size: 17, weight: .semibold))
                    Text("1–5 切换 · Space 播放 · X 淘汰 · F 收藏 · Return 留下")
                        .font(.system(size: 9))
                        .foregroundStyle(ShixiangTheme.tertiaryText)
                }
                Spacer()
                Toggle("响度拉齐", isOn: $matchesLoudness)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Button { close() } label: { Image(systemName: "xmark") }
                    .buttonStyle(ShixiangRoundButtonStyle(size: 28))
            }
            .padding(.horizontal, 18)
            .frame(height: 66)
            .background(ShixiangTheme.surface.opacity(0.96))

            Divider().overlay(ShixiangTheme.hairline)

            VStack(spacing: 8) {
                ForEach(Array(candidates.enumerated()), id: \.element.id) { index, item in
                    candidateRow(item, index: index)
                }
            }
            .padding(16)

            Divider().overlay(ShixiangTheme.hairline)
            HStack(spacing: 8) {
                Button("上一条") { move(-1) }
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button(player.isPlaying ? "暂停" : "播放") { toggleActive() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("下一条") { move(1) }
                    .keyboardShortcut(.downArrow, modifiers: [])
                Divider().frame(height: 22)
                Button("淘汰") { rejectActive() }
                    .keyboardShortcut("x", modifiers: [])
                Button("收藏") { favoriteActive() }
                    .keyboardShortcut("f", modifiers: [])
                Spacer()
                if let keptID, let item = candidates.first(where: { $0.id == keptID }) {
                    Text("已留下：\(item.displayName)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(ShixiangTheme.gold)
                        .lineLimit(1)
                }
                Button("留下当前") { keepActive() }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(ShixiangCommandButtonStyle(isPrimary: true))
            }
            .buttonStyle(ShixiangCommandButtonStyle())
            .padding(.horizontal, 16)
            .frame(height: 60)
            .background(ShixiangTheme.surface.opacity(0.96))
        }
        .frame(minWidth: 760, idealWidth: 880, minHeight: 430, idealHeight: 500)
        .background(ShixiangTheme.workspaceGradient)
        .onAppear { playActive() }
        .onChange(of: matchesLoudness) { _, _ in playActive() }
        .onDisappear { player.resetComparisonVolume() }
    }

    private func candidateRow(_ item: SoundItem, index: Int) -> some View {
        let isActive = index == activeIndex
        let isRejected = rejectedIDs.contains(item.id)
        let url = library.url(for: item)
        return Button {
            activeIndex = index
            playActive()
        } label: {
            HStack(spacing: 10) {
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(isActive ? ShixiangTheme.canvas : ShixiangTheme.gold)
                    .frame(width: 24, height: 24)
                    .background(isActive ? ShixiangTheme.gold : ShixiangTheme.gold.opacity(0.10))
                    .clipShape(Circle())
                Image(systemName: player.currentItemID == item.id && player.isPlaying ? "speaker.wave.2.fill" : "waveform")
                    .foregroundStyle(isActive ? ShixiangTheme.violet : ShixiangTheme.tertiaryText)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(item.relativePath)
                        .font(.system(size: 8))
                        .foregroundStyle(ShixiangTheme.tertiaryText)
                        .lineLimit(1)
                }
                Spacer()
                if library.sound(id: item.id)?.isFavorite ?? item.isFavorite {
                    Image(systemName: "star.fill").foregroundStyle(ShixiangTheme.gold)
                }
                if keptID == item.id { Label("留下", systemImage: "checkmark.circle.fill").foregroundStyle(ShixiangTheme.gold) }
                if isRejected { Label("淘汰", systemImage: "xmark.circle.fill").foregroundStyle(ShixiangTheme.tertiaryText) }
                Text(item.duration.shixiangTimecode)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(ShixiangTheme.tertiaryText)
            }
            .padding(.horizontal, 11)
            .frame(height: 55)
            .background(isActive ? ShixiangTheme.selectedSurface.opacity(0.72) : ShixiangTheme.elevated.opacity(0.58))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(isRejected ? 0.48 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrag {
            guard let url else { return NSItemProvider() }
            return SoundDragProvider.itemProvider(for: url)
        }
    }

    private func move(_ offset: Int) {
        guard !candidates.isEmpty else { return }
        var next = activeIndex
        for _ in 0..<candidates.count {
            next = (next + offset + candidates.count) % candidates.count
            if !rejectedIDs.contains(candidates[next].id) { break }
        }
        activeIndex = next
        playActive()
    }

    private func toggleActive() {
        guard let item = activeItem, let url = library.url(for: item) else { return }
        if player.currentItemID == item.id { player.togglePlayback() }
        else { playActive(url: url, item: item) }
    }

    private func playActive() {
        guard let item = activeItem, let url = library.url(for: item) else { return }
        playActive(url: url, item: item)
    }

    private func playActive(url: URL, item: SoundItem) {
        player.play(
            item: item,
            url: url,
            volumeMultiplier: matchesLoudness ? comparisonGain(for: item) : 1
        )
    }

    private func comparisonGain(for item: SoundItem) -> Float {
        let loudnessValues = candidates.compactMap { library.intelligence(for: $0.id)?.loudnessLUFS }
        guard let itemLUFS = library.intelligence(for: item.id)?.loudnessLUFS,
              let quietest = loudnessValues.min() else { return 1 }
        return Float(min(1, max(0.28, pow(10, (quietest - itemLUFS) / 20))))
    }

    private func rejectActive() {
        guard let item = activeItem else { return }
        rejectedIDs.insert(item.id)
        if keptID == item.id { keptID = nil }
        move(1)
    }

    private func favoriteActive() {
        guard let item = activeItem else { return }
        library.toggleFavorite(item)
    }

    private func keepActive() {
        guard let item = activeItem else { return }
        keptID = item.id
        rejectedIDs.remove(item.id)
        library.selectAndRevealSound(item.id)
    }

    private func close() {
        player.resetComparisonVolume()
        dismiss()
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
