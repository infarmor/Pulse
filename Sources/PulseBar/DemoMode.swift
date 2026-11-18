import AppKit
import PulseBarCore

/// `--demo` launch mode: a fictional track, generated artwork and synthetic bars.
///
/// Used for README screenshots: no real album covers, no audio capture, no Apple Music
/// access, and the user's own settings are never touched.
///
///     open Pulse.app --args --demo [--demo-palette N] [--demo-still] [--demo-expanded | --demo-collapsed]
///                                  [--demo-settings '<VisualizerSettings JSON>'] [--show-menu]
enum DemoMode {
    private static let arguments = ProcessInfo.processInfo.arguments

    static let isEnabled = arguments.contains("--demo")
    /// Freeze bars in one pleasant shape so screenshots are reproducible.
    static let isStill = arguments.contains("--demo-still")
    /// Show the menu with settings expanded / collapsed, without changing the stored preference.
    static var settingsExpandedOverride: Bool? {
        if arguments.contains("--demo-expanded") { return true }
        if arguments.contains("--demo-collapsed") { return false }
        return nil
    }

    static var settingsOverride: VisualizerSettings? {
        guard let json = value(after: "--demo-settings") else { return nil }
        return try? JSONDecoder().decode(VisualizerSettings.self, from: Data(json.utf8))
    }

    struct Palette {
        let title: String
        let album: String
        let colors: [NSColor]
    }

    static let palettes: [Palette] = [
        Palette(title: "Neon Afterglow", album: "Liquid Glass", colors: [rgb(0xFF2E6E), rgb(0xFF9A3D), rgb(0x6A1BFF)]),
        Palette(title: "Ocean Static", album: "Tides", colors: [rgb(0x00C6FF), rgb(0x0047FF), rgb(0x00FFC2)]),
        Palette(title: "Lime Circuit", album: "Voltage", colors: [rgb(0xC6FF3D), rgb(0x16C95A), rgb(0x063B2C)])
    ]

    static var palette: Palette {
        let index = value(after: "--demo-palette").flatMap(Int.init) ?? 0
        return palettes[abs(index) % palettes.count]
    }

    static var track: TrackInfo {
        TrackInfo(
            title: palette.title,
            artist: "Pulse Demo",
            album: palette.album,
            duration: 214,
            position: 83,
            soundVolume: 100,
            state: .playing,
            isMusicRunning: true
        )
    }

    /// Abstract gradient cover: diagonal gradient, a soft glow, and a few rings.
    static func artwork(side: CGFloat = 512) -> NSImage {
        let colors = palette.colors
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSGradient(colors: [colors[0], colors[2]])?.draw(in: rect, angle: -45)

            let glow = NSGradient(colors: [colors[1].withAlphaComponent(0.95), colors[1].withAlphaComponent(0)])
            glow?.draw(
                fromCenter: NSPoint(x: rect.width * 0.32, y: rect.height * 0.70), radius: 0,
                toCenter: NSPoint(x: rect.width * 0.32, y: rect.height * 0.70), radius: rect.width * 0.55,
                options: []
            )

            NSColor.white.withAlphaComponent(0.16).setStroke()
            for i in 1...4 {
                let r = rect.width * (0.12 + CGFloat(i) * 0.09)
                let ring = NSBezierPath(ovalIn: NSRect(
                    x: rect.width * 0.62 - r, y: rect.height * 0.34 - r, width: r * 2, height: r * 2
                ))
                ring.lineWidth = rect.width * 0.012
                ring.stroke()
            }
            return true
        }
    }

    /// Smooth, music-like bar heights. Fixed when `--demo-still` is set.
    static func bars(at time: TimeInterval) -> [Double] {
        let t = isStill ? 1.35 : time
        let base: [Double] = [0.42, 0.78, 0.96, 0.70, 0.55, 0.30]
        return (0..<base.count).map { i in
            let d = Double(i)
            let wobble = 0.22 * sin(t * (2.3 + d * 0.6) + d) + 0.10 * sin(t * 5.1 + d * 1.7)
            return min(1, max(0.08, base[i] + wobble))
        }
    }

    private static func value(after flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
