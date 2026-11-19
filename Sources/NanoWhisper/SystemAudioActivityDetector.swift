import CoreAudio
import Foundation

/// Detects whether audio is coming out of the system, excluding NanoWhisper's own sounds.
///
/// Cheap checks first (default output device running, another process running output),
/// then a CoreAudio process tap samples the actual system mix.
/// All methods block: call them off the main thread.
struct SystemAudioActivityDetector: Sendable {
    /// How long to wait for the tap to deliver its first buffer before giving up (`.unknown`).
    var tapStartTimeout: TimeInterval = 0.5
    /// How long to listen once the tap delivers audio buffers.
    var listeningWindow: TimeInterval = 0.05
    /// Any sample above this amplitude counts as audio (about -80 dBFS).
    static let silenceThreshold: Float = 0.0001

    func currentState() -> MediaPlaybackState {
        guard let deviceRunning = isDefaultOutputDeviceRunning() else { return .unknown }
        guard deviceRunning else { return .notPlaying }
        guard let otherProcessRunning = isAnotherProcessRunningOutput() else { return .unknown }
        guard otherProcessRunning else { return .notPlaying }

        if #available(macOS 14.2, *) {
            return probeSystemAudioViaTap()
        }
        // Before macOS 14.2 there is no process tap: "a process is running output" alone
        // cannot tell a playing player from a paused one, so do not claim anything.
        return .unknown
    }

    // MARK: - TCC permission prompt

    /// Runs the full tap + aggregate device + IO pipeline briefly to trigger
    /// the TCC permission prompt for System Audio Recording.
    @available(macOS 14.2, *)
    func requestAudioCaptureAccess() {
        guard let outputUID = defaultOutputDeviceUID(),
              let pipeline = createTapPipeline(name: "NanoWhisper-PermRequest", outputUID: outputUID, excluding: [])
        else { return }
        defer { destroyTapPipeline(pipeline) }

        var ioProcID: AudioDeviceIOProcID?
        let queue = DispatchQueue(label: "com.moonji.nanowhisper.perm-request")
        let err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, pipeline.aggregateID, queue) { _, _, _, _, _ in }

        if err == noErr, let procID = ioProcID {
            // AudioDeviceStart triggers the TCC prompt on first use
            if AudioDeviceStart(pipeline.aggregateID, procID) == noErr {
                Thread.sleep(forTimeInterval: 0.1)
                AudioDeviceStop(pipeline.aggregateID, procID)
            }
            AudioDeviceDestroyIOProcID(pipeline.aggregateID, procID)
        }
    }

    // MARK: - Cheap checks (no permission required)

    /// Is the default output device running at all? `nil` on CoreAudio error.
    private func isDefaultOutputDeviceRunning() -> Bool? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isRunning) == noErr else { return nil }
        return isRunning != 0
    }

    /// Does any process other than ourselves have running audio output? `nil` on CoreAudio error.
    private func isAnotherProcessRunningOutput() -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return nil }

        let processCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard processCount > 0 else { return false }

        var processIDs = [AudioObjectID](repeating: 0, count: processCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &processIDs
        ) == noErr else { return nil }
        // The list may have shrunk between the two calls.
        processIDs = Array(processIDs.prefix(Int(dataSize) / MemoryLayout<AudioObjectID>.size))

        let myPID = ProcessInfo.processInfo.processIdentifier

        for processID in processIDs {
            var isRunningOutput: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var runAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(processID, &runAddr, 0, nil, &size, &isRunningOutput) == noErr,
                  isRunningOutput != 0 else { continue }

            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(processID, &pidAddr, 0, nil, &pidSize, &pid) == noErr, pid == myPID {
                continue
            }
            return true
        }
        return false
    }

    // MARK: - Detection via CoreAudio process tap + aggregate device

    /// Samples the system mix, minus our own process, through a process tap.
    @available(macOS 14.2, *)
    private func probeSystemAudioViaTap() -> MediaPlaybackState {
        // Our own feedback sounds (start / stop / noResult) must never count as media.
        guard let ownProcess = ownAudioProcessObject() else { return .unknown }
        let excluded = ownProcess == kAudioObjectUnknown ? [] : [ownProcess]

        guard let outputUID = defaultOutputDeviceUID(),
              let pipeline = createTapPipeline(name: "NanoWhisper-AudioDetect", outputUID: outputUID, excluding: excluded)
        else { return .unknown }
        defer { destroyTapPipeline(pipeline) }

        let probe = TapProbe()
        let queue = DispatchQueue(label: "com.moonji.nanowhisper.audio-tap-detect", qos: .userInteractive)
        var ioProcID: AudioDeviceIOProcID?
        let err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, pipeline.aggregateID, queue) { _, inInputData, _, _, _ in
            probe.consume(inInputData)
        }
        guard err == noErr, let procID = ioProcID else { return .unknown }
        defer { AudioDeviceDestroyIOProcID(pipeline.aggregateID, procID) }

        guard AudioDeviceStart(pipeline.aggregateID, procID) == noErr else { return .unknown }
        let state = probe.waitForResult(startTimeout: tapStartTimeout, listeningWindow: listeningWindow)
        AudioDeviceStop(pipeline.aggregateID, procID)
        queue.sync {} // drain pending callbacks before tearing down
        return state
    }

    /// Our process's CoreAudio process object. `kAudioObjectUnknown` when CoreAudio has none
    /// for us (we produce no audio then, so there is nothing to exclude); `nil` on error.
    private func ownAudioProcessObject() -> AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &processObject
        ) == noErr else { return nil }
        return processObject
    }

    // MARK: - CoreAudio helpers

    private struct TapPipeline {
        let tapID: AudioObjectID
        let aggregateID: AudioObjectID
    }

    private func defaultOutputDeviceID() -> AudioDeviceID? {
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
        return deviceID
    }

    private func defaultOutputDeviceUID() -> String? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        var uidRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uidRef) == noErr,
              let uid = uidRef?.takeRetainedValue() as String? else { return nil }
        return uid
    }

    /// Creates a global stereo tap (minus `excluding`) and a private aggregate device reading it.
    @available(macOS 14.2, *)
    private func createTapPipeline(name: String, outputUID: String, excluding: [AudioObjectID]) -> TapPipeline? {
        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluding)
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
        return TapPipeline(tapID: tapID, aggregateID: aggID)
    }

    @available(macOS 14.2, *)
    private func destroyTapPipeline(_ pipeline: TapPipeline) {
        AudioHardwareDestroyAggregateDevice(pipeline.aggregateID)
        AudioHardwareDestroyProcessTap(pipeline.tapID)
    }
}

/// Collects what the tap IOProc sees. Written on the IO queue, waited on by the detecting thread.
private final class TapProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var receivedBuffers = false
    private var heardAudio = false
    private let firstBuffers = DispatchSemaphore(value: 0)
    private let audio = DispatchSemaphore(value: 0)

    /// Called from the IOProc for every input cycle.
    func consume(_ input: UnsafePointer<AudioBufferList>) {
        lock.lock()
        let alreadyHeard = heardAudio
        lock.unlock()
        let hasAudio = !alreadyHeard && Self.containsAudio(input)

        lock.lock()
        let isFirst = !receivedBuffers
        receivedBuffers = true
        let isFirstAudio = hasAudio && !heardAudio
        if hasAudio { heardAudio = true }
        lock.unlock()

        if isFirst { firstBuffers.signal() }
        if isFirstAudio { audio.signal() }
    }

    /// `.unknown` if the tap delivers nothing within `startTimeout`; otherwise listens for
    /// `listeningWindow` from the first buffer on.
    func waitForResult(startTimeout: TimeInterval, listeningWindow: TimeInterval) -> MediaPlaybackState {
        guard firstBuffers.wait(timeout: .now() + startTimeout) == .success else { return .unknown }
        return audio.wait(timeout: .now() + listeningWindow) == .success ? .playing : .notPlaying
    }

    private static func containsAudio(_ input: UnsafePointer<AudioBufferList>) -> Bool {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let samples = UnsafeBufferPointer(
                start: data.assumingMemoryBound(to: Float.self),
                count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            )
            if samples.contains(where: { abs($0) > SystemAudioActivityDetector.silenceThreshold }) {
                return true
            }
        }
        return false
    }
}
