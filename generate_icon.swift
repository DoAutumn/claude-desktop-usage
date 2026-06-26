// Programmatically draw the Claude Usage app icon at every iconset size.
// Used by build_app.sh — `swift generate_icon.swift <output.iconset>`.

import AppKit
import Foundation

let sizes: [(px: Int, name: String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

// Superellipse (squircle) path: |x|^n + |y|^n = 1, sampled around the rect.
// n≈5 matches the macOS Big Sur+ continuous-corner look far better than a plain
// rounded rectangle (whose corners read as too square).
func superellipsePath(in rect: NSRect, n: CGFloat = 5) -> NSBezierPath {
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let path = NSBezierPath()
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * copysign(pow(abs(ct), 2 / n), ct)
        let y = cy + b * copysign(pow(abs(st), 2 / n), st)
        if i == 0 { path.move(to: NSPoint(x: x, y: y)) }
        else { path.line(to: NSPoint(x: x, y: y)) }
    }
    path.close()
    return path
}

func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    defer { img.unlockFocus() }

    // 1. Inset the body so it occupies ~82% of the canvas (≈9% transparent
    //    margin per side). Filling the whole canvas makes the icon look
    //    oversized next to stock macOS icons in the Dock.
    let margin = size * 0.09
    let body = NSRect(x: margin, y: margin,
                      width: size - 2 * margin, height: size - 2 * margin)
    let bgPath = superellipsePath(in: body)
    bgPath.addClip()

    // Gradient: deep indigo → violet (top to bottom).
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.16, green: 0.13, blue: 0.36, alpha: 1.0),
        NSColor(srgbRed: 0.46, green: 0.30, blue: 0.69, alpha: 1.0),
    ])!
    gradient.draw(in: bgPath, angle: -90)

    // 2. Three usage bars centered within the body, varying heights.
    let bars: [CGFloat] = [0.28, 0.45, 0.62]  // relative heights
    let barWidth = body.width * 0.13
    let spacing = body.width * 0.05
    let totalWidth = barWidth * 3 + spacing * 2
    let startX = body.minX + (body.width - totalWidth) / 2
    let baseY = body.minY + body.height * 0.30
    let barRadius = barWidth * 0.35
    NSColor.white.withAlphaComponent(0.96).setFill()
    for (i, h) in bars.enumerated() {
        let x = startX + CGFloat(i) * (barWidth + spacing)
        let barHeight = body.height * h
        let rect = NSRect(x: x, y: baseY, width: barWidth, height: barHeight)
        NSBezierPath(roundedRect: rect, xRadius: barRadius, yRadius: barRadius).fill()
    }

    // 3. Subtle inner highlight along the top edge for that glossy macOS feel.
    let highlight = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.18),
        NSColor.white.withAlphaComponent(0.0),
    ])!
    highlight.draw(in: bgPath, angle: -90)

    return img
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(
        "usage: swift generate_icon.swift <iconset-dir>\n".data(using: .utf8)!)
    exit(1)
}
let outputDir = args[1]
try? FileManager.default.createDirectory(
    atPath: outputDir, withIntermediateDirectories: true)

for entry in sizes {
    let img = drawIcon(size: CGFloat(entry.px))
    guard let tiff = img.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    else {
        FileHandle.standardError.write("failed to encode \(entry.name)\n".data(using: .utf8)!)
        exit(1)
    }
    let url = URL(fileURLWithPath: "\(outputDir)/\(entry.name)")
    try png.write(to: url)
    print("  \(entry.name) (\(entry.px)px)")
}
