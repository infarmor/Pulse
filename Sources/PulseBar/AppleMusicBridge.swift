import AppKit
import Foundation
import ImageIO
import PulseBarCore

/// Bridges Apple Music playback state, track metadata, artwork, and transport controls
/// using `DistributedNotificationCenter` and `NSAppleScript` without ever launching
/// `Music.app` unexpectedly.
@MainActor
final class AppleMusicBridge {
    private nonisolated static let musicBundleID = "com.apple.Music"

    var onStateChange: ((TrackInfo, NSImage?, Bool) -> Void)?

    private let scriptQueue = DispatchQueue(label: "dev.pulsebar.music-applescript", qos: .userInitiated)
    private var distributedObserver: NSObjectProtocol?
    private var launchObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?

    private var currentTrack: TrackInfo = .empty
    private var currentArtwork: NSImage?
    private var cachedArtworkKey: String = ""
    private var automationPermissionDenied = false
    private var artworkRetryTask: Task<Void, Never>?

    func start() {
        installObservers()
        refreshFullState()
    }

    func stop() {
        artworkRetryTask?.cancel()
        artworkRetryTask = nil

        if let distributedObserver {
            DistributedNotificationCenter.default().removeObserver(distributedObserver)
            self.distributedObserver = nil
        }
        let wsCenter = NSWorkspace.shared.notificationCenter
        if let launchObserver {
            wsCenter.removeObserver(launchObserver)
            self.launchObserver = nil
        }
        if let terminateObserver {
            wsCenter.removeObserver(terminateObserver)
            self.terminateObserver = nil
        }
    }

    /// Refreshes metadata and (if needed) artwork from Apple Music when running.
    func refreshFullState() {
        guard isMusicAppRunning() else {
            artworkRetryTask?.cancel()
            currentArtwork = nil
            cachedArtworkKey = ""
            currentTrack = TrackInfo(isMusicRunning: false)
            emitUpdate()
            return
        }

        let previousKey = cachedArtworkKey
        let hasCachedArtwork = currentArtwork != nil

        scriptQueue.async { [weak self] in
            let metaResult = Self.fetchMetadataViaAppleScript()
            var fetchedArtworkData: Data?
            var artworkMissingForNow = false

            if let info = metaResult.track, info.hasTrackMetadata {
                let needsArtwork = (info.trackKey != previousKey) || !hasCachedArtwork
                if needsArtwork {
                    fetchedArtworkData = Self.fetchArtworkDataViaAppleScript()
                    artworkMissingForNow = (fetchedArtworkData == nil)
                }
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.automationPermissionDenied = metaResult.permissionDenied

                guard self.isMusicAppRunning() else {
                    self.currentTrack = TrackInfo(isMusicRunning: false)
                    self.currentArtwork = nil
                    self.cachedArtworkKey = ""
                    self.emitUpdate()
                    return
                }

                if let track = metaResult.track {
                    self.applyFetchedState(
                        track: track,
                        artworkData: fetchedArtworkData,
                        artworkMissing: artworkMissingForNow
                    )
                } else {
                    // Music is running even if we couldn't read it (e.g. Automation denied).
                    self.currentTrack.isMusicRunning = true
                    self.emitUpdate()
                }
            }
        }
    }

    /// Lightweight refresh of `player position` while the popover is open.
    func refreshPlaybackPosition() {
        guard isMusicAppRunning(), currentTrack.hasTrackMetadata else { return }

        scriptQueue.async { [weak self] in
            let pos = Self.fetchPositionViaAppleScript()
            Task { @MainActor [weak self] in
                guard let self, let pos else { return }
                self.currentTrack.position = pos
                self.emitUpdate()
            }
        }
    }

    func togglePlayPause() {
        sendSimpleCommand("playpause")
    }

    func nextTrack() {
        sendSimpleCommand("next track")
    }

    func previousTrack() {
        sendSimpleCommand("previous track")
    }

    func seek(to seconds: TimeInterval) {
        guard isMusicAppRunning() else { return }
        let clamped = max(0, seconds)
        currentTrack.position = clamped
        emitUpdate()

        let scriptSource = """
        tell application id "com.apple.Music"
            set player position to \(String(format: "%.3f", clamped))
        end tell
        """
        scriptQueue.async { [weak self] in
            _ = Self.runAppleScript(scriptSource)
            Task { @MainActor [weak self] in
                self?.refreshPlaybackPosition()
            }
        }
    }

    func openAppleMusic() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.musicBundleID) else {
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.refreshFullState()
            }
        }
    }

    private func sendSimpleCommand(_ command: String) {
        let musicRunning = isMusicAppRunning()
        if !musicRunning && command != "playpause" {
            // Next / previous make no sense with Music closed.
            return
        }

        // With Music closed, "play" launches it in the background and starts playback.
        let source = musicRunning
            ? """
            tell application id "com.apple.Music"
                \(command)
            end tell
            """
            : """
            tell application id "com.apple.Music" to play
            """
        let allowLaunch = !musicRunning
        scriptQueue.async { [weak self] in
            let result = Self.runAppleScript(source, allowLaunch: allowLaunch)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if result.permissionDenied {
                    self.automationPermissionDenied = true
                    self.emitUpdate()
                    return
                }
                self.automationPermissionDenied = false
                try? await Task.sleep(for: .milliseconds(120))
                self.refreshFullState()
            }
        }
    }

    private func installObservers() {
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let userInfo = notification.userInfo
            let rawState = userInfo?["Player State"] as? String
            let title = userInfo?["Name"] as? String
            let artist = userInfo?["Artist"] as? String
            let album = userInfo?["Album"] as? String
            let totalTimeMs = (userInfo?["Total Time"] as? NSNumber)?.doubleValue

            Task { @MainActor [weak self] in
                self?.handlePlayerInfoNotification(
                    rawState: rawState,
                    title: title,
                    artist: artist,
                    album: album,
                    totalTimeMs: totalTimeMs
                )
            }
        }

        let wsCenter = NSWorkspace.shared.notificationCenter
        launchObserver = wsCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app.bundleIdentifier == Self.musicBundleID
            else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                self?.refreshFullState()
            }
        }

        terminateObserver = wsCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app.bundleIdentifier == Self.musicBundleID
            else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.artworkRetryTask?.cancel()
                self.currentTrack = TrackInfo(isMusicRunning: false)
                self.currentArtwork = nil
                self.cachedArtworkKey = ""
                self.emitUpdate()
            }
        }
    }

    private func handlePlayerInfoNotification(
        rawState: String?,
        title: String?,
        artist: String?,
        album: String?,
        totalTimeMs: Double?
    ) {
        guard isMusicAppRunning() else {
            currentTrack = TrackInfo(isMusicRunning: false)
            currentArtwork = nil
            cachedArtworkKey = ""
            emitUpdate()
            return
        }

        let mappedState: PlaybackState = switch rawState {
        case "Playing": .playing
        case "Paused": .paused
        default: .stopped
        }

        if mappedState == .stopped {
            artworkRetryTask?.cancel()
            currentTrack = TrackInfo(state: .stopped, isMusicRunning: true)
            currentArtwork = nil
            cachedArtworkKey = ""
            emitUpdate()
            return
        }

        var updated = currentTrack
        updated.isMusicRunning = true
        updated.state = mappedState
        if let title { updated.title = title }
        if let artist { updated.artist = artist }
        if let album { updated.album = album }
        if let totalTimeMs, totalTimeMs > 0 {
            updated.duration = totalTimeMs / 1000.0
        }

        let trackChanged = updated.trackKey != cachedArtworkKey
        if trackChanged {
            updated.position = 0
            currentArtwork = nil
        }

        currentTrack = updated
        emitUpdate()

        // Pull exact position, volume, and artwork via AppleScript.
        refreshFullState()
    }

    private func applyFetchedState(track: TrackInfo, artworkData: Data?, artworkMissing: Bool) {
        let newKey = track.trackKey
        let trackChanged = newKey != cachedArtworkKey

        currentTrack = track

        if !track.hasTrackMetadata {
            artworkRetryTask?.cancel()
            currentArtwork = nil
            cachedArtworkKey = ""
            emitUpdate()
            return
        }

        if let artworkData, let decoded = Self.downsampledImage(from: artworkData, maxDimension: 256) {
            artworkRetryTask?.cancel()
            currentArtwork = decoded
            cachedArtworkKey = newKey
        } else if trackChanged {
            currentArtwork = nil
            cachedArtworkKey = newKey
        }

        emitUpdate()

        if artworkMissing && currentArtwork == nil && !newKey.isEmpty {
            scheduleArtworkRetry(expectedKey: newKey)
        }
    }

    /// Apple Music streaming tracks can take ~0.5–1.5s to cache cover art after track switch.
    private func scheduleArtworkRetry(expectedKey: String) {
        artworkRetryTask?.cancel()
        artworkRetryTask = Task { [weak self] in
            for delayMs in [650, 1400] {
                try? await Task.sleep(for: .milliseconds(delayMs))
                guard !Task.isCancelled, let self else { return }
                guard self.isMusicAppRunning(), self.cachedArtworkKey == expectedKey, self.currentArtwork == nil else {
                    return
                }

                let data = await withCheckedContinuation { continuation in
                    self.scriptQueue.async {
                        continuation.resume(returning: Self.fetchArtworkDataViaAppleScript())
                    }
                }

                guard !Task.isCancelled else { return }
                if let data, let image = Self.downsampledImage(from: data, maxDimension: 256), self.cachedArtworkKey == expectedKey {
                    self.currentArtwork = image
                    self.emitUpdate()
                    return
                }
            }
        }
    }

    private func emitUpdate() {
        onStateChange?(currentTrack, currentArtwork, automationPermissionDenied)
    }

    private func isMusicAppRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.musicBundleID).isEmpty
    }

    // MARK: - AppleScript Helpers (executed on `scriptQueue`)

    private struct MetadataResult: Sendable {
        let track: TrackInfo?
        let permissionDenied: Bool
    }

    private struct ScriptExecutionResult {
        let descriptor: NSAppleEventDescriptor?
        let permissionDenied: Bool
    }

    /// Runs AppleScript against Music. Unless `allowLaunch` is set, the script is wrapped in an
    /// `is running` check evaluated *inside* AppleScript, so a script queued just before the user
    /// quits Music can never relaunch it.
    private nonisolated static func runAppleScript(_ source: String, allowLaunch: Bool = false) -> ScriptExecutionResult {
        if !allowLaunch {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: musicBundleID)
                .contains { !$0.isTerminated }
            guard running else {
                return ScriptExecutionResult(descriptor: nil, permissionDenied: false)
            }
        }
        let fullSource = allowLaunch
            ? source
            : """
            if application id "\(musicBundleID)" is running then
            \(source)
            end if
            """
        guard let script = NSAppleScript(source: fullSource) else {
            return ScriptExecutionResult(descriptor: nil, permissionDenied: false)
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let errorCode = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            return ScriptExecutionResult(
                descriptor: nil,
                permissionDenied: errorCode == -1743 // errAEEventNotPermitted
            )
        }
        return ScriptExecutionResult(descriptor: result, permissionDenied: false)
    }

    private nonisolated static func fetchMetadataViaAppleScript() -> MetadataResult {
        let source = """
        tell application id "com.apple.Music"
            set stEnum to player state
            if stEnum is stopped then
                return {"stopped", "", "", "", 0.0, 0.0, sound volume}
            end if
            set stText to "paused"
            if stEnum is playing then
                set stText to "playing"
            end if
            set tName to ""
            set tArtist to ""
            set tAlbum to ""
            set tDur to 0.0
            try
                set tName to name of current track
                set tArtist to artist of current track
                set tAlbum to album of current track
                set tDur to duration of current track
            end try
            set pos to 0.0
            try
                set pos to player position
            end try
            set vol to 100
            try
                set vol to sound volume
            end try
            return {stText, tName, tArtist, tAlbum, tDur, pos, vol}
        end tell
        """

        let exec = runAppleScript(source)
        guard let list = exec.descriptor, list.numberOfItems >= 7 else {
            return MetadataResult(track: nil, permissionDenied: exec.permissionDenied)
        }

        let stateStr = list.atIndex(1)?.stringValue ?? "stopped"
        let title = list.atIndex(2)?.stringValue ?? ""
        let artist = list.atIndex(3)?.stringValue ?? ""
        let album = list.atIndex(4)?.stringValue ?? ""
        let duration = list.atIndex(5)?.doubleValue ?? 0
        let position = list.atIndex(6)?.doubleValue ?? 0
        let volume = Int(list.atIndex(7)?.int32Value ?? 100)

        let state: PlaybackState = switch stateStr {
        case "playing": .playing
        case "paused": .paused
        default: .stopped
        }

        let info = TrackInfo(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            position: position,
            soundVolume: volume,
            state: state,
            isMusicRunning: true
        )
        return MetadataResult(track: info, permissionDenied: false)
    }

    private nonisolated static func fetchPositionViaAppleScript() -> TimeInterval? {
        let source = """
        tell application id "com.apple.Music"
            if player state is stopped then return -1.0
            return player position
        end tell
        """
        let exec = runAppleScript(source)
        guard let value = exec.descriptor?.doubleValue, value >= 0 else {
            return nil
        }
        return value
    }

    private nonisolated static func fetchArtworkDataViaAppleScript() -> Data? {
        let rawSource = """
        tell application id "com.apple.Music"
            if (count of artworks of current track) > 0 then
                return raw data of artwork 1 of current track
            end if
        end tell
        """
        if let data = runAppleScript(rawSource).descriptor?.data, !data.isEmpty {
            return data
        }

        let pictSource = """
        tell application id "com.apple.Music"
            if (count of artworks of current track) > 0 then
                return data of artwork 1 of current track
            end if
        end tell
        """
        if let data = runAppleScript(pictSource).descriptor?.data, !data.isEmpty {
            return data
        }
        return nil
    }

    private nonisolated static func downsampledImage(from data: Data, maxDimension: CGFloat) -> NSImage? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension)
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
        }
        return NSImage(data: data)
    }
}
