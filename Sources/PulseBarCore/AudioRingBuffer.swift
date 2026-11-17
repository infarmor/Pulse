import Foundation
import os

/// Snapshot of recent audio diagnostics alongside sample telemetry.
public struct AudioBufferStats: Sendable, Equatable {
    public let totalCallbacks: UInt64
    public let nonZeroCallbacks: UInt64
    public let sampleRate: Double
    public let rms: Float

    public init(totalCallbacks: UInt64, nonZeroCallbacks: UInt64, sampleRate: Double, rms: Float) {
        self.totalCallbacks = totalCallbacks
        self.nonZeroCallbacks = nonZeroCallbacks
        self.sampleRate = sampleRate
        self.rms = rms
    }
}

/// Lock-protected fixed-capacity ring buffer for real-time audio IO capture.
/// Avoids heap allocations inside `write` so CoreAudio IO callbacks stay real-time safe.
public final class AudioRingBuffer: @unchecked Sendable {
    public let capacity: Int
    private let lock = OSAllocatedUnfairLock()

    private var buffer: [Float]
    private var writeIndex: Int = 0
    private var totalCallbacks: UInt64 = 0
    private var nonZeroCallbacks: UInt64 = 0
    private var sampleRate: Double = 48_000

    public init(capacity: Int = 16_384) {
        let safeCapacity = max(2_048, capacity)
        self.capacity = safeCapacity
        self.buffer = [Float](repeating: 0, count: safeCapacity)
    }

    /// Updates the sample rate reported by the active CoreAudio tap format.
    public func setSampleRate(_ newSampleRate: Double) {
        guard newSampleRate > 8_000 else { return }
        lock.lock()
        sampleRate = newSampleRate
        lock.unlock()
    }

    /// Appends mono samples from an audio IO thread without allocating memory.
    public func write(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, !samples.isEmpty else { return }

        var hasSignal = false
        for i in 0..<samples.count {
            if abs(base[i]) > 1e-6 {
                hasSignal = true
                break
            }
        }

        let cap = capacity
        lock.lock()
        totalCallbacks &+= 1
        if hasSignal {
            nonZeroCallbacks &+= 1
        }

        if samples.count >= cap {
            let offset = samples.count - cap
            for i in 0..<cap {
                buffer[i] = base[offset + i]
            }
            writeIndex = 0
            lock.unlock()
            return
        }

        let firstChunk = min(samples.count, cap - writeIndex)
        for i in 0..<firstChunk {
            buffer[writeIndex + i] = base[i]
        }
        let remaining = samples.count - firstChunk
        if remaining > 0 {
            for i in 0..<remaining {
                buffer[i] = base[firstChunk + i]
            }
        }
        writeIndex = (writeIndex + samples.count) % cap
        lock.unlock()
    }

    /// Copies the newest `count` samples chronologically into `destination` and computes RMS.
    public func copyLatest(_ count: Int, into destination: inout [Float]) -> AudioBufferStats {
        let clamped = min(count, capacity)
        if destination.count != clamped {
            destination = [Float](repeating: 0, count: clamped)
        }

        lock.lock()
        let cap = capacity
        let start = (writeIndex - clamped + cap) % cap
        let firstChunk = min(clamped, cap - start)

        destination.withUnsafeMutableBufferPointer { dst in
            guard let dstPtr = dst.baseAddress else { return }
            buffer.withUnsafeBufferPointer { src in
                guard let srcPtr = src.baseAddress else { return }
                dstPtr.update(from: srcPtr + start, count: firstChunk)
                let remaining = clamped - firstChunk
                if remaining > 0 {
                    (dstPtr + firstChunk).update(from: srcPtr, count: remaining)
                }
            }
        }

        let callbacks = totalCallbacks
        let nonZero = nonZeroCallbacks
        let rate = sampleRate
        lock.unlock()

        var sumSquares: Float = 0
        for sample in destination {
            sumSquares += sample * sample
        }
        let rms = destination.isEmpty ? 0 : sqrtf(sumSquares / Float(destination.count))

        return AudioBufferStats(
            totalCallbacks: callbacks,
            nonZeroCallbacks: nonZero,
            sampleRate: rate,
            rms: rms
        )
    }

    /// Clears buffered samples and resets zero/non-zero counters.
    public func reset() {
        lock.lock()
        for i in 0..<buffer.count {
            buffer[i] = 0
        }
        writeIndex = 0
        totalCallbacks = 0
        nonZeroCallbacks = 0
        lock.unlock()
    }
}
