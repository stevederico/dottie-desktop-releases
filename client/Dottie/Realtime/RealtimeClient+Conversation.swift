import Foundation
import AVFoundation
import AppKit
import CoreAudio

extension RealtimeClient {
    // MARK: - Conversation Mode (Full-Duplex)

    /// Toggles full-duplex conversation mode. No-op while a start is already in flight.
    func toggleConversation() {
        dispatchPrecondition(condition: .onQueue(.main))
        if isStartingConversation { return }
        if conversationState != .inactive {
            stopConversation()
        } else {
            startConversation()
        }
    }

    /// Orb click during a live call: "I'm done talking" — does not end the session.
    /// Inactive orb still starts a call. Menu bar / ESC still stop the session.
    func handleOrbClick() {
        dispatchPrecondition(condition: .onQueue(.main))
        if isStartingConversation { return }
        switch conversationState {
        case .inactive:
            startConversation()
        case .processing:
            break
        case .assistantSpeaking:
            AppLogger.shared.info("[Realtime] Orb click — interrupt Grok, session stays")
            stopTTS()
        case .userSpeaking, .idle:
            AppLogger.shared.info("[Realtime] Orb click — done talking")
            sendJSON(["type": "input_audio_buffer.commit"])
        }
    }

    /// Starts full-duplex conversation mode with a unified AVAudioEngine.
    /// Mic streams continuously, server handles VAD and barge-in.
    func startConversation() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard conversationState == .inactive else {
            AppLogger.shared.debug("[Realtime] Already in conversation mode")
            return
        }

        // Microphone permission pre-flight. Without this, a denied/undetermined mic
        // sends us straight into setupConversationEngine, where the input node reports
        // 0 channels and engine.start() fails BOTH with and without AEC — the user
        // gets a Ping, an empty panel, then dead silence with no explanation. This was
        // the single largest production failure class, all from one undiagnosable
        // failure mode. Gate it here, before any UI or WS work.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            // First-run: ask, then re-enter on grant. No Ping/panel yet — the system
            // prompt is the feedback. On denial, surface the banner.
            RecordingPermissionManager.requestMicrophonePermission { [weak self] granted in
                if granted {
                    self?.startConversation()
                } else {
                    self?.surfaceMicDeniedBanner()
                }
            }
            return
        case .denied, .restricted:
            surfaceMicDeniedBanner()
            return
        @unknown default:
            break
        }

        // After mic is authorized (never during .notDetermined): close VoiceWake's
        // init-window hole for the whole connect/STT/engine path. Re-entry from
        // waitForConnection / waitForSTTReady keeps this true.
        isStartingConversation = true
        VoiceWakeManager.shared.stopListening()

        if !isConnected {
            connect()
            waitForConnection { [weak self] connected in
                guard let self else { return }
                guard connected else {
                    // Abort: clear the VoiceWake gate in case this is the HAL-recovery
                    // re-entry (flag already true) — otherwise VoiceWake stays blocked.
                    if self.isStartingConversation {
                        self.isStartingConversation = false
                        VoiceWakeManager.shared.startListening()
                    }
                    return
                }
                self.startConversation()
            }
            return
        }

        // Gate voice until the STT service is ready. On first launch parakeet can
        // still be starting when the user clicks mic — without this gate the server
        // emits stt_error for every utterance until connectSTT() succeeds.
        // Grok Voice Agent uses xAI cloud STT inside the realtime socket — skip
        // the local parakeet gate when that mode is on (and provider is xAI).
        // Parakeet still boots server-side regardless, and the gateway falls back
        // to it when the Grok Voice mint fails (60s cooldown window), so the only
        // degraded overlap is parakeet's own first-boot seconds — not worth
        // gating the cloud happy path on.
        let xaiVoiceAgent = ChatProvider.current.usesGrokVoiceAgent
        if !xaiVoiceAgent && !GatewayClient.shared.isSTTReady {
            GatewayClient.shared.waitForSTTReady { [weak self] ready in
                guard let self else { return }
                if ready {
                    self.startConversation()
                } else {
                    AppLogger.shared.warn("[Realtime] Conversation aborted — STT not ready")
                    if self.isStartingConversation {  // clear VoiceWake gate on abort (HAL-recovery re-entry)
                        self.isStartingConversation = false
                        VoiceWakeManager.shared.startListening()
                    }
                    GatewayClient.shared.surfaceSTTUnavailableBanner(
                        message: "Voice input is not ready yet — dictation service still starting."
                    )
                }
            }
            return
        }

        sendJSON(["type": "conversation.start"])

        // Immediate user feedback BEFORE the engine setup (which can take 600ms+).
        // Without this the user clicked → ~1.8s of silence → Ping. Now: click → Ping
        // within ~50ms, panel shows, then engine work happens behind the scenes.
        AvatarPanelManager.shared.show()
        NSSound(named: "Ping")?.play()

        // Track conversation for message persistence
        if conversationId == nil {
            conversationId = MessageStore.shared.currentConversationId
        }

        currentTranscript = ""
        currentResponse = ""

        // setVoiceProcessingEnabled (AEC) can fail with kAudioUnitErr_FailedInitialization
        // (-10875) when the voice-processed I/O audio unit conflicts with a recently-active
        // playback unit, or when the system audio output is incompatible with VPIO's
        // internal aggregate-device requirements (e.g. Studio Display 8-channel output).
        // Once we know AEC fails on the current default output device, skip the failing
        // attempt entirely — saves ~3000ms (AEC-fail + retry-AEC + retry-no-AEC) on every
        // first click of the session. Memoization persists across launches keyed to the
        // device UID, so plugging in headphones invalidates it and we re-attempt AEC.
        let shouldTryAEC = !aecKnownFailedThisSession
        if !setupConversationEngine(useAEC: shouldTryAEC) {
            if shouldTryAEC {
                aecKnownFailedThisSession = true
                if let uid = Self.defaultOutputDeviceUID() {
                    UserDefaults.standard.set(uid, forKey: Self.aecFailedDeviceUIDKey)
                    AppLogger.shared.warn("[Realtime] AEC engine init failed on \(uid) — persisted; falling back to no-AEC")
                } else {
                    AppLogger.shared.warn("[Realtime] AEC engine init failed — falling back to no-AEC")
                }
            } else {
                AppLogger.shared.warn("[Realtime] Conversation engine init failed — retrying without AEC")
            }
            // No 250ms wait when we're already going AEC-less: the VPIO contention that
            // motivated the wait only applies when we're about to ask for VPIO again.
            // No re-attempt of AEC: if it just failed (or has been memoized as failing)
            // a second AEC attempt is virtually guaranteed to fail and burn ~800ms.
            guard setupConversationEngine(useAEC: false) else {
                let diag = conversationFailureDiagnostics()
                // 0-channel HAL-wedge recovery: a FRESH probe engine reporting 0
                // channels on BOTH nodes means the process-wide CoreAudio HAL client
                // is degenerate (a missing mic would still leave output at 2ch) —
                // usually wedged by a long-lived engine's faulted I/O unit
                // (VoiceWake/GlobalRecorder engines stay allocated after stop).
                // Release every engine in the process, give coreaudiod a beat to
                // re-provision, and re-enter ONCE. Production showed users retrying
                // 4-6 times over 3 minutes against the same wedge with zero recovery.
                if diag["inputChannels"] == "0", diag["outputChannels"] == "0", !halRecoveryAttempted {
                    halRecoveryAttempted = true
                    AppLogger.shared.warn("[Realtime] 0-channel audio on fresh probe (HAL wedge) — releasing all audio engines and retrying once")
                    teardownConversationEngine()
                    VoiceWakeManager.shared.releaseAudioEngineForRecovery()
                    GlobalRecorder.shared.releaseAudioEngineForRecovery()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        self?.startConversation()
                    }
                    return
                }
                // No-input-device classification: mic permission granted but the input
                // node reports 0 channels while output is healthy — there is simply no
                // microphone (Mac mini/Studio with no headset, or the input device
                // vanished). Not an engine fault: retrying can't help, so skip the
                // transient retry below and tell the user exactly what to do (separate
                // from real engine init failures).
                //
                // The 0-channel read MUST be corroborated against the system device
                // list: a Bluetooth headset mid profile-switch (A2DP→HFP) makes the
                // default input flap 2ch→0ch for a few hundred ms, and a machine with
                // a Studio Display mic + Bose QC35 got the "no microphone" banner from
                // exactly that race (field 2026.8.9). Devices present ⇒ transient ⇒
                // fall through to the 600ms retry below instead of aborting.
                if diag["micAuth"] == "authorized", diag["inputChannels"] == "0", diag["outputChannels"] != "0",
                   !Self.systemHasInputDevices() {
                    AppLogger.shared.warn("[Realtime] No microphone detected (\(diag)) — aborting conversation start")
                    // A Mac with no input device is a hardware state the banner
                    // explains, not a defect — warn, not error.
                    sendJSON(["type": "conversation.stop"])
                    isStartingConversation = false
                    VoiceWakeManager.shared.startListening()
                    surfaceNoMicrophoneBanner()
                    AvatarPanelManager.shared.hide()
                    return
                }
                // Transient-contention retry: engine start can fail on BOTH paths when
                // another process (or our own just-torn-down playback unit) still holds
                // the I/O unit — a state that clears within a few hundred ms. Prod
                // showed users hammering the mic button against exactly this. Retry the
                // whole flow once after 600ms before declaring failure; the flag makes
                // it one auto-retry per user attempt, never a loop.
                if !engineStartRetryAttempted {
                    engineStartRetryAttempted = true
                    AppLogger.shared.warn("[Realtime] Engine init failed on both paths (\(diag)) — retrying once in 600ms")
                    teardownConversationEngine()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        self?.startConversation()
                    }
                    return
                }
                engineStartRetryAttempted = false // next manual attempt earns a fresh retry
                // warn, not error — avoids duplicate error-level logs for one failure.
                AppLogger.shared.warn("[Realtime] Conversation engine init failed both with and without AEC — aborting (\(diag))")
                // Diagnostics make this event actionable instead of a bare count: mic
                // auth, input channel/sample-rate (0ch = no mic), output device + channel
                // count (>2 = VPIO-incompatible like Studio Display). Previously fired
                // blind, so we couldn't tell mic-denied from device-incompat from a throw.
                // Voice is dead for this user and the diag fields alone rarely say
                // why — pull the log tails once per launch so it's triageable
                // without asking them to reproduce.
                // No longer a silent return: tell the user voice failed and why, and
                // tear down the panel/Ping state so it doesn't sit on "Listening…".
                sendJSON(["type": "conversation.stop"])
                isStartingConversation = false
                // Re-arm VoiceWake explicitly: its auto-restart fired during setup and
                // was (correctly) blocked by the isStartingConversation gate, so nothing
                // else brings the wake word back after an aborted start. startListening()
                // no-ops when VoiceWake is disabled.
                VoiceWakeManager.shared.startListening()
                surfaceVoiceEngineFailedBanner()
                AvatarPanelManager.shared.hide()
                return
            }
            finishStartConversation()
            return
        }

        // AEC succeeded — clear any stale memoization for the current device (e.g. user
        // unplugged Studio Display, plugged headphones, AEC works again on this device).
        if aecKnownFailedThisSession {
            aecKnownFailedThisSession = false
            UserDefaults.standard.removeObject(forKey: Self.aecFailedDeviceUIDKey)
            AppLogger.shared.info("[Realtime] AEC succeeded — memoization cleared")
        }
        finishStartConversation()
    }

    /// Surfaces a persistent, actionable banner when conversation mode is blocked by
    /// missing mic permission, with a button that jumps to System Settings → Privacy &
    /// Security → Microphone. Mirrors the screen-recording-denied flow in the launcher.
    /// Safe to call before the avatar panel is shown (hide() is a no-op then).
    private func surfaceMicDeniedBanner() {
        AppLogger.shared.warn("[Realtime] Conversation aborted — microphone permission denied/restricted")
        if !micDeniedReported {
            micDeniedReported = true
        }
        AvatarPanelManager.shared.hide()
        NotificationCenter.default.post(
            name: .showErrorBanner,
            object: ChatBannerError(
                code: "mic_permission_denied",
                message: "Microphone access is required for voice. Enable it in System Settings.",
                actionLabel: "Open System Settings",
                action: .openSystemSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            )
        )
    }

    /// Surfaces a banner when mic permission is granted but no input device exists —
    /// Mac mini/Studio setups with no headset or external mic. Actionable and honest:
    /// the fix is hardware, not retrying.
    private func surfaceNoMicrophoneBanner() {
        NotificationCenter.default.post(
            name: .showErrorBanner,
            object: ChatBannerError(
                code: "no_input_device",
                message: "No microphone detected. Connect a microphone or headset to use voice.",
                actionLabel: nil,
                action: nil
            )
        )
    }

    /// Surfaces a banner when the audio engine fails to initialize even though mic
    /// permission is granted — the residual failure mode after the permission gate
    /// (another app holding the mic, an incompatible output device, a CoreAudio fault).
    private func surfaceVoiceEngineFailedBanner() {
        NotificationCenter.default.post(
            name: .showErrorBanner,
            object: ChatBannerError(
                code: "voice_engine_failed",
                message: "Voice couldn't start — the audio engine failed to initialize. Make sure no other app is using the microphone, then try again.",
                actionLabel: nil,
                action: nil
            )
        )
    }

    /// Whether ANY audio input device is attached, per the system device list —
    /// independent of the (possibly wedged or mid-transition) engine's input node.
    /// Discriminates "no mic hardware" from "the default input flapped to 0ch for
    /// a moment" (Bluetooth A2DP→HFP switches, aggregate-device reconfigs).
    static func systemHasInputDevices() -> Bool {
        !AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.isEmpty
    }

    /// Cheap, allocation-only probe (never calls start()) of the audio environment at
    /// the moment conversation init failed, for triage logs. inputChannels == 0 means no usable mic;
    /// outputChannels > 2 means a VPIO-incompatible device (e.g. Studio Display).
    private func conversationFailureDiagnostics() -> [String: String] {
        var diag: [String: String] = [:]
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    diag["micAuth"] = "authorized"
        case .denied:        diag["micAuth"] = "denied"
        case .restricted:    diag["micAuth"] = "restricted"
        case .notDetermined: diag["micAuth"] = "notDetermined"
        @unknown default:    diag["micAuth"] = "unknown"
        }
        let probe = AVAudioEngine()
        let inFmt = probe.inputNode.inputFormat(forBus: 0)
        diag["inputChannels"] = String(inFmt.channelCount)
        diag["inputSampleRate"] = String(Int(inFmt.sampleRate))
        let outFmt = probe.outputNode.outputFormat(forBus: 0)
        diag["outputChannels"] = String(outFmt.channelCount)
        if let uid = Self.defaultOutputDeviceUID() { diag["outputDeviceUID"] = uid }
        return diag
    }

    /// Reads the system default output device UID via CoreAudio. Used to key the AEC
    /// failure memoization so plugging headphones in/out invalidates the memo without
    /// affecting the memo for the prior device.
    static func defaultOutputDeviceUID() -> String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != 0 else { return nil }

        var uid: CFString?
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &uidSize, ptr)
        }
        guard status == noErr else { return nil }
        return uid as String?
    }

    private func finishStartConversation() {
        conversationState = .idle
        isStartingConversation = false // conversationState now gates VoiceWake
        halRecoveryAttempted = false   // engine came up → a future wedge gets a fresh recovery attempt
        engineStartRetryAttempted = false // ditto for the transient-contention retry
        abandonedTTSStream = false     // fresh engine → playback is viable again
        AppLogger.shared.info("[Realtime] Conversation mode started")
    }

    /// In turn-based mode, end the conversation so the user must re-trigger for the next turn.
    /// No-op in continuous mode (server-side VAD handles next-turn capture).
    func endConversationIfTurnBased() {
        guard UserDefaults.standard.bool(forKey: "conversationTurnBased"),
              conversationState != .inactive else { return }
        AppLogger.shared.info("[Realtime] Turn-based: TTS done, ending conversation")
        stopConversation()
    }

    /// Stops full-duplex conversation mode.
    func stopConversation() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard conversationState != .inactive else { return }

        AppLogger.shared.info("[Realtime] Stopping conversation mode")

        // Tear down unified engine
        teardownConversationEngine()

        // Stop any playing TTS
        let playerNode = conversationPlayerNode ?? audioPlayerNode
        playerNode?.stop()
        stopTTSPlayback()
        stopThinkingCue()

        // Tell server to exit conversation mode
        sendJSON(["type": "conversation.stop"])

        conversationState = .inactive
        isStartingConversation = false
        currentTranscript = ""
        currentResponse = ""

        // Hide indicators (AgentStateCoordinator also fires .hide on state→.idle;
        // explicit call here is defensive in case the recompute is debounced).
        FullScreenSpectrumOverlayManager.shared.hide()
        // The avatar panel doubles as the conversation UI, so startConversation()
        // shows it unconditionally. Only the persistent floating-avatar setting
        // keeps it up after the conversation ends; without this check the panel
        // lingered on screen forever once voice was used, even with the setting off.
        if !UserDefaults.standard.bool(forKey: "floatingAvatarEnabled") {
            AvatarPanelManager.shared.hide()
        }
        NSSound(named: "Pop")?.play()

        // Resume VoiceWake if enabled
        if UserDefaults.standard.bool(forKey: "voiceWakeEnabled") {
            VoiceWakeManager.shared.startListening()
        }
    }

    /// Heard-you tick, then a quiet loop until Grok starts speaking.
    func playThinkingCue() {
        dispatchPrecondition(condition: .onQueue(.main))
        stopThinkingCue()
        NSSound(named: "Tink")?.play()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return }
        guard let purr = NSSound(named: "Purr") else { return }
        purr.loops = true
        purr.volume = 0.3
        purr.play()
        thinkingSound = purr
    }

    func stopThinkingCue() {
        thinkingSound?.stop()
        thinkingSound = nil
    }

    /// Sets up a single AVAudioEngine with voice processing for both capture and playback.
    /// AEC works because input and output share the same engine — the output node
    /// provides the echo reference signal to the input node's voice processing.
    private func setupConversationEngine(useAEC: Bool = true) -> Bool {
        teardownConversationEngine()

        // The standalone playback engine (used for Read Aloud / voice preview / greeting TTS)
        // can still hold the audio unit when conversation mode starts immediately after a
        // TTS playback. CoreAudio HAL contention then surfaces as kAudioUnitErr_FailedInitialization
        // (-10875) when the conversation engine tries to initialize its input unit. Tear down
        // the playback engine first so the new unified engine has clean access to the mic.
        if let observer = playbackEngineObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackEngineObserver = nil
        }
        playbackEngine?.stop()
        playbackEngine = nil
        audioPlayerNode = nil

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwOutputFormat = engine.outputNode.outputFormat(forBus: 0)

        // Proactive Studio Display detection: AUVoiceProcessor's internal aggregate
        // device requires ≤2 output channels to construct. Studio Display reports 8
        // (6 woofers + 2 tweeters). Trying VPIO anyway throws
        // kAudioUnitErr_FailedInitialization (-10875) at engine.start() and fires
        // error-level log every conversation start (field 5.11, Studio Display user). Catching it here is
        // cheaper, doesn't surface as an "error" in logs, and runs the well-tested
        // no-AEC path directly. False positives (pro-audio interfaces with >2
        // channels where VPIO would have worked) just get the same soft-AEC
        // fallback users without AEC already use — same code path, no regression.
        let shouldUseAEC = useAEC && hwOutputFormat.channelCount <= 2
        if useAEC && !shouldUseAEC {
            AppLogger.shared.info("[Realtime] Output device reports \(hwOutputFormat.channelCount)ch — skipping AEC (VPIO requires ≤2)")
        }

        // Enable voice processing (AEC + noise suppression) on the input node when requested.
        // setVoiceProcessingEnabled allocates a voice-processed I/O audio unit which is a
        // shared system resource and can collide with a recently-active playback unit, surfacing
        // as kAudioUnitErr_FailedInitialization (-10875) at engine.start(). The retry path in
        // startConversation falls back to useAEC=false on second attempt to keep voice working
        // even when the system is contended; the cost is no client-side echo cancellation, so
        // the mic may pick up TTS playback (server-side VAD still gates barge-in).
        var aecActive = false
        if shouldUseAEC {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                aecActive = true
                AppLogger.shared.info("[Realtime] Voice processing (AEC) enabled on unified engine")
            } catch {
                AppLogger.shared.warn("[Realtime] Voice processing unavailable: \(error)")
            }
        } else {
            AppLogger.shared.info("[Realtime] Skipping AEC — using plain mic input (mic muted during TTS)")
        }
        conversationUsesAEC = aecActive

        let inputFormat = inputNode.outputFormat(forBus: 0)
        AppLogger.shared.info("[Realtime] VPIO formats input=\(inputFormat) output=\(hwOutputFormat)")

        // Target format: 16kHz mono int16 for STT
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                sampleRate: 16000,
                                                channels: 1,
                                                interleaved: true) else {
            AppLogger.shared.error("[Realtime] Failed to create target audio format")
            return false
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            AppLogger.shared.error("[Realtime] Failed to create audio converter")
            return false
        }
        // VPIO presents an I/O unit bus layout that bundles echo-reference channels
        // alongside the mic (10ch w/ AEC, 7ch w/o on this hardware). Aggregate devices
        // and Apple Studio Display setups expose similar multi-channel inputs. The
        // converter's default mixdown averages all N channels, attenuating the mic
        // signal Nx and dropping it below VAD threshold — server sees silence and never
        // detects end-of-speech. Pin the converted mono output to input channel 0
        // (always the primary mic on macOS audio units) so amplitude is preserved.
        if inputFormat.channelCount > 1 {
            converter.channelMap = [0]
            AppLogger.shared.info("[Realtime] Multi-channel input (\(inputFormat.channelCount)ch) — pinning converter to channel 0")
        }
        conversationConverter = converter

        // Attach player node for TTS output
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)

        // TTS format: 24kHz float32 mono
        guard let ttsFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 24000,
                                            channels: 1,
                                            interleaved: true) else {
            AppLogger.shared.error("[Realtime] Failed to create TTS audio format")
            return false
        }
        // When VPIO is enabled, the output node is locked to the hardware's voice-processed
        // format (typically 48kHz mono Float32). Forcing the mixer's output bus to 24kHz
        // creates a resample chain that fails kAUInitialize on the output unit (-10875).
        // Connect at hwOutputFormat and let AVAudioPlayerNode internally resample its
        // 24kHz scheduled buffers up to the VPIO format.
        let connectFormat: AVAudioFormat = aecActive ? hwOutputFormat : ttsFormat
        engine.connect(playerNode, to: engine.mainMixerNode, format: connectFormat)

        // A tap left behind by another flow (VoiceWake's SFSpeechRecognizer tap, or a
        // prior conversation teardown that failed) makes installTap throw an UNCAUGHT
        // Obj-C exception → SIGABRT (crash reports: installTapOnBus →
        // AVAudioIONodeImpl::SetOutputFormat). Swift can't catch it, so prevent it:
        // remove any existing tap, and bail if the input node has no valid format
        // (0 channels / 0 Hz — revoked mic permission or no input device).
        inputNode.removeTap(onBus: 0)
        guard inputFormat.channelCount > 0 && inputFormat.sampleRate > 0 else {
            AppLogger.shared.error("[Realtime] Invalid input format (\(inputFormat)) — aborting conversation start")
            return false
        }

        // Install mic tap — streams continuously to server. Wrapped in the safe
        // installer's Obj-C exception barrier so a format mismatch during a CoreAudio
        // device switch becomes a thrown error (→ return false, handled by the caller's
        // AEC retry) instead of an uncatchable installTapOnBus NSException → SIGABRT.
        //
        // format: nil — the tap adopts the node's LIVE format at install time instead
        // of the `inputFormat` snapshot read above. Between that read and this install,
        // engine.connect() / VPIO setup can reconfigure the I/O unit; installing with
        // the stale snapshot then throws the format-mismatch NSException on BOTH the
        // AEC and no-AEC attempts. The tap block is format-agnostic: it reads each
        // buffer's actual format and rebuilds the converter on change.
        var tapConverter = converter
        do {
        try AudioTapInstaller.installTap(on: inputNode, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self = self, self.conversationState != .inactive else { return }

            // Feed spectrum analyzer for visualization
            GlobalRecorder.shared.spectrumAnalyzer.processBuffer(buffer)

            // The device format can differ from the pre-install snapshot (see the
            // format: nil rationale above) or change mid-conversation on a route
            // switch. Rebuild the converter from the buffer's real format so audio
            // keeps flowing instead of converting garbage. tapConverter is closure
            // state touched only on the tap's audio thread — no race with main.
            let liveFormat = buffer.format
            if tapConverter.inputFormat != liveFormat {
                guard let fresh = AVAudioConverter(from: liveFormat, to: targetFormat) else { return }
                if liveFormat.channelCount > 1 { fresh.channelMap = [0] }
                AppLogger.shared.warn("[Realtime] Mic format changed \(tapConverter.inputFormat) → \(liveFormat) — rebuilt converter")
                tapConverter = fresh
            }

            // Convert to 16kHz int16
            let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / liveFormat.sampleRate) + 16
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }

            var consumed = false
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }
            tapConverter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

            if let error = error {
                AppLogger.shared.error("[Realtime] Conversion error: \(error)")
                return
            }

            if let channelData = convertedBuffer.int16ChannelData {
                let n = Int(convertedBuffer.frameLength)
                let data = Data(bytes: channelData[0], count: n * 2)
                // No AEC: speaker bleed is in the mic. Drop quiet frames while
                // Grok is playing so echo does not retrigger VAD; loud speech
                // still ships so barge-in works.
                if !self.conversationUsesAEC && self.isPlayingTTS
                    && ChatProvider.current.usesGrokVoiceAgent {
                    var sum: Double = 0
                    let samples = channelData[0]
                    for i in 0..<n { let s = Double(samples[i]); sum += s * s }
                    let rms = sqrt(sum / Double(max(n, 1)))
                    if rms < 2500 { return }
                }
                self.sendAudio(data)
            }
        }
        } catch {
            AppLogger.shared.error("[Realtime] Mic tap install failed (\(error.localizedDescription)) — aborting conversation start", error: error)
            return false
        }

        // Auto-restart engine on audio configuration changes (e.g., headphones plug
        // in / unplug, default-output device switch). queue:nil runs the block on
        // whatever thread posts the notification — must NOT be .main, because
        // AVAudioEngineImpl::IOUnitConfigurationChanged() posts the notification
        // synchronously and waits for all observers to complete; if main is
        // simultaneously deallocating an engine (which dispatch_syncs to the engine's
        // internal queue), main waits for engine queue → engine queue waits for
        // notification observers → main queue observer waits for main → deadlock.
        // Sample of the live freeze showed exactly this cycle.
        if let oldObserver = conversationConfigChangeObserver {
            NotificationCenter.default.removeObserver(oldObserver)
            conversationConfigChangeObserver = nil
        }
        conversationConfigChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: nil
        ) { [weak self] _ in
            guard let self = self, let eng = self.conversationEngine, !eng.isRunning else { return }
            AppLogger.shared.warn("[Realtime] Conversation engine config changed — restarting")
            try? eng.start()
        }

        do {
            try engine.start()
            conversationEngine = engine
            conversationPlayerNode = playerNode
            audioFormat = ttsFormat
            AppLogger.shared.info("[Realtime] Unified conversation engine started")
            return true
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            // Demoted from .error to .warn: this catch is hit by the well-defined
            // fallback path in startConversation (retry without AEC). Firing
            // warn for the first half of a documented retry — the terminal
            // double-failure case in startConversation (above) still uses .error.
            AppLogger.shared.warn("[Realtime] Conversation engine start failed (will retry without AEC if applicable): \(error)")
            return false
        }
    }

    /// Tears down the unified conversation engine.
    private func teardownConversationEngine() {
        // Remove the block-observer using its token. The previous removeObserver(self,...)
        // call was a no-op (block observers register an internal proxy, not self) so
        // observers leaked across every conversation start.
        if let observer = conversationConfigChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            conversationConfigChangeObserver = nil
        }
        if let engine = conversationEngine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning {
                engine.stop()
            }
        }
        conversationEngine = nil
        conversationPlayerNode = nil
        conversationConverter = nil
    }
}
