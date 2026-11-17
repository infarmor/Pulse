import AppKit
import PulseBarCore
import SwiftUI

/// `NSHostingView` subclass that forwards all mouse hits directly to the parent `NSStatusBarButton`.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
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

    private static let restingEnvelope: [Double] = [0.0, 0.04, 0.08, 0.08, 0.04, 0.0]

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(0..<SpectrumAnalyzer.barCount, id: \.self) { index in
                let level = index < levels.count ? levels[index] : 0
                let effective = max(level, isPlaying ? 0.02 : Self.restingEnvelope[index])
                let height = minHeight + CGFloat(min(1.0, max(0.0, effective))) * (maxHeight - minHeight)

                Capsule(style: .continuous)
                    .fill(Color.white.opacity(isPlaying ? activeOpacity : idleOpacity))
                    .frame(width: barWidth, height: height)
            }
        }
        .frame(height: maxHeight, alignment: .center)
    }
}

/// Compact capsule widget rendered directly inside the macOS menu bar `NSStatusItem`.
struct StatusBarPillView: View {
    let controller: VisualizerController

    var body: some View {
        HStack(spacing: 6.5) {
            artworkThumbnail
            EqualizerBarsView(
                levels: controller.bars,
                isPlaying: controller.isActivelyVisualizing && controller.bars.contains(where: { $0 > 0.004 })
                    || controller.track.state == .playing
            )
        }
        .padding(.leading, 4.5)
        .padding(.trailing, 6.0)
        .frame(width: 52, height: 21)
        .background(
            Capsule(style: .continuous)
                .fill(Color(red: 0.14, green: 0.132, blue: 0.125, opacity: 0.90))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    Color.white.opacity(controller.isPopoverOpen ? 0.24 : 0.10),
                    lineWidth: 0.5
                )
        )
        .frame(width: 54, height: 22)
        .contentShape(Capsule())
    }

    @ViewBuilder
    private var artworkThumbnail: some View {
        Group {
            if let artwork = controller.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                ZStack {
                    Color.white.opacity(0.09)
                    Image(systemName: "music.note")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.70))
                }
            }
        }
        .frame(width: 15, height: 15)
        .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.4)
        )
        .animation(.easeInOut(duration: 0.2), value: controller.track.trackKey)
    }
}
