import Foundation

/// Persists `VisualizerSettings` in `UserDefaults`.
public final class SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "dev.pulsebar.visualizer.settings"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> VisualizerSettings {
        guard
            let data = defaults.data(forKey: key),
            let decoded = try? JSONDecoder().decode(VisualizerSettings.self, from: data)
        else {
            return VisualizerSettings()
        }
        return decoded
    }

    public func save(_ settings: VisualizerSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
