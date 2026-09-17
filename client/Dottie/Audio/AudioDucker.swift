import Foundation
import AppKit
import CoreAudio
import AudioToolbox
import AVFoundation

/// Lowers the volume of all OTHER apps' audio (browser/YouTube/Spotify/Music) to
/// `duckedGain` while Dottie is dictating or speaking, keeping Dottie's OWN audio
/// at full volume.
///
/// Mechanism (macOS 14.4+ public Core Audio process-tap API): a private global
/// process tap captures every process EXCEPT Dottie, muting the originals. A
/// private aggregate device (tap + real output device) re-renders the tapped audio
/// through an IOProc that multiplies every sample by the current gain. When ducking
/// ends (or the app quits/crashes-then-quits) everything is destroyed and audio
/// routing returns to normal.
///
/// Ref-counted: `begin()` / `end()` are balanced; only the first enabled `begin()`
/// builds the stack, only the last `end()` tears it down. All Core Audio failures
/// degrade gracefully — on any error during setup the partial state is torn down so
/// other apps are NEVER left muted.
final class AudioDucker {
    static let shared = AudioDucker()

    /// Gain applied to all other apps' audio while ducking (5%).
    private let duckedGain: Float32 = 0.05
    /// Per-sample exponential ramp coefficient (~20ms glide @48k) so the gain change
    /// at the start/end of each duck is smooth instead of a click/jump.
    private let rampCoef: Float32 = 0.0012
    /// Once ducking ends we keep the (expensive) tap+aggregate alive for this long so
    /// back-to-back TTS turns don't thrash device creation — the source of the audible
    /// hitch. Only a genuine idle gap tears the stack down.
    private let idleTeardownDelay: TimeInterval = 8.0
    private let aggregateUID = "com.example.dottie.ducker"
    private let aggregateName = "Dottie Ducker"

    // MARK: - Main-thread ref count + lifecycle state

    private var refCount: Int = 0
    private var idleTeardownWork: DispatchWorkItem?

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var running = false

    // MARK: - Gain shared with the realtime IOProc

    /// Target gain, written on the main thread, read once per IO buffer on the audio
    /// thread. Guarded by `gainLock` (held only for a single Float read/write).
    private let gainLock = NSLock()
    private var _targetGain: Float32 = 1.0
    private var targetGain: Float32 {
        get { gainLock.lock(); defer { gainLock.unlock() }; return _targetGain }
        set { gainLock.lock(); _targetGain = newValue; gainLock.unlock() }
    }
    /// Smoothed gain actually applied. Touched ONLY on the audio thread (single writer,
    /// no lock needed) — ramps toward `targetGain` each sample.
    private var rampGain: Float32 = 1.0

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    // MARK: - Public API

    /// Ref-counted. First `begin()` (when enabled) starts ducking all other apps'
    /// audio. Safe to call repeatedly; balanced by `end()`.
    func begin() {
        runOnMain {
            // Read enablement LIVE every begin(). Default ON when key absent.
            let enabled = UserDefaults.standard.object(forKey: "musicDuckingEnabled") as? Bool ?? true
            guard enabled else { return }

            // A new duck cancels any pending idle teardown so back-to-back utterances
            // reuse the live stack instead of rebuilding it (the source of the hitch).
            self.idleTeardownWork?.cancel()
            self.idleTeardownWork = nil

            self.refCount += 1
            guard self.refCount == 1 else { return }   // already ducking

            // Build the stack only if it isn't already alive (kept alive across the
            // idle window). On failure, start() leaves audio untouched.
            if !self.running {
                guard self.start() else {
                    self.refCount = 0
                    self.targetGain = 1.0
                    return
                }
            }
            // IOProc ramps smoothly toward this — no instant step, no click.
            self.targetGain = self.duckedGain
        }
    }

    /// Ref-counted. The last `end()` ramps back to full volume and schedules an idle
    /// teardown; it does NOT tear down immediately, so a following utterance is glitch-free.
    func end() {
        runOnMain {
            guard self.refCount > 0 else { return }    // floor at 0
            self.refCount -= 1
            guard self.refCount == 0 else { return }

            // Ramp other apps back to full, then release the (expensive) stack only if
            // still idle after the delay — a quick next turn cancels this.
            self.targetGain = 1.0
            self.idleTeardownWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                guard self.refCount == 0 else { return }
                self.idleTeardownWork = nil
                self.teardown()
            }
            self.idleTeardownWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + self.idleTeardownDelay, execute: work)
        }
    }

    // MARK: - Setup (main thread)

    /// Builds tap + aggregate + IOProc and starts it. Returns true on success. On ANY
    /// failure, tears down all partial state and returns false (audio untouched).
    private func start() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))

        guard !self.running else { return true }

        // 0. The tap re-render path assumes a ≤2ch output device. On multi-channel
        //    outputs (Apple Studio Display = 8ch) the stereo tap can't be re-rendered
        //    through the aggregate correctly and the device glitches ALL audio on it —
        //    Dottie's own TTS becomes garbled/robotic. Same ≤2ch constraint as VPIO
        //    (RealtimeClient+Conversation). Verified 2026-07-06 on Studio Display:
        //    ducking on = garbled TTS, ducking off = clean.
        //    yagni: skip ducking on such devices; upgrade path is a frame-wise 2→N
        //    channel upmix in ioProc if Studio Display ducking is ever wanted.
        if let devID = Self.defaultOutputDeviceID(), Self.outputChannelCount(devID) > 2 {
            AppLogger.shared.warn("[AudioDucker] output device has >2 channels — skipping ducking (tap re-render unsupported)")
            return false
        }

        // 1. Our own process AudioObjectID (to exclude from the tap).
        guard let ourProcessObjectID = self.ownProcessObjectID() else {
            AppLogger.shared.error("[AudioDucker] could not resolve own process object id — skipping ducking")
            return false
        }

        // 2. Tap description: capture everything EXCEPT Dottie, mute the originals.
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [ourProcessObjectID])
        desc.isPrivate = true
        desc.muteBehavior = CATapMuteBehavior.muted

        // 3. Create the process tap.
        var newTap: AUAudioObjectID = 0
        var status = AudioHardwareCreateProcessTap(desc, &newTap)
        guard status == noErr, newTap != 0 else {
            AppLogger.shared.error("[AudioDucker] AudioHardwareCreateProcessTap failed: \(status)")
            return false
        }
        self.tapID = newTap

        // 4. Current default output device + its UID.
        guard let outputUID = Self.defaultOutputDeviceUID() else {
            AppLogger.shared.error("[AudioDucker] could not resolve default output device UID")
            self.teardown()
            return false
        }

        // 5. Private aggregate device: sub-device = real output, tap list = our tap.
        let aggDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: self.aggregateName,
            kAudioAggregateDeviceUIDKey: self.aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: desc.uuid.uuidString]
            ],
        ]

        var newAgg: AudioObjectID = 0
        status = AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &newAgg)
        guard status == noErr, newAgg != 0 else {
            AppLogger.shared.error("[AudioDucker] AudioHardwareCreateAggregateDevice failed: \(status)")
            self.teardown()
            return false
        }
        self.aggregateID = newAgg

        // 6. Install + start the IOProc that re-renders the tap at reduced gain.
        var newProc: AudioDeviceIOProcID?
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        status = AudioDeviceCreateIOProcID(newAgg, AudioDucker.ioProc, selfPtr, &newProc)
        guard status == noErr, let proc = newProc else {
            AppLogger.shared.error("[AudioDucker] AudioDeviceCreateIOProcID failed: \(status)")
            self.teardown()
            return false
        }
        self.ioProcID = proc

        status = AudioDeviceStart(newAgg, proc)
        guard status == noErr else {
            AppLogger.shared.error("[AudioDucker] AudioDeviceStart failed: \(status)")
            self.teardown()
            return false
        }

        self.running = true
        AppLogger.shared.info("[AudioDucker] ducking started (output \(outputUID), gain \(self.duckedGain))")
        return true
    }

    // MARK: - Teardown (main thread)

    /// Destroys IOProc, aggregate device, and process tap in reverse order. Idempotent —
    /// safe to call on partial state and never tears down twice.
    private func teardown() {
        dispatchPrecondition(condition: .onQueue(.main))

        self.idleTeardownWork?.cancel()
        self.idleTeardownWork = nil
        self.targetGain = 1.0
        self.rampGain = 1.0

        if self.running, self.aggregateID != 0, let proc = self.ioProcID {
            let status = AudioDeviceStop(self.aggregateID, proc)
            if status != noErr {
                AppLogger.shared.error("[AudioDucker] AudioDeviceStop failed: \(status)")
            }
        }
        self.running = false

        if self.aggregateID != 0, let proc = self.ioProcID {
            let status = AudioDeviceDestroyIOProcID(self.aggregateID, proc)
            if status != noErr {
                AppLogger.shared.error("[AudioDucker] AudioDeviceDestroyIOProcID failed: \(status)")
            }
        }
        self.ioProcID = nil

        if self.aggregateID != 0 {
            let status = AudioHardwareDestroyAggregateDevice(self.aggregateID)
            if status != noErr {
                AppLogger.shared.error("[AudioDucker] AudioHardwareDestroyAggregateDevice failed: \(status)")
            }
            self.aggregateID = 0
        }

        if self.tapID != 0 {
            let status = AudioHardwareDestroyProcessTap(self.tapID)
            if status != noErr {
                AppLogger.shared.error("[AudioDucker] AudioHardwareDestroyProcessTap failed: \(status)")
            }
            self.tapID = 0
        }
    }

    @objc private func handleTerminate() {
        runOnMain {
            self.refCount = 0
            self.teardown()
        }
    }

    // MARK: - IOProc (audio thread)

    /// Copies the tap's INPUT buffers to the aggregate's OUTPUT buffers, scaling every
    /// Float32 sample by the current gain. Defensive about layout — on any mismatch it
    /// passes through at gain 1.0 (or zero-fills) rather than crashing.
    private static let ioProc: AudioDeviceIOProc = {
        (_ inDevice, _ inNow, inInputData, _ inInputTime, outOutputData, _ inOutputTime, inClientData) -> OSStatus in

        guard let clientData = inClientData else { return noErr }
        let ducker = Unmanaged<AudioDucker>.fromOpaque(clientData).takeUnretainedValue()
        let target = ducker.targetGain
        let coef = ducker.rampCoef
        var gain = ducker.rampGain   // audio-thread-only ramp state

        let outList = UnsafeMutableAudioBufferListPointer(outOutputData)
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))

        for outIdx in 0..<outList.count {
            let outBuf = outList[outIdx]
            guard let outData = outBuf.mData else { continue }
            let outBytes = Int(outBuf.mDataByteSize)

            // Match a corresponding input buffer; if none, output silence.
            guard outIdx < inList.count else {
                memset(outData, 0, outBytes)
                continue
            }
            let inBuf = inList[outIdx]
            guard let inData = inBuf.mData else {
                memset(outData, 0, outBytes)
                continue
            }

            // Channel layout must match for per-sample scaling; otherwise pass through
            // at gain 1.0 (copy the smaller byte count) rather than misalign.
            let copyBytes = min(outBytes, Int(inBuf.mDataByteSize))
            if inBuf.mNumberChannels != outBuf.mNumberChannels {
                memcpy(outData, inData, copyBytes)
                if copyBytes < outBytes { memset(outData + copyBytes, 0, outBytes - copyBytes) }
                continue
            }

            let sampleCount = copyBytes / MemoryLayout<Float32>.size
            let inSamples = inData.assumingMemoryBound(to: Float32.self)
            let outSamples = outData.assumingMemoryBound(to: Float32.self)
            for i in 0..<sampleCount {
                // Exponential glide toward target — smooth, click-free duck in/out.
                gain += (target - gain) * coef
                outSamples[i] = inSamples[i] * gain
            }
            // Zero any trailing region the input didn't cover.
            if copyBytes < outBytes { memset(outData + copyBytes, 0, outBytes - copyBytes) }
        }

        // Snap when essentially at target, then persist ramp state for the next buffer.
        if abs(target - gain) < 0.0005 { gain = target }
        ducker.rampGain = gain

        return noErr
    }

    // MARK: - Helpers

    /// Translates our PID to its CoreAudio process AudioObjectID so the tap can exclude it.
    private func ownProcessObjectID() -> AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        var objectID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &objectID
        )
        guard status == noErr, objectID != 0 else {
            AppLogger.shared.error("[AudioDucker] TranslatePIDToProcessObject failed: \(status)")
            return nil
        }
        return objectID
    }

    /// System default output device ID via CoreAudio.
    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != 0 else {
            AppLogger.shared.error("[AudioDucker] DefaultOutputDevice query failed: \(status)")
            return nil
        }
        return deviceID
    }

    /// Total output channel count of a device (sum over its output stream buffers).
    private static func outputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Reads the system default output device UID via CoreAudio. Mirrors the pattern in
    /// `RealtimeClient.defaultOutputDeviceUID()`.
    private static func defaultOutputDeviceUID() -> String? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString?
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &uidSize, ptr)
        }
        guard status == noErr else {
            AppLogger.shared.error("[AudioDucker] DeviceUID query failed: \(status)")
            return nil
        }
        return uid as String?
    }

    /// Runs `work` synchronously on the main thread (guards the ref count + lifecycle).
    private func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
