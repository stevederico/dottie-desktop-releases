//
//  GlobalRecorder.swift
//  Dottie
//
//  Standalone recorder for hotkey-triggered cursor-mode dictation.
//

import Foundation
import AVFoundation
import AppKit

/// The recording context that determines how transcribed text is dispatched after recording completes.
enum RecordingMode {
    /// Paste transcription at the current cursor position (hold-to-talk activation).
    case cursorMode
}

/// Standalone recorder for hotkey-triggered cursor-mode dictation.
/// Records audio via `AVAudioEngine` and pastes the transcription at the current cursor position.
class GlobalRecorder: ObservableObject {
    static let shared = GlobalRecorder()

    @Published var isRecording: Bool = false
    @Published var isTranscribing: Bool = false
    /// Cumulative live transcript while the PTT key is held (streaming mode only —
    /// empty in batch fallback). Rendered by the spectrum overlay.
    @Published private(set) var livePartial: String = ""

    private var currentMode: RecordingMode = .cursorMode
    // var, not let: releaseAudioEngineForRecovery() replaces the instance to free
    // its I/O audio unit (see VoiceWakeManager for the HAL-wedge rationale).
    private var audioEngine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?

    let spectrumAnalyzer = AudioSpectrumAnalyzer()

    // Lead-in VAD: adaptive replacement for a hard 300ms trim. The old fixed
    // window clipped fast speakers whose first word started before 300ms. Now
    // we sample the first ~50ms as noise floor, then start writing the moment
    // a frame exceeds noise + threshold — or unconditionally after maxLeadInSeconds
    // to avoid losing whispered/quiet speech.
    private var tapStartTime: Date?
    private var hasStartedWriting: Bool = false
    private var noiseFloor: Float = 0
    private let noiseOffsetThreshold: Float = 0.01
    private let minLeadInSeconds: TimeInterval = 0.05
    private let maxLeadInSeconds: TimeInterval = 0.5

    // ESC key monitoring
    private var escKeyMonitor: Any?

    // Dictation-latency instrumentation (dictation-amazing-plan P0): the moment
    // the key was released / recording stopped, used as t0 for release→text timing.
    private var dictationStoppedAt: Date?

    // Streaming PTT (dictation-amazing-plan P2): while the key is held, converted
    // 16kHz mono int16 PCM streams to the gateway's /v1/dictation/stream proxy so
    // key-release only pays the finalize tail. The WAV keeps being written in
    // parallel — any stream failure falls back to the batch upload unchanged.
    private var streamClient: DictationStreamClient?
    private var streamConverter: AVAudioConverter?

    /// Bumped by every stop/cancel. `startRecording` captures it before any async
    /// hop (STT readiness poll, mic permission prompt) and the continuation bails
    /// if it changed — otherwise a key release during the wait was a no-op
    /// (`stopRecording` returns at `guard isRecording`) and the deferred
    /// `performRecording()` opened a hot mic with no key held, endable only by ESC.
    private var startGeneration = 0

    // Paste-path timing constants (dictation-amazing-plan P1). Trimmed from the
    // former 200ms pre-paste / 50ms Cmd+V gap; keep a small floor so the target
    // app has focus and processes the synthetic Cmd+V before we release it.
    private static let prePasteDelay: TimeInterval = 0.02
    private static let cmdVGapMicros: UInt32 = 10_000
    private static let clipboardRestoreDelay: TimeInterval = 0.3
    /// Max time the stream finalize may take after key release before the
    /// watchdog abandons it for the batch WAV path. Server finalize is ~30ms;
    /// this bound exists because a hung finish (observed in the field) must
    /// never strand a dictation with no pasted text.
    private static let streamFinishWatchdog: TimeInterval = 2.5

    // Public accessor for recording mode
    var currentRecordingMode: RecordingMode {
        return currentMode
    }

    private init() {}

    deinit {
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioFile = nil
    }

    /// Releases the recorder's I/O audio unit by replacing the engine instance.
    /// Part of RealtimeClient's 0-channel HAL-wedge recovery — a stopped engine
    /// still holds its I/O unit allocated, which can keep the process-wide
    /// CoreAudio HAL client degenerate. No-op while a recording is in flight.
    func releaseAudioEngineForRecovery() {
        guard !isRecording else {
            AppLogger.shared.warn("[GlobalRecorder] Skipping engine release — recording in flight")
            return
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine = AVAudioEngine()
        AppLogger.shared.info("[GlobalRecorder] Audio engine released and recreated (HAL recovery)")
    }

    /// Begins audio recording in the specified mode after verifying microphone permission.
    /// - Parameter mode: The recording context that determines post-transcription behavior.
    func startRecording(mode: RecordingMode) {
        AppLogger.shared.info("GlobalRecorder.startRecording(mode: \(mode))")
        currentMode = mode

        // Stop any existing TTS playback
        RealtimeClient.shared.stopTTS()

        // Pause VoiceWake to avoid speech recognizer conflicts
        VoiceWakeManager.shared.stopListening()

        // Check permission status
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        // Every async continuation below is stale once the key is released.
        let gen = startGeneration

        switch status {
        case .authorized:
            AppLogger.shared.info("Microphone permission granted - starting recording")
            if GatewayClient.shared.isSTTReady {
                performRecording()
            } else {
                GatewayClient.shared.waitForSTTReady { [weak self] ready in
                    guard let self, gen == self.startGeneration else { return }
                    if ready {
                        self.performRecording()
                    } else {
                        AppLogger.shared.warn("[STT] Recording aborted — STT not ready")
                        GatewayClient.shared.surfaceSTTUnavailableBanner()
                    }
                }
            }

        case .notDetermined:
            // First run: ask, then re-enter on grant — discarding the result meant
            // the very first PTT press did nothing at all after the user allowed.
            AppLogger.shared.info("Microphone permission not determined - requesting")
            RecordingPermissionManager.requestMicrophonePermission { [weak self] granted in
                guard let self, gen == self.startGeneration else { return }
                if granted {
                    self.startRecording(mode: mode)
                } else {
                    self.showPermissionDeniedAlert()
                }
            }

        case .denied, .restricted:
            AppLogger.shared.warn("Microphone permission denied or restricted")
            showPermissionDeniedAlert()

        @unknown default:
            AppLogger.shared.warn("Unknown microphone permission status")
        }
    }

    /// Stops the audio engine, cleans up ESC monitoring,
    /// hides the spectrum overlay, and begins file verification followed by transcription.
    func stopRecording() {
        AppLogger.shared.info("GlobalRecorder.stopRecording() called, audioEngine.isRunning=\(audioEngine.isRunning)")

        // Invalidate any pending start before the guard below — a key release that
        // arrives while startRecording() is still waiting on STT readiness or the
        // mic prompt must cancel it, not fall through as a no-op.
        startGeneration &+= 1

        // Idempotency guard: a double stopRecording() (e.g. hotkey-up racing an
        // ESC cancel or a second key-up event) must not re-transcribe and
        // re-paste the same file. Only proceed if a recording is actually in
        // flight; flip the flag immediately so a re-entrant call no-ops.
        guard isRecording else {
            AppLogger.shared.debug("stopRecording() ignored — not currently recording")
            return
        }
        isRecording = false
        livePartial = ""
        dictationStoppedAt = Date()
        AudioDucker.shared.end()

        // Clean up ESC key monitoring
        stopEscKeyMonitoring()

        if audioEngine.isRunning {
            AppLogger.shared.debug("Removing audio tap and stopping engine")
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }

        isTranscribing = true

        // Reset spectrum analyzer
        spectrumAnalyzer.reset()

        // Pre-provision the I/O unit for the NEXT dictation while this one
        // transcribes — start() then only pays the HAL resume, not the full
        // audio-unit setup (VoiceWakeManager does the same before its start()).
        audioEngine.prepare()

        // Hide full-screen spectrum overlay (cursor mode pastes silently at cursor;
        // no transcript display needed beyond the spectrum cue).
        FullScreenSpectrumOverlayManager.shared.hide()

        // Close the audio file
        audioFile = nil

        // Consume the recording URL so a re-entrant stop can't reuse it.
        let url = recordingURL
        recordingURL = nil

        if let url = url {
            AppLogger.shared.info("Recording saved to: \(url.path)")

            // The file is already fully written: audioEngine.stop() flushes pending
            // buffers and `audioFile = nil` above closes the handle. The old fixed
            // 100ms wait here was dead latency on the release→text path — transcribe
            // immediately. (dictation-amazing-plan P1)
            //
            // Streaming-first (P2): audio already streamed while the key was held,
            // so finalize only pays the tail window. Any stream failure falls back
            // to the batch WAV upload below — streaming can only be faster, never
            // lossier.
            if let client = streamClient {
                streamClient = nil
                streamConverter = nil
                let t0 = dictationStoppedAt ?? Date()
                // Once-guard shared by the finish completion and the watchdog.
                // Both run on the main thread, so a captured var is race-free.
                var streamHandled = false
                let handleStreamResult: ((text: String, sttMs: Int?, formatMs: Int?)?) -> Void = { [weak self] result in
                    guard let self, !streamHandled else { return }
                    streamHandled = true
                    if let result, !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.isTranscribing = false
                        let now = Date()
                        self.logDictationLatency(
                            text: result.text,
                            toTextSec: now.timeIntervalSince(t0),
                            overheadSec: 0,
                            roundtripSec: now.timeIntervalSince(t0),
                            sttMs: result.sttMs, formatMs: result.formatMs,
                            mode: "stream"
                        )
                        AppLogger.shared.info("Stream transcription successful (\(result.text.count) chars)")
                        self.handleTranscriptionResult(result.text)
                    } else {
                        AppLogger.shared.debug("[DictationStream] falling back to batch upload")
                        self.verifyAndTranscribeRecording(url: url)
                    }
                }
                client.finish(completion: handleStreamResult)
                // Watchdog: the stream path must never strand a dictation. In the
                // field, finish's completion sometimes never fired (no paste, no
                // fallback) — if it hasn't resolved by now, cancel the stream
                // session and decode the parallel WAV instead.
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.streamFinishWatchdog) {
                    guard !streamHandled else { return }
                    AppLogger.shared.error("[DictationStream] finish watchdog fired after \(Self.streamFinishWatchdog)s — stream hung, using batch path")
                    client.cancel()
                    handleStreamResult(nil)
                }
            } else {
                verifyAndTranscribeRecording(url: url)
            }
        } else {
            AppLogger.shared.error("No recording URL available")
            streamClient?.cancel()
            streamClient = nil
            streamConverter = nil
            isTranscribing = false
            // VoiceWake was paused in startRecording(); restore it on this
            // failure exit so a single failed dictation doesn't kill "Hey Dottie".
            resumeVoiceWakeIfEnabled()
        }
    }

    /// Cancels the current recording without transcribing. Stops the audio engine,
    /// cleans up all monitors, hides overlays, and deletes the recorded file.
    func cancelRecording() {
        AppLogger.shared.info("GlobalRecorder.cancelRecording() - ESC pressed, canceling without transcription")

        // Invalidate any pending start (see stopRecording).
        startGeneration &+= 1

        // Clean up ESC key monitoring
        stopEscKeyMonitoring()

        if audioEngine.isRunning {
            AppLogger.shared.debug("Removing audio tap and stopping engine")
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }

        isRecording = false
        livePartial = ""
        AudioDucker.shared.end()
        isTranscribing = false

        // Reset spectrum analyzer
        spectrumAnalyzer.reset()

        // Hide full-screen spectrum overlay
        FullScreenSpectrumOverlayManager.shared.hide()

        // Free the dictation stream session (ESC = discard everything)
        streamClient?.cancel()
        streamClient = nil
        streamConverter = nil

        // Close and delete the audio file
        audioFile = nil
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
            AppLogger.shared.info("Recording file deleted: \(url.path)")
        }
        recordingURL = nil

        // Resume VoiceWake if enabled
        resumeVoiceWakeIfEnabled()
    }

    // MARK: - ESC Key Monitoring
    private func startEscKeyMonitoring() {
        escKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            // ESC key code is 53
            if event.keyCode == 53 && self.isRecording {
                AppLogger.shared.info("ESC key pressed - canceling recording")
                DispatchQueue.main.async {
                    self.cancelRecording()
                }
                return nil // Consume the event
            }

            return event
        }
        AppLogger.shared.info("ESC key monitoring started")
    }

    private func stopEscKeyMonitoring() {
        if let monitor = escKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escKeyMonitor = nil
        }
    }

    /// Calculates RMS audio level from buffer.
    private func calculateRMSLevel(buffer: AVAudioPCMBuffer) -> Float {
        GatewayClient.calculateRMSLevel(buffer: buffer)
    }

    /// Converts a tap buffer to 16 kHz mono int16 PCM for the dictation stream.
    /// Returns nil (silently) on any conversion hiccup — the WAV batch path is
    /// still recording the same audio, so a dropped chunk only means fallback.
    private func convertForStreaming(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let converter = streamConverter else { return nil }
        let ratio = converter.outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return nil }
        var fed = false
        var conversionError: NSError?
        converter.convert(to: out, error: &conversionError) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, out.frameLength > 0, let channel = out.int16ChannelData else { return nil }
        return Data(bytes: channel[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
    }

    private func performRecording() {
        AppLogger.shared.info("GlobalRecorder.performRecording() - mode: \(currentMode)")

        // Never double-install the tap on audioEngine.inputNode — a second install
        // on the same bus throws, and the catch below leaves the engine running.
        guard !isRecording else {
            AppLogger.shared.warn("performRecording() ignored — already recording")
            return
        }

        do {
            // Show full-screen spectrum overlay (the "Dottie can hear you" cue)
            FullScreenSpectrumOverlayManager.shared.show(with: spectrumAnalyzer)

            // Create ~/.dottie/recordings/ directory
            let dottieDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dottie")
            let recordingsDir = dottieDir.appendingPathComponent("recordings")
            do {
                try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
            } catch {
                AppLogger.shared.error("[GlobalRecorder] failed to create recordings dir, write will fail: \(error)")
            }

            let audioFilename = recordingsDir.appendingPathComponent("recording_\(Date().timeIntervalSince1970).wav")
            recordingURL = audioFilename
            AppLogger.shared.debug("Recording URL: \(audioFilename.path)")

            // Configure AVAudioEngine for recording
            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            AppLogger.shared.debug("Input format: sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount)")

            // Guard the input format before installing a tap. When CoreAudio is
            // mid-device-switch the input node reports a 0-channel / 0-Hz format;
            // installTap then throws an UNCAUGHT Obj-C exception (AVAudioIONodeImpl::
            // SetOutputFormat) → SIGABRT — Swift's do/catch can't catch it. Bail to
            // the catch below (cleans up + shows the error) instead of aborting.
            guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
                throw NSError(domain: "GlobalRecorder", code: -10,
                              userInfo: [NSLocalizedDescriptionKey: "Audio input not ready — try again"])
            }

            // Create stereo recording format with proper WAV settings
            let recordingSettings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: inputFormat.sampleRate,
                AVNumberOfChannelsKey: min(2, inputFormat.channelCount),
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false
            ]

            AppLogger.shared.debug("Recording format created successfully")

            // Create audio file for writing
            audioFile = try AVAudioFile(forWriting: audioFilename, settings: recordingSettings)
            AppLogger.shared.debug("Audio file created for writing")

            // Streaming PTT: set up the input→16kHz-mono-int16 converter and open
            // the stream session in parallel with recording. Both are best-effort;
            // nil converter or a failed session just means the batch path wins.
            //
            // Multilingual mode skips streaming entirely: the incremental EOU
            // model is English-tuned and butchers other languages (measured:
            // "buenos diazaria program" vs the batch model's perfect Spanish),
            // while the batch Parakeet v3 auto-detects 25 languages. Batch-only
            // still lands in ~100-300ms server-side — correct beats partials.
            let multilingual = UserDefaults.standard.string(forKey: "dictationLanguageMode") == "multilingual"
            if !multilingual, let streamFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true) {
                streamConverter = AVAudioConverter(from: inputFormat, to: streamFormat)
            }
            if streamConverter != nil {
                let client = DictationStreamClient()
                client.onPartial = { [weak self] text in
                    guard let self, self.isRecording else { return }
                    self.livePartial = text
                }
                streamClient = client
                client.begin()
            }

            // Install tap on input node
            tapStartTime = Date()
            hasStartedWriting = false
            noiseFloor = 0
            // Routed through the safe installer: its Obj-C exception barrier turns a
            // mid-device-switch format mismatch into a thrown error (caught below)
            // instead of an uncatchable installTapOnBus NSException → SIGABRT.
            try AudioTapInstaller.installTap(on: inputNode, bufferSize: 1024, format: nil) { [weak self] (buffer, _) in
                guard let self = self else { return }

                // Always feed spectrum analyzer so the visual indicator reacts
                // during calibration and silence.
                self.spectrumAnalyzer.processBuffer(buffer)

                // Lead-in VAD: skip/buffer until voice detected or maxLeadInSeconds.
                if !self.hasStartedWriting {
                    let elapsed = self.tapStartTime.map { Date().timeIntervalSince($0) } ?? 0
                    let level = self.calculateRMSLevel(buffer: buffer)

                    if elapsed < self.minLeadInSeconds {
                        // Calibration window: accumulate noise floor. First few
                        // frames are assumed to be ambient / mic-activation hiss.
                        self.noiseFloor = max(self.noiseFloor, level)
                        return
                    }

                    let voiceDetected = level > (self.noiseFloor + self.noiseOffsetThreshold)
                    let hardTimeout = elapsed >= self.maxLeadInSeconds
                    if !voiceDetected && !hardTimeout {
                        return
                    }
                    // Either we heard voice or we hit the timeout — open the gate.
                    self.hasStartedWriting = true
                    AppLogger.shared.debug("[Recorder] Lead-in VAD opened after \(Int(elapsed * 1000))ms (level=\(level), floor=\(self.noiseFloor), reason=\(voiceDetected ? "voice" : "timeout"))")
                }

                do {
                    try self.audioFile?.write(from: buffer)
                } catch {
                    AppLogger.shared.error("Error writing audio buffer: \(error)")
                }

                // Stream the same post-VAD audio to the dictation stream session
                // (converted to 16kHz mono int16). Same gate as the file write, so
                // stream and batch see identical audio.
                if let client = self.streamClient, let pcm = self.convertForStreaming(buffer) {
                    client.append(pcm)
                }
            }
            AppLogger.shared.debug("Audio tap installed")

            // Start ESC key monitoring (all modes)
            startEscKeyMonitoring()

            // Start the audio engine
            AppLogger.shared.info("Starting audio engine...")
            try audioEngine.start()
            isRecording = true
            AudioDucker.shared.begin()
            NSSound(named: "Ping")?.play()
            AppLogger.shared.info("Audio engine started - recording in progress")

        } catch {
            AppLogger.shared.error("Failed to start recording: \(error.localizedDescription)")
            // Clean up orphaned audio tap if engine failed to start
            audioEngine.inputNode.removeTap(onBus: 0)
            audioFile = nil
            isRecording = false
            showRecordingError(error.localizedDescription)

            // Hide overlay on error
            FullScreenSpectrumOverlayManager.shared.hide()
        }
    }

    private func verifyAndTranscribeRecording(url: URL) {
        AppLogger.shared.debug("Verifying recording file: \(url.path)")

        guard FileManager.default.fileExists(atPath: url.path) else {
            AppLogger.shared.error("Recording file does not exist at \(url.path)")
            isTranscribing = false
            // VoiceWake was paused in startRecording(); every failure exit must
            // resume it or one bad dictation kills "Hey Dottie" for the session.
            resumeVoiceWakeIfEnabled()
            return
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = attributes[.size] as? Int64 ?? 0

            if fileSize == 0 {
                AppLogger.shared.error("Recording file is empty")
                isTranscribing = false
                resumeVoiceWakeIfEnabled()
                return
            }

            // Header-only WAV (~4KB): the lead-in VAD never opened, i.e. an
            // accidental sub-200ms key tap with no speech. Uploading it just
            // gets a 400 from the audio server and a scary "could not
            // transcribe" toast — skip silently instead.
            if fileSize <= 4096 {
                AppLogger.shared.info("Recording has no audio frames (\(fileSize) bytes, accidental tap) — skipping")
                isTranscribing = false
                try? FileManager.default.removeItem(at: url)
                resumeVoiceWakeIfEnabled()
                return
            }

            AppLogger.shared.info("Recording file verified: \(fileSize) bytes")
            transcribeAudio(from: url)
        } catch {
            AppLogger.shared.error("Error verifying recording file: \(error)")
            isTranscribing = false
            resumeVoiceWakeIfEnabled()
        }
    }

    private func transcribeAudio(from fileURL: URL) {
        AppLogger.shared.info("Starting transcription from: \(fileURL.lastPathComponent)")

        let t0 = dictationStoppedAt ?? Date()
        let uploadStart = Date()
        GatewayClient.shared.transcribeAudio(from: fileURL) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isTranscribing = false

                switch result {
                case .success(let r):
                    let now = Date()
                    self.logDictationLatency(
                        text: r.text,
                        toTextSec: now.timeIntervalSince(t0),
                        overheadSec: uploadStart.timeIntervalSince(t0),
                        roundtripSec: now.timeIntervalSince(uploadStart),
                        sttMs: r.sttMs, formatMs: r.formatMs
                    )
                    AppLogger.shared.info("Transcription successful (\(r.text.count) chars)")
                    self.handleTranscriptionResult(r.text)

                case .failure(let error):
                    // Detection point already covered by stt.audio_server_unavailable
                    // (GatewayClient.transcribeAudio). Demote here to avoid duplicate logs.
                    AppLogger.shared.warn("Transcription error: \(error)")
                    if case ClientError.serverError(503, _) = error {
                        // Surface through persistent banner instead of a
                        // dismissible alert. A background poller clears the
                        // banner when /health comes back, so the user never
                        // has to manually retry-to-check — they just try PTT
                        // again when the banner disappears.
                        //
                        // A 503 here means the gateway (:1317) health probe
                        // failed, so neither local nor cloud STT can run — all
                        // dictation flows through the gateway. Avoid "audio
                        // server" wording, which an xAI-mode user (no local
                        // parakeet) would read as a missing local component;
                        // name the dictation service generically instead.
                        GatewayClient.shared.surfaceSTTUnavailableBanner(
                            message: "Dictation service unavailable — transcription offline."
                        )
                    } else {
                        DispatchQueue.main.async {
                            let alert = NSAlert()
                            alert.messageText = "Transcription Failed"
                            alert.informativeText = "Could not transcribe audio. Please try again."
                            alert.alertStyle = .critical
                            alert.addButton(withTitle: "OK")
                            alert.runModal()
                        }
                    }
                    // VoiceWake was paused in startRecording(); resume on the
                    // failure path too — the success path resumes via
                    // handleTranscriptionResult, but a failed dictation must not
                    // permanently kill "Hey Dottie" for the rest of the session.
                    self.resumeVoiceWakeIfEnabled()
                }
            }
        }
    }

    /// Strips leading STT artifacts: filler words (uh, um) and partial-word fragments (Wh, Th)
    /// that parakeet picks up from initial breath/phoneme sounds.
    private func stripLeadingFillers(_ text: String) -> String {
        let fillers: Set<String> = ["uh", "um", "hmm", "ah", "eh", "oh", "huh"]
        // Valid short words that should NOT be stripped
        let validShort: Set<String> = [
            "a", "i", "an", "am", "as", "at", "be", "by", "do", "go", "he",
            "if", "in", "is", "it", "me", "my", "no", "of", "on", "or", "so",
            "to", "up", "us", "we", "hi", "ok", "yo"
        ]
        var words = text.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard words.count > 1, let first = words.first else { return text }
        let cleaned = first.lowercased().trimmingCharacters(in: .punctuationCharacters)
        // Strip if it's a known filler OR a short fragment that isn't a real word
        let isFragment = cleaned.count <= 3 && !validShort.contains(cleaned) && cleaned.allSatisfy(\.isLetter)
        if fillers.contains(cleaned) || isFragment {
            words.removeFirst()
            guard let next = words.first else { return text }
            let capitalized = next.prefix(1).uppercased() + next.dropFirst()
            if words.count > 1 {
                return capitalized + " " + words[1]
            }
            return capitalized
        }
        return text
    }

    private func handleTranscriptionResult(_ text: String) {
        // Skip empty or too-short transcriptions (likely noise or partial wake word)
        let trimmed = stripLeadingFillers(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard trimmed.count >= 3 else {
            AppLogger.shared.info("Transcription too short (\(trimmed.count) chars) - skipping")
            resumeVoiceWakeIfEnabled()
            return
        }

        // Text replacements ("addr" → full address) before paste — applies to
        // stream and batch results alike.
        let expanded = DictationVocabulary.applyReplacements(trimmed)

        // Always broadcast the final transcript. Onboarding's sample field listens
        // and inserts text without Cmd+V — synthetic paste needs Accessibility +
        // focus and often fails mid-setup even when STT worked.
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .dictationTranscript,
                object: nil,
                userInfo: ["text": expanded]
            )
        }

        // During onboarding the tryout field already gets the notification above.
        // Also Cmd+V'ing into the focused field doubled the text ("hello hello").
        let onboardingOpen = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        if onboardingOpen {
            DictationStats.record(text: expanded)
            resumeVoiceWakeIfEnabled()
            return
        }

        // Cursor mode: snapshot the user's clipboard, paste the transcript, then
        // restore the clipboard after the paste lands (dictation-amazing-plan P1 —
        // dictation must not clobber whatever the user had copied).
        let saved = snapshotPasteboard()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(expanded, forType: .string)
        pasteAtCursor(restoring: saved)
        DictationStats.record(text: expanded)
        resumeVoiceWakeIfEnabled()
    }

    /// Local debug log for PTT release→text timing (ints + char count only — no transcript).
    private func logDictationLatency(text: String, toTextSec: TimeInterval, overheadSec: TimeInterval, roundtripSec: TimeInterval, sttMs: Int?, formatMs: Int?, mode: String = "batch") {
        let toText = Int(toTextSec * 1000)
        let overhead = Int(overheadSec * 1000)
        let roundtrip = Int(roundtripSec * 1000)
        AppLogger.shared.debug("[Dictation] mode=\(mode) to_text=\(toText)ms overhead=\(overhead)ms roundtrip=\(roundtrip)ms stt=\(sttMs.map(String.init) ?? "-")ms format=\(formatMs.map(String.init) ?? "-")ms chars=\(text.count)")
    }

    /// Deep-copies the current pasteboard so it can be restored after a synthetic
    /// paste. Copies every representation of each item, so rich content (files,
    /// images, styled text) survives — not just plain strings.
    private func snapshotPasteboard() -> [NSPasteboardItem] {
        NSPasteboard.general.pasteboardItems?.compactMap { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy.types.isEmpty ? nil : copy
        } ?? []
    }

    /// Restores a previously snapshotted pasteboard. No-op on an empty snapshot
    /// (the user had nothing copied — leave the transcript on the clipboard).
    private func restorePasteboard(_ items: [NSPasteboardItem]) {
        guard !items.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(items)
    }

    /// Resumes VoiceWake listening if the user has it enabled in settings.
    private func resumeVoiceWakeIfEnabled() {
        if UserDefaults.standard.bool(forKey: "voiceWakeEnabled") {
            // Cancel any stale subscription before resuming (prevents double resume)
            VoiceWakeManager.shared.cancelRecordingCompletionSubscription()
            VoiceWakeManager.shared.startListening()
        }
    }

    /// Pastes the given text at the cursor in the frontmost app, reusing the
    /// existing accessibility-gated paste path (NSPasteboard + synthesized Cmd+V)
    /// WITHOUT going through the recording flow. Used by voice "start dictation"
    /// to deposit a dictated utterance at the cursor. No audio engine is touched.
    func pasteTextAtCursor(_ text: String) {
        let trimmed = stripLeadingFillers(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty else {
            AppLogger.shared.info("[GlobalRecorder] pasteTextAtCursor: empty after trim - skipping")
            return
        }
        let saved = snapshotPasteboard()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(trimmed, forType: .string)
        pasteAtCursor(restoring: saved)
    }

    private func pasteAtCursor(restoring saved: [NSPasteboardItem] = []) {
        // Check accessibility permission first
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)

        if !trusted {
            AppLogger.shared.warn("Accessibility permission not granted - prompting user")
            // Show permission dialog for cursorMode (dictation)
            if currentMode == .cursorMode {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Accessibility Permission Required"
                    alert.informativeText = "Dottie needs Accessibility permission to paste transcribed text. Please enable it in System Settings > Privacy & Security > Accessibility."
                    alert.alertStyle = .critical
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
            return
        }

        // Use a background queue to avoid main thread blocking
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + Self.prePasteDelay) {
            self.executePaste()
            // Restore the user's clipboard once the target app has consumed the paste.
            if !saved.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.clipboardRestoreDelay) {
                    self.restorePasteboard(saved)
                }
            }
        }
    }

    private func executePaste() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            AppLogger.shared.error("Failed to create CGEventSource")
            return
        }

        // V key = keycode 9
        let vKeyCode: CGKeyCode = 9

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true) else {
            AppLogger.shared.error("Failed to create keyDown event")
            return
        }
        keyDown.flags = .maskCommand

        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            AppLogger.shared.error("Failed to create keyUp event")
            return
        }
        keyUp.flags = .maskCommand

        // Post the events
        keyDown.post(tap: .cghidEventTap)
        usleep(Self.cmdVGapMicros)
        keyUp.post(tap: .cghidEventTap)

        AppLogger.shared.info("Paste CMD+V executed successfully")
    }

    private func showPermissionDeniedAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Microphone Access Required"
            alert.informativeText = "Dottie needs microphone access to record audio. Please grant permission in System Settings > Privacy & Security > Microphone, then restart the app."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func showRecordingError(_ message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Recording Error"
            alert.informativeText = "Failed to start recording: \(message)"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

// MARK: - Recording Permission

/// Centralized microphone permission handling.
class RecordingPermissionManager {
    /// Opens System Settings to Privacy & Security → Microphone. macOS only shows
    /// the mic prompt once; after a "Don't Allow" the OS never re-prompts, so this
    /// deep link is the only way for the user to grant access without a reinstall.
    static func openSystemPreferences() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Request microphone permission.
    static func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                if granted {
                    AppLogger.info("Microphone permission granted")
                } else {
                    AppLogger.warn("Microphone permission denied")
                }
                completion(granted)
            }
        }
    }
}
