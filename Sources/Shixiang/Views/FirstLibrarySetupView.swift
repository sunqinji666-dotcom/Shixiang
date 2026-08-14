import AppKit
import SwiftUI

enum ShixiangDistributionLinks {
    static let officialWebsiteURL = URL(string: "https://shixiang.jack-sun.com")!

    @MainActor
    static func openOfficialSoundPack() {
        NSWorkspace.shared.open(officialWebsiteURL)
    }
}

enum FirstLibrarySetupPolicy {
    static func shouldPresent(
        hasPresented: Bool,
        isInitialLoadComplete: Bool,
        isDeferredStartupLoading: Bool,
        packCount: Int
    ) -> Bool {
        !hasPresented
            && isInitialLoadComplete
            && !isDeferredStartupLoading
            && packCount == 0
    }
}

struct FirstLibrarySetupView: View {
    let downloadOfficialPack: () -> Void
    let importOwnPack: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(ShixiangRoundButtonStyle(size: 28))
                .help("暂时关闭")
                .accessibilityLabel("关闭音效库引导")
            }
            .padding(.horizontal, 20)
            .frame(height: 54)

            VStack(spacing: 18) {
                soundPackMark

                VStack(spacing: 8) {
                    Text("还没有音效库？先送你一套。")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(ShixiangTheme.primaryText)
                    Text("这套声音资产由作者多年从公开互联网资源与自行购买的专业素材中持续收集、筛选和整理。不是临时拼凑，而是一点一点攒下来的创作家底。")
                        .font(.system(size: 12))
                        .foregroundStyle(ShixiangTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                }

                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("5 万+")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(ShixiangTheme.gold)
                        Text("长期积累的声音素材")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(ShixiangTheme.tertiaryText)
                    }
                    Rectangle()
                        .fill(ShixiangTheme.hairline)
                        .frame(width: 1, height: 42)
                    VStack(alignment: .leading, spacing: 5) {
                        Label("公开互联网资源", systemImage: "globe.asia.australia.fill")
                        Label("作者自行购买积累", systemImage: "cart.fill.badge.plus")
                        Label("长期筛选与人工整理", systemImage: "hands.sparkles.fill")
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ShixiangTheme.secondaryText)
                }
                .padding(.horizontal, 18)
                .frame(height: 76)
                .background(ShixiangTheme.gold.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(ShixiangTheme.gold.opacity(0.2), lineWidth: 1)
                }

                VStack(spacing: 10) {
                    Button(action: downloadOfficialPack) {
                        Label("前往官网领取 5 万+ 附加音效库", systemImage: "safari.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ShixiangCommandButtonStyle(isPrimary: true))
                    .controlSize(.large)

                    Button(action: importOwnPack) {
                        Label("导入我自己的音效包", systemImage: "folder.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ShixiangCommandButtonStyle())
                    .controlSize(.large)
                }
                .frame(maxWidth: 350)

                Text("点击后前往拾响官网查看领取说明\n素材版权归原作者或发行方，具体使用范围以包内来源与授权说明为准")
                    .font(.system(size: 10))
                    .foregroundStyle(ShixiangTheme.tertiaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 38)
            .padding(.bottom, 34)
        }
        .frame(width: 620, height: 570)
        .background(ShixiangTheme.workspaceGradient)
    }

    private var soundPackMark: some View {
        ZStack {
            Circle()
                .fill(ShixiangTheme.violet.opacity(0.13))
                .frame(width: 112, height: 112)
            Circle()
                .stroke(ShixiangTheme.gold.opacity(0.24), lineWidth: 1)
                .frame(width: 92, height: 92)
            ShixiangMark(size: 68)
        }
        .accessibilityHidden(true)
    }
}
