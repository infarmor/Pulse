import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Usage: generate_icon.swift <iconset_dir>\n", stderr)
    exit(1)
}

let outputDir = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let specs: [(name: String, px: Int)] = [
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

func renderIcon(size px: Int) -> CGImage? {
    let s = CGFloat(px)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: px,
        height: px,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    let inset = s * 0.08
    let cardRect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let cardRadius = cardRect.width * 0.225
    let cardPath = CGPath(roundedRect: cardRect, cornerWidth: cardRadius, cornerHeight: cardRadius, transform: nil)

    ctx.saveGState()
    ctx.addPath(cardPath)
    ctx.clip()

    let gradColors = [
        CGColor(red: 0.19, green: 0.175, blue: 0.165, alpha: 1.0),
        CGColor(red: 0.09, green: 0.085, blue: 0.082, alpha: 1.0)
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: cardRect.midX, y: cardRect.maxY),
            end: CGPoint(x: cardRect.midX, y: cardRect.minY),
            options: []
        )
    }
    ctx.restoreGState()

    // Subtle rim
    ctx.saveGState()
    ctx.addPath(cardPath)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14))
    ctx.setLineWidth(max(1, s * 0.012))
    ctx.strokePath()
    ctx.restoreGState()

    // Inner dark capsule pill silhouette + 6 equalizer bars
    let barHeights: [CGFloat] = [0.22, 0.48, 0.82, 0.82, 0.48, 0.22]
    let maxBarH = cardRect.height * 0.48
    let barW = max(1.2, cardRect.width * 0.056)
    let barGap = cardRect.width * 0.044
    let totalW = CGFloat(barHeights.count) * barW + CGFloat(barHeights.count - 1) * barGap
    var x = cardRect.midX - totalW / 2.0

    for (idx, frac) in barHeights.enumerated() {
        let h = max(barW, maxBarH * frac)
        let y = cardRect.midY - h / 2.0
        let rect = CGRect(x: x, y: y, width: barW, height: h)
        let r = barW / 2.0
        let path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        let alpha: CGFloat = (idx == 2 || idx == 3) ? 0.92 : (idx == 1 || idx == 4 ? 0.78 : 0.65)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
        ctx.addPath(path)
        ctx.fillPath()
        x += barW + barGap
    }

    return ctx.makeImage()
}

for spec in specs {
    guard let img = renderIcon(size: spec.px) else { continue }
    let fileURL = outputDir.appendingPathComponent(spec.name)
    guard let dest = CGImageDestinationCreateWithURL(fileURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        continue
    }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}
