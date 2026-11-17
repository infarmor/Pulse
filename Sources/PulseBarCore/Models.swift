import Foundation

/// Playback state of Apple Music.
public enum PlaybackState: String, Sendable, Equatable, Codable {
    case stopped
    case playing
    case paused
}

/// Snapshot of the active Apple Music track and playback status.
public struct TrackInfo: Sendable, Equatable {
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval
    public var position: TimeInterval
    public var soundVolume: Int
    public var state: PlaybackState
    public var isMusicRunning: Bool

    public init(
        title: String = "",
        artist: String = "",
        album: String = "",
        duration: TimeInterval = 0,
        position: TimeInterval = 0,
        soundVolume: Int = 100,
        state: PlaybackState = .stopped,
        isMusicRunning: Bool = false
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = max(0, duration)
        self.position = max(0, position)
        self.soundVolume = max(0, min(100, soundVolume))
        self.state = state
        self.isMusicRunning = isMusicRunning
    }

    public static let empty = TrackInfo()

    /// Stable identifier for caching artwork across play/pause updates of the same track.
    public var trackKey: String {
        guard !title.isEmpty || !artist.isEmpty || !album.isEmpty else {
            return ""
        }
        return "\(artist)\u{1F}\(album)\u{1F}\(title)"
    }

    public var hasTrackMetadata: Bool {
        !title.isEmpty && state != .stopped
    }
}

/// Visual arrangement of the 6 frequency bars inside the pill.
public enum EqualizerStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case island
    case classic

    public var id: String { rawValue }

    public var localizedName: String {
        switch self {
        case .island:
            return "Остров"
        case .classic:
            return "Спектр"
        }
    }
}

/// Size preset of the menu bar capsule.
public enum PillSize: String, CaseIterable, Codable, Sendable, Identifiable {
    case compact
    case regular
    case large

    public var id: String { rawValue }

    public var localizedName: String {
        switch self {
        case .compact: return "S"
        case .regular: return "M"
        case .large: return "L"
        }
    }

    public var metrics: PillMetrics {
        switch self {
        case .compact:
            return PillMetrics(
                statusItemWidth: 66, width: 64, height: 24, artwork: 18,
                contentSpacing: 7, trailingPadding: 9,
                barWidth: 2.6, barSpacing: 2.0, barMinHeight: 3, barMaxHeight: 13
            )
        case .regular:
            return PillMetrics(
                statusItemWidth: 78, width: 76, height: 28, artwork: 22,
                contentSpacing: 8, trailingPadding: 11,
                barWidth: 3.0, barSpacing: 2.4, barMinHeight: 3.5, barMaxHeight: 16
            )
        case .large:
            return PillMetrics(
                statusItemWidth: 92, width: 90, height: 32, artwork: 26,
                contentSpacing: 9, trailingPadding: 13,
                barWidth: 3.6, barSpacing: 2.8, barMinHeight: 4, barMaxHeight: 19
            )
        }
    }
}

/// Background material of the menu bar capsule.
public enum PillBackground: String, CaseIterable, Codable, Sendable, Identifiable {
    case glass
    case clearGlass
    case solid

    public var id: String { rawValue }

    public var localizedName: String {
        switch self {
        case .glass: return "Стекло"
        case .clearGlass: return "Прозрачное"
        case .solid: return "Тёмное"
        }
    }
}

/// Layout numbers (in points) for one `PillSize`.
public struct PillMetrics: Sendable, Equatable {
    public let statusItemWidth: Double
    public let width: Double
    public let height: Double
    /// Circular artwork diameter; inset so it sits concentric with the capsule's end.
    public let artwork: Double
    public let contentSpacing: Double
    public let trailingPadding: Double
    public let barWidth: Double
    public let barSpacing: Double
    public let barMinHeight: Double
    public let barMaxHeight: Double

    /// Equal inset on top, bottom, and leading edge so the round artwork is concentric with the capsule.
    public var artworkInset: Double { (height - artwork) / 2 }
}

/// Health state of the CoreAudio process tap stream.
public enum AudioTapStatus: Equatable, Sendable {
    case idle
    case starting
    case running
    case silentSuspectedPermission
    case failed(String)

    public var needsAttention: Bool {
        switch self {
        case .silentSuspectedPermission, .failed:
            return true
        case .idle, .starting, .running:
            return false
        }
    }
}

/// Persisted user preferences for PulseBar.
public struct VisualizerSettings: Codable, Equatable, Sendable {
    public var equalizerStyle: EqualizerStyle
    public var onlyWhenMusicPlaying: Bool
    public var hidePillWhenStopped: Bool
    public var sensitivity: Double
    public var pillSize: PillSize
    /// Tint equalizer bars with the dominant color of the album artwork.
    public var tintBarsWithArtwork: Bool
    public var pillBackground: PillBackground
    /// Tint the capsule background with the artwork color.
    public var tintGlassWithArtwork: Bool

    public init(
        equalizerStyle: EqualizerStyle = .island,
        onlyWhenMusicPlaying: Bool = true,
        hidePillWhenStopped: Bool = false,
        sensitivity: Double = 1.0,
        pillSize: PillSize = .regular,
        tintBarsWithArtwork: Bool = true,
        pillBackground: PillBackground = .glass,
        tintGlassWithArtwork: Bool = false
    ) {
        self.equalizerStyle = equalizerStyle
        self.onlyWhenMusicPlaying = onlyWhenMusicPlaying
        self.hidePillWhenStopped = hidePillWhenStopped
        self.sensitivity = min(1.8, max(0.5, sensitivity))
        self.pillSize = pillSize
        self.tintBarsWithArtwork = tintBarsWithArtwork
        self.pillBackground = pillBackground
        self.tintGlassWithArtwork = tintGlassWithArtwork
    }

    private enum CodingKeys: String, CodingKey {
        case equalizerStyle, onlyWhenMusicPlaying, hidePillWhenStopped, sensitivity, pillSize
        case tintBarsWithArtwork, pillBackground, tintGlassWithArtwork
    }

    /// Tolerates settings saved by older versions (missing keys fall back to defaults).
    public init(from decoder: Decoder) throws {
        let defaults = VisualizerSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            equalizerStyle: (try? c.decodeIfPresent(EqualizerStyle.self, forKey: .equalizerStyle)) ?? defaults.equalizerStyle,
            onlyWhenMusicPlaying: (try? c.decodeIfPresent(Bool.self, forKey: .onlyWhenMusicPlaying)) ?? defaults.onlyWhenMusicPlaying,
            hidePillWhenStopped: (try? c.decodeIfPresent(Bool.self, forKey: .hidePillWhenStopped)) ?? defaults.hidePillWhenStopped,
            sensitivity: (try? c.decodeIfPresent(Double.self, forKey: .sensitivity)) ?? defaults.sensitivity,
            pillSize: (try? c.decodeIfPresent(PillSize.self, forKey: .pillSize)) ?? defaults.pillSize,
            tintBarsWithArtwork: (try? c.decodeIfPresent(Bool.self, forKey: .tintBarsWithArtwork))
                ?? defaults.tintBarsWithArtwork,
            pillBackground: (try? c.decodeIfPresent(PillBackground.self, forKey: .pillBackground))
                ?? defaults.pillBackground,
            tintGlassWithArtwork: (try? c.decodeIfPresent(Bool.self, forKey: .tintGlassWithArtwork))
                ?? defaults.tintGlassWithArtwork
        )
    }
}

/// Formats seconds into `m:ss` or `h:mm:ss` for player scrubbers.
public func formatPlaybackTime(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds > 0 else {
        return "0:00"
    }
    let totalSeconds = Int(seconds.rounded(.down))
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let secs = totalSeconds % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%d:%02d", minutes, secs)
}
