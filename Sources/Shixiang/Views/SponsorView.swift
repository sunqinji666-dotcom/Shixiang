import AppKit
import SwiftUI

enum SponsorCoinLifecycle {
    static let maximumClicks = 6
    static let preferenceKey = "shixiang.sponsorCoin.clickCount.v1"

    // Keep the fifth-click coin large enough to find at the same location, then let the sixth
    // click complete the disappearance. The button's layout slot remains stable throughout.
    private static let scales: [CGFloat] = [1.0, 0.90, 0.78, 0.65, 0.50, 0.32, 0]

    static func scale(after clickCount: Int) -> CGFloat {
        scales[min(max(clickCount, 0), maximumClicks)]
    }
}

struct SponsorCoinIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var size: CGFloat = 30
    var isInteractive = false

    @State private var isHovering = false
    @State private var shimmerPhase: CGFloat = -1.15

    var body: some View {
        ZStack {
            Circle()
                .fill(ShixiangTheme.gold.opacity(isHovering ? 0.24 : 0.12))
                .blur(radius: size * 0.22)
                .scaleEffect(isHovering ? 1.22 : 1.04)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 1.0, green: 0.91, blue: 0.65),
                            Color(red: 0.89, green: 0.60, blue: 0.22),
                            Color(red: 0.55, green: 0.28, blue: 0.055)
                        ],
                        center: UnitPoint(x: 0.30, y: 0.24),
                        startRadius: 0,
                        endRadius: size * 0.76
                    )
                )
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.54), Color.clear, Color.black.opacity(0.52)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: max(0.8, size * 0.045)
                )
                .padding(size * 0.04)
            Circle()
                .stroke(Color(red: 0.34, green: 0.16, blue: 0.025).opacity(0.88), lineWidth: max(0.6, size * 0.025))
                .padding(size * 0.13)
            RoundedRectangle(cornerRadius: size * 0.055, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.18, green: 0.085, blue: 0.018), Color(red: 0.38, green: 0.18, blue: 0.035)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size * 0.31, height: size * 0.31)
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.055, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 0.6)
                }
            Circle()
                .trim(from: 0.04, to: 0.31)
                .stroke(Color.white.opacity(isHovering ? 0.52 : 0.34), style: StrokeStyle(lineWidth: max(0.8, size * 0.032), lineCap: .round))
                .padding(size * 0.18)
                .rotationEffect(.degrees(-44))

            if !reduceMotion {
                LinearGradient(
                    colors: [Color.clear, Color.white.opacity(0.54), Color.clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: size * 0.23, height: size * 1.24)
                .rotationEffect(.degrees(24))
                .offset(x: shimmerPhase * size)
                .blendMode(.screen)
                .mask(Circle())
                .allowsHitTesting(false)
            }
        }
        .frame(width: size, height: size)
        .rotation3DEffect(.degrees(isHovering && isInteractive && !reduceMotion ? 8 : 0), axis: (x: 0.35, y: 1, z: 0))
        .offset(y: isHovering && isInteractive && !reduceMotion ? -1.5 : 0)
        .shadow(color: Color.black.opacity(0.34), radius: isHovering ? 8 : 5, y: isHovering ? 5 : 3)
        .shadow(color: ShixiangTheme.gold.opacity(isHovering ? 0.38 : 0.20), radius: isHovering ? 10 : 6)
        .contentShape(Circle())
        .onHover { hovering in
            guard isInteractive else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                isHovering = hovering
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            shimmerPhase = -1.15
            withAnimation(.linear(duration: 1.05).repeatForever(autoreverses: false).delay(2.8)) {
                shimmerPhase = 1.15
            }
        }
        .accessibilityHidden(true)
    }
}

struct SponsorCoinButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.11), value: configuration.isPressed)
    }
}

struct SponsorView: View {
    @Environment(\.dismiss) private var dismiss
    var closeAction: (() -> Void)?

    init(closeAction: (() -> Void)? = nil) {
        self.closeAction = closeAction
    }

    var body: some View {
        ZStack {
            ShixiangTheme.canvas

            Circle()
                .fill(ShixiangTheme.violet.opacity(0.16))
                .frame(width: 360, height: 360)
                .blur(radius: 70)
                .offset(x: -170, y: -220)

            Circle()
                .fill(ShixiangTheme.gold.opacity(0.13))
                .frame(width: 320, height: 320)
                .blur(radius: 75)
                .offset(x: 180, y: 210)

            VStack(spacing: 16) {
                HStack(alignment: .center) {
                    HStack(spacing: 10) {
                        SponsorCoinIcon(size: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("赞助拾响")
                                .font(.system(size: 20, weight: .semibold))
                            Text("免费 · 开源 · 为创作者而生")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(ShixiangTheme.gold)
                        }
                    }

                    Spacer()

                    Button {
                        if let closeAction {
                            closeAction()
                        } else {
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 28, height: 28)
                            .background(ShixiangTheme.elevated)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭赞助窗口")
                }

                Text("如果拾响帮你更快找到了声音，可以请作者喝杯咖啡。赞助完全自愿，不会影响任何功能。")
                    .font(.system(size: 12))
                    .foregroundStyle(ShixiangTheme.secondaryText)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                sponsorQRCode
                    .frame(width: 292, height: 292)
                    .padding(12)
                    .background(Color(red: 0.985, green: 0.975, blue: 0.935))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(ShixiangTheme.gold.opacity(0.50), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 28, y: 12)

                HStack(spacing: 7) {
                    Image(systemName: "viewfinder")
                    Text("请使用微信扫码赞助")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ShixiangTheme.primaryText)

                Text("谢谢你支持一个免费、开源的创作者工具。")
                    .font(.system(size: 10))
                    .foregroundStyle(ShixiangTheme.tertiaryText)
            }
            .padding(28)
        }
        .frame(width: 440, height: 530)
    }

    @ViewBuilder
    private var sponsorQRCode: some View {
        if let url = Bundle.main.url(forResource: "WechatSponsorQR", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .accessibilityLabel("微信赞助收款二维码")
        } else {
            VStack(spacing: 10) {
                Image(systemName: "qrcode")
                    .font(.system(size: 54))
                Text("二维码资源暂不可用")
                    .font(.system(size: 11))
            }
            .foregroundStyle(Color.black.opacity(0.72))
        }
    }
}
