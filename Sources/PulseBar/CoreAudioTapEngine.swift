import AudioToolbox
import CoreAudio
import Foundation
import os
import PulseBarCore

let pulseLog = Logger(subsystem: "dev.pulsebar.app", category: "audio")

/// Captures live system audio PCM samples via CoreAudio Process Tap (`macOS 14.2+`)
/// into a real-time-safe `AudioRingBuffer`.
final class CoreAudioTapEngine: @unchecked Sendable {
    private let ringBuffer: AudioRingBuffer
    private let queue = DispatchQueue(label: "dev.pulsebar.coreaudio-tap", qos: .userInitiated)
    private let onStatusChange: @Sendable (AudioTapStatus) -> Void

    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var isStarted = false
    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?
    private var serviceRestartListenerBlock: AudioObjectPropertyListenerBlock?
    /// Per-device listeners (aggregate sample rate, tap format); removed on teardown.
    private var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var pendingRestartWorkItem: DispatchWorkItem?

    /// Pre-allocated scratch buffer for multi-channel downmix in the real-time IOProc.
    private final class DownmixScratch: @unchecked Sendable {
        var buffer: [Float]
        init(capacity: Int = 8_192) {
            self.buffer = [Float](repeating: 0, count: capacity)
        }
    }

    init(
        ringBuffer: AudioRingBuffer,
        onStatusChange: @escaping @Sendable (AudioTapStatus) -> Void
    ) {
        self.ringBuffer = ringBuffer
        self.onStatusChange = onStatusChange
    }

    deinit {
        stop()
    }

    /// Starts (or ensures active) the CoreAudio process tap and IO stream.
    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    /// Stops IO callbacks and tears down the aggregate device and tap.
    func stop() {
        queue.sync {
            pendingRestartWorkItem?.cancel()
            pendingRestartWorkItem = nil
            removeSystemListeners()
            teardownTapOnQueue()
            onStatusChange(.idle)
        }
    }

    /// Restarts the tap (for instance, after granting System Audio Recording permission).
    func restart() {
        queue.async { [weak self] in
            guard let self else { return }
            self.teardownTapOnQueue()
            self.ringBuffer.reset()
            self.startOnQueue()
        }
    }

    /// Temporarily pauses or resumes AudioDevice IO without destroying the tap,
    /// saving CPU when Apple Music is paused.
    func setIOActive(_ active: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            if active {
                if self.tapID == AudioObjectID(kAudioObjectUnknown) {
                    self.startOnQueue()
                } else if !self.isStarted, let ioProcID = self.ioProcID {
                    let status = AudioDeviceStart(self.aggregateDeviceID, ioProcID)
                    if status == noErr {
                        self.isStarted = true
                        self.onStatusChange(.running)
                    } else {
                        self.teardownTapOnQueue()
                        self.startOnQueue()
                    }
                }
            } else if self.isStarted, let ioProcID = self.ioProcID {
                AudioDeviceStop(self.aggregateDeviceID, ioProcID)
                self.isStarted = false
                // Drop the last captured audio so nothing keeps analysing a frozen snapshot.
                self.ringBuffer.reset()
            }
        }
    }

    private func startOnQueue() {
        guard tapID == AudioObjectID(kAudioObjectUnknown) else {
            if !isStarted, let ioProcID {
                let status = AudioDeviceStart(aggregateDeviceID, ioProcID)
                if status == noErr {
                    isStarted = true
                    onStatusChange(.running)
                }
            }
            return
        }

        onStatusChange(.starting)
        installSystemListenersIfNeeded()

        let tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        tapDescription.uuid = UUID()
        tapDescription.name = "Pulse System Audio Tap"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var createdTapID = AudioObjectID(kAudioObjectUnknown)
        let createTapStatus = AudioHardwareCreateProcessTap(tapDescription, &createdTapID)
        guard createTapStatus == noErr, createdTapID != AudioObjectID(kAudioObjectUnknown) else {
            onStatusChange(.failed("Ошибка создания Audio Tap (\(createTapStatus))"))
            return
        }
        tapID = createdTapID

        let tapUID = readTapUID(tapID: createdTapID) ?? tapDescription.uuid.uuidString
        let tapFormat = readTapFormat(tapID: createdTapID)

        // Tap-only private aggregate. The default output device is deliberately NOT added as a
        // sub-device: devices such as AirPods or USB headsets would bring their microphone into
        // the aggregate's input scope, so starting IO would switch them to call-quality (HFP),
        // light the mic indicator, and mix the mic into the visualizer.
        let aggregateDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Pulse-AudioTap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUID
                ]
            ]
        ]

        var createdAggID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &createdAggID)
        guard aggStatus == noErr, createdAggID != AudioObjectID(kAudioObjectUnknown) else {
            AudioHardwareDestroyProcessTap(createdTapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            onStatusChange(.failed("Ошибка Aggregate Device (\(aggStatus))"))
            return
        }
        aggregateDeviceID = createdAggID

        // The aggregate's nominal rate is what the IOProc actually delivers.
        let sampleRate = readNominalSampleRate(deviceID: createdAggID) ?? tapFormat?.mSampleRate ?? 48_000
        ringBuffer.setSampleRate(sampleRate)
        installDeviceListeners(aggregateID: createdAggID, tapID: createdTapID)

        let isFloat = ((tapFormat?.mFormatFlags ?? kAudioFormatFlagIsFloat) & kAudioFormatFlagIsFloat) != 0
        let bitsPerChannel = tapFormat?.mBitsPerChannel ?? 32
        let scratch = DownmixScratch()
        pulseLog.notice("tap created id=\(createdTapID, privacy: .public) uid=\(tapUID, privacy: .public) fmtRead=\(tapFormat != nil, privacy: .public) sr=\(sampleRate, privacy: .public) ch=\(tapFormat?.mChannelsPerFrame ?? 0, privacy: .public) flags=\(tapFormat?.mFormatFlags ?? 0, privacy: .public) bits=\(tapFormat?.mBitsPerChannel ?? 0, privacy: .public) isFloat=\(isFloat, privacy: .public) agg=\(createdAggID, privacy: .public)")
        let ring = ringBuffer

        var newIOProcID: AudioDeviceIOProcID?
        let ioCreateStatus = AudioDeviceCreateIOProcIDWithBlock(
            &newIOProcID,
            createdAggID,
            nil
        ) { _, inInputData, _, _, _ in
            guard isFloat, bitsPerChannel == 32 else { return }

            let bufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard !bufferList.isEmpty else { return }

            // The tap stream is the last input stream of the aggregate; read only that one.
            let buf = bufferList[bufferList.count - 1]
            guard let rawPtr = buf.mData, buf.mDataByteSize > 0 else { return }
            let channels = max(1, Int(buf.mNumberChannels))
            let frameCount = Int(buf.mDataByteSize) / MemoryLayout<Float>.size / channels
            guard frameCount > 0 else { return }

            let floatPtr = rawPtr.assumingMemoryBound(to: Float.self)
            if channels == 1 {
                ring.write(UnsafeBufferPointer(start: floatPtr, count: frameCount))
                return
            }

            // Interleaved multi-channel: downmix to mono into preallocated scratch.
            let usableFrames = min(frameCount, scratch.buffer.count)
            let invChannels = 1.0 / Float(channels)
            scratch.buffer.withUnsafeMutableBufferPointer { dst in
                guard let dstPtr = dst.baseAddress else { return }
                for frame in 0..<usableFrames {
                    var sum: Float = 0
                    let base = frame * channels
                    for ch in 0..<channels {
                        sum += floatPtr[base + ch]
                    }
                    dstPtr[frame] = sum * invChannels
                }
                ring.write(UnsafeBufferPointer(start: dstPtr, count: usableFrames))
            }
        }

        guard ioCreateStatus == noErr, let validIOProc = newIOProcID else {
            teardownTapOnQueue()
            onStatusChange(.failed("Ошибка AudioDeviceCreateIOProc (\(ioCreateStatus))"))
            return
        }
        ioProcID = validIOProc

        let startStatus = AudioDeviceStart(createdAggID, validIOProc)
        guard startStatus == noErr else {
            teardownTapOnQueue()
            onStatusChange(.failed("Нет доступа к системному аудио (\(startStatus))"))
            return
        }

        isStarted = true
        onStatusChange(.running)
    }

    private func teardownTapOnQueue() {
        removeDeviceListeners()
        if let proc = ioProcID, aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            if isStarted {
                AudioDeviceStop(aggregateDeviceID, proc)
            }
            AudioDeviceDestroyIOProcID(aggregateDeviceID, proc)
        }
        ioProcID = nil
        isStarted = false

        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        ringBuffer.reset()
    }

    /// Debounced teardown + restart on the engine queue. Keeps the previous IO state
    /// (a paused tap stays paused after the rebuild).
    private func scheduleRestart(reason: String) {
        pendingRestartWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.tapID != AudioObjectID(kAudioObjectUnknown) else { return }
            pulseLog.notice("restarting tap: \(reason, privacy: .public)")
            let wasStarted = self.isStarted
            self.teardownTapOnQueue()
            self.startOnQueue()
            if !wasStarted, self.isStarted, let proc = self.ioProcID {
                AudioDeviceStop(self.aggregateDeviceID, proc)
                self.isStarted = false
            }
        }
        pendingRestartWorkItem = item
        queue.asyncAfter(deadline: .now() + 0.35, execute: item)
    }

    private func installSystemListenersIfNeeded() {
        let system = AudioObjectID(kAudioObjectSystemObject)

        if defaultOutputListenerBlock == nil {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.scheduleRestart(reason: "default output changed")
            }
            if AudioObjectAddPropertyListenerBlock(system, &address, queue, block) == noErr {
                defaultOutputListenerBlock = block
            }
        }

        if serviceRestartListenerBlock == nil {
            // coreaudiod restarted: our private tap/aggregate are gone and must be rebuilt.
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyServiceRestarted,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.scheduleRestart(reason: "audio service restarted")
            }
            if AudioObjectAddPropertyListenerBlock(system, &address, queue, block) == noErr {
                serviceRestartListenerBlock = block
            }
        }
    }

    private func removeSystemListeners() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        if let block = defaultOutputListenerBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(system, &address, queue, block)
            defaultOutputListenerBlock = nil
        }
        if let block = serviceRestartListenerBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyServiceRestarted,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(system, &address, queue, block)
            serviceRestartListenerBlock = nil
        }
    }

    /// Rebuild when the stream's rate or format changes (e.g. a DAC switched to 96 kHz,
    /// Bluetooth renegotiation), otherwise the FFT bands would map to the wrong frequencies.
    private func installDeviceListeners(aggregateID: AudioObjectID, tapID: AudioObjectID) {
        let watched: [(AudioObjectID, AudioObjectPropertySelector, String)] = [
            (aggregateID, kAudioDevicePropertyNominalSampleRate, "sample rate changed"),
            (tapID, kAudioTapPropertyFormat, "tap format changed")
        ]
        for (object, selector, reason) in watched {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.scheduleRestart(reason: reason)
            }
            if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
                deviceListeners.append((object, address, block))
            }
        }
    }

    private func removeDeviceListeners() {
        for (object, address, block) in deviceListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }
        deviceListeners.removeAll()
    }

    private func readNominalSampleRate(deviceID: AudioObjectID) -> Double? {
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        return status == noErr && rate > 8_000 ? rate : nil
    }

    private func readTapUID(tapID: AudioObjectID) -> String? {
        readCFStringProperty(objectID: tapID, selector: kAudioTapPropertyUID)
    }

    private func readCFStringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var cfStr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &cfStr) { ptr in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let retained = cfStr else {
            return nil
        }
        return retained.takeRetainedValue() as String
    }

    private func readTapFormat(tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        return status == noErr ? asbd : nil
    }
}
