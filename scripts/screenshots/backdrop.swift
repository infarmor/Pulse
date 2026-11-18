// Shows a generated "wallpaper" in a click-through window under the menu bar for a few
// seconds, so screenshots of Pulse have a clean, consistent background.
// Usage: swift backdrop.swift <x> <y> <w> <h> <seconds> <out.png>   (top-left screen coords)
import AppKit

let a = CommandLine.arguments
let rectTL = NSRect(x: Double(a[1])!, y: Double(a[2])!, width: Double(a[3])!, height: Double(a[4])!)
let seconds = Double(a[5])!
let outPath = a[6]

func wallpaper(size: NSSize) -> NSImage {
    NSImage(size: size, flipped: true) { r in
        NSGradient(colors: [
            NSColor(srgbRed: 0.06, green: 0.05, blue: 0.16, alpha: 1),
            NSColor(srgbRed: 0.22, green: 0.07, blue: 0.36, alpha: 1),
            NSColor(srgbRed: 0.55, green: 0.10, blue: 0.40, alpha: 1)
        ])?.draw(in: r, angle: 60)
        let blobs: [(CGFloat, CGFloat, CGFloat, NSColor)] = [
            (0.25, 0.20, 0.55, NSColor(srgbRed: 1.0, green: 0.35, blue: 0.45, alpha: 0.55)),
            (0.80, 0.35, 0.45, NSColor(srgbRed: 0.30, green: 0.45, blue: 1.0, alpha: 0.45)),
            (0.55, 0.85, 0.60, NSColor(srgbRed: 1.0, green: 0.60, blue: 0.25, alpha: 0.35))
        ]
        for (x, y, radius, color) in blobs {
            let c = NSPoint(x: r.width * x, y: r.height * y)
            NSGradient(colors: [color, color.withAlphaComponent(0)])?
                .draw(fromCenter: c, radius: 0, toCenter: c, radius: r.width * radius, options: [])
        }
        return true
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // never steal focus (that would close the popover)

let screen = NSScreen.screens[0]
let image = wallpaper(size: rectTL.size)
// Windows can't sit under the menu bar, so start the window at the menu bar's bottom edge and
// show the matching part of the wallpaper; screen pixel (x, y) == wallpaper pixel (x-X, y-Y).
let topInset = max(0, screen.frame.maxY - screen.visibleFrame.maxY - rectTL.minY)
let visibleSize = NSSize(width: rectTL.width, height: rectTL.height - topInset)
let visiblePart = NSImage(size: visibleSize, flipped: true) { r in
    image.draw(in: r, from: NSRect(x: 0, y: 0, width: visibleSize.width, height: visibleSize.height),
               operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    return true
}
let frame = NSRect(x: rectTL.minX, y: screen.frame.height - rectTL.maxY, width: visibleSize.width, height: visibleSize.height)
if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: outPath))
}

let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.level = NSWindow.Level(rawValue: 20)   // above apps, below the menu bar and popovers
window.ignoresMouseEvents = true
window.hasShadow = false
window.collectionBehavior = [.canJoinAllSpaces, .stationary]
let view = NSImageView(frame: NSRect(origin: .zero, size: frame.size))
view.image = visiblePart
view.imageScaling = .scaleAxesIndependently
window.contentView = view
window.orderFrontRegardless()

DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { app.terminate(nil) }
app.run()
