//
//  RealtimeClient+TTSPlayback.swift
//  Dottie
//
//  Speak/stop TTS requests + PCM playback / drain / stopTTSPlayback.
//

import Foundation
import AppKit
import AVFoundation

extension RealtimeClient {

    // MARK: - Standalone TTS (Read Aloud / Voice Preview)

    /// Speaks text through the realtime WebSocket TTS pipeline.
    /// Sends raw text to gateway which sanitizes before forwarding to Kokoros.
    /// - Parameters:
    ///   - text: Raw text to speak (gateway sanitizes server-side).
    ///   - voice: Optional voice override.
    ///   - messageId: Optional message ID for UI state tracking (Read Aloud).
    ///   - isAutoSpeak: Unused (truncation handled server-side).
    ///   - onComplete: Called when playback finishes.
    func speakText(
        _ text: String,
        voice: String? = nil,
        messageId: UUID? = nil,
        isAutoSpeak: Bool = false,
        onComplete: ((Bool) -> Void)? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onComplete?(false)
            return
        }
        // A second speakText() before the first finished used to silently drop the
        // pending handler, leaving its caller (Read Aloud button, onboarding gate)
        // waiting forever. Drain it as a failure first — before claiming the
        // highlight below, so its deferred cleanup can't clear the new owner's id.
        if let pending = self.ttsCompletionHandler {
            self.ttsCompletionHandler = nil
            pending(false)
        }

        if let messageId = messageId {
            self.speakingMessageId = messageId
        }

        self.ttsCompletionHandler = { [weak self] success in
            DispatchQueue.main.async {
                // Only release the highlight if this call still owns it.
                if let self, self.speakingMessageId == messageId {
                    self.speakingMessageId = nil
                }
            }
            onComplete?(success)
        }

        // Update voice config if overridden. The `voice` field on session.update
        // only sets the LOCAL Kokoro voice — in xAI mode the server picks the TTS
        // voice from config.xaiVoice and ignores config.voice entirely. Some
        // callers pass a Kokoro id (e.g. onboarding sends "am_michael"), so in
        // xAI mode forwarding it as `voice` would be silently dropped. Make the
        // override provider-aware: route it to `xaiVoice` for xAI (the server
        // validates against its known voice set and falls back to the default on
        // an unrecognized id, instead of dropping the override), and keep using
        // `voice` for the local path. Other cloud providers don't expose a
        // per-call TTS voice override here, so omit it and let their picker apply.
        if let voice = voice {
            switch ChatProvider.current {
            case .xai, .dottiePro:
                // Full-Grok: Dottie Pro voices ride xAI TTS through the relay,
                // so the override routes to xaiVoice exactly like BYOK xai.
                // (The server falls back to local Kokoro if the relay fails.)
                self.sendJSON(["type": "session.update", "xaiVoice": voice])
            case .openai, .anthropic, .ollama, .dottieLocal, .cerebras:
                self.sendJSON(["type": "session.update", "voice": voice])
            }
        }

        if !self.isConnected {
            self.connect()
            self.waitForConnection { [weak self] connected in
                guard let self, connected else {
                    onComplete?(false)
                    return
                }
                self.sendTTSRequest(trimmed)
            }
            return
        }

        self.sendTTSRequest(trimmed)
    }

    /// Sends tts.request, sets generating state, and starts a 30s timeout.
    private func sendTTSRequest(_ text: String) {
        isGeneratingTTS = true
        // New stream — re-arm playback after a prior one was abandoned on a
        // torn-down engine.
        abandonedTTSStream = false

        // Timeout: if no audio arrives in 30s, fail with feedback
        ttsGenerationTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, self.isGeneratingTTS else { return }
            AppLogger.shared.error("[Realtime] TTS generation timed out (30s)")
            self.isGeneratingTTS = false
            self.stopTTSPlayback()
            NSSound(named: "Basso")?.play() // Error sound
            // Fire the completion so callers can move on. Onboarding gates its
            // voice-choice buttons (and thus Get Started) on this closure — before
            // this, a silent timeout stranded the user on the progress screen
            // forever with no way forward but relaunching.
            let handler = self.ttsCompletionHandler
            self.ttsCompletionHandler = nil
            handler?(false)
        }
        ttsGenerationTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)

        sendJSON(["type": "tts.request", "text": text, "id": UUID().uuidString])
    }

    /// Stops any in-progress TTS playback (standalone or conversational).
    func stopTTS() {
        isGeneratingTTS = false
        ttsGenerationTimeout?.cancel()
        ttsGenerationTimeout = nil
        // Stop whichever player node is active
        conversationPlayerNode?.stop()
        audioPlayerNode?.stop()
        stopTTSPlayback()

        // stopTTSPlayback() returns early at `guard isPlayingTTS`, so a stop during
        // GENERATION (before the first audio.delta) never reached the lines that
        // clear the highlight and fire the handler — the Read Aloud button stayed
        // disabled forever and ESC during onboarding blocked Get Started. Nil the
        // handler before invoking it, so this is a no-op when stopTTSPlayback ran.
        if let handler = ttsCompletionHandler {
            ttsCompletionHandler = nil
            speakingMessageId = nil
            handler(false)
        }

        // Notify server to cancel pending TTS
        if isConnected {
            sendJSON(["type": "input.interrupt"])
        }
    }

    /// Cancels a pending one-shot dictation arm WITHOUT ending the conversation.
    /// Sends `input.interrupt` (which clears the server-side dictationArmed flag)
    /// and clears the local "Dictating…" hint so the user resumes normal voice.
    func cancelDictation() {
        AppLogger.shared.info("[Realtime] Cancelling pending dictation")
        if isConnected {
            sendJSON(["type": "input.interrupt"])
        }
        DispatchQueue.main.async {
            AgentStateCoordinator.shared.dictationActive = false
        }
    }

    // MARK: - Audio Output (TTS Playback)

    /// Compute normalized RMS (0..1) from raw int16 PCM bytes. Used to drive the
    /// spectrum pulse line off the actual TTS waveform instead of a faked sinusoid.
    /// Square-root compressed so quiet syllables still register visually.
    static func computeRMS(int16Data: Data) -> Float {
        guard int16Data.count >= 2 else { return 0 }
        var sumSquares: Double = 0
        let count = int16Data.count / 2
        int16Data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            let int16Ptr = ptr.bindMemory(to: Int16.self)
            for i in 0..<count {
                let sample = Double(int16Ptr[i]) / 32768.0
                sumSquares += sample * sample
            }
        }
        let rms = sqrt(sumSquares / Double(max(count, 1)))
        // sqrt-compress for visual sensitivity to soft passages.
        let compressed = sqrt(rms)
        return Float(min(1.0, compressed))
    }

    func playPCMAudio(_ data: Data, sampleRate: Int) {
        // Convert PCM int16 data to float for playback
        let floatData = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> [Float] in
            let int16Ptr = ptr.bindMemory(to: Int16.self)
            return int16Ptr.map { Float($0) / 32768.0 }
        }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(sampleRate),
                                         channels: 1,
                                         interleaved: false) else {
            return
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(floatData.count)) else {
            return
        }

        buffer.frameLength = AVAudioFrameCount(floatData.count)
        if let channelData = buffer.floatChannelData {
            for i in 0..<floatData.count {
                channelData[0][i] = floatData[i]
            }
        }

        // Dispatch all audio engine work to main thread to prevent engine teardown race
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // This stream already hit a dead engine — the rest of its chunks would
            // fail identically. Drop them without another log line.
            guard !self.abandonedTTSStream else { return }

            let isConversation = self.conversationState != .inactive

            // In conversation mode, use the unified engine's player node.
            // In standalone TTS (Read Aloud / voice preview), use the separate playback engine.
            let activePlayerNode: AVAudioPlayerNode?
            let activeEngine: AVAudioEngine?

            if isConversation {
                activePlayerNode = self.conversationPlayerNode
                activeEngine = self.conversationEngine
            } else {
                // Recreate engine from scratch if nil or dead
                if self.audioPlayerNode == nil || !(self.playbackEngine?.isRunning ?? false) {
                    self.setupAudioPlayer(format: format)
                }
                activePlayerNode = self.audioPlayerNode
                activeEngine = self.playbackEngine
            }

            // Final check: engine must be running. Cold standalone path may need one
            // more setup; conversation mode waits for conversation engine (setup is
            // owned by startConversation). Recoverable — warn, not error.
            var engine = activeEngine
            var player = activePlayerNode
            if engine?.isRunning != true, !isConversation {
                self.setupAudioPlayer(format: format)
                engine = self.playbackEngine
                player = self.audioPlayerNode
            }
            guard engine?.isRunning == true else {
                // Single-shot: abandon the whole stream, not this one chunk. The
                // conversation engine is owned by startConversation and is not
                // rebuilt here, so every remaining audio.delta would land on the
                // same dead engine (field: 52 warnings from one install on 8.1.7).
                self.abandonedTTSStream = true
                AppLogger.shared.warn("[Realtime] Playback engine not running — abandoning TTS stream")
                self.stopTTSPlayback()
                return
            }

            guard let playerNode = player else {
                self.abandonedTTSStream = true
                AppLogger.shared.warn("[Realtime] No audio player node — abandoning TTS stream")
                return
            }

            let wasIdle = !self.isPlayingTTS

            // New audio arriving — cancel any pending drain debounce and track the scheduled buffer.
            self.ttsDrainDebounce?.cancel()
            self.ttsDrainDebounce = nil
            self.pendingAudioBuffers += 1

            // scheduleBuffer / play raise ObjC NSExceptions when the engine was
            // torn down mid-session (gateway force-respawn) — Swift cannot catch
            // those → SIGABRT (field Clownboy 8GB). Barrier matches AudioTapInstaller.
            if engine?.isRunning != true {
                self.abandonedTTSStream = true
                AppLogger.shared.warn("[Realtime] Engine stopped before scheduleBuffer — abandoning TTS stream")
                self.pendingAudioBuffers = max(0, self.pendingAudioBuffers - 1)
                self.stopTTSPlayback()
                return
            }
            if let nsErr = DTTryBlock({
                playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        // Floor at 0 — a stopTTSPlayback() that zeroed the counter while
                        // buffers were still scheduled would otherwise drive this negative,
                        // and a negative count never satisfies the `<= 0` drain check cleanly.
                        self.pendingAudioBuffers = max(0, self.pendingAudioBuffers - 1)
                        guard self.pendingAudioBuffers <= 0 else { return }

                        // All buffers drained. Wait 400ms for the next streaming chunk; if none arrives,
                        // call stopTTSPlayback(). A new chunk will cancel this debounce.
                        let task = DispatchWorkItem { [weak self] in
                            guard let self = self else { return }
                            if self.pendingAudioBuffers <= 0 && self.isPlayingTTS {
                                self.stopTTSPlayback()
                                // Natural end of playback — now that audio has fully drained,
                                // tear down a turn-based conversation. The tts.done safety-net
                                // timer no longer owns this (it's gated on no-queued-buffers and
                                // fires far earlier, at synthesis end), so the real teardown
                                // hook lives here, at genuine playback completion.
                                self.endConversationIfTurnBased()
                            }
                        }
                        self.ttsDrainDebounce = task
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: task)
                    }
                }

                if !playerNode.isPlaying {
                    playerNode.play()
                }
            }) {
                AppLogger.shared.warn("[Realtime] scheduleBuffer/play failed: \(nsErr.localizedDescription)")
                self.pendingAudioBuffers = max(0, self.pendingAudioBuffers - 1)
                self.stopTTSPlayback()
                return
            }

            // Only mark as playing if engine is actually running after play()
            if wasIdle && (engine?.isRunning ?? false) {
                self.isPlayingTTS = true
                AudioDucker.shared.begin()
                // New playback session — advance the generation so any stale tts.done
                // safety-net timer scheduled for a prior session no longer matches and bails.
                self.ttsPlaybackGeneration &+= 1
                // Barge-in is handled by server-side VAD in conversation mode (mic always on).
            }
        }
    }

    private func setupAudioPlayer(format: AVAudioFormat) {
        // Remove previous observer before tearing down engine
        if let observer = playbackEngineObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackEngineObserver = nil
        }

        // Tear down previous engine if any
        playbackEngine?.stop()
        playbackEngine = nil
        audioPlayerNode = nil

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)

        // Auto-restart engine on audio configuration changes (e.g. headphones plugged in)
        playbackEngineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in
            guard let self = self, let eng = self.playbackEngine, !eng.isRunning else { return }
            AppLogger.shared.warn("[Realtime] Audio engine config changed — restarting")
            try? eng.start()
        }

        do {
            try engine.start()
            self.playbackEngine = engine
            self.audioPlayerNode = playerNode
            self.audioFormat = format
        } catch {
            AppLogger.shared.error("[Realtime] Failed to start playback engine: \(error)", error: error)
        }
    }

    /// Cleans up TTS playback state and fires completion.
    func stopTTSPlayback() {
        guard isPlayingTTS else { return }
        isPlayingTTS = false
        AudioDucker.shared.end()
        speakingMessageId = nil
        pendingAudioBuffers = 0
        ttsDrainDebounce?.cancel()
        ttsDrainDebounce = nil

        // In conversation mode, transition back to idle (still listening)
        if conversationState == .assistantSpeaking {
            conversationState = .idle
        }

        let handler = ttsCompletionHandler
        ttsCompletionHandler = nil
        handler?(true)
    }
}
