import AppKit
import SwiftUI

struct CreatorOnboardingView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ShixiangIconBadge(systemImage: "sparkles", size: 38, tint: ShixiangTheme.gold)
                VStack(alignment: .leading, spacing: 3) {
                    Text("把声音放回创作的节奏里")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(ShixiangTheme.primaryText)
                    Text("拾响本地版快速上手")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ShixiangTheme.tertiaryText)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(ShixiangRoundButtonStyle(size: 28))
            }
            .padding(.horizontal, 22)
            .frame(height: 72)
            .background(ShixiangTheme.surface.opacity(0.96))

            Divider().overlay(ShixiangTheme.hairline)

            HStack(alignment: .top, spacing: 12) {
                guideCard(
                    number: "01",
                    title: "导入完整文件夹",
                    text: "原目录与文件名保持不变。拾响只建立本地索引，移动硬盘也可以随时重新定位。",
                    icon: "folder.badge.plus"
                )
                guideCard(
                    number: "02",
                    title: "高速试听与整理",
                    text: "点击波形立即试听，J / K / L 控制进度，F 收藏；批量模式可以一次收藏或添加标签。",
                    icon: "waveform.badge.magnifyingglass"
                )
                guideCard(
                    number: "03",
                    title: "拖入 Final Cut Pro",
                    text: "拖住列表左侧图标或底部播放器卡片，直接放进时间线；原音频始终只读。",
                    icon: "film.stack"
                )
            }
            .padding(22)

            VStack(alignment: .leading, spacing: 10) {
                Text("常用快捷键")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ShixiangTheme.secondaryText)
                HStack(spacing: 8) {
                    shortcut("↑ / ↓", "选择")
                    shortcut("Space / K", "播放暂停")
                    shortcut("J / L", "前后 5 秒")
                    shortcut("F", "收藏")
                    shortcut("⌘F", "搜索")
                    shortcut("⌘R", "增量刷新")
                    shortcut("⌘⇧H", "资料库体检")
                }
            }
            .padding(.horizontal, 22)

            Spacer(minLength: 20)

            HStack {
                Label("音频、路径、标签和分析结果都留在本机", systemImage: "lock.shield.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(ShixiangTheme.tertiaryText)
                Spacer()
                Button {
                    ShixiangDistributionLinks.openOfficialSoundPack()
                } label: {
                    Label("领取 5 万+ 音效库", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(ShixiangCommandButtonStyle(isActive: true))
                .help("没有音效包时，前往拾响官网查看领取与导入说明")
                Button("稍后再说") { dismiss() }
                    .buttonStyle(ShixiangCommandButtonStyle())
                Button {
                    dismiss()
                    Task { @MainActor in
                        await Task.yield()
                        library.importPackWithPanel()
                    }
                } label: {
                    Label("导入音效包", systemImage: "folder.badge.plus")
                }
                .buttonStyle(ShixiangCommandButtonStyle(isPrimary: true))
            }
            .padding(.horizontal, 22)
            .frame(height: 66)
            .background(ShixiangTheme.surface.opacity(0.82))
        }
        .frame(width: 760, height: 500)
        .background(ShixiangTheme.workspaceGradient)
    }

    private func guideCard(
        number: String,
        title: String,
        text: String,
        icon: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(ShixiangTheme.gold)
                Spacer()
                Text(number)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(ShixiangTheme.violet)
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ShixiangTheme.primaryText)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(ShixiangTheme.secondaryText)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .padding(14)
        .background(ShixiangTheme.elevated.opacity(0.76))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(ShixiangTheme.hairline, lineWidth: 1)
        }
    }

    private func shortcut(_ keys: String, _ title: String) -> some View {
        VStack(spacing: 5) {
            Text(keys)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(ShixiangTheme.primaryText)
            Text(title)
                .font(.system(size: 8))
                .foregroundStyle(ShixiangTheme.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(ShixiangTheme.canvas.opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
