import SwiftUI

/// A calm three-to-four-second branded launch surface. The full local library is already being prepared behind
/// it; this view contains no choices or unfinished product promises, only a calm identity moment.
struct ModeSelectionView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var markHasAppeared = false

    var body: some View {
        ZStack {
            ShixiangTheme.canvas.ignoresSafeArea()

            launchAtmosphere

            VStack(spacing: 24) {
                Spacer()

                ShixiangMark(size: 140)
                    .scaleEffect(markHasAppeared ? 1 : 0.92)
                    .opacity(markHasAppeared ? 1 : 0)
                    .shadow(color: ShixiangTheme.gold.opacity(0.18), radius: 36)

                VStack(spacing: 8) {
                    Text("拾响")
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                        .tracking(9)
                        .foregroundStyle(ShixiangTheme.primaryText)

                    Text("你的终极音效管理软件。")
                        .font(.system(size: 15, weight: .regular))
                        .tracking(1.4)
                        .foregroundStyle(ShixiangTheme.secondaryText)
                }
                .opacity(markHasAppeared ? 0.92 : 0)
                .offset(y: markHasAppeared ? 0 : 7)

                Spacer()
                Spacer()
            }
            .padding(.top, 36)
        }
        .ignoresSafeArea(.container, edges: .top)
        .allowsHitTesting(false)
        .task {
            if reduceMotion {
                markHasAppeared = true
            } else {
                withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.85)) {
                    markHasAppeared = true
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("拾响，你的终极音效管理软件。正在准备本地音效库")
    }

    @ViewBuilder
    private var launchAtmosphere: some View {
        if reduceMotion {
            staticAtmosphere
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                Canvas { context, size in
                    drawFlowingSilk(
                        in: &context,
                        size: size,
                        time: timeline.date.timeIntervalSinceReferenceDate
                    )
                }
            }
            .ignoresSafeArea()
        }
    }

    private var staticAtmosphere: some View {
        VStack {
            Spacer()
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            ShixiangTheme.violet.opacity(0.30),
                            ShixiangTheme.blue.opacity(0.14),
                            .clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 360
                    )
                )
                .frame(height: 330)
                .blur(radius: 42)
                .offset(y: 100)
        }
        .ignoresSafeArea()
    }

    private func drawFlowingSilk(
        in context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval
    ) {
        let baseY = size.height * 0.76
        let ribbonHeight = max(90, size.height * 0.15)

        // Soft lower glow makes the ribbons feel suspended in illuminated water rather than
        // drawn as hard vector waves.
        let glowRect = CGRect(
            x: -size.width * 0.12,
            y: size.height * 0.57,
            width: size.width * 1.24,
            height: size.height * 0.56
        )
        context.fill(
            Path(ellipseIn: glowRect),
            with: .radialGradient(
                Gradient(colors: [
                    ShixiangTheme.violet.opacity(0.19),
                    ShixiangTheme.blue.opacity(0.08),
                    .clear
                ]),
                center: CGPoint(x: size.width * 0.52, y: size.height * 0.82),
                startRadius: 10,
                endRadius: size.width * 0.56
            )
        )

        let ribbons: [(phase: Double, amplitude: CGFloat, thickness: CGFloat, opacity: Double)] = [
            (0.0, 0.62, 1.00, 0.34),
            (1.8, 0.46, 0.78, 0.25),
            (3.5, 0.34, 0.60, 0.18)
        ]

        for (index, ribbon) in ribbons.enumerated() {
            var upper = Path()
            var lowerPoints: [CGPoint] = []
            let steps = 96
            for step in 0...steps {
                let progress = CGFloat(step) / CGFloat(steps)
                let x = progress * size.width
                let traveling = Double(progress) * 7.4 + time * (0.42 + Double(index) * 0.055) + ribbon.phase
                let secondary = Double(progress) * 14.0 - time * 0.24 + ribbon.phase * 0.7
                let wave = CGFloat(sin(traveling) * 0.72 + sin(secondary) * 0.28)
                let envelope = 0.56 + sin(progress * .pi) * 0.44
                let centerY = baseY + wave * ribbonHeight * ribbon.amplitude * envelope
                let halfThickness = ribbonHeight * 0.42 * ribbon.thickness * (0.45 + envelope * 0.55)
                let upperPoint = CGPoint(x: x, y: centerY - halfThickness)
                let lowerPoint = CGPoint(x: x, y: centerY + halfThickness)
                if step == 0 { upper.move(to: upperPoint) } else { upper.addLine(to: upperPoint) }
                lowerPoints.append(lowerPoint)
            }
            for point in lowerPoints.reversed() { upper.addLine(to: point) }
            upper.closeSubpath()

            context.fill(
                upper,
                with: .linearGradient(
                    Gradient(colors: [
                        ShixiangTheme.gold.opacity(ribbon.opacity * 0.72),
                        ShixiangTheme.violet.opacity(ribbon.opacity),
                        ShixiangTheme.blue.opacity(ribbon.opacity * 0.82),
                        ShixiangTheme.violet.opacity(ribbon.opacity * 0.58)
                    ]),
                    startPoint: CGPoint(x: 0, y: baseY - ribbonHeight),
                    endPoint: CGPoint(x: size.width, y: baseY + ribbonHeight)
                )
            )
        }
    }
}
