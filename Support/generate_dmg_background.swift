import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fputs("Usage: generate_dmg_background <output.png>\n", stderr)
    exit(1)
}

let size = NSSize(width: 760, height: 480)
let image = NSImage(size: size)
image.lockFocus()

guard let context = NSGraphicsContext.current?.cgContext else {
    fputs("Unable to create graphics context\n", stderr)
    exit(2)
}

let colorSpace = CGColorSpaceCreateDeviceRGB()
let colors = [
    NSColor(calibratedRed: 0.965, green: 0.970, blue: 0.995, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.925, green: 0.955, blue: 0.995, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.975, green: 0.955, blue: 0.995, alpha: 1).cgColor
] as CFArray
let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 0.55, 1])!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: size.height),
    end: CGPoint(x: size.width, y: 0),
    options: []
)

context.setFillColor(NSColor.white.withAlphaComponent(0.34).cgColor)
context.fillEllipse(in: CGRect(x: -70, y: 250, width: 430, height: 280))
context.setFillColor(NSColor(calibratedRed: 0.55, green: 0.42, blue: 1, alpha: 0.07).cgColor)
context.fillEllipse(in: CGRect(x: 430, y: -60, width: 420, height: 300))

func drawCentered(_ text: String, y: CGFloat, font: NSFont, color: NSColor) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color
    ]
    let attributed = NSAttributedString(string: text, attributes: attributes)
    let textSize = attributed.size()
    attributed.draw(at: NSPoint(x: (size.width - textSize.width) / 2, y: y))
}

drawCentered(
    "把拾响拖入 Applications 即可安装",
    y: 422,
    font: .systemFont(ofSize: 21, weight: .semibold),
    color: NSColor(calibratedWhite: 0.12, alpha: 0.92)
)
drawCentered(
    "一步完成安装 · 本地 AI 在 macOS 26.2+ 可用",
    y: 394,
    font: .systemFont(ofSize: 12, weight: .medium),
    color: NSColor(calibratedWhite: 0.32, alpha: 0.82)
)

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 316, y: 244))
arrow.curve(to: NSPoint(x: 445, y: 244), controlPoint1: NSPoint(x: 350, y: 268), controlPoint2: NSPoint(x: 410, y: 268))
arrow.move(to: NSPoint(x: 445, y: 244))
arrow.line(to: NSPoint(x: 420, y: 267))
arrow.move(to: NSPoint(x: 445, y: 244))
arrow.line(to: NSPoint(x: 420, y: 221))
arrow.lineWidth = 9
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
NSColor(calibratedRed: 0.36, green: 0.39, blue: 0.96, alpha: 0.94).setStroke()
arrow.stroke()

drawCentered(
    "需要 Apple Silicon · macOS 14.0+ · AI 需要 macOS 26.2+",
    y: 28,
    font: .systemFont(ofSize: 12, weight: .medium),
    color: NSColor(calibratedWhite: 0.30, alpha: 0.86)
)
drawCentered(
    "shixiang.jack-sun.com",
    y: 9,
    font: .systemFont(ofSize: 10.5, weight: .regular),
    color: NSColor(calibratedRed: 0.35, green: 0.28, blue: 0.72, alpha: 0.82)
)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Unable to encode PNG\n", stderr)
    exit(3)
}

try png.write(to: URL(fileURLWithPath: arguments[1]), options: .atomic)
