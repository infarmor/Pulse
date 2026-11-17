import AppKit
import PulseBarCore
import SwiftUI

/// Compact player and settings popover anchored to the menu bar pill.
struct PlayerPopoverView: View {
    let controller: VisualizerController
    let onQuit: () -> Void

    @State private var isDraggingScrubber = false
    @State private var dragProgress: Double = 0

    var body: some View {
        VStack(spacing: 14) {
            nowPlayingSection

            if controller.track.hasTrackMetadata && controller.track.duration > 0 {
                scrubberSection
            }

            transportControlsSection

            if controller.automationPermissionDenied {
                permissionBanner(
                    icon: "lock.shield",
                    title: "Нет доступа к управлению Apple Music",
                    message: "Разрешите PulseBar управлять приложением «Музыка» в разделе Автоматизация.",
                    actionTitle: "Открыть настройки",
                    onAction: controller.openAutomationPrivacySettings,
                    onRetry: controller.retryAutomationPermission
                )
            }

            if controller.audioStatus.needsAttention {
                audioStatusBanner
            }

            Divider()
                .opacity(0.45)

            settingsSection

            Divider()
                .opacity(0.45)

            footerSection
        }
        .padding(16)
        .frame(width: 316)
    }

    // MARK: - Sections

    private var nowPlayingSection: some View {
        HStack(spacing: 12) {
            Button(action: controller.openAppleMusic) {
                ZStack {
                    if let artwork = controller.artwork {
                        Image(nsImage: artwork)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                    } else {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.secondary.opacity(0.16))
                        Image(systemName: "music.note")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .help("Открыть Apple Music")

            VStack(alignment: .leading, spacing: 3) {
                if controller.track.hasTrackMetadata {
                    Text(controller.track.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)

                    if !controller.track.artist.isEmpty {
                        Text(controller.track.artist)
                            .font(.system(size: 12))
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
                        .font(.system(size: 13.5, weight: .semibold))

                    Text("Запустите Music, чтобы видеть обложку")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)

                    Button("Открыть Music") {
                        controller.openAppleMusic()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.top, 1)
                } else {
                    Text("Воспроизведение остановлено")
                        .font(.system(size: 13.5, weight: .semibold))

                    Text("Выберите трек в Apple Music")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var scrubberSection: some View {
        let duration = max(1, controller.track.duration)
        let currentPos = isDraggingScrubber ? dragProgress * duration : min(duration, controller.track.position)
        let fraction = min(1, max(0, currentPos / duration))

        return VStack(spacing: 5) {
            GeometryReader { geo in
                let width = max(1, geo.size.width)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.12))
                        .frame(height: 4)

                    Capsule()
                        .fill(Color.primary.opacity(0.75))
                        .frame(width: max(4, width * fraction), height: 4)
                }
                .frame(height: 14)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDraggingScrubber = true
                            dragProgress = min(1, max(0, value.location.x / width))
                        }
                        .onEnded { value in
                            let targetFraction = min(1, max(0, value.location.x / width))
                            isDraggingScrubber = false
                            controller.seek(to: targetFraction * duration)
                        }
                )
            }
            .frame(height: 14)

            HStack {
                Text(formatPlaybackTime(currentPos))
                Spacer()
                Text(formatPlaybackTime(duration))
            }
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var transportControlsSection: some View {
        HStack {
            HStack(spacing: 14) {
                Button(action: controller.previousTrack) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Предыдущий трек")

                Button(action: controller.togglePlayPause) {
                    Image(systemName: controller.track.state == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(Color.primary.opacity(0.13))
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(controller.track.state == .playing ? "Пауза" : "Воспроизвести")

                Button(action: controller.nextTrack) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Следующий трек")
            }

            Spacer()

            HStack(spacing: 6) {
                EqualizerBarsView(
                    levels: controller.bars,
                    isPlaying: controller.isActivelyVisualizing && controller.bars.contains(where: { $0 > 0.004 })
                        || controller.track.state == .playing,
                    barWidth: 2.2,
                    spacing: 1.8,
                    minHeight: 3,
                    maxHeight: 16,
                    activeOpacity: 0.85,
                    idleOpacity: 0.45
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(red: 0.14, green: 0.132, blue: 0.125, opacity: 0.90))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private var audioStatusBanner: some View {
        switch controller.audioStatus {
        case .silentSuspectedPermission:
            permissionBanner(
                icon: "waveform.badge.exclamationmark",
                title: "Системный звук не поступает",
                message: "Проверьте разрешение «Запись только системного аудио» для PulseBar в Настройках.",
                actionTitle: "Открыть настройки",
                onAction: controller.openAudioPrivacySettings,
                onRetry: controller.retryAudioCapture
            )
        case .failed(let reason):
            permissionBanner(
                icon: "exclamationmark.triangle",
                title: "Audio Tap не запущен",
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
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(.orange)
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(actionTitle, action: onAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Повторить", action: onRetry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.top, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 0.5)
        )
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Стиль полос")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { controller.settings.equalizerStyle },
                    set: { controller.updateEqualizerStyle($0) }
                )) {
                    ForEach(EqualizerStyle.allCases) { style in
                        Text(style.localizedName).tag(style)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 150)
            }

            HStack(spacing: 10) {
                Text("Чувствительность")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { controller.settings.sensitivity },
                        set: { controller.updateSensitivity($0) }
                    ),
                    in: 0.6...1.6
                )
                .controlSize(.small)
            }

            Toggle(
                "Только когда играет Apple Music",
                isOn: Binding(
                    get: { controller.settings.onlyWhenMusicPlaying },
                    set: { controller.updateOnlyWhenMusicPlaying($0) }
                )
            )
            .font(.system(size: 12))
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(
                "Скрывать капсулу когда на паузе",
                isOn: Binding(
                    get: { controller.settings.hidePillWhenStopped },
                    set: { controller.updateHidePillWhenStopped($0) }
                )
            )
            .font(.system(size: 12))
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(
                "Запускать при входе в систему",
                isOn: Binding(
                    get: { controller.launchAtLoginEnabled },
                    set: { controller.toggleLaunchAtLogin($0) }
                )
            )
            .font(.system(size: 12))
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private var footerSection: some View {
        HStack {
            Text("PulseBar 1.0")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Выход", action: onQuit)
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}
