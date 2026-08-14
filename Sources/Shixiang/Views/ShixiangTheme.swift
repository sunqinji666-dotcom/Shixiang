import AppKit
import SwiftUI

enum ShixiangTheme {
    static let canvas = Color(red: 0.043, green: 0.045, blue: 0.055)
    static let surface = Color(red: 0.070, green: 0.072, blue: 0.084)
    static let elevated = Color(red: 0.095, green: 0.097, blue: 0.112)
    static let hairline = Color.white.opacity(0.085)
    static let primaryText = Color.white.opacity(0.92)
    static let secondaryText = Color.white.opacity(0.56)
    static let tertiaryText = Color.white.opacity(0.34)
    static let gold = Color(red: 0.82, green: 0.65, blue: 0.35)
    static let violet = Color(red: 0.39, green: 0.34, blue: 0.96)
    static let blue = Color(red: 0.33, green: 0.55, blue: 1.0)
    static let selectedSurface = Color(red: 0.115, green: 0.102, blue: 0.225)
    static let warmSurface = Color(red: 0.135, green: 0.112, blue: 0.080)
    static let playGradient = LinearGradient(
        colors: [violet, blue],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let workspaceGradient = LinearGradient(
        colors: [
            Color(red: 0.050, green: 0.052, blue: 0.064),
            canvas,
            Color(red: 0.036, green: 0.038, blue: 0.048)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

private enum ShixiangBrandIcon {
    static let image: NSImage? = {
        if let image = NSImage(named: NSImage.applicationIconName) {
            return image
        }
        guard let url = Bundle.main.url(forResource: "Shixiang", withExtension: "icns") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()
}

/// The one canonical 拾响 mark used inside the app. The source is the same application icon
/// shipped in Contents/Resources/Shixiang.icns, so the launch surface, sidebar, workspace header
/// and About screen cannot drift into separate hand-drawn versions of the brand.
struct ShixiangMark: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let applicationIcon = ShixiangBrandIcon.image {
                Image(nsImage: applicationIcon)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
            } else {
                // The resource is required by the app bundle. Keep an empty placeholder rather
                // than drawing a second, visually different brand if a damaged bundle is used.
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.24), radius: size * 0.12, y: size * 0.045)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("拾响")
    }
}

struct ShixiangIconBadge: View {
    let systemImage: String
    var size: CGFloat = 30
    var tint: Color = ShixiangTheme.gold

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(tint.opacity(0.11))
            Image(systemName: systemImage)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .stroke(tint.opacity(0.20), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

/// A lightweight, one-to-one slider for high-frequency audio controls. It draws only two
/// rectangles and one circle, and never asks a native NSSlider to animate toward the pointer.
struct ShixiangDirectSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    var tint: Color = ShixiangTheme.violet
    var isEnabled = true
    var accessibilityName = "滑块"
    var accessibilityValueText: String?
    var accessibilityHintText: String?
    var onEditingBegan: () -> Void = {}
    let onChange: (Double) -> Void
    var onEditingEnded: (Double) -> Void = { _ in }

    @State private var isHovering = false
    @State private var isTracking = false

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let fraction = normalizedFraction(value)
            let thumbX = max(5, min(width - 5, width * fraction))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(ShixiangTheme.secondaryText.opacity(0.20))
                    .frame(height: 3)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.86), tint],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, width * fraction), height: 3)

                Circle()
                    .fill(isTracking ? ShixiangTheme.gold : Color.white.opacity(0.94))
                    .frame(
                        width: isTracking || isHovering ? 10 : 8,
                        height: isTracking || isHovering ? 10 : 8
                    )
                    .overlay {
                        Circle().stroke(Color.black.opacity(0.22), lineWidth: 0.5)
                    }
                    .position(x: thumbX, y: geometry.size.height / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            // Win the drag-recognition race against the hidden title-bar window background.
            // Without high priority, macOS may interpret the same pointer motion as a request
            // to move the whole window because the app intentionally allows background dragging.
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        if !isTracking {
                            isTracking = true
                            onEditingBegan()
                        }
                        onChange(mappedValue(x: gesture.location.x, width: width))
                    }
                    .onEnded { gesture in
                        guard isEnabled else { return }
                        let finalValue = mappedValue(x: gesture.location.x, width: width)
                        onChange(finalValue)
                        onEditingEnded(finalValue)
                        isTracking = false
                    }
            )
        }
        .frame(height: 18)
        .opacity(isEnabled ? 1 : 0.36)
        .onHover { isHovering = $0 }
        .transaction { transaction in
            // Audio controls should track the pointer exactly, with no catch-up animation.
            transaction.animation = nil
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(
            accessibilityValueText ?? "\(Int(normalizedFraction(value) * 100))%"
        )
        .accessibilityHint(accessibilityHintText ?? "")
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            let step = (range.upperBound - range.lowerBound) / 20
            let adjustedValue: Double
            switch direction {
            case .increment:
                adjustedValue = min(range.upperBound, value + step)
            case .decrement:
                adjustedValue = max(range.lowerBound, value - step)
            @unknown default:
                return
            }
            onChange(adjustedValue)
            onEditingEnded(adjustedValue)
        }
    }

    private func normalizedFraction(_ value: Double) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    private func mappedValue(x: CGFloat, width: CGFloat) -> Double {
        let fraction = min(max(Double(x / width), 0), 1)
        return range.lowerBound + fraction * (range.upperBound - range.lowerBound)
    }
}

extension View {
    func shixiangPanel(cornerRadius: CGFloat = 14) -> some View {
        background(ShixiangTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(ShixiangTheme.hairline, lineWidth: 1)
            }
    }

    /// Content-aware pointer response for SF Symbols. The native `.help` tooltip supplies the
    /// text; the symbol itself responds according to its meaning (refresh rotates, chevrons nudge).
    func shixiangHoverIcon(_ systemImage: String) -> some View {
        modifier(ShixiangHoverIconModifier(systemImage: systemImage))
    }
}

private struct ShixiangHoverIconModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let systemImage: String
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering = $0 }
            .rotationEffect(.degrees(rotationDegrees))
            .offset(x: horizontalNudge, y: verticalNudge)
            .scaleEffect(scale)
            .brightness(!reduceMotion && isHovering ? 0.035 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovering)
    }

    private var rotationDegrees: Double {
        guard !reduceMotion, isHovering else { return 0 }
        if systemImage.contains("arrow.clockwise") || systemImage.contains("arrow.counterclockwise") {
            return 360
        }
        if systemImage == "repeat" || systemImage.contains("arrow.triangle.2.circlepath") {
            return 180
        }
        if systemImage.contains("filter") || systemImage.contains("line.3.horizontal.decrease") {
            return 7
        }
        if systemImage == "sparkles" || systemImage.contains("wand") {
            return 8
        }
        if systemImage.contains("star") || systemImage.contains("stethoscope") {
            return 6
        }
        if systemImage.contains("arrow.up.arrow.down") {
            return 5
        }
        return 0
    }

    private var verticalNudge: CGFloat {
        guard !reduceMotion, isHovering else { return 0 }
        if systemImage.contains("chevron") { return systemImage.contains("up") ? -1.5 : 1.5 }
        if systemImage.contains("gobackward") { return 0 }
        if systemImage.contains("goforward") { return 0 }
        if systemImage.contains("checklist") || systemImage.contains("list.") { return -1.25 }
        if systemImage.contains("folder") || systemImage.contains("sidebar") { return -1 }
        return 0
    }

    private var horizontalNudge: CGFloat {
        guard !reduceMotion, isHovering else { return 0 }
        if systemImage.contains("gobackward") { return -1.5 }
        if systemImage.contains("goforward") { return 1.5 }
        return 0
    }

    private var scale: CGFloat {
        guard !reduceMotion, isHovering else { return 1 }
        if systemImage == "sparkles" || systemImage.contains("play") || systemImage.contains("pause") {
            return 1.06
        }
        return 1.02
    }
}

struct ShixiangCommandButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var isPrimary = false
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(foreground(configuration: configuration))
            .padding(.horizontal, 10)
            .frame(minHeight: 34)
            .background(background(configuration: configuration))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.975 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
    }

    private func foreground(configuration: Configuration) -> Color {
        if isPrimary { return .white }
        if isActive { return ShixiangTheme.gold }
        return ShixiangTheme.secondaryText
    }

    @ViewBuilder
    private func background(configuration: Configuration) -> some View {
        if isPrimary {
            ShixiangTheme.playGradient
                .opacity(configuration.isPressed ? 0.78 : 1)
        } else if isActive {
            ShixiangTheme.gold.opacity(configuration.isPressed ? 0.10 : 0.14)
        } else {
            ShixiangTheme.elevated.opacity(configuration.isPressed ? 0.68 : 1)
        }
    }

    private var borderColor: Color {
        if isPrimary { return Color.white.opacity(0.14) }
        if isActive { return ShixiangTheme.gold.opacity(0.34) }
        return ShixiangTheme.hairline
    }
}

struct ShixiangRoundButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var isActive = false
    var isPrimary = false
    var size: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.34, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(background(configuration: configuration))
            .clipShape(Circle())
            .overlay {
                Circle().stroke(border, lineWidth: 1)
            }
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.94 : 1)
            .opacity(isEnabled ? 1 : 0.32)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }

    private var foreground: Color {
        if isPrimary || isActive { return .white }
        return ShixiangTheme.secondaryText
    }

    @ViewBuilder
    private func background(configuration: Configuration) -> some View {
        if isPrimary {
            ShixiangTheme.playGradient.opacity(configuration.isPressed ? 0.78 : 1)
        } else if isActive {
            ShixiangTheme.violet.opacity(configuration.isPressed ? 0.48 : 0.72)
        } else {
            ShixiangTheme.elevated.opacity(configuration.isPressed ? 0.64 : 0.92)
        }
    }

    private var border: Color {
        isPrimary || isActive ? Color.white.opacity(0.12) : ShixiangTheme.hairline
    }
}

private struct StopPitchPreviewActionKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    /// A lightweight command instead of observing the preview controller in every library row.
    /// This keeps preview clock updates from invalidating thousands of list identities.
    var stopPitchPreview: () -> Void {
        get { self[StopPitchPreviewActionKey.self] }
        set { self[StopPitchPreviewActionKey.self] = newValue }
    }
}
