import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: generate_icon <iconset-directory> <icns-file>\n", stderr)
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let icnsDestination = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func drawIcon(size: Int, destination: URL) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { throw CocoaError(.fileWriteUnknown) }

    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    let s = CGFloat(size)
    let bounds = NSRect(x: 0, y: 0, width: s, height: s)
    NSColor.clear.setFill()
    bounds.fill()

    let tile = bounds.insetBy(dx: s * 0.055, dy: s * 0.055)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: s * 0.225, yRadius: s * 0.225)
    let background = NSGradient(colors: [
        color(0.16, 0.13, 0.22),
        color(0.055, 0.052, 0.075)
    ])!
    background.draw(in: tilePath, angle: -58)

    color(0.60, 0.44, 1.0, 0.13).setFill()
    NSBezierPath(ovalIn: NSRect(x: s * 0.20, y: s * 0.49, width: s * 0.72, height: s * 0.72)).fill()

    color(0.97, 0.77, 0.38, 0.08).setStroke()
    let halo = NSBezierPath(ovalIn: bounds.insetBy(dx: s * 0.185, dy: s * 0.185))
    halo.lineWidth = max(1, s * 0.012)
    halo.stroke()

    let heights: [CGFloat] = [0.22, 0.42, 0.65, 0.86, 0.58, 0.34, 0.18]
    let barWidth = s * 0.066
    let spacing = s * 0.035
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * spacing
    var x = (s - total) / 2
    for (index, height) in heights.enumerated() {
        let barHeight = s * 0.48 * height
        let rect = NSRect(x: x, y: (s - barHeight) / 2, width: barWidth, height: barHeight)
        let path = NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)
        let mix = CGFloat(index) / CGFloat(max(1, heights.count - 1))
        color(0.58 + mix * 0.38, 0.42 + mix * 0.32, 0.98 - mix * 0.46).setFill()
        path.fill()
        x += barWidth + spacing
    }

    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: destination, options: .atomic)
}

for (name, size) in variants {
    try drawIcon(size: size, destination: outputDirectory.appendingPathComponent(name))
}

func bigEndianData(_ value: UInt32) -> Data {
    var number = value.bigEndian
    return Data(bytes: &number, count: MemoryLayout<UInt32>.size)
}

let icnsRepresentations: [(String, String)] = [
    ("icp4", "icon_16x16.png"),
    ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png")
]

var body = Data()
for (type, fileName) in icnsRepresentations {
    let png = try Data(contentsOf: outputDirectory.appendingPathComponent(fileName))
    body.append(type.data(using: .ascii)!)
    body.append(bigEndianData(UInt32(png.count + 8)))
    body.append(png)
}

var icns = Data("icns".utf8)
icns.append(bigEndianData(UInt32(body.count + 8)))
icns.append(body)
try icns.write(to: icnsDestination, options: .atomic)
