import AppKit
import PulseBarCore
import SwiftUI

/// Player and settings menu anchored to the menu bar capsule.
struct PlayerPopoverView: View {
    let controller: VisualizerController
    let onQuit: () -> Void

    @State private var isDraggingScrubber = false
    @State private var dragProgress: Double = 0
    @AppStorage("dev.pulsebar.ui.settingsExpanded") private var settingsExpandedStored = false

    private var settingsExpanded: Bool {
        get { DemoMode.settingsExpandedOverride ?? settingsExpandedStored }
        nonmutating set { settingsExpandedStored = newValue }
    }

    private static let width: CGFloat = 300
    private static let appVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"

    var body: some View {
        VStack(spacing: 0) {
            playerCard

            VStack(spacing: 10) {
                banners
                settingsDisclosure
                if settingsExpanded {
                    settingsGroups
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                footer
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
        .frame(width: Self.width)
        .animation(.easeInOut(duration: 0.22), value: settingsExpanded)
    }

    // MARK: - Player

    private var playerCard: some View {
        VStack(spacing: 14) {
            nowPlaying
            if controller.track.hasTrackMetadata && controller.track.duration > 0 {
                scrubber
            }
            transport
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(artworkBackdrop)
    }

    /// Soft, blurred copy of the cover behind the player for a bit of the track's color.
    @ViewBuilder
    private var artworkBackdrop: some View {
        if let artwork = controller.artwork {
            Image(nsImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .blur(radius: 40)
                .opacity(0.55)
                .mask(
                    LinearGradient(
                        colors: [.black, .black.opacity(0.6), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipped()
                .allowsHitTesting(false)
        }
    }

    private var nowPlaying: some View {
        HStack(spacing: 14) {
            Button(action: controller.openAppleMusic) {
                ZStack {
                    if let artwork = controller.artwork {
                        Image(nsImage: artwork)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Color.primary.opacity(0.08)
                        Image(systemName: "music.note")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .help("Открыть Apple Music")

            VStack(alignment: .leading, spacing: 3) {
                if controller.track.hasTrackMetadata {
                    Text(controller.track.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)
                    if !controller.track.artist.isEmpty {
                        Text(controller.track.artist)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !controller.track.album.isEmpty {
                        Text(controller.track.album)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                } else if !controller.track.isMusicRunning {
                    Text("Apple Music не запущен")
                        .font(.system(size: 14, weight: .semibold))
                    Button("Открыть Музыку", action: controller.openAppleMusic)
                        .buttonStyle(.link)
                        .font(.system(size: 12, weight: .medium))
                } else {
                    Text("Ничего не играет")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Выберите трек в Apple Music")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var scrubber: some View {
        let duration = max(1, controller.track.duration)
        let currentPos = isDraggingScrubber ? dragProgress * duration : min(duration, controller.track.position)
        let fraction = min(1, max(0, currentPos / duration))

        return VStack(spacing: 4) {
            GeometryReader { geo in
                let width = max(1, geo.size.width)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.14))
                    Capsule()
                        .fill(Color.primary.opacity(0.8))
                        .frame(width: max(4, width * fraction))
                }
                .frame(height: isDraggingScrubber ? 6 : 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDraggingScrubber = true
                            dragProgress = min(1, max(0, value.location.x / width))
                        }
                        .onEnded { value in
                            let target = min(1, max(0, value.location.x / width))
                            isDraggingScrubber = false
                            controller.seek(to: target * duration)
                        }
                )
                .animation(.easeOut(duration: 0.12), value: isDraggingScrubber)
            }
            .frame(height: 12)

            HStack {
                Text(formatPlaybackTime(currentPos))
                Spacer()
                Text("-" + formatPlaybackTime(max(0, duration - currentPos)))
            }
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: 28) {
            transportButton("backward.fill", size: 16, help: "Предыдущий трек", action: controller.previousTrack)

            Button(action: controller.togglePlayPause) {
                Image(systemName: controller.track.state == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 46, height: 46)
                    .capsuleBackground(.glass)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(controller.track.state == .playing ? "Пауза" : "Воспроизвести")

            transportButton("forward.fill", size: 16, help: "Следующий трек", action: controller.nextTrack)
        }
        .frame(maxWidth: .infinity)
    }

    private func transportButton(_ symbol: String, size: CGFloat, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Banners

    @ViewBuilder
    private var banners: some View {
        if controller.automationPermissionDenied {
            permissionBanner(
                icon: "lock.shield",
                title: "Нет доступа к Apple Music",
                message: "Разрешите Pulse управлять приложением «Музыка» в разделе «Автоматизация».",
                actionTitle: "Открыть настройки",
                onAction: controller.openAutomationPrivacySettings,
                onRetry: controller.retryAutomationPermission
            )
        }
        switch controller.audioStatus {
        case .silentSuspectedPermission:
            permissionBanner(
                icon: "waveform.badge.exclamationmark",
                title: "Системный звук не поступает",
                message: "Проверьте разрешение «Запись только системного аудио» для Pulse.",
                actionTitle: "Открыть настройки",
                onAction: controller.openAudioPrivacySettings,
                onRetry: controller.retryAudioCapture
            )
        case .failed(let reason):
            permissionBanner(
                icon: "exclamationmark.triangle",
                title: "Захват звука не запущен",
                message: reason,
                actionTitle: "Настройки",
                onAction: controller.openAudioPrivacySettings,
                onRetry: controller.retryAudioCapture
            )
        case .idle, .starting, .running:
            EmptyView()
        }
    }

    private func permissionBanner(
        icon: String,
        title: String,
        message: String,
        actionTitle: String,
        onAction: @escaping () -> Void,
        onRetry: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .symbolRenderingMode(.multicolor)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(actionTitle, action: onAction)
                    .buttonStyle(.borderedProminent)
                Button("Повторить", action: onRetry)
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }

    // MARK: - Settings

    private var settingsDisclosure: some View {
        Button {
            settingsExpanded.toggle()
        } label: {
            HStack {
                Label("Настройки", systemImage: "slider.horizontal.3")
                    .font(.system(size: 12.5, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(settingsExpanded ? 90 : 0))
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(settingsExpanded ? 0.07 : 0.04))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var settingsGroups: some View {
        VStack(spacing: 10) {
            settingsGroup("Капсула") {
                row("Размер") {
                    Picker("", selection: binding(\.pillSize, controller.updatePillSize)) {
                        ForEach(PillSize.allCases) { Text($0.localizedName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 132)
                }
                rowDivider
                row("Фон") {
                    Picker("", selection: binding(\.pillBackground, controller.updatePillBackground)) {
                        ForEach(PillBackground.allCases) { Text($0.localizedName).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                rowDivider
                row("Полосы") {
                    Picker("", selection: binding(\.equalizerStyle, controller.updateEqualizerStyle)) {
                        ForEach(EqualizerStyle.allCases) { Text($0.localizedName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 132)
                }
                rowDivider
                toggleRow("Полосы в цвет обложки", \.tintBarsWithArtwork, controller.updateTintBarsWithArtwork)
                rowDivider
                toggleRow("Фон в цвет обложки", \.tintGlassWithArtwork, controller.updateTintGlassWithArtwork)
            }

            settingsGroup("Звук") {
                row("Чувствительность") {
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.wave.1.fill")
                        Slider(value: binding(\.sensitivity, controller.updateSensitivity), in: 0.6...1.6)
                            .controlSize(.mini)
                            .frame(width: 72)
                        Image(systemName: "speaker.wave.3.fill")
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                }
                rowDivider
                toggleRow("Только Apple Music", \.onlyWhenMusicPlaying, controller.updateOnlyWhenMusicPlaying)
            }

            settingsGroup("Система") {
                toggleRow("Скрывать без музыки", \.hidePillWhenStopped, controller.updateHidePillWhenStopped)
                rowDivider
                row("Запускать при входе") {
                    Toggle("", isOn: Binding(
                        get: { controller.launchAtLoginEnabled },
                        set: { controller.toggleLaunchAtLogin($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
            }
        }
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
        }
    }

    private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12.5))
                .lineLimit(1)
            Spacer(minLength: 8)
            control()
                .labelsHidden()
        }
        .frame(minHeight: 32)
    }

    private func toggleRow(
        _ title: String,
        _ keyPath: KeyPath<VisualizerSettings, Bool>,
        _ update: @escaping @MainActor (Bool) -> Void
    ) -> some View {
        row(title) {
            Toggle("", isOn: binding(keyPath, update))
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }

    private var rowDivider: some View {
        Divider().opacity(0.5)
    }

    private func binding<Value>(
        _ keyPath: KeyPath<VisualizerSettings, Value>,
        _ update: @escaping @MainActor (Value) -> Void
    ) -> Binding<Value> {
        Binding(get: { controller.settings[keyPath: keyPath] }, set: update)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            HStack(spacing: 5) {
                Image(systemName: "waveform")
                Text("Pulse \(Self.appVersion)")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)
            Spacer()
            Button(action: onQuit) {
                Label("Выйти", systemImage: "power")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
}
