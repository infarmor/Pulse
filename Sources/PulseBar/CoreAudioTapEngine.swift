import AudioToolbox
import CoreAudio
import Foundation
import PulseBarCore

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
            removeDefaultOutputListener()
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
        installDefaultOutputListenerIfNeeded()

        let tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        tapDescription.uuid = UUID()
        tapDescription.name = "PulseBar System Audio Tap"
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
        let sampleRate = tapFormat?.mSampleRate ?? 48_000
        ringBuffer.setSampleRate(sampleRate)

        let outputUID = readDefaultOutputDeviceUID()
        var aggregateDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "PulseBar-AudioTap",
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

        if let outputUID {
            aggregateDesc[kAudioAggregateDeviceSubDeviceListKey] = [
                [kAudioSubDeviceUIDKey: outputUID]
            ]
            aggregateDesc[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
        }

        var createdAggID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &createdAggID)
        guard aggStatus == noErr, createdAggID != AudioObjectID(kAudioObjectUnknown) else {
            AudioHardwareDestroyProcessTap(createdTapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            onStatusChange(.failed("Ошибка Aggregate Device (\(aggStatus))"))
            return
        }
        aggregateDeviceID = createdAggID

        let isFloat = ((tapFormat?.mFormatFlags ?? kAudioFormatFlagIsFloat) & kAudioFormatFlagIsFloat) != 0
        let bitsPerChannel = tapFormat?.mBitsPerChannel ?? 32
        let scratch = DownmixScratch()
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

            if bufferList.count == 1 {
                let buf = bufferList[0]
                guard let rawPtr = buf.mData, buf.mDataByteSize > 0 else { return }
                let channels = max(1, Int(buf.mNumberChannels))
                let totalFloats = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
                let frameCount = totalFloats / channels
                guard frameCount > 0 else { return }

                let floatPtr = rawPtr.assumingMemoryBound(to: Float.self)
                if channels == 1 {
                    ring.write(UnsafeBufferPointer(start: floatPtr, count: frameCount))
                } else {
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
                return
            }

            // Non-interleaved multi-buffer fallback: average channel 0..N-1.
            let firstBuf = bufferList[0]
            guard firstBuf.mData != nil, firstBuf.mDataByteSize > 0 else { return }
            let frameCount = Int(firstBuf.mDataByteSize) / MemoryLayout<Float>.size
            let usableFrames = min(frameCount, scratch.buffer.count)
            guard usableFrames > 0 else { return }

            let invBuffers = 1.0 / Float(bufferList.count)
            scratch.buffer.withUnsafeMutableBufferPointer { dst in
                guard let dstPtr = dst.baseAddress else { return }
                for frame in 0..<usableFrames {
                    dstPtr[frame] = 0
                }
                for buf in bufferList {
                    guard let ptr = buf.mData else { continue }
                    let chPtr = ptr.assumingMemoryBound(to: Float.self)
                    let count = min(usableFrames, Int(buf.mDataByteSize) / MemoryLayout<Float>.size)
                    for frame in 0..<count {
                        dstPtr[frame] += chPtr[frame] * invBuffers
                    }
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
    }

    private func installDefaultOutputListenerIfNeeded() {
        guard defaultOutputListenerBlock == nil else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.pendingRestartWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.tapID != AudioObjectID(kAudioObjectUnknown) else { return }
                let wasStarted = self.isStarted
                self.teardownTapOnQueue()
                self.startOnQueue()
                if !wasStarted, self.isStarted, let proc = self.ioProcID {
                    AudioDeviceStop(self.aggregateDeviceID, proc)
                    self.isStarted = false
                }
            }
            self.pendingRestartWorkItem = item
            self.queue.asyncAfter(deadline: .now() + 0.35, execute: item)
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            block
        )
        if status == noErr {
            defaultOutputListenerBlock = block
        }
    }

    private func removeDefaultOutputListener() {
        guard let block = defaultOutputListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            block
        )
        defaultOutputListenerBlock = nil
    }

    private func readDefaultOutputDeviceUID() -> String? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let devStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard devStatus == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else {
            return nil
        }

        return readCFStringProperty(
            objectID: deviceID,
            selector: kAudioDevicePropertyDeviceUID
        )
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
