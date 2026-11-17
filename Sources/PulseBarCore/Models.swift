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

    public init(
        equalizerStyle: EqualizerStyle = .island,
        onlyWhenMusicPlaying: Bool = true,
        hidePillWhenStopped: Bool = false,
        sensitivity: Double = 1.0
    ) {
        self.equalizerStyle = equalizerStyle
        self.onlyWhenMusicPlaying = onlyWhenMusicPlaying
        self.hidePillWhenStopped = hidePillWhenStopped
        self.sensitivity = min(1.8, max(0.5, sensitivity))
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
