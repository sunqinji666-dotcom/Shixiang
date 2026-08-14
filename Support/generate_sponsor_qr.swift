import AppKit
import CoreImage
import Foundation

private let payload = "wxp://f2f0BLnJr9WWaN6ft2VMdZ4rnCqUoXWSlluxTaj6VThdCZc"
guard CommandLine.arguments.count == 3 else {
    fputs("Usage: generate_sponsor_qr <source-wechat-image> <output.png>\n", stderr)
    exit(1)
}
private let sourcePath = CommandLine.arguments[1]
private let outputPath = CommandLine.arguments[2]

guard let source = NSImage(contentsOfFile: sourcePath) else {
    fputs("无法读取微信收款原图。\n", stderr)
    exit(2)
}

guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
    fputs("系统不支持二维码生成器。\n", stderr)
    exit(3)
}
filter.setValue(Data(payload.utf8), forKey: "inputMessage")
filter.setValue("H", forKey: "inputCorrectionLevel")
guard let qrImage = filter.outputImage else {
    fputs("无法生成二维码。\n", stderr)
    exit(4)
}

// Integral scaling keeps every QR module perfectly sharp. Quiet space remains a full 4+ modules.
let moduleScale: CGFloat = 14
let scaledQR = qrImage.transformed(by: CGAffineTransform(scaleX: moduleScale, y: moduleScale))
let context = CIContext(options: [.useSoftwareRenderer: false])
guard let qrCG = context.createCGImage(scaledQR, from: scaledQR.extent) else {
    fputs("无法渲染二维码。\n", stderr)
    exit(5)
}

let canvasSize = NSSize(width: 760, height: 760)
let result = NSImage(size: canvasSize)
result.lockFocus()

let canvasRect = NSRect(origin: .zero, size: canvasSize)
NSColor(calibratedRed: 0.985, green: 0.975, blue: 0.935, alpha: 1).setFill()
NSBezierPath(roundedRect: canvasRect, xRadius: 36, yRadius: 36).fill()

let qrSize = NSSize(width: qrCG.width, height: qrCG.height)
let qrRect = NSRect(
    x: (canvasSize.width - qrSize.width) * 0.5,
    y: (canvasSize.height - qrSize.height) * 0.5,
    width: qrSize.width,
    height: qrSize.height
)
NSGraphicsContext.current?.cgContext.interpolationQuality = .none
NSImage(cgImage: qrCG, size: qrSize).draw(in: qrRect)

// Extract only the hand-drawn Jacksun avatar from the original payment image. It is placed in
// the QR's error-correctable centre, away from all three finder patterns.
let avatarDiameter: CGFloat = 114
let avatarRect = NSRect(
    x: (canvasSize.width - avatarDiameter) * 0.5,
    y: (canvasSize.height - avatarDiameter) * 0.5,
    width: avatarDiameter,
    height: avatarDiameter
)
let avatarBorderRect = avatarRect.insetBy(dx: -7, dy: -7)
let avatarBorder = NSBezierPath(ovalIn: avatarBorderRect)
NSColor(calibratedRed: 0.77, green: 0.50, blue: 0.18, alpha: 1).setFill()
avatarBorder.fill()
NSColor.white.setFill()
NSBezierPath(ovalIn: avatarRect.insetBy(dx: -2, dy: -2)).fill()

NSGraphicsContext.saveGraphicsState()
NSBezierPath(ovalIn: avatarRect).addClip()
// AppKit's source coordinates use a lower-left origin. This crop isolates the avatar square
// inside the original WeChat QR while excluding the green verification badge.
let avatarSource = NSRect(x: 365, y: 608, width: 100, height: 100)
source.draw(in: avatarRect, from: avatarSource, operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

result.unlockFocus()

guard let tiff = result.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("无法编码二维码 PNG。\n", stderr)
    exit(6)
}

try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
print(outputPath)
