import Cocoa
import CoreAudio

/// Controls system-wide media playback during recording.
/// Detects active audio output via a CoreAudio Process Tap (samples actual audio content),
/// then simulates the Play/Pause media key via CGEvent to toggle playback.
@MainActor
final class MediaController {
    private var didPauseMedia = false

    static let audioPrivacySettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"

    // MARK: - CoreAudio helpers

    /// Returns the UID of the default output audio device, or `nil` on failure.
    private nonisolated func getDefaultOutputDeviceUID() -> String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return nil }

        var uidRef: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<CFString>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &uidRef
        ) == noErr, let uid = uidRef?.takeRetainedValue() as String? else { return nil }

        return uid
    }

    /// Creates a tap + aggregate device pair. Returns `(tapID, aggregateID)` or `nil`.
    @available(macOS 14.2, *)
    private nonisolated func createTapPipeline(name: String, outputUID: String) -> (tapID: AudioObjectID, aggID: AudioObjectID)? {
        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDesc.uuid = UUID()
        tapDesc.name = name
        tapDesc.muteBehavior = .unmuted
        tapDesc.isPrivate = true

        var tapID: AudioObjectID = kAudioObjectUnknown
        guard AudioHardwareCreateProcessTap(tapDesc, &tapID) == noErr else { return nil }

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var aggID: AudioObjectID = kAudioObjectUnknown
        guard AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID) == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        return (tapID, aggID)
    }

    @available(macOS 14.2, *)
    private nonisolated func destroyTapPipeline(tapID: AudioObjectID, aggID: AudioObjectID) {
        AudioHardwareDestroyAggregateDevice(aggID)
        AudioHardwareDestroyProcessTap(tapID)
    }

    // MARK: - TCC permission prompt

    /// Runs the full tap + aggregate device + IO pipeline briefly to trigger
    /// the TCC permission prompt for System Audio Recording.
    /// Call from a background thread.
    @available(macOS 14.2, *)
    nonisolated func requestAudioCaptureAccess() {
        guard let outputUID = getDefaultOutputDeviceUID(),
              let (tapID, aggID) = createTapPipeline(name: "NanoWhisper-PermRequest", outputUID: outputUID)
        else { return }

        var ioProcID: AudioDeviceIOProcID?
        let queue = DispatchQueue(label: "com.moonji.nanowhisper.perm-request")
        let err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggID, queue) { _, _, _, _, _ in }

        if err == noErr, let procID = ioProcID {
            // AudioDeviceStart triggers the TCC prompt on first use
            if AudioDeviceStart(aggID, procID) == noErr {
                Thread.sleep(forTimeInterval: 0.1)
                AudioDeviceStop(aggID, procID)
            }
            AudioDeviceDestroyIOProcID(aggID, procID)
        }

        destroyTapPipeline(tapID: tapID, aggID: aggID)
    }

    // MARK: - Per-process audio output check (no permission required)

    /// Returns `true` if any process (other than ourselves) has active audio output streams.
    private nonisolated func isAnyProcessRunningOutput() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return false }

        let processCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard processCount > 0 else { return false }

        var processIDs = [AudioObjectID](repeating: 0, count: processCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &processIDs
        ) == noErr else { return false }

        let myPID = ProcessInfo.processInfo.processIdentifier

        for processID in processIDs {
            var isRunningOutput: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var runAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            guard AudioObjectGetPropertyData(
                processID, &runAddr, 0, nil, &size, &isRunningOutput
            ) == noErr else { continue }

            guard isRunningOutput != 0 else { continue }

            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            if AudioObjectGetPropertyData(
                processID, &pidAddr, 0, nil, &pidSize, &pid
            ) == noErr, pid == myPID {
                continue
            }

            return true
        }

        return false
    }

    // MARK: - Detection via CoreAudio Process Tap + Aggregate Device

    /// Returns `true` if actual audio is being produced by the system.
    /// Uses a CoreAudio Process Tap to sample real audio content for ~50ms.
    @available(macOS 14.2, *)
    private nonisolated func isAudioPlayingViaTap() -> Bool {
        guard let outputUID = getDefaultOutputDeviceUID(),
              let (tapID, aggID) = createTapPipeline(name: "NanoWhisper-AudioDetect", outputUID: outputUID)
        else { return false }

        let detectedAudio = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        detectedAudio.initialize(to: false)

        let queue = DispatchQueue(label: "com.moonji.nanowhisper.audio-tap-detect", qos: .userInteractive)
        var ioProcID: AudioDeviceIOProcID?

        let err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggID, queue) {
            _, inInputData, _, _, _ in
            guard !detectedAudio.pointee else { return }

            let bufferList = inInputData.pointee
            let bufferCount = Int(bufferList.mNumberBuffers)
            withUnsafePointer(to: bufferList.mBuffers) { firstBuffer in
                for i in 0..<bufferCount {
                    let buffer = firstBuffer.advanced(by: i).pointee
                    guard let data = buffer.mData else { continue }
                    let floatCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    let floatPtr = data.assumingMemoryBound(to: Float.self)
                    for j in 0..<floatCount {
                        if abs(floatPtr[j]) > 0.0001 {
                            detectedAudio.pointee = true
                            return
                        }
                    }
                }
            }
        }

        guard err == noErr, let procID = ioProcID else {
            detectedAudio.deallocate()
            destroyTapPipeline(tapID: tapID, aggID: aggID)
            return false
        }

        guard AudioDeviceStart(aggID, procID) == noErr else {
            AudioDeviceDestroyIOProcID(aggID, procID)
            detectedAudio.deallocate()
            destroyTapPipeline(tapID: tapID, aggID: aggID)
            return false
        }

        Thread.sleep(forTimeInterval: 0.05)

        let result = detectedAudio.pointee

        AudioDeviceStop(aggID, procID)
        AudioDeviceDestroyIOProcID(aggID, procID)
        detectedAudio.deallocate()
        destroyTapPipeline(tapID: tapID, aggID: aggID)

        return result
    }

    /// Quick check: is the default output audio device running at all?
    private nonisolated func isAudioOutputDeviceRunning() -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr else { return false }

        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        var isRunning: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &isRunning
        ) == noErr else { return false }

        return isRunning != 0
    }

    /// Returns `true` if actual audio is being produced.
    /// Cheap checks first (device running, per-process output) to avoid
    /// the expensive 50ms tap when no audio is playing.
    private nonisolated func isActualAudioPlaying() -> Bool {
        guard isAudioOutputDeviceRunning() else { return false }
        guard isAnyProcessRunningOutput() else { return false }

        if #available(macOS 14.2, *) {
            return isAudioPlayingViaTap()
        }

        // Fallback for older macOS: trust per-process check
        return true
    }

    // MARK: - Media key simulation via CGEvent

    private static let keyTypePlayPause: Int32 = 16

    private func sendMediaKeyToggle() {
        sendMediaKey(Self.keyTypePlayPause, keyDown: true)
        sendMediaKey(Self.keyTypePlayPause, keyDown: false)
    }

    private func sendMediaKey(_ keyType: Int32, keyDown: Bool) {
        let flags: Int32 = keyDown ? 0xa00 : 0xb00
        let data1 = Int((keyType << 16) | flags)

        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ) else { return }

        event.cgEvent?.post(tap: .cghidEventTap)
    }

    // MARK: - Public API

    /// Pauses system media if actual audio is being produced.
    /// Must be called BEFORE playing any feedback sounds to avoid false positives.
    func pauseIfPlaying() {
        guard isActualAudioPlaying() else { return }
        sendMediaKeyToggle()
        didPauseMedia = true
    }

    /// Resumes media only if we previously paused it.
    func resumeIfPaused() {
        guard didPauseMedia else { return }
        didPauseMedia = false
        sendMediaKeyToggle()
    }
}
