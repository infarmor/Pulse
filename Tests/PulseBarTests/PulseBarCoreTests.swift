import Foundation
import PulseBarCore
import Testing

@Suite("PulseBarCore Tests")
struct PulseBarCoreTests {
    @Test("AudioRingBuffer handles wrap-around and preserves latest samples")
    func ringBufferWrapAround() {
        let ring = AudioRingBuffer(capacity: 2_048)
        let chunkA = (0..<1_500).map { Float($0) * 0.001 }
        let chunkB = (1_500..<2_600).map { Float($0) * 0.001 }

        chunkA.withUnsafeBufferPointer { ring.write($0) }
        chunkB.withUnsafeBufferPointer { ring.write($0) }

        var out: [Float] = []
        let stats = ring.copyLatest(1_024, into: &out)
        #expect(out.count == 1_024)
        #expect(stats.totalCallbacks == 2)
        #expect(stats.nonZeroCallbacks == 2)
        #expect(abs(out.last! - Float(2_599) * 0.001) < 1e-5)
        #expect(abs(out.first! - Float(2_600 - 1_024) * 0.001) < 1e-5)
    }

    @Test("AudioRingBuffer detects zero-only callbacks cleanly")
    func ringBufferZeroTelemetry() {
        let ring = AudioRingBuffer(capacity: 2_048)
        let zeros = [Float](repeating: 0, count: 512)
        zeros.withUnsafeBufferPointer { ring.write($0) }
        zeros.withUnsafeBufferPointer { ring.write($0) }

        var out: [Float] = []
        let stats = ring.copyLatest(512, into: &out)
        #expect(stats.totalCallbacks == 2)
        #expect(stats.nonZeroCallbacks == 0)
        #expect(stats.rms == 0)
    }

    @Test("SpectrumAnalyzer responds to bass vs treble sine waves and decays when inactive")
    func spectrumAnalyzerFrequencyResponseAndDecay() {
        let analyzer = SpectrumAnalyzer(fftSize: 2_048)
        let sampleRate = 48_000.0

        func sineSamples(frequency: Double) -> [Float] {
            (0..<2_048).map { i in
                0.5 * sinf(Float(2.0 * Double.pi * frequency * Double(i) / sampleRate))
            }
        }

        let bassSamples = sineSamples(frequency: 170.0)
        var bassBars: [Double] = []
        for _ in 0..<15 {
            bassBars = analyzer.process(
                samples: bassSamples,
                sampleRate: sampleRate,
                isActive: true,
                style: .classic,
                sensitivity: 1.0,
                deltaTime: 0.02
            )
        }
        #expect(bassBars.count == 6)
        #expect(bassBars[1] > bassBars[5])
        #expect(bassBars[1] > 0.3)

        analyzer.reset()
        let trebleSamples = sineSamples(frequency: 2_600.0)
        var trebleBars: [Double] = []
        for _ in 0..<15 {
            trebleBars = analyzer.process(
                samples: trebleSamples,
                sampleRate: sampleRate,
                isActive: true,
                style: .classic,
                sensitivity: 1.0,
                deltaTime: 0.02
            )
        }
        #expect(trebleBars[4] > trebleBars[0])
        #expect(trebleBars[4] > 0.3)

        // Inactive frames should smoothly settle back to rest.
        for _ in 0..<80 {
            _ = analyzer.process(
                samples: trebleSamples,
                sampleRate: sampleRate,
                isActive: false,
                style: .island,
                sensitivity: 1.0,
                deltaTime: 0.02
            )
        }
        #expect(analyzer.isSettledAtRest)
    }

    @Test("SpectrumAnalyzer island style keeps balanced envelope for bass-heavy input")
    func spectrumAnalyzerIslandEnvelope() {
        let analyzer = SpectrumAnalyzer(fftSize: 2_048)
        let sampleRate = 48_000.0
        let mixSamples = (0..<2_048).map { i -> Float in
            let t = Double(i) / sampleRate
            return 0.4 * sinf(Float(2.0 * .pi * 160.0 * t))
                + 0.35 * sinf(Float(2.0 * .pi * 950.0 * t))
                + 0.15 * sinf(Float(2.0 * .pi * 6_000.0 * t))
        }

        var bars: [Double] = []
        for _ in 0..<20 {
            bars = analyzer.process(
                samples: mixSamples,
                sampleRate: sampleRate,
                isActive: true,
                style: .island,
                sensitivity: 1.0,
                deltaTime: 0.02
            )
        }
        #expect(bars[2] > bars[0])
        #expect(bars[3] > bars[5])
    }

    @Test("SettingsStore round-trips preferences")
    func settingsRoundTrip() {
        let suiteName = "dev.pulsebar.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        let expected = VisualizerSettings(
            equalizerStyle: .classic,
            onlyWhenMusicPlaying: false,
            hidePillWhenStopped: true,
            sensitivity: 1.35
        )
        store.save(expected)
        let loaded = store.load()
        #expect(loaded == expected)
    }

    @Test("formatPlaybackTime formats minutes and hours")
    func timeFormatting() {
        #expect(formatPlaybackTime(0) == "0:00")
        #expect(formatPlaybackTime(65) == "1:05")
        #expect(formatPlaybackTime(3661) == "1:01:01")
    }
}
