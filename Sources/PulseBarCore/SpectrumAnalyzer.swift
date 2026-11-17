import Accelerate
import Foundation

/// Real-time 6-band FFT spectrum analyzer optimized for compact menu bar equalizers.
public final class SpectrumAnalyzer {
    public static let barCount = 6

    public let fftSize: Int
    private let halfSize: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup

    private var window: [Float]
    private var windowed: [Float]
    private var realBuffer: [Float]
    private var imagBuffer: [Float]
    private var squaredMagnitudes: [Float]

    private var agcPeakDB: Float = SpectrumAnalyzer.initialAGCPeakDB
    private static let initialAGCPeakDB: Float = -30.0
    private var smoothedBars: [Double] = [Double](repeating: 0, count: barCount)

    private static let bandRanges: [(low: Double, high: Double)] = [
        (45, 110),     // 0: Sub-bass
        (110, 260),    // 1: Bass / kick punch
        (260, 650),    // 2: Low-mids / warmth
        (650, 1600),   // 3: Mids / vocals
        (1600, 4200),  // 4: Upper-mids / presence
        (4200, 11500)  // 5: Brilliance / hi-hats
    ]

    private static let spectralTiltGains: [Float] = [
        0.82, 0.92, 1.05, 1.28, 1.60, 2.15
    ]

    public init(fftSize: Int = 2048) {
        precondition(fftSize > 0 && (fftSize & (fftSize - 1)) == 0, "fftSize must be a power of 2")
        self.fftSize = fftSize
        self.halfSize = fftSize / 2
        self.log2n = vDSP_Length(log2(Double(fftSize)))
        guard let setup = vDSP_create_fftsetup(self.log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("Failed to create vDSP FFTSetup for size \(fftSize)")
        }
        self.fftSetup = setup

        self.window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&self.window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        self.windowed = [Float](repeating: 0, count: fftSize)
        self.realBuffer = [Float](repeating: 0, count: halfSize)
        self.imagBuffer = [Float](repeating: 0, count: halfSize)
        self.squaredMagnitudes = [Float](repeating: 0, count: halfSize)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// True once all smoothed bar values have decayed to rest (`< 0.004`).
    public var isSettledAtRest: Bool {
        smoothedBars.allSatisfy { $0 < 0.004 }
    }

    /// Current smoothed normalized bar heights in `0...1`.
    public var currentBars: [Double] {
        smoothedBars
    }

    /// Computes updated normalized `[0...1]` heights for the 6 visualizer bars.
    /// When `isActive` is `false`, bars smoothly decay toward `0`.
    public func process(
        samples: [Float],
        sampleRate: Double,
        isActive: Bool,
        style: EqualizerStyle,
        sensitivity: Double,
        deltaTime: TimeInterval
    ) -> [Double] {
        let dt = min(0.1, max(1.0 / 120.0, deltaTime))

        let targets: [Double]
        if isActive && samples.count == fftSize && sampleRate > 8_000 {
            let rawBands = computeSixBandLevels(
                samples: samples,
                sampleRate: sampleRate,
                sensitivity: sensitivity,
                deltaTime: dt
            )
            targets = mapBandsToStyle(rawBands, style: style)
        } else {
            targets = [Double](repeating: 0, count: Self.barCount)
            // Slowly drift AGC toward a neutral level while idle so the next track re-calibrates quickly.
            agcPeakDB += (Self.initialAGCPeakDB - agcPeakDB) * Float(min(1.0, dt * 0.5))
        }

        let attackAlpha = 1.0 - exp(-dt / 0.030)
        let decayAlpha = 1.0 - exp(-dt / 0.145)

        for i in 0..<Self.barCount {
            let target = targets[i]
            let current = smoothedBars[i]
            let alpha = target > current ? attackAlpha : decayAlpha
            let next = current + (target - current) * alpha
            smoothedBars[i] = next < 0.001 ? 0.0 : min(1.0, next)
        }

        return smoothedBars
    }

    /// Resets internal smoothing and AGC history immediately.
    public func reset() {
        agcPeakDB = Self.initialAGCPeakDB
        for i in 0..<Self.barCount {
            smoothedBars[i] = 0
        }
    }

    private func computeSixBandLevels(
        samples: [Float],
        sampleRate: Double,
        sensitivity: Double,
        deltaTime: Double
    ) -> [Double] {
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        realBuffer.withUnsafeMutableBufferPointer { realPtr in
            imagBuffer.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(
                    realp: realPtr.baseAddress!,
                    imagp: imagPtr.baseAddress!
                )

                windowed.withUnsafeBufferPointer { winPtr in
                    winPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfSize))
                    }
                }

                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&splitComplex, 1, &squaredMagnitudes, 1, vDSP_Length(halfSize))
            }
        }

        let binHz = sampleRate / Double(fftSize)
        let normScale = 1.0 / Float(fftSize)
        var bandDBs = [Float](repeating: -80.0, count: Self.barCount)
        var frameMaxDB: Float = -80.0

        for (index, range) in Self.bandRanges.enumerated() {
            let startBin = max(1, Int(floor(range.low / binHz)))
            let endBin = min(halfSize - 1, max(startBin, Int(ceil(range.high / binHz))))
            let count = endBin - startBin + 1

            var sumSq: Float = 0
            var peakSq: Float = 0
            for bin in startBin...endBin {
                let sq = squaredMagnitudes[bin]
                sumSq += sq
                if sq > peakSq {
                    peakSq = sq
                }
            }

            let rmsMag = sqrtf(sumSq / Float(max(1, count))) * normScale
            let peakMag = sqrtf(peakSq) * normScale
            let weightedMag = (0.60 * peakMag + 0.40 * rmsMag) * Self.spectralTiltGains[index]

            let db = 20.0 * log10f(max(weightedMag, 1e-6))
            bandDBs[index] = db
            if db > frameMaxDB {
                frameMaxDB = db
            }
        }

        // Effectively digital silence: don't let AGC chase the noise floor.
        if frameMaxDB < -96.0 {
            return [Double](repeating: 0, count: Self.barCount)
        }

        // Rolling automatic gain control. The process tap delivers audio *after* the system
        // volume, so the level can sit anywhere from ~0 dBFS down to -70 dBFS depending on
        // the volume slider. Track the recent peak over that whole range: fast attack,
        // ~5 dB/s release, so bars stay lively at any volume.
        if frameMaxDB > agcPeakDB {
            agcPeakDB += (frameMaxDB - agcPeakDB) * 0.35
        } else {
            agcPeakDB = max(-90.0, agcPeakDB - Float(deltaTime) * 5.0)
        }
        let ceilingDB = min(0.0, agcPeakDB + 1.5)
        // Higher sensitivity = wider window below the peak = taller bars for quieter detail.
        let dynamicRangeDB: Float = 30.0 * Float(max(0.5, min(1.8, sensitivity)))
        let floorDB = ceilingDB - dynamicRangeDB

        return bandDBs.map { db in
            let normalized = (db - floorDB) / (ceilingDB - floorDB)
            let clamped = max(0.0, min(1.0, Double(normalized)))
            // Mild perceptual curve so mid-level beats remain expressive.
            return pow(clamped, 1.15)
        }
    }

    private func mapBandsToStyle(_ bands: [Double], style: EqualizerStyle) -> [Double] {
        guard bands.count == Self.barCount else { return bands }
        switch style {
        case .classic:
            return bands
        case .island:
            // Arrange 6 real frequency bands in a balanced Dynamic-Island envelope:
            // outer sparkle/air, inner warmth/sub-bass, center punch/vocals.
            return [
                bands[4] * 0.62,
                bands[2] * 0.86,
                bands[1] * 1.00,
                bands[3] * 1.00,
                bands[0] * 0.86,
                bands[5] * 0.62
            ]
        }
    }
}
