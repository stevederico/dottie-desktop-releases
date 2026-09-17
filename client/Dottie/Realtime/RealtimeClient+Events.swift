import Foundation
import AppKit
import AVFoundation
import Combine

extension RealtimeClient {
    // Recoverable cold-start / soft states that should NOT be tracked as errors.
    // `empty_response`: warm-up miss, retried inline. See AgentStateCoordinator soft-fail.
    static let coldStartCodes: Set<String> = ["empty_response", "stt_unavailable"]



    // MARK: - Event Dispatch (WebSocket text messages)

    func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            AppLogger.shared.error("[Realtime] Failed to parse message (\(text.count) chars)")
            return
        }

        // Check for status messages
        if let status = json["status"] as? String {
            if status == "ready" {
                AppLogger.shared.info("[Realtime] Connection ready")
                isConnected = true
                connectionState = .connected
                retryCount = 0
                cancelReconnect()
                lastMessageTime = Date()
                startHeartbeatMonitor()
                startPingTimer()
                eventPublisher.send(.connected)
                sendConfig()
                // Config first so provider is set before conversation.start on a new socket.
                if conversationState != .inactive || isStartingConversation {
                    sendJSON(["type": "conversation.start"])
                }
            } else if status == "error" {
                let code = json["code"] as? String ?? "connection_error"
                let message = json["message"] as? String ?? json["error"] as? String ?? "Connection error"
                let recoverable = json["recoverable"] as? Bool ?? true
                AppLogger.shared.error("[Realtime] Server error [\(code)] (\(message.count) chars)")
                eventPublisher.send(.structuredError(code: code, message: message, recoverable: recoverable, info: json))
            }
            return
        }

        // Handle typed events
        guard let type = json["type"] as? String else { return }

        switch type {
        case "transcript.delta":
            if let delta = json["delta"] as? String {
                DispatchQueue.main.async {
                    self.currentTranscript += delta
                }
                eventPublisher.send(.transcriptDelta(delta))
            }

        case "transcript.done":
            if let text = json["text"] as? String {
                DispatchQueue.main.async {
                    self.currentTranscript = text
                }
                // Persist user message FIRST, then publish event (which creates placeholder)
                persistUserMessage(text)
                eventPublisher.send(.transcriptDone(text))
            }

        case "transcript.partial":
            if let text = json["text"] as? String {
                DispatchQueue.main.async {
                    self.currentTranscript = text
                    AgentStateCoordinator.shared.liveTranscript = text
                }
            }

        case "response.delta":
            hasReportedEngineDeath = false
            hasReportedXaiVoiceUnavailable = false
            hasReportedLLMError = false
            // A stream is flowing again — allow TTS chunks to schedule after a
            // previous turn abandoned playback on a dead conversation engine.
            abandonedTTSStream = false
            // First token of a text turn — record TTFT once, then clear so the
            // rest of the stream's deltas don't re-fire.
            if let start = turnStartTime {
                turnStartTime = nil
            }
            // A response is actively streaming — mark in-flight so connect() won't
            // tear down mid-stream. Covers voice turns that never call sendTextMessage.
            isResponding = true
            if let delta = json["delta"] as? String {
                DispatchQueue.main.async {
                    self.currentResponse += delta
                }
                eventPublisher.send(.responseDelta(delta))
            }

        case "thinking.delta":
            if let delta = json["delta"] as? String {
                eventPublisher.send(.thinkingDelta(delta))
            }

        case "response.done":
            // Response finished — clear the in-flight guard so subsequent reconnect /
            // sendTextMessage attempts aren't blocked by a stale "response in progress".
            isResponding = false
            if let text = json["text"] as? String {
                DispatchQueue.main.async {
                    self.currentResponse = text
                }
                eventPublisher.send(.responseDone(text))
            }
            // Turn-based mode: end the conversation after the model finishes so the user
            // has to re-trigger via hotkey/avatar/mic to start the next turn. Continuous
            // mode (default) leaves the WS open and lets server-side VAD pick up the
            // next utterance automatically. The delay lets pending audio.delta packets
            // play before teardown when autoSpeak is on.
            if UserDefaults.standard.bool(forKey: "conversationTurnBased"),
               conversationState != .inactive {
                let delay: Double = isPlayingTTS || isGeneratingTTS ? 0 : 0.2
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self, self.conversationState != .inactive else { return }
                    if self.isPlayingTTS || self.isGeneratingTTS {
                        // Defer to tts.done handler below — it will tear down once playback finishes.
                        return
                    }
                    AppLogger.shared.info("[Realtime] Turn-based: response done, ending conversation")
                    self.stopConversation()
                }
            }

        case "audio.delta":
            if let base64Audio = json["audio"] as? String,
               let audioData = Data(base64Encoded: base64Audio) {
                // First audio chunk — clear generating state
                if isGeneratingTTS {
                    isGeneratingTTS = false
                    ttsGenerationTimeout?.cancel()
                    ttsGenerationTimeout = nil
                }
                // Transition to assistantSpeaking on first audio in conversation mode
                if conversationState == .processing || conversationState == .idle {
                    stopThinkingCue()
                    conversationState = .assistantSpeaking
                }
                eventPublisher.send(.audioReceived(audioData))
                // Compute RMS from int16 PCM and push to the coordinator so the spectrum
                // pulse line tracks the real TTS audio (was previously a fake sinusoid).
                let rms = Self.computeRMS(int16Data: audioData)
                DispatchQueue.main.async {
                    AgentStateCoordinator.shared.pushSpeakingAudioLevel(rms)
                }
                playPCMAudio(audioData, sampleRate: json["sample_rate"] as? Int ?? 24000)
            }

        case "tts.done":
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // In conversation mode TTS plays through conversationEngine
                // (playbackEngine is nil); select the active engine first.
                let eng = (self.conversationState != .inactive) ? self.conversationEngine : self.playbackEngine
                // If engine already dead, reset immediately
                if self.isPlayingTTS && !(eng?.isRunning ?? false) {
                    AppLogger.shared.warn("[Realtime] Engine dead at tts.done — resetting")
                    self.stopTTSPlayback()
                    self.endConversationIfTurnBased()
                    return
                }
                // Safety net for genuinely-stuck playback only. The server emits
                // tts.done at SYNTHESIS end, far ahead of playback drain, so an
                // UNCONDITIONAL 5s force-reset cut off real audio mid-sentence on
                // long replies. Gate it: capture the current playback generation now,
                // and only force-reset if (a) we're still flagged playing, (b) NO audio
                // is still queued (pendingAudioBuffers <= 0 — the drain debounce owns
                // the normal path while buffers remain), and (c) no newer playback
                // session started in the meantime (generation unchanged).
                let scheduledGeneration = self.ttsPlaybackGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self = self else { return }
                    // A newer request started — its own lifecycle owns teardown.
                    guard self.ttsPlaybackGeneration == scheduledGeneration else { return }
                    if self.isPlayingTTS && self.pendingAudioBuffers <= 0 {
                        AppLogger.shared.warn("[Realtime] TTS state stuck (no queued buffers) — force-resetting")
                        self.stopTTSPlayback()
                    }
                    // Only end the turn-based conversation once playback is truly idle.
                    if !self.isPlayingTTS && self.pendingAudioBuffers <= 0 {
                        self.endConversationIfTurnBased()
                    }
                }
            }

        case "tool.start":
            if let name = json["name"] as? String {
                let id = (json["id"] as? String) ?? UUID().uuidString
                let input = json["input"] as? [String: Any] ?? [:]
                AppLogger.shared.debug("[Realtime] Tool started: \(name) (\(id))")
                eventPublisher.send(.toolStart(id: id, name: name, input: input))
            }

        case "tool.result":
            if let name = json["name"] as? String {
                let id = (json["id"] as? String) ?? UUID().uuidString
                let result = json["result"] as? String ?? ""
                AppLogger.shared.debug("[Realtime] Tool result: \(name) (\(id))")
                eventPublisher.send(.toolResult(id: id, name: name, result: result))
                // A chained tool.result after a confirm-style ui.action is that
                // action's outcome; agent_loop.js now echoes the originating card's
                // `componentId` so we resolve only the matching pending ack. A
                // `{"cancelled":true}` ui_action result still counts as success.
                resolveUIActionAck(success: true, result: result, error: nil, componentId: json["componentId"] as? String)
            }

        case "tool.error":
            // Server emits { type: 'tool.error', id, name, error, componentId? } when
            // a tool call fails (agent_loop.js). Surface it as a distinct .toolError
            // event so AgentStateCoordinator can mark the tool card failed (not a
            // success-with-"Error:"-prefix), and fail any awaiting confirm ack.
            if let name = json["name"] as? String {
                let id = (json["id"] as? String) ?? UUID().uuidString
                let errText = json["error"] as? String ?? json["message"] as? String ?? "Tool failed"
                AppLogger.shared.warn("[Realtime] Tool error: \(name) (\(id)) — \(errText)")
                eventPublisher.send(.toolError(id: id, name: name, error: errText))
                resolveUIActionAck(success: false, result: nil, error: errText, componentId: json["componentId"] as? String)
            }

        case "ui.action.expired":
            // Server could no longer run this confirm (the agent turn ended before
            // it arrived). Fail the pending ack instead of letting the optimistic
            // timeout report false success — the destructive action did NOT run.
            AppLogger.shared.warn("[Realtime] UI action expired server-side — action not executed")
            resolveUIActionAck(success: false, result: nil,
                               error: "This action expired before it could run. Please try again.",
                               componentId: json["componentId"] as? String)

        case "tool.ui":
            if let id = json["id"] as? String,
               let component = json["component"] as? String {
                let data = json["data"] as? [String: Any] ?? [:]
                let actions = json["actions"] as? [[String: Any]] ?? []
                AppLogger.shared.debug("[Realtime] Tool UI: \(component) (\(id))")
                pendingConfirmation = (id: id, component: component)
                eventPublisher.send(.toolUI(id: id, component: component, data: data, actions: actions))
            }

        case "session.loaded":
            let messageCount = json["messageCount"] as? Int ?? 0
            AppLogger.shared.info("[Realtime] Session loaded with \(messageCount) messages")
            eventPublisher.send(.sessionLoaded(messageCount: messageCount))

        case "message.persisted":
            let role = json["role"] as? String ?? "unknown"
            AppLogger.shared.debug("[Realtime] Message persisted: \(role)")
            eventPublisher.send(.messagePersisted(role: role))

        case "response.followup":
            if let text = json["text"] as? String, !text.isEmpty {
                AppLogger.shared.debug("[Realtime] Followup suggestion (\(text.count) chars)")
                eventPublisher.send(.followup(text))
            }

        case "image.generated":
            // AI-generated image attachments removed from chat UI; ignore.
            break

        case "compaction":
            AppLogger.shared.info("[Realtime] Conversation compacted")
            eventPublisher.send(.compaction)

        case "tools.context_changed":
            // ToolSearch dev overlay — backend emits this after every
            // `tool_search` execution. Face no longer tracks tool-context UI state.
            // and updates the tool-context card in the System Health sheet.
            let domain = json["domain"] as? String
            let addedNames = json["addedNames"] as? [String] ?? []
            let loadedCount = json["loadedCount"] as? Int ?? addedNames.count
            AppLogger.shared.debug("[Realtime] tools.context_changed domain=\(domain ?? "nil") added=\(addedNames.count) total=\(loadedCount)")
            eventPublisher.send(.toolContextChanged(domain: domain, addedNames: addedNames, loadedCount: loadedCount))

        case "session.title":
            if let title = json["title"] as? String,
               let convId = json["conversation_id"] as? String {
                AppLogger.shared.info("[Realtime] Title generated: \(title)")
                eventPublisher.send(.sessionTitle(conversationId: convId, title: title))
            }

        case "error":
            let code = json["code"] as? String ?? "unknown"
            let message = json["message"] as? String ?? json["error"] as? String ?? "Unknown error"
            let recoverable = json["recoverable"] as? Bool ?? true
            AppLogger.shared.warn("[Realtime] Error [\(code)] (\(message.count) chars, recoverable: \(recoverable))")
            // Missing ~/.dottie/api_token (zero-admit field class) — force re-bootstrap once.
            if message.lowercased().contains("registration token missing") {
                Task { await RegistrationManager.shared.bootstrapTokenIfNeeded(force: true) }
            }
            // Pro free-credit wall: surface paywall (Subscribe / BYOK / Local) instead
            // of a silent hang or generic rate-limit copy. Cap hits are ledgered on
            // dottie-pro (`pro_calls` rejected) — no client `pro.cap.*` event.
            let proCap = ProPaywall.classify(message: message)
            if proCap == .freeCreditUsed {
                NotificationCenter.default.post(name: ProPaywall.freeCreditUsedNotification, object: nil)
            }
            switch proCap {
            case .freeCreditUsed:
                AppLogger.shared.warn("[Realtime] pro.cap kind=free_credit source=realtime")
            case .dailyLimit:
                AppLogger.shared.warn("[Realtime] pro.cap kind=daily_limit source=realtime")
            case .spendingCap:
                AppLogger.shared.warn("[Realtime] pro.cap kind=spending_cap source=realtime")
            case .other:
                break
            }
            // Any server error aborts the in-flight response — clear the guard so the
            // socket can reconnect / accept the next message instead of deadlocking.
            isResponding = false
            // A confirm-style ui.action's tool re-call that throws is reported by the
            // server as `emitError('llm_error', 'UI action tool error: …')`, NOT as a
            // tool.error. The agent loop is paused on the UI action, so any error here
            // while an ack is pending is that action's failure — resolve it red.
            resolveUIActionAck(success: false, result: nil, error: message)
            // Engine-died-during-chat detection. Two server-side codes can land
            // here when the LLM engine crashes mid-session: `engine_down`
            // (supervisor knew the engine was down) and `llm_error` carrying
            // "fetch failed" (engine died but supervisor's health state hadn't
            // updated yet — see engine_health.js:isLocalEngineDownError). Both
            // mean the same thing to the user: their chat just failed because
            // the model is gone.
            let isEngineDied = code == "engine_down" || (code == "llm_error" && message.lowercased().contains("fetch failed"))
            if isEngineDied {
                if !hasReportedEngineDeath {
                    AppLogger.shared.warn("[Realtime] engine died code=\(code)")
                    hasReportedEngineDeath = true
                }
            } else if !Self.coldStartCodes.contains(code) && proCap == .other {
                let isVoiceMint = code == "xai_voice_unavailable"
                let isLLMError = code == "llm_error"
                let dedupeKey = "\(code)|\(message.prefix(80))|\(ChatProvider.current.rawValue)"
                if reportedRealtimeErrorKeys.contains(dedupeKey)
                    || (isVoiceMint && hasReportedXaiVoiceUnavailable) || (isLLMError && hasReportedLLMError) {
                    // still route UI below
                } else {
                    reportedRealtimeErrorKeys.insert(dedupeKey)
                    if isVoiceMint { hasReportedXaiVoiceUnavailable = true }
                    if isLLMError { hasReportedLLMError = true }
                    AppLogger.shared.warn("[Realtime] server error code=\(code)")
                }
            }
            // Route engine-death events through the existing `engine_down` UI path
            // regardless of whether the supervisor's health state had caught up
            // before the server emitted (which is what differentiates `engine_down`
            // from `llm_error`+"fetch failed" — same root cause, accidentally
            // different code on the wire). The launcher's 10s countdown + auto-retry
            // handles `engine_down` but treats `llm_error` as terminal — translating
            // here means every engine crash gets the same auto-retry, not just the ones the
            // supervisor noticed in time.
            //
            // `model_missing` and `model_downloading` are explicit alternative
            // codes the gateway emits when the local GGUF isn't on disk yet —
            // do NOT fold those into engine_down (they need distinct banners
            // because retrying when the file is absent loops forever).
            let publishCode = (code == "model_missing" || code == "model_downloading")
                ? code
                : (isEngineDied ? "engine_down" : code)
            eventPublisher.send(.structuredError(code: publishCode, message: message, recoverable: recoverable, info: json))
            // TTS error — reset generating/playing state and fire completion as failure
            if code == "tts_error" {
                isGeneratingTTS = false
                ttsGenerationTimeout?.cancel()
                ttsGenerationTimeout = nil
                pendingAudioBuffers = 0
                ttsDrainDebounce?.cancel()
                ttsDrainDebounce = nil
                if isPlayingTTS {
                    isPlayingTTS = false
                }
                let handler = ttsCompletionHandler
                ttsCompletionHandler = nil
                handler?(false)
                NSSound(named: "Basso")?.play()
            }

        // MARK: Conversation Mode Events (Full-Duplex)

        case "input_audio_buffer.speech_started":
            if conversationState != .inactive {
                stopThinkingCue()
                conversationState = .userSpeaking
            }

        case "input_audio_buffer.speech_stopped":
            if conversationState == .userSpeaking {
                conversationState = .processing
                playThinkingCue()
            }

        case "input_audio_buffer.speech_rejected":
            if conversationState == .userSpeaking || conversationState == .processing {
                conversationState = .idle
            }

        case "conversation.interrupted":
            // Server detected barge-in — stop TTS playback immediately
            if conversationState != .inactive {
                AppLogger.shared.info("[Realtime] Server barge-in — stopping TTS")
                let playerNode = conversationPlayerNode ?? audioPlayerNode
                playerNode?.stop()
                stopTTSPlayback()
                stopThinkingCue()
                conversationState = .userSpeaking
            }

        case "conversation.started":
            AppLogger.shared.info("[Realtime] Server confirmed conversation mode")

        case "conversation.stopped":
            AppLogger.shared.info("[Realtime] Server confirmed conversation mode stopped")

        case "control.command":
            // Server recognized a spoken control command. "start_dictation" arms
            // one-shot dictation: the next final transcript is pasted at the cursor
            // instead of going to the LLM. Publish an event so the UI can show a hint.
            if let command = json["command"] as? String, command == "start_dictation" {
                AppLogger.shared.info("[Realtime] Dictation armed")
                eventPublisher.send(.dictationArmed)
            }

        case "dictation.text":
            // The captured dictation utterance. Paste it at the cursor in the
            // frontmost app via GlobalRecorder's accessibility-gated paste path.
            // This is NOT a chat turn — do not persist it.
            guard let text = json["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            AppLogger.shared.info("[Realtime] Dictation text received (\(text.count) chars)")
            GlobalRecorder.shared.pasteTextAtCursor(text)
            eventPublisher.send(.dictationText(text))

        case "pong", "interrupt.acknowledged":
            // Server-sent ack messages — no client action needed.
            break

        default:
            AppLogger.shared.debug("[Realtime] Unknown event type: \(type)")
        }
    }
}
