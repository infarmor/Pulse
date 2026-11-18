import AppKit
import Foundation
import Observation
import PulseBarCore
import ServiceManagement
import SwiftUI

/// Central `@MainActor` coordinator uniting Apple Music metadata, CoreAudio FFT processing,
/// user settings, and menu bar pill / popover state.
@MainActor
@Observable
final class VisualizerController {
    var track: TrackInfo = .empty
    var artwork: NSImage?
    /// Bar tint extracted from the current artwork (`nil` for grayscale / missing covers).
    var artworkAccent: Color?
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
    /// Height of the status item's window (the real menu bar height on this screen).
    var menuBarHeight: Double = 24

    var onPillVisibilityShouldUpdate: ((Bool) -> Void)?
    var onPillSizeChange: ((PillSize) -> Void)?

    private let settingsStore = DemoMode.isEnabled
        ? SettingsStore(defaults: UserDefaults(suiteName: "dev.pulsebar.demo") ?? .standard)
        : SettingsStore()
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
    /// False while the display sleeps or the user session is switched away.
    private var displayActive = true
    private var lastTotalCallbacks: UInt64 = .max
    private var silentSince: Date?
    private var animationInterval: TimeInterval = SpectrumTiming.active
    private var positionAccumulator: TimeInterval = 0

    private enum SpectrumTiming {
        static let active: TimeInterval = 1.0 / 50.0
        /// Slow probe in "any system audio" mode while everything is silent.
        static let idleProbe: TimeInterval = 1.0 / 4.0
    }

    init() {
        self.settings = DemoMode.settingsOverride ?? settingsStore.load()
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

    /// Color for equalizer bars: artwork tint when enabled and available, otherwise the
    /// menu bar's own foreground color.
    var barColor: Color {
        if settings.tintBarsWithArtwork, let artworkAccent {
            return artworkAccent
        }
        return .primary
    }

    /// Capsule background tint: artwork color when enabled and available.
    var capsuleTint: Color? {
        settings.tintGlassWithArtwork ? artworkAccent : nil
    }

    var isActivelyVisualizing: Bool {
        // Nothing to draw while the screen is off or the pill is hidden.
        guard displayActive, shouldShowPill || isPopoverOpen else { return false }
        if settings.onlyWhenMusicPlaying {
            // Automation denied: playback state is unknown, so fall back to audio-level gating.
            if automationPermissionDenied && track.isMusicRunning && track.state == .stopped {
                return true
            }
            return track.state == .playing
        }
        return true
    }

    func start() {
        if DemoMode.isEnabled {
            // Fictional track + generated cover; no Apple Music, no audio capture.
            track = DemoMode.track
            let cover = DemoMode.artwork()
            artwork = cover
            artworkAccent = Self.barTint(from: cover)
            updateAnimationTimerState()
            onPillVisibilityShouldUpdate?(shouldShowPill)
            return
        }
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
        bars = [Double](repeating: 0, count: SpectrumAnalyzer.barCount)
        audioEngine?.start()
        musicBridge.refreshFullState()
        updateAnimationTimerState()
    }

    /// Display sleep / screen lock / fast user switching: pause capture and drawing.
    func setDisplayActive(_ active: Bool) {
        guard displayActive != active else { return }
        displayActive = active
        if !active {
            animationTimer?.invalidate()
            animationTimer = nil
            bars = [Double](repeating: 0, count: SpectrumAnalyzer.barCount)
            analyzer.reset()
        }
        syncAudioIOState()
        updateAnimationTimerState()
    }

    // MARK: - Playback Actions

    func togglePlayPause() {
        if DemoMode.isEnabled {
            track.state = track.state == .playing ? .paused : .playing
            updateAnimationTimerState()
            return
        }
        musicBridge.togglePlayPause()
    }

    func nextTrack() {
        guard !DemoMode.isEnabled else { return }
        musicBridge.nextTrack()
    }

    func previousTrack() {
        guard !DemoMode.isEnabled else { return }
        musicBridge.previousTrack()
    }

    func seek(to seconds: TimeInterval) {
        if DemoMode.isEnabled {
            track.position = min(track.duration, max(0, seconds))
            return
        }
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

    func updatePillSize(_ size: PillSize) {
        settings.pillSize = size
        persistSettings()
        onPillSizeChange?(size)
    }

    func updatePillBackground(_ style: PillBackground) {
        settings.pillBackground = style
        persistSettings()
    }

    func updateTintGlassWithArtwork(_ value: Bool) {
        settings.tintGlassWithArtwork = value
        persistSettings()
    }

    func updateTintBarsWithArtwork(_ value: Bool) {
        settings.tintBarsWithArtwork = value
        persistSettings()
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
        } catch {
            pulseLog.error("login item change failed: \(error.localizedDescription, privacy: .public)")
        }
        if enabled && SMAppService.mainApp.status == .requiresApproval {
            // macOS wants the user to approve the login item in System Settings.
            SMAppService.openSystemSettingsLoginItems()
        }
        refreshLaunchAtLoginStatus()
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
    }

    // MARK: - Internal State Updates

    private func persistSettings() {
        settingsStore.save(settings)
    }

    private func handleAudioEngineStatus(_ status: AudioTapStatus) {
        pulseLog.notice("engine status -> \(String(describing: status), privacy: .public)")
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
        guard !DemoMode.isEnabled else { return }
        let wasVisible = shouldShowPill
        track = newTrack
        if newArtwork !== artwork {
            artwork = newArtwork
            artworkAccent = newArtwork.flatMap(Self.barTint(from:))
        }
        automationPermissionDenied = permissionDenied

        syncAudioIOState()
        updateAnimationTimerState()

        let nowVisible = shouldShowPill
        if wasVisible != nowVisible {
            onPillVisibilityShouldUpdate?(nowVisible)
        }
    }

    /// Downsamples the cover to 24×24 and picks a legible, vivid tint from it.
    private static func barTint(from image: NSImage) -> Color? {
        guard
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }

        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn, let accent = ArtworkPalette.accentColor(rgba: pixels, width: side, height: side) else {
            return nil
        }
        let tint = ArtworkPalette.legibleBarTint(accent)
        return Color(.sRGB, red: tint.red, green: tint.green, blue: tint.blue)
    }

    private func syncAudioIOState() {
        let shouldCapture = isActivelyVisualizing
        audioEngine?.setIOActive(shouldCapture)
    }

    private func handlePopoverOpenChange() {
        positionSyncTimer?.invalidate()
        positionSyncTimer = nil

        // Pill visibility / visualizing state may depend on the popover being open.
        syncAudioIOState()
        updateAnimationTimerState()
        onPillVisibilityShouldUpdate?(shouldShowPill || isPopoverOpen)

        if isPopoverOpen && !DemoMode.isEnabled {
            refreshLaunchAtLoginStatus()
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
            startAnimationTimer(interval: SpectrumTiming.active)
        } else {
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }

    private func startAnimationTimer(interval: TimeInterval) {
        animationTimer?.invalidate()
        animationInterval = interval
        lastFrameDate = Date()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stepFrame()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stepFrame() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastFrameDate)
        let dt = max(1.0 / 120.0, min(0.1, elapsed))
        lastFrameDate = now

        if DemoMode.isEnabled {
            bars = track.state == .playing
                ? DemoMode.bars(at: now.timeIntervalSinceReferenceDate)
                : [Double](repeating: 0, count: SpectrumAnalyzer.barCount)
            return
        }

        let active = isActivelyVisualizing
        let stats = ringBuffer.copyLatest(analyzer.fftSize, into: &sampleScratch)
        // No new callbacks since last frame: capture stalled (device gone, coreaudiod restart,
        // IO paused). Don't keep analysing the same frozen snapshot.
        let hasFreshAudio = stats.totalCallbacks != lastTotalCallbacks && stats.totalCallbacks > 0
        lastTotalCallbacks = stats.totalCallbacks

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

        // In "any system audio" mode, animate whenever RMS is above the noise floor.
        let audible = stats.rms > 1e-4
        let gateOnLevel = !settings.onlyWhenMusicPlaying
            || (automationPermissionDenied && track.state == .stopped)
        let analyse = active && hasFreshAudio && (gateOnLevel ? audible : true)

        let updatedBars = analyzer.process(
            samples: sampleScratch,
            sampleRate: stats.sampleRate,
            isActive: analyse,
            style: settings.equalizerStyle,
            sensitivity: settings.sensitivity,
            deltaTime: dt
        )
        // Publish only visible changes: every publish redraws the status item.
        if zip(updatedBars, bars).contains(where: { abs($0 - $1) > 0.004 }) {
            bars = updatedBars
        }

        // Advance the scrubber twice a second instead of every frame (keeps the popover calm).
        if isPopoverOpen && track.state == .playing && track.duration > 0 {
            positionAccumulator += min(elapsed, 1.0)   // real time, even at the 4 Hz probe
            if positionAccumulator >= 0.5 {
                track.position = min(track.duration, track.position + positionAccumulator)
                positionAccumulator = 0
            }
        } else {
            positionAccumulator = 0
        }

        // In level-gated mode, drop to a slow probe during silence and speed back up on sound.
        if gateOnLevel && active {
            if audible {
                silentSince = nil
                if animationInterval != SpectrumTiming.active {
                    startAnimationTimer(interval: SpectrumTiming.active)
                }
            } else if analyzer.isSettledAtRest {
                let since = silentSince ?? now
                silentSince = since
                if now.timeIntervalSince(since) > 1.0, animationInterval != SpectrumTiming.idleProbe {
                    startAnimationTimer(interval: SpectrumTiming.idleProbe)
                }
            }
        } else if animationInterval != SpectrumTiming.active, animationTimer != nil {
            silentSince = nil
            startAnimationTimer(interval: SpectrumTiming.active)
        }

        if !isActivelyVisualizing && analyzer.isSettledAtRest {
            bars = [Double](repeating: 0, count: SpectrumAnalyzer.barCount)
            updateAnimationTimerState()
        }
    }
}
