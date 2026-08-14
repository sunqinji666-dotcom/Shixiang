import AppKit
import SwiftUI

struct FinalCutDeliveryCheckView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: AudioPlayerController
    @Environment(\.dismiss) private var dismiss

    let item: SoundItem?

    @State private var report: FinalCutDeliveryReport?
    @State private var errorMessage: String?
    @State private var isChecking = false
    @State private var diagnosticsTask: Task<Void, Never>?
    @State private var usesABRange = true
    @State private var manualResult: ManualResult?
    @AppStorage("shixiang.fcpSmoke.lastPassedBuild") private var lastPassedBuild = ""
    @AppStorage("shixiang.fcpSmoke.lastPassedAt") private var lastPassedAt = 0.0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(ShixiangTheme.hairline)

            if let item, let fileURL {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        sourceCard(item: item, fileURL: fileURL)
                        diagnosticsCard
                        dragTestCard(fileURL: fileURL)
                        manualResultCard
                    }
                    .padding(18)
                }
            } else {
                ContentUnavailableView(
                    "先选择一个声音",
                    systemImage: "waveform.badge.exclamationmark",
                    description: Text("回到主列表选择声音后，再打开 Final Cut Pro 交付诊断。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 590, idealHeight: 660)
        .background(ShixiangTheme.workspaceGradient)
        .task(id: fileURL) { runDiagnostics() }
        .onDisappear { diagnosticsTask?.cancel() }
    }

    private var fileURL: URL? {
        item.flatMap { library.url(for: $0) }
    }

    private var activeABRange: ClosedRange<TimeInterval>? {
        guard player.currentItemID == item?.id,
              let start = player.loopStart,
              let end = player.loopEnd,
              end > start + 0.05 else {
            return nil
        }
        return start...end
    }

    private var deliveryRange: ClosedRange<TimeInterval>? {
        usesABRange ? activeABRange : nil
    }

    private var header: some View {
        HStack(spacing: 12) {
            ShixiangIconBadge(systemImage: "film.stack", size: 34, tint: ShixiangTheme.violet)
            VStack(alignment: .leading, spacing: 2) {
                Text("Final Cut Pro 交付诊断")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ShixiangTheme.primaryText)
                Text("先验证文件与拖拽表示，再用真实时间线完成最后一步")
                    .font(.system(size: 10))
                    .foregroundStyle(ShixiangTheme.tertiaryText)
            }
            Spacer()
            if let report {
                Label(
                    report.isReady ? "自动检查通过" : "需要处理",
                    systemImage: report.isReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                )
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(report.isReady ? ShixiangTheme.gold : .orange)
            }
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(ShixiangRoundButtonStyle(size: 28))
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
        .background(ShixiangTheme.surface.opacity(0.95))
    }

    private func sourceCard(item: SoundItem, fileURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("当前交付源", systemImage: "waveform")
                .font(.system(size: 12, weight: .semibold))
            HStack(spacing: 11) {
                ShixiangIconBadge(systemImage: "music.note", size: 34, tint: ShixiangTheme.gold)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(fileURL.path)
                        .font(.system(size: 8))
                        .foregroundStyle(ShixiangTheme.tertiaryText)
                        .lineLimit(1)
                }
                Spacer()
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
                .buttonStyle(ShixiangCommandButtonStyle())
            }
        }
        .healthCardStyle()
    }

    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("自动交付检查", systemImage: "checklist")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("重新检查") { runDiagnostics() }
                    .buttonStyle(ShixiangCommandButtonStyle())
                    .disabled(isChecking || fileURL == nil)
            }

            if isChecking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(ShixiangTheme.gold)
                    Text("正在读取音频容器、声道和拖拽表示…")
                        .font(.system(size: 10))
                        .foregroundStyle(ShixiangTheme.secondaryText)
                }
                .frame(height: 34)
            } else if let report {
                VStack(spacing: 6) {
                    ForEach(report.checks) { check in
                        HStack(spacing: 9) {
                            Image(systemName: icon(for: check.state))
                                .foregroundStyle(color(for: check.state))
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(check.title)
                                    .font(.system(size: 10, weight: .semibold))
                                Text(check.detail)
                                    .font(.system(size: 8))
                                    .foregroundStyle(ShixiangTheme.tertiaryText)
                                    .lineLimit(2)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 9)
                        .frame(minHeight: 39)
                        .background(ShixiangTheme.canvas.opacity(0.42))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
        .healthCardStyle()
    }

    private func dragTestCard(fileURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("真实时间线拖拽", systemImage: "hand.draw")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if let range = activeABRange {
                    Toggle(
                        "使用 A/B \(formatTime(range.lowerBound))–\(formatTime(range.upperBound))",
                        isOn: $usesABRange
                    )
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 9, weight: .medium))
                }
            }

            HStack(spacing: 14) {
                VStack(spacing: 6) {
                    ShixiangIconBadge(systemImage: "music.note", size: 44, tint: ShixiangTheme.violet)
                    Text(deliveryRange == nil ? "拖动原文件" : "拖动 A/B 片段")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(ShixiangTheme.gold)
                }
                .frame(width: 112, height: 82)
                .background(ShixiangTheme.canvas.opacity(0.58))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(ShixiangTheme.violet.opacity(0.28), lineWidth: 1)
                }
                .onDrag {
                    SoundDragProvider.itemProvider(for: fileURL, timeRange: deliveryRange)
                }
                .help("按住并拖到 Final Cut Pro 时间线")

                VStack(alignment: .leading, spacing: 5) {
                    Text("1. 打开 Final Cut Pro 的空白项目")
                    Text("2. 从左侧音乐图标拖入时间线")
                    Text("3. 核对文件名、时长和声音是否正确")
                    Text("4. 回到这里记录结果")
                }
                .font(.system(size: 9))
                .foregroundStyle(ShixiangTheme.secondaryText)
                Spacer()
            }
        }
        .healthCardStyle()
    }

    private var manualResultCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("人工烟测记录", systemImage: "checkmark.seal")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if lastPassedAt > 0 {
                    Text("最近通过：\(Date(timeIntervalSince1970: lastPassedAt).formatted(date: .abbreviated, time: .shortened)) · \(lastPassedBuild)")
                        .font(.system(size: 8))
                        .foregroundStyle(ShixiangTheme.tertiaryText)
                }
            }
            HStack(spacing: 8) {
                Button("已成功拖入 FCP") {
                    manualResult = .passed
                    lastPassedAt = Date().timeIntervalSince1970
                    lastPassedBuild = currentBuildLabel
                }
                .buttonStyle(ShixiangCommandButtonStyle(isPrimary: true))
                Button("本次失败") { manualResult = .failed }
                    .buttonStyle(ShixiangCommandButtonStyle())
                Spacer()
                if let manualResult {
                    Label(manualResult.title, systemImage: manualResult.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(manualResult == .passed ? ShixiangTheme.gold : .orange)
                }
            }
            Text("只有真实拖入 FCP 时间线后再记录“通过”；自动检查不能替代这一步。记录不包含文件名或路径。")
                .font(.system(size: 8))
                .foregroundStyle(ShixiangTheme.tertiaryText)
        }
        .healthCardStyle()
    }

    private func runDiagnostics() {
        diagnosticsTask?.cancel()
        guard let fileURL else {
            report = nil
            errorMessage = nil
            return
        }
        isChecking = true
        errorMessage = nil
        report = nil
        diagnosticsTask = Task {
            do {
                let result = try await Task.detached(priority: .utility) {
                    try FinalCutDeliveryDiagnostics.inspect(url: fileURL)
                }.value
                guard !Task.isCancelled else { return }
                report = result
                isChecking = false
                diagnosticsTask = nil
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "交付检查失败：\(error.localizedDescription)"
                isChecking = false
                diagnosticsTask = nil
            }
        }
    }

    private func icon(for state: FinalCutDeliveryCheck.State) -> String {
        switch state {
        case .passed: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func color(for state: FinalCutDeliveryCheck.State) -> Color {
        switch state {
        case .passed: return ShixiangTheme.gold
        case .warning: return .orange
        case .failed: return .red
        }
    }

    private func formatTime(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var currentBuildLabel: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "108"
        return "\(marketing) · Build \(build)"
    }
}

private enum ManualResult: Equatable {
    case passed
    case failed

    var title: String { self == .passed ? "本次已记录通过" : "已记录失败，请检查格式或拖拽目标" }
    var icon: String { self == .passed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill" }
}

private extension View {
    func healthCardStyle() -> some View {
        padding(13)
            .background(ShixiangTheme.elevated.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(ShixiangTheme.hairline, lineWidth: 1)
            }
    }
}
