import AppKit
import SwiftUI

struct LibraryHealthView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: AudioPlayerController
    @Environment(\.dismiss) private var dismiss

    @State private var report: LibraryHealthReport?
    @State private var isChecking = false
    @State private var errorMessage: String?
    @State private var inspectionTask: Task<Void, Never>?
    @State private var inspectionProgress: LibraryHealthProgress?
    @State private var inspectionID = UUID()
    @State private var isDuplicateReviewPresented = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(ShixiangTheme.hairline)

            if isChecking && report == nil {
                checkingPlaceholder
            } else if let report {
                VStack(spacing: 0) {
                    if isChecking { checkingStrip }
                    reportContent(report)
                }
            } else if let errorMessage {
                ContentUnavailableView(
                    "体检没有完成",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            }
        }
        .frame(minWidth: 720, idealWidth: 800, minHeight: 590, idealHeight: 680)
        .background(ShixiangTheme.workspaceGradient)
        .task { runInspection() }
        .onDisappear { inspectionTask?.cancel() }
        .onChange(of: library.libraryRevision) { _, _ in
            runInspection()
        }
        .sheet(isPresented: $isDuplicateReviewPresented) {
            if let report {
                DuplicateReviewView(report: report)
                    .environmentObject(library)
                    .environmentObject(player)
            }
        }
        .alert(
            "拾响",
            isPresented: Binding(
                get: { library.alertMessage != nil },
                set: { if !$0 { library.alertMessage = nil } }
            )
        ) {
            Button("知道了") { library.alertMessage = nil }
        } message: {
            Text(library.alertMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ShixiangIconBadge(systemImage: "stethoscope", size: 34, tint: ShixiangTheme.gold)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("素材库体检")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ShixiangTheme.primaryText)
                Text("只读检查原素材 · 不自动删除或改名")
                    .font(.system(size: 10))
                    .foregroundStyle(ShixiangTheme.tertiaryText)
            }
            Spacer()
            Button(action: runInspection) {
                Label(isChecking ? "检查中" : "重新检查", systemImage: "arrow.clockwise")
            }
            .buttonStyle(ShixiangCommandButtonStyle())
            .disabled(isChecking)
            if isChecking {
                Button("取消") { inspectionTask?.cancel() }
                    .buttonStyle(ShixiangCommandButtonStyle())
            }
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(ShixiangRoundButtonStyle(size: 28))
        }
        .padding(.horizontal, 18)
        .frame(height: 62)
        .background(ShixiangTheme.surface.opacity(0.95))
    }

    private var checkingPlaceholder: some View {
        VStack(spacing: 14) {
            if let fraction = inspectionProgress?.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 260)
                    .tint(ShixiangTheme.gold)
            } else {
                ProgressView().controlSize(.regular).tint(ShixiangTheme.gold)
            }
            Text(inspectionProgress?.phase.title ?? "正在核对文件、疑似重复项与本地缓存…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ShixiangTheme.secondaryText)
            if let inspectionProgress, inspectionProgress.total > 0 {
                Text("\(inspectionProgress.completed.formatted(.number)) / \(inspectionProgress.total.formatted(.number))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(ShixiangTheme.tertiaryText)
            }
            Text("大型素材库第一次检查可能需要一点时间，播放与搜索仍可继续使用。")
                .font(.system(size: 10))
                .foregroundStyle(ShixiangTheme.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var checkingStrip: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(ShixiangTheme.gold)
            Text(inspectionProgress?.phase.title ?? "正在重新检查")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ShixiangTheme.secondaryText)
            Spacer()
            if let inspectionProgress, inspectionProgress.total > 0 {
                Text("\(inspectionProgress.completed.formatted(.number)) / \(inspectionProgress.total.formatted(.number))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(ShixiangTheme.tertiaryText)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 32)
        .background(ShixiangTheme.gold.opacity(0.07))
    }

    private func reportContent(_ report: LibraryHealthReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                    spacing: 10
                ) {
                    HealthMetric(title: "已检查", value: report.totalCount.formatted(.number), icon: "waveform")
                    HealthMetric(
                        title: "缺失文件",
                        value: report.missingItems.count.formatted(.number),
                        icon: "questionmark.folder",
                        warns: !report.missingItems.isEmpty
                    )
                    HealthMetric(
                        title: "疑似重复",
                        value: report.probableDuplicateCount.formatted(.number),
                        icon: "square.on.square",
                        warns: report.probableDuplicateCount > 0
                    )
                    HealthMetric(
                        title: "波形缓存",
                        value: formatBytes(report.waveformCacheBytes),
                        icon: "externaldrive"
                    )
                }

                if !report.inaccessiblePacks.isEmpty {
                    healthSection(title: "需要重新定位", icon: "externaldrive.badge.exclamationmark") {
                        VStack(spacing: 8) {
                            ForEach(report.inaccessiblePacks) { pack in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(pack.name).font(.system(size: 11, weight: .semibold))
                                        Text(pack.rootURL.path)
                                            .font(.system(size: 9))
                                            .foregroundStyle(ShixiangTheme.tertiaryText)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Button("重新定位") { library.relinkPackWithPanel(pack.id) }
                                        .buttonStyle(ShixiangCommandButtonStyle(isPrimary: true))
                                }
                            }
                        }
                    }
                }

                healthSection(title: "本地数据库", icon: "cylinder.split.1x2") {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("SQLite 索引  \(formatBytes(report.databaseBytes))")
                                .font(.system(size: 11, weight: .semibold))
                            Label(
                                report.hasRecoveryBackup ? "恢复备份正常" : "下一次结构保存时生成恢复备份",
                                systemImage: report.hasRecoveryBackup ? "checkmark.shield.fill" : "shield"
                            )
                            .font(.system(size: 9))
                            .foregroundStyle(report.hasRecoveryBackup ? ShixiangTheme.gold : ShixiangTheme.secondaryText)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 7) {
                            Text("别名、标签与收藏只保存在拾响，不写入原音频")
                                .font(.system(size: 9))
                                .foregroundStyle(ShixiangTheme.tertiaryText)
                            HStack(spacing: 8) {
                                Button("导出备份") {
                                    library.exportRecoverySnapshotWithPanel()
                                }
                                .buttonStyle(ShixiangCommandButtonStyle(isPrimary: true))
                                .disabled(library.isRecoveryTransferInProgress)
                                Button("导入备份") {
                                    library.importRecoverySnapshotWithPanel(player: player)
                                }
                                .buttonStyle(ShixiangCommandButtonStyle())
                                .disabled(library.isRecoveryTransferInProgress)
                            }
                            if library.isRecoveryTransferInProgress {
                                Label("正在后台处理资料库备份…", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(ShixiangTheme.gold)
                            }
                        }
                    }
                }

                healthSection(title: "缓存维护", icon: "waveform.path") {
                    HStack {
                        Text("波形缓存可随时重建，清理不会影响任何原音频。")
                            .font(.system(size: 10))
                            .foregroundStyle(ShixiangTheme.secondaryText)
                        Spacer()
                        Button("清理波形缓存") { clearWaveformCache() }
                            .buttonStyle(ShixiangCommandButtonStyle())
                            .disabled(isChecking || report.waveformCacheBytes == 0)
                    }
                }

                if !report.missingItems.isEmpty {
                    healthSection(
                        title: "缺失文件（\(report.missingItems.count.formatted(.number))）",
                        icon: "questionmark.folder"
                    ) {
                        VStack(spacing: 10) {
                            ForEach(missingGroups(report), id: \.packID) { group in
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack(spacing: 8) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(group.packName)
                                                .font(.system(size: 11, weight: .semibold))
                                            Text("缺失 \(group.items.count.formatted(.number)) 项")
                                                .font(.system(size: 9))
                                                .foregroundStyle(ShixiangTheme.tertiaryText)
                                        }
                                        Spacer()
                                        if report.inaccessiblePacks.contains(where: { $0.id == group.packID }) {
                                            Button("重新定位") {
                                                library.relinkPackWithPanel(group.packID)
                                            }
                                            .buttonStyle(ShixiangCommandButtonStyle(isPrimary: true))
                                        } else {
                                            Button("增量刷新") {
                                                library.startRefreshPack(group.packID)
                                            }
                                            .buttonStyle(ShixiangCommandButtonStyle(isPrimary: true))
                                        }
                                    }
                                    ForEach(group.items.prefix(12)) { item in
                                        HealthFileRow(item: item, isMissing: true)
                                    }
                                    if group.items.count > 12 {
                                        Text("另有 \((group.items.count - 12).formatted(.number)) 项未展开；刷新后会从索引中准确更新。")
                                            .font(.system(size: 9))
                                            .foregroundStyle(ShixiangTheme.tertiaryText)
                                    }
                                }
                                .padding(10)
                                .background(ShixiangTheme.canvas.opacity(0.46))
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }
                        }
                    }
                }

                if !report.duplicateGroups.isEmpty {
                    healthSection(
                        title: "疑似重复组（\(report.duplicateGroups.count.formatted(.number))）",
                        icon: "square.on.square"
                    ) {
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("待处理 \(pendingDuplicateGroupCount(report).formatted(.number)) 组 · 已忽略 \(ignoredDuplicateGroupCount(report).formatted(.number)) 组")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(ShixiangTheme.primaryText)
                                Text("本次复用 \(report.reusedFingerprintCount.formatted(.number)) 个缓存指纹，减少重复读取音频。")
                                    .font(.system(size: 9))
                                    .foregroundStyle(ShixiangTheme.tertiaryText)
                            }
                            Spacer()
                            Button("打开处理中心") {
                                isDuplicateReviewPresented = true
                            }
                            .buttonStyle(ShixiangCommandButtonStyle(isPrimary: true))
                        }
                    }
                }

                if report.missingItems.isEmpty && report.inaccessiblePacks.isEmpty {
                    Label("素材路径完整，资料库连接正常", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ShixiangTheme.gold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
            .padding(18)
        }
    }

    private func healthSection<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ShixiangTheme.primaryText)
            content()
        }
        .padding(13)
        .background(ShixiangTheme.elevated.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ShixiangTheme.hairline, lineWidth: 1)
        }
    }

    private func runInspection() {
        inspectionTask?.cancel()
        let currentInspectionID = UUID()
        inspectionID = currentInspectionID
        isChecking = true
        inspectionProgress = nil
        errorMessage = nil
        inspectionTask = Task {
            do {
                let snapshot = try await library.healthSnapshot()
                guard !Task.isCancelled, inspectionID == currentInspectionID else { return }
                let newReport = try await LibraryHealthService.inspect(snapshot) { progress in
                    Task { @MainActor in
                        guard inspectionID == currentInspectionID else { return }
                        inspectionProgress = progress
                    }
                }
                guard !Task.isCancelled, inspectionID == currentInspectionID else { return }
                report = newReport
                isChecking = false
                inspectionProgress = nil
            } catch is CancellationError {
                guard inspectionID == currentInspectionID else { return }
                isChecking = false
                inspectionProgress = nil
                return
            } catch {
                guard inspectionID == currentInspectionID else { return }
                errorMessage = error.localizedDescription
                isChecking = false
                inspectionProgress = nil
            }
        }
    }

    private func missingGroups(_ report: LibraryHealthReport) -> [MissingFileGroup] {
        Dictionary(grouping: report.missingItems, by: \.packID)
            .compactMap { packID, items in
                guard let packName = items.first?.packName else { return nil }
                return MissingFileGroup(packID: packID, packName: packName, items: items)
            }
            .sorted { $0.packName.localizedStandardCompare($1.packName) == .orderedAscending }
    }

    private func pendingDuplicateGroupCount(_ report: LibraryHealthReport) -> Int {
        report.duplicateGroups.lazy.filter {
            !library.ignoredDuplicateFingerprints.contains($0.fingerprint)
        }.count
    }

    private func ignoredDuplicateGroupCount(_ report: LibraryHealthReport) -> Int {
        report.duplicateGroups.lazy.filter {
            library.ignoredDuplicateFingerprints.contains($0.fingerprint)
        }.count
    }

    private func clearWaveformCache() {
        isChecking = true
        Task {
            await WaveformCacheMaintenance.clear()
            runInspection()
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct MissingFileGroup {
    let packID: UUID
    let packName: String
    let items: [LibraryHealthItem]
}

private struct HealthMetric: View {
    let title: String
    let value: String
    let icon: String
    var warns = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(warns ? ShixiangTheme.gold : ShixiangTheme.violet)
                .accessibilityHidden(true)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(ShixiangTheme.primaryText)
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(ShixiangTheme.tertiaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(ShixiangTheme.elevated.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(warns ? ShixiangTheme.gold.opacity(0.32) : ShixiangTheme.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityHint(warns ? "需要关注" : "")
    }
}

private struct HealthFileRow: View {
    let item: LibraryHealthItem
    let isMissing: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: isMissing ? "questionmark.circle" : "waveform")
                .foregroundStyle(isMissing ? ShixiangTheme.gold : ShixiangTheme.secondaryText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                Text(item.packName + " / " + item.relativePath)
                    .font(.system(size: 8))
                    .foregroundStyle(ShixiangTheme.tertiaryText)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isMissing ? "缺失文件：\(item.displayName)" : item.displayName)
            .accessibilityValue(item.packName + " / " + item.relativePath)
            Spacer()
            if !isMissing {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                } label: {
                    Image(systemName: "arrow.forward.square")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("在访达中显示 \(item.displayName)")
                .help("在访达中显示")
            }
        }
        .frame(minHeight: 28)
    }
}
