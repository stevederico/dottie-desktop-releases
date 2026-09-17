//
//  AudioTapInstaller.swift
//  Dottie
//
//  Single safe entry point for installing an AVAudioEngine input tap.
//
//  Every call site that installs a mic tap (VoiceWakeManager, GlobalRecorder,
//  RealtimeClient conversation) previously crashed with SIGABRT when CoreAudio
//  reconfigured the input device (route change, sleep/wake, AggregateDevice
//  rebuild) between reading the input format and installing the tap: a stale or
//  invalid format makes `-[AVAudioNode installTapOnBus:bufferSize:format:block:]`
//  raise an Objective-C NSException (AVAudioIONodeImpl::SetOutputFormat) that
//  Swift's `do/catch` cannot catch → std::terminate → abort().
//
//  This helper centralizes the fix so it can't rot per-site:
//   1. removes any stale tap,
//   2. resolves + guards the live format as late as possible (closes the
//      time-of-check/time-of-use race),
//   3. installs the tap inside `DTTryBlock` (the Obj-C exception barrier), so any
//      throw surfaces as a normal Swift error the caller can recover from.
//

import AVFoundation

enum AudioTapInstaller {
    /// Installs a tap on bus 0 of `node`, converting AVFoundation's uncatchable
    /// NSException into a thrown Swift error.
    ///
    /// - Parameters:
    ///   - node: the input node to tap.
    ///   - bufferSize: tap buffer size in frames.
    ///   - format: explicit tap format, or `nil` to use the node's live output
    ///     format. Pass `nil` when the tap block is format-agnostic (lets the
    ///     installer resolve the freshest format and minimizes the stale-format
    ///     window); pass an explicit format when downstream code (e.g. an
    ///     `AVAudioConverter`) is built against that exact format.
    ///   - block: the tap callback.
    /// - Throws: `AudioTapError.inputNotReady` if the resolved format is invalid
    ///   (0 channels / 0 Hz), or the caught `NSError` if `installTap` raised.
    static func installTap(on node: AVAudioInputNode,
                           bufferSize: AVAudioFrameCount,
                           format: AVAudioFormat?,
                           block: @escaping AVAudioNodeTapBlock) throws {
        // Clear any tap a prior (possibly failed) teardown left behind — a
        // double-install is itself one of the NSException triggers.
        node.removeTap(onBus: 0)

        // Resolve the format as late as possible and validate it. During a device
        // switch the node reports a 0-channel / 0-Hz format; installing with that
        // is the exact condition that throws.
        let resolved = format ?? node.outputFormat(forBus: 0)
        guard resolved.channelCount > 0, resolved.sampleRate > 0 else {
            throw AudioTapError.inputNotReady(channels: resolved.channelCount,
                                              sampleRate: resolved.sampleRate)
        }

        // Install inside the Obj-C exception barrier. Pass the caller's original
        // `format` (possibly nil) so each site keeps its exact tap semantics; the
        // guard above used the resolved format only for validation.
        if let nsError = DTTryBlock({
            node.installTap(onBus: 0, bufferSize: bufferSize, format: format, block: block)
        }) {
            // Roll back a partially-installed tap before surfacing the error.
            node.removeTap(onBus: 0)
            throw nsError
        }
    }
}

enum AudioTapError: LocalizedError {
    case inputNotReady(channels: AVAudioChannelCount, sampleRate: Double)

    var errorDescription: String? {
        switch self {
        case let .inputNotReady(channels, sampleRate):
            return "Audio input not ready (ch=\(channels), sr=\(sampleRate))"
        }
    }
}
