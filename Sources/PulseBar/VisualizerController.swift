import AppKit
import Foundation
import Observation
import PulseBarCore
import ServiceManagement

/// Central `@MainActor` coordinator uniting Apple Music metadata, CoreAudio FFT processing,
/// user settings, and menu bar pill / popover state.
@MainActor
@Observable
final class VisualizerController {
    var track: TrackInfo = .empty
    var artwork: NSImage?
    var bars: [Double] = [Double](repeating: 0, count: SpectrumAnalyzer.barCount)
    var settings: VisualizerSettings
    var audioStatus: AudioTapStatus = .idle
    var automationPermissionDenied = false
    var isPopoverOpen = false {
        didSet {
            handlePopoverOpenChange()
        }
    }
    var launchAtLoginEnabled = false

    var onPillVisibilityShouldUpdate: ((Bool) -> Void)?

    private let settingsStore = SettingsStore()
    private let ringBuffer = AudioRingBuffer(capacity: 16_384)
    private let analyzer = SpectrumAnalyzer(fftSize: 2048)
    private let musicBridge = AppleMusicBridge()
    private var audioEngine: CoreAudioTapEngine?

    private var sampleScratch: [Float]
    private var animationTimer: Timer?
    private var positionSyncTimer: Timer?
    private var lastFrameDate = Date()
    private var tapStartupTime: Date?
    private var hasPlayedAudioOnce = false

    init() {
        self.settings = settingsStore.load()
        self.sampleScratch = [Float](repeating: 0, count: analyzer.fftSize)
        self.launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)

        self.audioEngine = CoreAudioTapEngine(ringBuffer: ringBuffer) { [weak self] status in
            Task { @MainActor [weak self] in
                self?.handleAudioEngineStatus(status)
            }
        }

        musicBridge.onStateChange = { [weak self] newTrack, newArtwork, denied in
            Task { @MainActor [weak self] in
                self?.handleMusicUpdate(track: newTrack, artwork: newArtwork, permissionDenied: denied)
            }
        }
    }

    var shouldShowPill: Bool {
        if !settings.hidePillWhenStopped {
            return true
        }
        return track.state == .playing || track.state == .paused
    }

    var isActivelyVisualizing: Bool {
        if settings.onlyWhenMusicPlaying {
            return track.state == .playing
        }
        return true
    }

    func start() {
        musicBridge.start()
        audioEngine?.start()
        updateAnimationTimerState()
        onPillVisibilityShouldUpdate?(shouldShowPill)
    }

    func stop() {
        animationTimer?.invalidate()
        animationTimer = nil
        positionSyncTimer?.invalidate()
        positionSyncTimer = nil
        musicBridge.stop()
        audioEngine?.stop()
    }

    func handleSystemWillSleep() {
        animationTimer?.invalidate()
        animationTimer = nil
        audioEngine?.stop()
    }

    func handleSystemDidWake() {
        ringBuffer.reset()
        analyzer.reset()
        audioEngine?.start()
        musicBridge.refreshFullState()
        updateAnimationTimerState()
    }

    // MARK: - Playback Actions

    func togglePlayPause() {
        musicBridge.togglePlayPause()
    }

    func nextTrack() {
        musicBridge.nextTrack()
    }

    func previousTrack() {
        musicBridge.previousTrack()
    }

    func seek(to seconds: TimeInterval) {
        musicBridge.seek(to: seconds)
    }

    func openAppleMusic() {
        musicBridge.openAppleMusic()
    }

    // MARK: - Permissions & Settings

    func retryAudioCapture() {
        ringBuffer.reset()
        hasPlayedAudioOnce = false
        tapStartupTime = Date()
        audioEngine?.restart()
    }

    func retryAutomationPermission() {
        automationPermissionDenied = false
        musicBridge.refreshFullState()
    }

    func openAudioPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func openAutomationPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    func updateEqualizerStyle(_ style: EqualizerStyle) {
        settings.equalizerStyle = style
        persistSettings()
    }

    func updateOnlyWhenMusicPlaying(_ value: Bool) {
        settings.onlyWhenMusicPlaying = value
        persistSettings()
        syncAudioIOState()
        updateAnimationTimerState()
    }

    func updateHidePillWhenStopped(_ value: Bool) {
        settings.hidePillWhenStopped = value
        persistSettings()
        onPillVisibilityShouldUpdate?(shouldShowPill)
    }

    func updateSensitivity(_ value: Double) {
        settings.sensitivity = min(1.8, max(0.5, value))
        persistSettings()
    }

    func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
        } catch {
            launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
        }
    }

    // MARK: - Internal State Updates

    private func persistSettings() {
        settingsStore.save(settings)
    }

    private func handleAudioEngineStatus(_ status: AudioTapStatus) {
        audioStatus = status
        if status == .running {
            tapStartupTime = Date()
            // Allow ~1.5s after initial start so macOS finishes TCC check cleanly before idling.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                self?.syncAudioIOState()
            }
        }
    }

    private func handleMusicUpdate(track newTrack: TrackInfo, artwork newArtwork: NSImage?, permissionDenied: Bool) {
        let wasVisible = shouldShowPill
        track = newTrack
        artwork = newArtwork
        automationPermissionDenied = permissionDenied

        syncAudioIOState()
        updateAnimationTimerState()

        let nowVisible = shouldShowPill
        if wasVisible != nowVisible {
            onPillVisibilityShouldUpdate?(nowVisible)
        }
    }

    private func syncAudioIOState() {
        let shouldCapture = isActivelyVisualizing
        audioEngine?.setIOActive(shouldCapture)
    }

    private func handlePopoverOpenChange() {
        positionSyncTimer?.invalidate()
        positionSyncTimer = nil

        if isPopoverOpen {
            musicBridge.refreshFullState()
            let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.musicBridge.refreshPlaybackPosition()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            positionSyncTimer = timer
        }
    }

    private func updateAnimationTimerState() {
        let needsTimer = isActivelyVisualizing || !analyzer.isSettledAtRest
        if needsTimer {
            guard animationTimer == nil else { return }
            lastFrameDate = Date()
            let timer = Timer(timeInterval: 1.0 / 50.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.stepFrame()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            animationTimer = timer
        } else {
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }

    private func stepFrame() {
        let now = Date()
        let dt = max(1.0 / 120.0, min(0.1, now.timeIntervalSince(lastFrameDate)))
        lastFrameDate = now

        let active = isActivelyVisualizing
        let stats = ringBuffer.copyLatest(analyzer.fftSize, into: &sampleScratch)

        if stats.nonZeroCallbacks > 0 {
            hasPlayedAudioOnce = true
            if audioStatus == .silentSuspectedPermission {
                audioStatus = .running
            }
        } else if
            !hasPlayedAudioOnce,
            track.state == .playing,
            track.soundVolume > 0,
            audioStatus == .running,
            let started = tapStartupTime,
            now.timeIntervalSince(started) > 2.5,
            stats.totalCallbacks > 90
        {
            audioStatus = .silentSuspectedPermission
        }

        // In "any system audio" mode while Apple Music is idle, animate whenever RMS > noise floor.
        let effectiveActive: Bool
        if settings.onlyWhenMusicPlaying {
            effectiveActive = active
        } else {
            effectiveActive = stats.rms > 1e-4 || !analyzer.isSettledAtRest
        }

        let updatedBars = analyzer.process(
            samples: sampleScratch,
            sampleRate: stats.sampleRate,
            isActive: effectiveActive && (settings.onlyWhenMusicPlaying ? true : stats.rms > 1e-4),
            style: settings.equalizerStyle,
            sensitivity: settings.sensitivity,
            deltaTime: dt
        )
        bars = updatedBars

        if isPopoverOpen && track.state == .playing && track.duration > 0 {
            track.position = min(track.duration, track.position + dt)
        }

        if !isActivelyVisualizing && analyzer.isSettledAtRest {
            bars = [Double](repeating: 0, count: SpectrumAnalyzer.barCount)
            updateAnimationTimerState()
        }
    }
}
