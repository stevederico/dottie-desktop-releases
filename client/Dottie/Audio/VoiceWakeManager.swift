//
//  VoiceWakeManager.swift
//  Dottie
//
//  Created by Claude Code on 1/25/26.
//

import Foundation
import Speech
import AVFoundation
import AppKit
import Combine

/// Manages hands-free wake word detection using `SFSpeechRecognizer` for continuous audio monitoring.
/// Recognizes configurable trigger phrases (default "hey dottie") with common phonetic variations,
/// enforces a cooldown between activations, and restarts recognition with exponential backoff on failure.
class VoiceWakeManager: ObservableObject {
    static let shared = VoiceWakeManager()

    @Published var isListening: Bool = false
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "voiceWakeEnabled")
            if isEnabled {
                // Explicit re-enable is a fresh episode — clear the give-up state.
                consecutiveStartFailures = 0
                startListening()
            } else {
                stopListening()
            }
        }
    }
    @Published var triggerPhrase: String {
        didSet {
            UserDefaults.standard.set(triggerPhrase, forKey: "voiceWakeTriggerPhrase")
        }
    }
    @Published var permissionStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined

    var onWakeWordDetected: (() -> Void)?

    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    // var, not let: releaseAudioEngineForRecovery() replaces the instance to free
    // its I/O audio unit — a stopped AVAudioEngine still holds the unit allocated,
    // and a degenerate unit can wedge the process-wide CoreAudio HAL client
    // (every fresh engine then reports 0-channel formats).
    private var audioEngine = AVAudioEngine()
    private var lastDetectionTime: Date = .distantPast
    private let cooldownInterval: TimeInterval = 3.0 // Prevent rapid re-triggers
    private var recordingCompletionCancellable: AnyCancellable?

    // Restart backoff to prevent infinite restart loops
    private var restartAttempts: Int = 0
    private let maxRestartAttempts: Int = 5
    private var lastRestartTime: Date = .distantPast
    private let restartBackoffInterval: TimeInterval = 30.0 // Reset counter after this interval

    // Flag to distinguish intentional stop (wake word detected) from error/final state
    private var wakeWordTriggered: Bool = false

    // Cancellable restart work item to prevent overlapping async dispatches
    private var restartWorkItem: DispatchWorkItem?

    // Consecutive session-start failures across backoff cycles. The per-cycle
    // restartAttempts counter resets every 30s, so a permanently-broken audio
    // input (mic gone, engine can't start) retried + error-logged forever —
    // this was the 2026.7.7 log flood (39 error-level lines from one install).
    // After the cap we stop retrying and log once; a device change, app
    // reactivation, or the enable toggle resets the counter and tries again.
    private var consecutiveStartFailures: Int = 0
    private let maxConsecutiveStartFailures: Int = 15
    // Attempt count at which a run of failed starts stops being a recoverable
    // transient (self-heals via backoff) and becomes a real stuck state worth an
    // error-level log. Below the give-up cap so one stuck episode logs once while still retrying.
    private let stuckFailureThreshold: Int = 3

    // Observer for audio route/device changes (headphones, default-device switch,
    // sleep/wake). Lets us restart the recognizer AFTER the route settles instead
    // of racing the CoreAudio device rebuild (the SIGABRT trigger).
    private var configChangeObserver: NSObjectProtocol?

    // Guard against concurrent startListening() calls
    private var isStartingSession: Bool = false

    // Track TTS playback to require full phrase (prevents self-triggering on "dottie" alone)
    private var ttsPlaybackCancellable: AnyCancellable?
    private var isTTSPlaying: Bool = false
    private var ttsStoppedTime: Date = .distantPast
    // `isPlayingTTS` flips false the moment the last audio.delta event finishes
    // draining, but Kokoros/AVAudioPlayerNode can still be emitting tail-out
    // audio that the microphone hears for another couple of seconds. The old
    // 1.5s window let TTS saying "Dottie" re-wake the assistant. 3.0s was
    // measured against long-sentence playback to stay on the safe side.
    private let postTTSCooldown: TimeInterval = 3.0

    /// Cached permission snapshot used to detect transitions. When the app
    /// comes back to foreground (`didBecomeActive`), we compare current status
    /// to this snapshot and auto-start listening if the user granted access in
    /// System Settings while the app was in the background.
    private var lastKnownMicStatus: AVAuthorizationStatus = .notDetermined
    private var lastKnownSpeechStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined

    private init() {
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        self.isEnabled = UserDefaults.standard.bool(forKey: "voiceWakeEnabled")
        self.triggerPhrase = UserDefaults.standard.string(forKey: "voiceWakeTriggerPhrase") ?? "hey dottie"

        checkPermissionStatus()
        self.lastKnownMicStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        self.lastKnownSpeechStatus = permissionStatus

        // Re-check permissions on app foreground — catches the case where the
        // user granted mic/speech in System Settings while we were backgrounded.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppBecameActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        // Track TTS playback - during TTS and shortly after, require full "hey dottie" to prevent self-trigger
        ttsPlaybackCancellable = RealtimeClient.shared.$isPlayingTTS
            .removeDuplicates()
            .sink { [weak self] isPlaying in
                guard let self = self else { return }
                let wasPlaying = self.isTTSPlaying
                self.isTTSPlaying = isPlaying
                // Track when TTS stopped to enforce post-TTS cooldown
                if wasPlaying && !isPlaying {
                    self.ttsStoppedTime = Date()
                    AppLogger.shared.debug("[VoiceWake] TTS stopped - post-cooldown active for \(self.postTTSCooldown)s")
                }
                AppLogger.shared.debug("[VoiceWake] TTS playing: \(isPlaying)")
            }

        registerConfigChangeObserver()
    }

    /// Restart the wake recognizer when the audio route changes (headphones
    /// plug/unplug, default-device switch, sleep/wake). Without this, a
    /// restart can race the in-flight CoreAudio device rebuild and install a
    /// tap against a stale format. queue: nil + async-to-main (in
    /// handleConfigurationChange) avoids the synchronous-teardown deadlock
    /// documented in RealtimeClient+Conversation. Re-registered whenever the
    /// engine instance is replaced (observer is bound to `object: audioEngine`).
    private func registerConfigChangeObserver() {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine, queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    /// Releases the wake engine's I/O audio unit by replacing the engine instance.
    /// Called by RealtimeClient's 0-channel HAL-wedge recovery: stopping an engine
    /// is not enough — its allocated I/O unit can keep the process's CoreAudio HAL
    /// client degenerate, making every AVAudioEngine in the process (including
    /// brand-new ones) report 0-channel formats. Safe to call anytime; the next
    /// startListening() builds state against the fresh instance.
    func releaseAudioEngineForRecovery() {
        stopListening()
        audioEngine = AVAudioEngine()
        registerConfigChangeObserver()
        AppLogger.shared.info("[VoiceWake] Audio engine released and recreated (HAL recovery)")
    }

    /// Touches the input HAL and pre-allocates the engine's I/O unit. The FIRST
    /// mic-path access in the process does the CoreAudio cold init — measured as
    /// a 5s main-thread hang (beachball) when startListening() paid it on main
    /// at launch+5s. Call this from a background queue BEFORE the main-thread
    /// start; access is sequential (caller chains main-start after it), never
    /// concurrent with engine use. Does not record and never triggers a TCC prompt.
    func prewarmAudio() {
        _ = audioEngine.inputNode.inputFormat(forBus: 0)
        audioEngine.prepare()
    }

    /// Coalesces the burst of configuration-change notifications a single route
    /// switch emits, then restarts recognition once the route has settled. The
    /// safe installer still guards each attempt, so this is hardening (avoid the
    /// race) layered on top of the barrier (survive it).
    private func handleConfigurationChange() {
        guard isEnabled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            AppLogger.shared.debug("[VoiceWake] Audio configuration changed — scheduling restart")
            self.restartWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.isEnabled else { return }
                // A device change is a legitimate fresh restart cause, not a
                // failure loop — reset the backoff counters before restarting.
                self.restartAttempts = 0
                self.consecutiveStartFailures = 0
                self.restartRecognition()
            }
            self.restartWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    /// Called when Dottie returns to foreground. Compares current mic + speech
    /// auth status to the last-known snapshot; if either transitioned to
    /// `.authorized` and VoiceWake is enabled but not listening, start it now.
    /// This is what lets users flip permissions in System Settings without
    /// having to quit and relaunch the app.
    @objc private func handleAppBecameActive() {
        let currentMic = AVCaptureDevice.authorizationStatus(for: .audio)
        let currentSpeech = SFSpeechRecognizer.authorizationStatus()

        let micTransitionedToAuthorized = lastKnownMicStatus != .authorized && currentMic == .authorized
        let speechTransitionedToAuthorized = lastKnownSpeechStatus != .authorized && currentSpeech == .authorized

        lastKnownMicStatus = currentMic
        lastKnownSpeechStatus = currentSpeech
        permissionStatus = currentSpeech

        // Recovery exit for the give-up state: app reactivation with permissions
        // in place re-arms listening after consecutiveStartFailures hit the cap.
        let gaveUpAndCanRecover = consecutiveStartFailures >= maxConsecutiveStartFailures
            && currentMic == .authorized && currentSpeech == .authorized
        if (micTransitionedToAuthorized || speechTransitionedToAuthorized || gaveUpAndCanRecover) && isEnabled && !isListening {
            consecutiveStartFailures = 0
            AppLogger.shared.info("[VoiceWake] \(gaveUpAndCanRecover ? "App reactivated after start-failure backoff" : "Permission granted while backgrounded") — auto-starting listening")
            startListening()
        }

        // Also broadcast so other permission-sensitive subsystems (e.g. screen
        // recording) can react to the same transition without
        // duplicating the didBecomeActive subscription.
        NotificationCenter.default.post(name: .permissionsChanged, object: nil)
    }

    deinit {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
        stopListening()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
    }

    // MARK: - Permission Handling

    /// Refreshes `permissionStatus` with the current `SFSpeechRecognizer` authorization status.
    func checkPermissionStatus() {
        permissionStatus = SFSpeechRecognizer.authorizationStatus()
    }

    /// Requests speech recognition authorization from the user.
    /// - Parameter completion: Called on the main thread with `true` if authorized, `false` otherwise.
    func requestPermission(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                self?.permissionStatus = status
                let authorized = status == .authorized
                completion(authorized)
            }
        }
    }

    // MARK: - Listening Control

    /// Begins continuous wake word listening if enabled and permissions are granted.
    /// Checks microphone and speech recognition authorization before installing an audio tap
    /// and starting an on-device `SFSpeechRecognitionTask`.
    func startListening() {
        guard isEnabled else { return }

        // Guard against concurrent start attempts
        guard !isStartingSession else {
            AppLogger.shared.debug("[VoiceWake] Already starting, skipping")
            return
        }

        // Don't start while GlobalRecorder is recording (it needs exclusive microphone access)
        guard !GlobalRecorder.shared.isRecording else {
            AppLogger.shared.debug("[VoiceWake] Skipping start - GlobalRecorder is recording")
            return
        }

        // Same gate as restartRecognition(): conversation mode holds the mic (VPIO).
        // Starting the wake engine underneath it makes audioEngine.start() fail
        // repeatedly — restart paths already check this, but direct callers
        // (permission grant, enable toggle, app-active recovery) did not.
        // isStartingConversation covers the init window, where conversationState
        // is still .inactive but VPIO setup is in flight.
        guard RealtimeClient.shared.conversationState == .inactive,
              !RealtimeClient.shared.isStartingConversation else {
            AppLogger.shared.debug("[VoiceWake] Skipping start - conversation mode active/starting")
            return
        }

        // Check microphone permission first
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micStatus == .authorized else {
            AppLogger.shared.info("[VoiceWake] Microphone permission not granted (status: \(micStatus.rawValue)), cannot start listening")
            return
        }

        // Only request permission if not yet determined
        // Avoid infinite loop when permission is denied
        guard permissionStatus == .authorized else {
            if permissionStatus == .notDetermined {
                requestPermission { [weak self] granted in
                    if granted {
                        self?.startListening()
                    }
                }
            } else {
                AppLogger.shared.debug("[VoiceWake] Speech permission denied or restricted, not requesting again")
            }
            return
        }

        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            AppLogger.shared.debug("[VoiceWake] Speech recognizer not available")
            return
        }

        // Stop any existing session
        stopListening()

        isStartingSession = true
        do {
            try startRecognitionSession()
            isListening = true
            isStartingSession = false
            wakeWordTriggered = false
            consecutiveStartFailures = 0
            AppLogger.shared.info("[VoiceWake] Started listening for wake word: \(triggerPhrase)")
        } catch {
            isStartingSession = false
            consecutiveStartFailures += 1
            // A single failed start is the recoverable-transient path (mic
            // contention at launch, device switch) — it self-heals via the 0.5s
            // backoff restart, so it's warn, not error. Escalate to error
            // only once the backoff has failed enough times to be a genuinely
            // stuck state, and only on that crossing — one log per episode.
            if consecutiveStartFailures == stuckFailureThreshold {
                AppLogger.shared.error("[VoiceWake] Recognition stuck after \(consecutiveStartFailures) attempts: \(error)", error: error)
                // Field 2026.8 (14 events / 6 installs): the stuck error is
                // kAudioUnitErr_FormatNotSupported (-10868) — the engine caches
                // the input format of the device it was built against, and a
                // device switch leaves every restart re-arming a tap with a
                // stale format. Restarting the same engine can never clear it;
                // replacing the instance does. The pending backoff restart then
                // builds the tap against the current device.
                audioEngine = AVAudioEngine()
                registerConfigChangeObserver()
                AppLogger.shared.info("[VoiceWake] Audio engine recreated after stuck start — next restart uses the current input format")
            } else {
                AppLogger.shared.warn("[VoiceWake] Failed to start recognition (attempt \(consecutiveStartFailures)): \(error)")
            }
            isListening = false
        }
    }

    /// Stops the audio engine, cancels the active recognition task, and tears down the audio tap.
    func stopListening() {
        // Cancel any pending restart work item
        restartWorkItem?.cancel()
        restartWorkItem = nil

        // Cancel any pending recording completion subscription
        recordingCompletionCancellable?.cancel()
        recordingCompletionCancellable = nil

        // Always try to remove tap and stop engine (prevents orphaned taps that cause crashes)
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning {
            audioEngine.stop()
        }

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        recognitionRequest = nil
        recognitionTask = nil
        isListening = false

        AppLogger.shared.info("[VoiceWake] Stopped listening")
    }

    /// Cancels any pending recording completion subscription (called by GlobalRecorder before resuming).
    func cancelRecordingCompletionSubscription() {
        recordingCompletionCancellable?.cancel()
        recordingCompletionCancellable = nil
    }

    // MARK: - Recognition Session
    private func startRecognitionSession() throws {
        // Check microphone permission first
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micStatus == .authorized else {
            AppLogger.shared.info("[VoiceWake] Microphone permission not granted (status: \(micStatus.rawValue)), cannot start recognition")
            throw NSError(domain: "VoiceWake", code: -2, userInfo: [NSLocalizedDescriptionKey: "Microphone permission required"])
        }

        // Cancel any existing task
        recognitionTask?.cancel()
        recognitionTask = nil

        // Configure audio session
        let inputNode = audioEngine.inputNode

        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw NSError(domain: "VoiceWake", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to create recognition request"])
        }

        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = true // Use on-device for privacy and speed

        // Start recognition task
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }

            var isFinal = false

            if let result = result {
                let transcription = result.bestTranscription.formattedString.lowercased()
                isFinal = result.isFinal
                AppLogger.shared.debug("[VoiceWake] Heard utterance (final=\(isFinal), tts=\(self.isTTSPlaying), chars=\(transcription.count))")

                // Check for wake word
                if self.containsWakeWord(transcription) {
                    AppLogger.shared.info("[VoiceWake] Wake word matched")
                    self.handleWakeWordDetected()
                }
            }

            if error != nil || isFinal {
                // Only auto-restart if no other voice flow is holding the mic.
                // Without the conversationState check, VoiceWake's restart races the
                // conversation engine's `installTap` on the same input node, and
                // AVFAudio throws an uncaught Obj-C exception → SIGABRT (seen in
                // crash reports as `installTapOnBus` → `AVAudioIONodeImpl::SetOutputFormat`).
                let isOtherFlowActive = GlobalRecorder.shared.isRecording
                    || RealtimeClient.shared.conversationState != .inactive
                    || RealtimeClient.shared.isStartingConversation
                if self.isEnabled && !isOtherFlowActive && !self.wakeWordTriggered {
                    // Callback is off the main thread — marshal the shared
                    // restartWorkItem mutations onto main, matching the ~167 pattern.
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        self.restartWorkItem?.cancel()
                        let workItem = DispatchWorkItem { [weak self] in
                            self?.restartRecognition()
                        }
                        self.restartWorkItem = workItem
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
                    }
                }

                // Log non-trivial errors for debugging
                if let error = error as NSError?, !(error.domain == "kAFAssistantErrorDomain" && error.code == 1110) {
                    AppLogger.shared.debug("[VoiceWake] Recognition ended: \(error.localizedDescription)")
                }
            }
        }

        // Install tap via the safe installer. It removes any stale tap, re-reads
        // the LIVE input format immediately before install (closing the TOCTOU
        // window where a format read earlier goes stale mid-device-switch),
        // guards it, and wraps installTap in an Obj-C exception barrier — so a
        // format mismatch becomes a thrown error caught here (→ startListening
        // catch → restartRecognition backoff) instead of an uncatchable
        // installTapOnBus NSException → SIGABRT.
        do {
            try AudioTapInstaller.installTap(on: inputNode, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
            }
        } catch {
            self.recognitionRequest = nil
            recognitionTask?.cancel()
            recognitionTask = nil
            AppLogger.shared.warn("[VoiceWake] Tap install failed (\(error.localizedDescription)) — will retry")
            throw error
        }

        // Start audio engine only if not already running
        if !audioEngine.isRunning {
            audioEngine.prepare()
            do {
                try audioEngine.start()
            } catch {
                // Clean up orphaned tap if engine fails to start
                inputNode.removeTap(onBus: 0)
                self.recognitionRequest = nil
                recognitionTask?.cancel()
                recognitionTask = nil
                // warn, not error: the rethrow lands in startListening's catch,
                // which owns the single error-level log for this failure —
                // error here double-counted every failure in logs.
                AppLogger.shared.warn("[VoiceWake] Audio engine failed to start: \(error.localizedDescription)")
                throw error
            }
        }
    }

    private func restartRecognition() {
        guard isEnabled else { return }

        // Give up after the cap — retrying a permanently-broken audio input
        // forever only floods logs. Device change, app reactivation,
        // or the enable toggle resets the counter and re-arms listening.
        guard consecutiveStartFailures < maxConsecutiveStartFailures else {
            AppLogger.shared.warn("[VoiceWake] \(consecutiveStartFailures) consecutive start failures — pausing until device change or app reactivation")
            return
        }

        // Don't restart while another voice flow holds the mic. Same gate as the
        // restart-trigger site above — covers the case where the deferred dispatch
        // fired but conversation mode started in the 500ms window.
        guard !GlobalRecorder.shared.isRecording else {
            AppLogger.shared.debug("[VoiceWake] Skipping restart - GlobalRecorder is recording")
            return
        }
        guard RealtimeClient.shared.conversationState == .inactive,
              !RealtimeClient.shared.isStartingConversation else {
            AppLogger.shared.debug("[VoiceWake] Skipping restart - conversation mode active/starting")
            return
        }

        // Check if we should reset the restart counter (enough time has passed)
        let now = Date()
        if now.timeIntervalSince(lastRestartTime) >= restartBackoffInterval {
            restartAttempts = 0
        }

        // Check if we've exceeded max restart attempts
        guard restartAttempts < maxRestartAttempts else {
            AppLogger.shared.debug("[VoiceWake] Max restart attempts reached (\(maxRestartAttempts)), pausing for backoff period")
            // Wait for backoff period, then reset and try again
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self, self.isEnabled else { return }
                self.restartAttempts = 0
                self.startListening()
            }
            self.restartWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + restartBackoffInterval, execute: workItem)
            return
        }

        restartAttempts += 1
        lastRestartTime = now

        // Inline session teardown without calling stopListening() to avoid toggling isListening
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil

        // Exponential backoff: 0.2s, 0.4s, 0.8s, 1.6s, 3.2s
        let backoffDelay = 0.2 * pow(2.0, Double(restartAttempts - 1))
        let workItem = DispatchWorkItem { [weak self] in
            self?.startListening()
        }
        self.restartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + backoffDelay, execute: workItem)
    }

    // MARK: - Wake Word Detection
    private func containsWakeWord(_ text: String) -> Bool {
        let isInPostTTSCooldown = Date().timeIntervalSince(ttsStoppedTime) < postTTSCooldown
        // While Dottie is speaking (and for a short tail after), ignore the wake word
        // ENTIRELY. The wake recognizer's mic has no echo-cancellation, so TTS that
        // literally says "Dottie" — or any speech the recognizer mishears as the trigger —
        // would self-wake the assistant. Previously this only restricted bare "dottie" and
        // still let the full phrase through, which is exactly what TTS saying the name hits.
        // ESC and conversation-mode barge-in still interrupt TTS, so no interaction is lost.
        if isTTSPlaying || isInPostTTSCooldown {
            AppLogger.shared.debug("[VoiceWake] Ignoring wake during \(isTTSPlaying ? "TTS" : "post-TTS cooldown")")
            return false
        }
        return Self.matchesWakePhrase(in: text, triggerPhrase: triggerPhrase, restrictToFullPhrase: false)
    }

    /// Pure wake-phrase matcher. Extracted from `containsWakeWord` so it can be unit-tested
    /// without driving the SFSpeechRecognizer/audio engine. Lower-cased and trimmed inside.
    /// `restrictToFullPhrase` = caller is in TTS-playing or post-TTS cooldown window — short
    /// variations like bare "dottie" are blocked to prevent the assistant self-triggering on
    /// TTS echo of its own name.
    static func matchesWakePhrase(in text: String, triggerPhrase: String, restrictToFullPhrase: Bool) -> Bool {
        let normalizedTrigger = triggerPhrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = text.lowercased()

        let fullPhraseVariations = [
            normalizedTrigger,
            normalizedTrigger.replacingOccurrences(of: "dottie", with: "dotty"),
            normalizedTrigger.replacingOccurrences(of: "dottie", with: "dodi"),
            normalizedTrigger.replacingOccurrences(of: "dottie", with: "daddy"),
        ]
        // Short variations only apply to the default Dottie phrase. Custom triggers
        // ("computer") shouldn't be polluted by hardcoded "dottie" matches.
        let shortVariations = normalizedTrigger.contains("dottie") ? ["dottie"] : []

        if restrictToFullPhrase {
            return fullPhraseVariations.contains { normalizedText.contains($0) }
        }
        let allVariations = fullPhraseVariations + shortVariations
        return allVariations.contains { normalizedText.contains($0) }
    }

    private func handleWakeWordDetected() {
        // The SFSpeechRecognizer recognitionTask callback fires off the main thread.
        // Marshal all the state-teardown writes (isListening, recognitionTask,
        // recognitionRequest, restartWorkItem, wakeWordTriggered — all reached via
        // stopListening() below) onto main, matching requestPermission()'s pattern.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handleWakeWordDetected()
            }
            return
        }

        // Check cooldown to prevent rapid triggers
        let now = Date()
        guard now.timeIntervalSince(lastDetectionTime) >= cooldownInterval else {
            AppLogger.shared.debug("[VoiceWake] Ignoring wake word - cooldown active")
            return
        }

        lastDetectionTime = now
        restartAttempts = 0  // Reset counter - successful detection proves system works
        AppLogger.shared.debug("[VoiceWake] Wake word detected!")

        // Stop any TTS playback so user can speak
        RealtimeClient.shared.stopTTS()

        // Mark as intentional stop to prevent auto-restart from completion handler
        wakeWordTriggered = true

        // Temporarily pause listening while handling wake word
        stopListening()

        // Notify delegate on main thread after a brief delay to let speech recognizer release
        // This prevents resource conflicts when GlobalRecorder starts its own recognizer.
        // 150ms, down from a hand-picked 300ms (2026-07-19 speed pass): stopListening()
        // above already tears down the tap/recognizer synchronously; the remaining wait
        // only covers CoreAudio's async HAL release. Every "Hey Dottie" pays this in full,
        // so keep it as tight as the SIGABRT history (tap-contention) allows.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.onWakeWordDetected?()

            // Resume listening when the active voice flow ends. Watch GlobalRecorder
            // (cursor-mode dictation) and RealtimeClient's conversationState (full-duplex
            // conversation). Resume only when both are idle so VoiceWake doesn't grab
            // the mic mid-conversation.
            self.recordingCompletionCancellable = Publishers.CombineLatest(
                GlobalRecorder.shared.$isRecording,
                RealtimeClient.shared.$conversationState
            )
                .dropFirst() // Skip initial values
                .sink { [weak self] isRecording, conversationState in
                    guard let self = self else { return }
                    let isActive = isRecording || conversationState != .inactive
                    if !isActive {
                        self.recordingCompletionCancellable?.cancel()
                        self.recordingCompletionCancellable = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            if self.isEnabled {
                                self.startListening()
                            }
                        }
                    }
                }

            // Fallback: if no voice flow starts within 2 seconds, resume listening
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self = self else { return }
                let isActive = GlobalRecorder.shared.isRecording
                    || RealtimeClient.shared.conversationState != .inactive
                    || RealtimeClient.shared.isStartingConversation
                if self.recordingCompletionCancellable != nil && !isActive {
                    AppLogger.shared.debug("[VoiceWake] Fallback: voice flow didn't start, resuming listening")
                    self.recordingCompletionCancellable?.cancel()
                    self.recordingCompletionCancellable = nil
                    if self.isEnabled {
                        self.startListening()
                    }
                }
            }
        }
    }
}
