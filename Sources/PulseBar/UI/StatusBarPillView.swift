import AppKit
import PulseBarCore
import SwiftUI

/// `NSHostingView` that handles status item clicks itself instead of letting the
/// `NSStatusBarButton` track them. The button never enters its pressed state, so macOS
/// doesn't draw its gray selection plate around the capsule.
final class StatusItemHostingView<Content: View>: NSHostingView<Content> {
    var onLeftClick: (() -> Void)?
    var onRightClick: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Claim every hit inside our frame; SwiftUI content inside is purely decorative.
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            // ⌘-drag rearranges menu bar items: leave it to the system.
            super.mouseDown(with: event)
        } else if event.modifierFlags.contains(.control) {
            onRightClick?()
        } else {
            onLeftClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }
}

/// Reusable 6-bar capsule equalizer view shared between the menu bar pill and the popover preview.
struct EqualizerBarsView: View {
    let levels: [Double]
    let isPlaying: Bool
    var barWidth: CGFloat = 1.8
    var spacing: CGFloat = 1.4
    var minHeight: CGFloat = 2.4
    var maxHeight: CGFloat = 12.6
    var activeOpacity: Double = 0.78
    var idleOpacity: Double = 0.40
    var color: Color = .white

    private static let restingEnvelope: [Double] = [0.0, 0.04, 0.08, 0.08, 0.04, 0.0]

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(0..<SpectrumAnalyzer.barCount, id: \.self) { index in
                let level = index < levels.count ? levels[index] : 0
                let effective = max(level, isPlaying ? 0.02 : Self.restingEnvelope[index])
                let height = minHeight + CGFloat(min(1.0, max(0.0, effective))) * (maxHeight - minHeight)

                Capsule(style: .continuous)
                    .fill(color.opacity(isPlaying ? activeOpacity : idleOpacity))
                    .frame(width: barWidth, height: height)
            }
        }
        .frame(height: maxHeight, alignment: .center)
        .animation(.easeInOut(duration: 0.4), value: color)
    }
}

/// Capsule background: Liquid Glass (regular / clear) on macOS 26+, or the classic dark fill.
/// Falls back to translucent materials on earlier systems.
struct CapsuleBackground: ViewModifier {
    var style: PillBackground = .glass
    var tint: Color?
    var highlighted: Bool = false

    private static let solidFill = Color(red: 0.14, green: 0.132, blue: 0.125, opacity: 0.90)

    func body(content: Content) -> some View {
        switch style {
        case .solid:
            solidBody(content)
        case .glass, .clearGlass:
            if #available(macOS 26.0, *) {
                // Glass.tint isn't rendered for status items, so lay the artwork tint over the
                // glass as a translucent fill under the content.
                content
                    .background {
                        if let tint {
                            Capsule(style: .continuous).fill(tint.opacity(highlighted ? 0.42 : 0.30))
                        }
                    }
                    .glassEffect(glass, in: Capsule(style: .continuous))
            } else {
                content
                    .background(
                        Capsule(style: .continuous)
                            .fill(style == .clearGlass ? .ultraThinMaterial : .thinMaterial)
                    )
                    .background(Capsule(style: .continuous).fill((tint ?? .clear).opacity(0.30)))
                    .overlay(border)
            }
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        let base: Glass = style == .clearGlass ? .clear : .regular
        return highlighted && tint == nil ? base.tint(.white.opacity(0.12)) : base
    }

    private func solidBody(_ content: Content) -> some View {
        content
            .background(
                ZStack {
                    Capsule(style: .continuous).fill(Self.solidFill)
                    if let tint {
                        Capsule(style: .continuous).fill(tint.opacity(0.40))
                    }
                }
            )
            .overlay(border)
    }

    private var border: some View {
        Capsule(style: .continuous)
            .strokeBorder(Color.white.opacity(highlighted ? 0.24 : 0.10), lineWidth: 0.5)
    }
}

extension View {
    func capsuleBackground(_ style: PillBackground = .glass, tint: Color? = nil, highlighted: Bool = false) -> some View {
        modifier(CapsuleBackground(style: style, tint: tint, highlighted: highlighted))
    }
}

/// Compact capsule widget rendered directly inside the macOS menu bar `NSStatusItem`.
struct StatusBarPillView: View {
    let controller: VisualizerController

    var body: some View {
        let m = controller.settings.pillSize.metrics
        GeometryReader { geo in
            // The pill may extend past the 22 pt button into the taller menu bar window
            // (notch displays), but must shrink on shorter menu bars instead of clipping.
            let fit = min(1.0, max(0.5, (controller.menuBarHeight - 2) / m.height))
            pill(m)
                .scaleEffect(fit)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(width: m.statusItemWidth)
        .contentShape(Rectangle())
    }

    private func pill(_ m: PillMetrics) -> some View {
        HStack(spacing: m.contentSpacing) {
            artworkThumbnail(m)
            EqualizerBarsView(
                levels: controller.bars,
                isPlaying: controller.isActivelyVisualizing && controller.bars.contains(where: { $0 > 0.004 })
                    || controller.track.state == .playing,
                barWidth: m.barWidth,
                spacing: m.barSpacing,
                minHeight: m.barMinHeight,
                maxHeight: m.barMaxHeight,
                activeOpacity: 0.92,
                idleOpacity: 0.45,
                color: controller.barColor
            )
            .frame(maxWidth: .infinity)
        }
        .padding(.leading, m.artworkInset)
        .padding(.trailing, m.trailingPadding)
        .frame(width: m.width, height: m.height)
        .capsuleBackground(
            controller.settings.pillBackground,
            tint: controller.capsuleTint,
            highlighted: controller.isPopoverOpen
        )
        .animation(.easeInOut(duration: 0.4), value: controller.capsuleTint)
    }

    @ViewBuilder
    private func artworkThumbnail(_ m: PillMetrics) -> some View {
        Group {
            if let artwork = controller.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                ZStack {
                    Color.primary.opacity(0.10)
                    Image(systemName: "music.note")
                        .font(.system(size: m.artwork * 0.48, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: m.artwork, height: m.artwork)
        .clipShape(Circle())
        .animation(.easeInOut(duration: 0.2), value: controller.track.trackKey)
    }
}
