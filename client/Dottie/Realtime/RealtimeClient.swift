//
//  RealtimeClient.swift
//  Dottie
//
//  WebSocket client for realtime voice pipeline (Her experience).
//  Connects to ws://127.0.0.1:1317/v1/realtime for bidirectional audio streaming.
//
//  Split into domain extensions (Dottie/Realtime/):
//    RealtimeClient+Events.swift        — WS event dispatch (handleTextMessage switch)
//    RealtimeClient+Reconnect.swift     — auto-reconnect, heartbeat monitoring, app-level ping
//    RealtimeClient+Conversation.swift  — full-duplex conversation mode (engine setup/teardown, AEC)
//    RealtimeClient+TTSPlayback.swift  — speak/stop TTS + PCM playback / drain
//

import Foundation
import AVFoundation
import Combine
import AppKit
import CoreAudio

/// Events emitted by the realtime client.
enum RealtimeEvent {
    case connected
    case disconnected(Error?)
    case transcriptDelta(String)
    case transcriptDone(String)
    case thinkingDelta(String)
    case responseDelta(String)
    case responseDone(String)
    case audioReceived(Data)
    case error(String)
    case structuredError(code: String, message: String, recoverable: Bool, info: [String: Any])
    case toolStart(id: String, name: String, input: [String: Any])
    case toolResult(id: String, name: String, result: String)
    case toolError(id: String, name: String, error: String)
    case toolUI(id: String, component: String, data: [String: Any], actions: [[String: Any]])
    case sessionLoaded(messageCount: Int)
    case messagePersisted(role: String)
    case followup(String)
    case compaction
    case sessionTitle(conversationId: String, title: String)
    case toolContextChanged(domain: String?, addedNames: [String], loadedCount: Int)
    case dictationArmed
    case dictationText(String)
}

/// Connection lifecycle state for the realtime WebSocket client.
enum RealtimeConnectionState {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(Error)
}

/// Full-duplex conversation mode state (Grok Voice experience).
enum ConversationState {
    case inactive          // No conversation in progress
    case idle              // Listening, no speech detected, no response in progress
    case userSpeaking      // Server VAD detected speech onset
    case processing        // STT → LLM running, still listening
    case assistantSpeaking // TTS playing, still listening (barge-in possible)
}

/// Realtime voice WebSocket client for the "Her" experience.
/// Streams audio to the Gateway and receives transcript/response/audio events.
/// Supports auto-reconnect with exponential backoff and heartbeat monitoring.
class RealtimeClient: NSObject, ObservableObject {
    static let shared = RealtimeClient()

    @Published var isConnected = false
    @Published var currentTranscript = ""
    @Published var currentResponse = ""
    @Published var pendingConfirmation: (id: String, component: String)?
    @Published var isPlayingTTS = false
    @Published var isGeneratingTTS = false
    @Published var connectionState: RealtimeConnectionState = .disconnected

    /// Full-duplex conversation mode state.
    @Published var conversationState: ConversationState = .inactive

    /// ID of the message currently being spoken (for Read Aloud UI state).
    @Published var speakingMessageId: UUID?

    var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession!
    var audioPlayerNode: AVAudioPlayerNode?
    var playbackEngine: AVAudioEngine?
    var audioFormat: AVAudioFormat?

    // MARK: - Unified Conversation Engine (Full-Duplex)
    /// Single AVAudioEngine for both capture and playback with voice processing (AEC).
    var conversationEngine: AVAudioEngine?
    /// Player node attached to the conversation engine for TTS output.
    var conversationPlayerNode: AVAudioPlayerNode?
    /// Audio converter for resampling mic input to 16kHz int16 in conversation mode.
    var conversationConverter: AVAudioConverter?
    /// True if the active conversation engine has AEC enabled. When false, the mic tap
    /// suppresses outbound audio while TTS is playing to prevent the AI's own voice from
    /// triggering server-side VAD barge-in (the feedback loop manifests as TTS getting
    /// cut off ~1s after it starts and the response cycle restarting endlessly).
    var conversationUsesAEC: Bool = true
    /// True when AEC has been observed to fail on the current default output device.
    /// Loaded from UserDefaults at init by matching the persisted output-device UID
    /// against the live one. Persisting the failure across launches eliminates the
    /// ~3000ms first-click penalty on hardware where VPIO can never init (Studio
    /// Display 8ch output, multi-channel aggregate devices). When the user plugs in
    /// or unplugs headphones the default output UID changes, so the memo no longer
    /// matches and we re-attempt AEC on the new device.
    var aecKnownFailedThisSession: Bool = false
    /// Mic-denied warn logged once per app session (banner still shows every time).
    var micDeniedReported: Bool = false
    static let aecFailedDeviceUIDKey = "aecKnownFailedOutputDeviceUID"
    /// One-shot guard for the 0-channel HAL-wedge recovery in startConversation():
    /// when both engine-init attempts fail AND a fresh probe engine reports 0-channel
    /// input+output (process-wide CoreAudio HAL client wedged), we release every
    /// long-lived audio engine in the process and retry ONCE. Reset on a successful
    /// conversation start so a later wedge gets its own recovery attempt.
    var halRecoveryAttempted: Bool = false
    /// One-shot gate for the transient-contention retry in startConversation():
    /// engine init failing on both AEC paths gets a single delayed re-attempt
    /// (I/O-unit contention clears in ~hundreds of ms). Reset on success and on
    /// terminal abort so every user-initiated attempt earns exactly one retry.
    var engineStartRetryAttempted: Bool = false
    /// True from the moment startConversation() commits to engine setup until the
    /// conversation is active (or aborted). Closes the init-window hole in
    /// VoiceWake's mic gates: conversationState stays .inactive during the whole
    /// setup (which can take seconds on the AEC-fail path), so VoiceWake's
    /// auto-restart — scheduled 0.5s after our stopListening() cancels its task —
    /// used to re-grab the mic while VPIO was initializing. That contention is a
    /// prime suspect for both AEC init failures and the 0-channel HAL wedge.
    var isStartingConversation: Bool = false
    /// Observer token from the block-based AVAudioEngineConfigurationChange registration.
    /// Held so we can remove the exact observer instance in teardown (the `removeObserver(self,...)`
    /// form was a no-op since `self` was never registered as the observer — block observers
    /// register an internal proxy and only the returned token can remove them). Without
    /// proper removal, every conversation start leaks an observer that wakes up on every
    /// future audio config change, eventually deadlocking when one of those stale observers
    /// runs on the main queue while another engine is being deallocated on it.
    var conversationConfigChangeObserver: NSObjectProtocol?

    /// Quiet loop while Grok Voice is thinking (speech_stopped → first audio).
    var thinkingSound: NSSound?

    /// Completion handler for the current TTS request.
    var ttsCompletionHandler: ((Bool) -> Void)?
    var ttsGenerationTimeout: DispatchWorkItem?

    /// Count of audio buffers scheduled on the player node but not yet rendered.
    /// Used to detect end of playback — `AVAudioPlayerNode.isPlaying` stays true between play()/stop(),
    /// so we track drain manually via `.dataPlayedBack` completion callbacks.
    var pendingAudioBuffers = 0
    /// Debounce task that fires `stopTTSPlayback()` when the buffer queue has been drained for ~400ms.
    /// Cancelled when a new buffer arrives, giving streaming chunks a grace period.
    var ttsDrainDebounce: DispatchWorkItem?

    /// Monotonic counter bumped each time a fresh TTS playback session begins
    /// (idle → playing in playPCMAudio). The tts.done safety-net force-reset captures
    /// this value when scheduling and bails if it advances before the timer fires —
    /// so a newer request's playback is never killed by an older request's stale timer.
    /// The server emits tts.done at SYNTHESIS end, far ahead of playback drain, so the
    /// unconditional reset previously cut off audio mid-sentence.
    var ttsPlaybackGeneration = 0

    /// True while the server is actively producing a response (set when a response
    /// starts streaming, cleared on response.done and on any error/abort). The
    /// connect() guard tests THIS instead of `currentResponse.count`, which was
    /// never cleared at idle: response.done sets currentResponse to the final text
    /// and nothing reset it, so after the first completed chat every reconnect /
    /// sendTextMessage attempt hit a dead "response in progress" guard and timed out
    /// forever. Tracking an explicit flag that is reliably cleared fixes the deadlock.
    var isResponding = false

    /// Conversation ID for message persistence.
    var conversationId: UUID?

    // MARK: - UI Action Acknowledgement

    /// Outcome of a confirm-dialog UI action once the
    /// server-side tool re-call resolves. `success == false` carries the error text.
    struct UIActionOutcome {
        let success: Bool
        let result: String?
        let error: String?
    }

    /// Single-slot pending UI-action acknowledgement. The agent loop PAUSES on a
    /// UI action (agent_loop.js: `Pausing for UI action`), so at most one confirm
    /// action is in flight at a time — the very next tool.result / tool.error /
    /// llm_error after we send `ui.action` is that action's outcome. We can't
    /// correlate by componentId (the server's chained tool.result carries a fresh
    /// `tool_<ts>_chained` id + the action's tool name, NOT the component id — see
    /// the deferred note), so we resolve the next server outcome instead.
    /// Cleared as soon as it resolves or times out; the continuation is resumed
    /// exactly once (guarded by niling the slot before resuming).
    var pendingUIActionAck: (componentId: String, continuation: CheckedContinuation<UIActionOutcome, Never>)?
    /// Timeout work item for the pending UI-action ack; cancelled on resolution.
    var pendingUIActionAckTimeout: DispatchWorkItem?
    /// Seconds to wait for a server outcome before giving up on a UI action.
    /// MUST exceed the server's 60s agent-loop UI-pause (agent_loop.js) — a
    /// slow-but-real tool (iMessage send, calendar op) can take >12s, and the
    /// old 12s cap resolved success BEFORE the tool finished, reporting
    /// destructive actions as done when they hadn't run. When this fires the
    /// server genuinely never responded within its own action window, so we
    /// resolve FAILURE, not optimistic success. The server also sends an explicit
    /// `ui.action.expired` on an orphaned confirm, so the common case resolves
    /// immediately and never waits this long.
    static let uiActionAckTimeout: TimeInterval = 65

    // MARK: - Reconnection State

    var retryCount = 0
    static let maxRetries = 10
    static let baseRetryDelay: TimeInterval = 5
    var reconnectTimer: DispatchWorkItem?
    /// Last socket-close diagnostics, captured in `receiveMessage`'s failure path
    /// and read by `scheduleReconnect` when retries are exhausted — so the
    /// Reconnect-exhaustion log names WHY the socket died.
    var lastCloseCode: Int?
    var lastSocketError: String?
    /// Set when a text turn is sent; consumed on the first `response.delta` to
    /// Turn start for TTFT measurement. nil between turns.
    var turnStartTime: Date?
    /// Set to `true` when the user explicitly calls `disconnect()` to suppress auto-reconnect.
    var intentionalDisconnect = false

    /// Dedupe flag for engine-died-during-chat logs. Cleared on `response.delta`.
    var hasReportedEngineDeath = false
    /// Server error warn once per session per code|reason|provider.
    var reportedRealtimeErrorKeys = Set<String>()
    /// Reconnect-exhaustion warn at most once per 10 minutes.
    var lastMaxRetriesReport: Date?
    /// Dedupe xai_voice_unavailable server-error logs (server also cooldowns mint).
    var hasReportedXaiVoiceUnavailable = false
    /// Set when `playPCMAudio` finds the conversation engine dead mid-stream.
    /// The gateway keeps streaming `audio.delta` for the rest of the utterance and
    /// every chunk hit the same dead engine — one install logged 52 warnings for a
    /// single turn. Once set, remaining chunks are dropped silently; a new TTS
    /// request, a new streamed response, or a fresh conversation clears it.
    var abandonedTTSStream = false
    /// Dedupe llm_error server-error logs; re-armed on `response.delta`.
    var hasReportedLLMError = false

    // MARK: - Heartbeat Monitoring

    /// Timestamp of the last message received from the server.
    var lastMessageTime: Date?
    /// Timer that fires periodically to check for heartbeat timeout.
    var heartbeatTimer: Timer?
    /// Seconds of silence before triggering a reconnect when idle.
    static let heartbeatTimeout: TimeInterval = 45
    /// Seconds of silence before reconnecting WHILE a response is streaming.
    /// Local LLM turns on a 16GB Mac routinely run 45-100s (single KV slot,
    /// large-prompt re-prefill, tool loops). At the 45s idle timeout the
    /// heartbeat killed the socket mid-generation and the stale-task guard
    /// dropped `response.done` → the UI hung on "Thinking…" forever. A response
    /// in flight is proof the server is alive, so give it a much longer grace.
    static let respondingHeartbeatTimeout: TimeInterval = 180

    /// Timer that sends application-level ping messages to keep connection alive.
    var pingTimer: Timer?
    /// Seconds between application-level pings.
    static let pingInterval: TimeInterval = 25

    /// Stored observer tokens for cleanup.
    private var permissionsObserver: Any?
    private var chatConfigObserver: Any?
    var playbackEngineObserver: Any?

    /// Publisher for realtime events.
    let eventPublisher = PassthroughSubject<RealtimeEvent, Never>()

    // Live transcription is now driven server-side by parakeet via the
    // transcript.partial event (see realtime.js partialTick). The voice overlay
    // and the LLM read from the same source — no more dual-recognizer drift.

    private override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        urlSession = URLSession(configuration: config, delegate: nil, delegateQueue: .main)

        // If we've previously memoized an AEC failure on the same output device that's
        // currently active, skip the failing attempt on the very first conversation start.
        if let savedUID = UserDefaults.standard.string(forKey: Self.aecFailedDeviceUIDKey),
           let currentUID = Self.defaultOutputDeviceUID(),
           savedUID == currentUID {
            aecKnownFailedThisSession = true
            AppLogger.shared.info("[Realtime] AEC memoized failed on output device \(currentUID) — skipping AEC on first start")
        }

        // Re-send the WS config whenever the user toggles a permission in Settings.
        // The realtime WS caches permissions locally in its per-connection `cfg.permissions`,
        // so without this the WS would keep using the old permission set for subsequent
        // chats and the KV cache warmup (which re-fires on GatewayClient.pushChatConfig)
        // would mismatch on tool count and cost 8s of cold prompt reprocess.
        permissionsObserver = NotificationCenter.default.addObserver(
            forName: .permissionsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isConnected else { return }
            self.sendConfig()
        }

        // Re-send the WS config whenever the user flips the chat provider/model/apiKey
        // (Local⇄xAI). Without this, a mid-session flip would only land in the cached
        // /v1/config and the live socket would keep routing to the previous provider
        // until reconnect. sendConfig() now carries provider/model/apiKey inline, so a
        // flip takes effect on the open WS immediately, both directions.
        chatConfigObserver = NotificationCenter.default.addObserver(
            forName: .chatConfigChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isConnected else { return }
            self.sendConfig()
        }
    }

    deinit {
        if let observer = permissionsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = chatConfigObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = playbackEngineObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        heartbeatTimer?.invalidate()
        pingTimer?.invalidate()
        reconnectTimer?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        playbackEngine?.stop()
        conversationEngine?.inputNode.removeTap(onBus: 0)
        conversationEngine?.stop()
        urlSession.invalidateAndCancel()
    }

    // MARK: - Connection Management

    /// Connects to the realtime WebSocket endpoint.
    /// Checks audio server health before connecting. Sends conversation_id for message persistence.
    func connect() {
        dispatchPrecondition(condition: .onQueue(.main))
        if webSocketTask != nil && isConnected {
            AppLogger.shared.debug("[Realtime] Already connected")
            return
        }
        if case .connecting = connectionState {
            AppLogger.shared.debug("[Realtime] Connection already in progress")
            return
        }
        // Don't reconnect during active response streaming — the stale task guard
        // in receiveMessage() would silently drop events (including response.done),
        // leaving the UI stuck in "Thinking..." state forever. Tracks the explicit
        // `isResponding` flag (cleared on response.done / error / abort) rather than
        // `currentResponse.count`, which stayed non-zero after the first completed
        // chat and deadlocked all subsequent reconnect/sendTextMessage attempts.
        if isResponding {
            AppLogger.shared.info("[Realtime] Skipping connect — response in progress")
            return
        }
        // Clean up stale task if exists but not connected
        if webSocketTask != nil && !isConnected {
            AppLogger.shared.info("[Realtime] Cleaning up stale WebSocket task")
            webSocketTask?.cancel(with: .goingAway, reason: nil)
            webSocketTask = nil
        }

        cancelReconnect()
        intentionalDisconnect = false
        connectionState = .connecting

        performConnect()
    }

    /// Performs the actual WebSocket connection after health checks pass.
    private func performConnect() {
        // Build URL with conversation_id for session persistence
        var urlString = "ws://127.0.0.1:\(AppPorts.agentServer)/v1/realtime"
        if let convId = conversationId ?? MessageStore.shared.currentConversationId {
            urlString += "?conversation_id=\(convId.uuidString)"
            conversationId = convId
        }

        guard let url = URL(string: urlString) else {
            AppLogger.shared.error("[Realtime] Invalid WebSocket URL")
            connectionState = .disconnected
            return
        }

        AppLogger.shared.info("[Realtime] Connecting to \(url)")
        // The /v1/realtime WS handler authenticates no-Origin connections (the native
        // app sends no Origin) via the bearer token. Browsers can't set Authorization on
        // a WebSocket and authenticate by Origin allowlist instead, so this header path is
        // what authorizes the native client. Read the token at connect-time so a regenerated
        // ~/.dottie/agent_token is picked up on the next connection. Header, not query param,
        // to keep the token out of URL logs.
        var request = URLRequest(url: url)
        let token = AgentToken.load() ?? ""
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        webSocketTask = urlSession.webSocketTask(with: request)
        webSocketTask?.maximumMessageSize = 5 * 1024 * 1024 // 5MB — ample for voice data
        webSocketTask?.resume()

        receiveMessage()
    }

    /// Switches the realtime WebSocket to a new conversation. The `conversation_id`
    /// query param is baked into the URL at connect-time, so changing the active
    /// conversation requires a full reconnect — otherwise messages continue to
    /// persist to the old session ID even after the UI rotates.
    /// - Parameter newId: The UUID of the conversation to bind the socket to. Pass
    ///   `nil` to clear and let the next connect fall back to `MessageStore`.
    func switchConversation(to newId: UUID?) {
        dispatchPrecondition(condition: .onQueue(.main))
        if conversationId == newId { return }
        AppLogger.shared.info("[Realtime] Switching conversation: \(conversationId?.uuidString ?? "nil") → \(newId?.uuidString ?? "nil")")
        conversationId = newId
        // Drop in-flight response state from the previous conversation. Without
        // this, the connect() guard ("Skipping connect — response in progress")
        // bails because currentResponse still holds the prior chat's streaming
        // text, leaving the WS dead on the new conversation_id and bleeding
        // stale assistant text into the fresh chat.
        currentResponse = ""
        currentTranscript = ""
        // No response is in flight on the new conversation — clear the guard flag
        // too, otherwise a prior chat's still-true isResponding would block the
        // immediate reconnect below for the new conversation_id.
        isResponding = false
        // Tear down current socket so the next connect picks up the new id.
        intentionalDisconnect = true
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        // CRITICAL: clear isConnected synchronously. The new socket is only "ready"
        // when the server confirms ("Connection ready" → isConnected = true). If we
        // leave isConnected true here, a sendTextMessage() fired immediately after the
        // switch (e.g. opening the launcher then typing) skips its !isConnected
        // reconnect-and-wait guard and writes to the not-yet-open socket — the frame
        // is dropped and the UI hangs on "Thinking…" forever (no response ever comes).
        isConnected = false
        connectionState = .disconnected
        // Immediately reconnect with the new id.
        intentionalDisconnect = false
        connect()
    }

    /// Disconnects from the WebSocket. Cancels any pending reconnect.
    func disconnect() {
        dispatchPrecondition(condition: .onQueue(.main))
        AppLogger.shared.info("[Realtime] Disconnecting")
        intentionalDisconnect = true
        cancelReconnect()
        stopHeartbeatMonitor()
        stopPingTimer()
        if conversationState != .inactive {
            stopConversation()
        }
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        isResponding = false
        connectionState = .disconnected
        retryCount = 0
        eventPublisher.send(.disconnected(nil))
    }

    // MARK: - Message Handling

    private func receiveMessage() {
        let task = webSocketTask
        task?.receive { [weak self] result in
            guard let self = self else { return }
            // Ignore callbacks from stale/cancelled tasks to prevent race conditions
            // where an old task's failure handler destroys a newly-created task.
            guard task === self.webSocketTask else { return }

            switch result {
            case .success(let message):
                self.lastMessageTime = Date()
                self.handleMessage(message)
                self.receiveMessage() // Continue listening

            case .failure(let error):
                // Most WebSocket "failures" are benign disconnects (app shutdown,
                // gateway restart, sleep/wake, network blip). Only escalate to
                // ERROR only when genuinely unexpected.
                // NSURLErrorCancelled (-999) and intentionalDisconnect are never errors.
                let nsErr = error as NSError
                let isCancelled = nsErr.code == NSURLErrorCancelled
                if isCancelled || self.intentionalDisconnect {
                    AppLogger.shared.debug("[Realtime] WebSocket closed: \(error.localizedDescription)")
                } else {
                    AppLogger.shared.warn("[Realtime] WebSocket disconnected (will reconnect): \(error.localizedDescription)")
                }
                // Stash the cause for the reconnect-exhaustion log. Prefer the
                // WS close code if the server sent one; fall back to the URL error code.
                if let close = task?.closeCode, close != .invalid {
                    self.lastCloseCode = close.rawValue
                } else {
                    self.lastCloseCode = nsErr.code
                }
                self.lastSocketError = error.localizedDescription
                // -1011 on a loopback upgrade = the gateway answered the handshake
                // with a non-101 status; for /v1/realtime that is its 401.
                if !self.intentionalDisconnect, nsErr.code == NSURLErrorBadServerResponse {
                    AgentManager.shared.handleGatewayAuthRejected(source: "realtime_ws")
                }
                self.webSocketTask = nil
                DispatchQueue.main.async {
                    self.isConnected = false
                    // A dropped socket aborts any in-flight response — clear the guard
                    // so scheduleReconnect()'s connect() isn't blocked by a stale flag.
                    self.isResponding = false
                }
                self.stopHeartbeatMonitor()
                self.stopPingTimer()
                self.eventPublisher.send(.disconnected(error))
                self.scheduleReconnect()
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            handleTextMessage(text)
        case .data(let data):
            // Binary data (shouldn't happen from server, but handle it)
            AppLogger.shared.debug("[Realtime] Received binary data: \(data.count) bytes")
        @unknown default:
            break
        }
    }

    // MARK: - Send Messages

    /// Pushes session config to the realtime server.
    func sendConfig() {
        let voice = UserDefaults.standard.string(forKey: "selectedVoice") ?? ModelDefaults.voice

        // Send provider/model/apiKey/permissions inline alongside the audio settings.
        // The server WS-config handler applies msg.provider/msg.model/msg.apiKey when
        // present, so an early-connecting WS no longer races the cached /v1/config POST,
        // and a mid-session Local⇄xAI flip takes effect on the live socket immediately.
        var config: [String: Any] = [
            "type": "config",
            "voice": voice,
            "sample_rate": 16000,
            "autoSpeak": UserDefaults.standard.bool(forKey: "autoSpeak"),
            // Replace-input mode: voice drives the mouse and keyboard directly.
            // Sent on every config push so a mid-session toggle reaches the live
            // socket — the server preloads/drops the input primitives on the flip.
            "replaceInput": UserDefaults.standard.bool(forKey: "replaceInputEnabled"),
            // Grok Voice Agent: on for Dottie Pro + BYOK xAI (provider-derived).
            "xaiVoiceAgent": ChatProvider.current.usesGrokVoiceAgent,
            "xaiVoiceModel": UserDefaults.standard.string(forKey: "xaiVoiceModel")
                ?? "grok-voice-think-fast-2.0"
        ]
        // Main-display size in points. The gateway has no display access, and
        // in replace-input mode the model needs it to resolve "top right" —
        // without it, it burns a tool_search turn hunting for the screen size
        // and never fires a primitive.
        if let frame = NSScreen.main?.frame {
            config["screen"] = ["width": frame.width, "height": frame.height]
        }
        for (key, value) in GatewayClient.shared.chatConfigBody() {
            config[key] = value
        }

        sendJSON(config)
    }

    /// Sends a JSON message to the server.
    func sendJSON(_ dict: [String: Any]) {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: dict)
        } catch {
            AppLogger.shared.error("[Realtime] failed to serialize outbound message, not sent: \(error)")
            return
        }
        guard let text = String(data: data, encoding: .utf8) else {
            // Cannot happen for JSONSerialization output. Warn keeps the line in the log.
            AppLogger.shared.warn("[Realtime] failed to decode serialized message as UTF-8, not sent")
            return
        }

        webSocketTask?.send(.string(text)) { error in
            if let error = error {
                AppLogger.shared.error("[Realtime] Send error: \(error)")
            }
        }
    }

    /// Sends binary audio data to the server.
    func sendAudio(_ data: Data) {
        // Mic frames keep flowing for a beat after the socket drops; a send on a
        // closed task is that race, not a fault — the reconnect path owns it.
        guard let task = webSocketTask, task.state == .running else { return }
        task.send(.data(data)) { error in
            if let error = error {
                AppLogger.shared.warn("[Realtime] Audio send error: \(error)")
            }
        }
    }

    /// Sends a UI action response (e.g., confirming a destructive tool).
    /// - Parameters:
    ///   - componentId: The ID of the tool/component to respond to.
    ///   - actionId: The action identifier (e.g., "confirm", "cancel").
    ///   - payload: Optional additional data for the action.
    func sendUIAction(componentId: String, actionId: String, payload: [String: Any]? = nil) {
        var message: [String: Any] = [
            "type": "ui.action",
            "id": componentId,
            "action": actionId
        ]
        if let payload = payload {
            message["payload"] = payload
        }
        sendJSON(message)
        pendingConfirmation = nil
    }

    /// Sends a UI action and AWAITS the correlated server outcome (the tool re-call's
    /// `tool.result`, a `tool.error`, or an `llm_error`). Resolves optimistically after
    /// `uiActionAckTimeout` if no signal arrives, so the card never hangs. Always
    /// resumes the continuation exactly once.
    ///
    /// Correlation is single-slot, not by id: the agent loop pauses on a UI action so
    /// only one confirm action can be outstanding, and the next server outcome is it.
    /// Cancel/dismiss is NOT routed here — `ToolConfirmActionHandler` resolves those locally.
    @MainActor
    func sendUIActionAwaitingOutcome(componentId: String, actionId: String, payload: [String: Any]? = nil) async -> UIActionOutcome {
        // Replace any stale pending ack (shouldn't happen — loop is paused — but be safe).
        if let stale = pendingUIActionAck {
            pendingUIActionAck = nil
            pendingUIActionAckTimeout?.cancel()
            pendingUIActionAckTimeout = nil
            // Abandoned without a confirmed outcome — don't claim success we can't verify.
            stale.continuation.resume(returning: UIActionOutcome(success: false, result: nil, error: nil))
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<UIActionOutcome, Never>) in
            pendingUIActionAck = (componentId: componentId, continuation: continuation)

            // Bounded fallback: if no server outcome arrives within the window (which
            // exceeds the server's own 60s action pause), the action did not run —
            // resolve FAILURE so the card never falsely reports success.
            let timeout = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.resolveUIActionAck(success: false, result: nil,
                                        error: "Timed out waiting for this action to run.",
                                        viaTimeout: true)
            }
            pendingUIActionAckTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.uiActionAckTimeout, execute: timeout)

            // Fire the action AFTER the slot is armed so a synchronous-fast server
            // reply can't race ahead of the resolver being in place.
            sendUIAction(componentId: componentId, actionId: actionId, payload: payload)
        }
    }

    /// Resolves the pending UI-action ack (if any) with a server outcome. Idempotent:
    /// no-op when no ack is pending. Called from the event switch on the next
    /// tool.result / tool.error / llm_error after a confirm action is sent.
    /// All pending-ack state lives on the main queue (the timeout fires on main and
    /// the continuation is armed on main), so hop to main if a future change ever
    /// dispatches the receive callback off-main — never crash, never race the slot.
    /// - Parameter viaTimeout: true when fired by the bounded-timeout fallback.
    /// - Parameter componentId: when the server echoes the originating card's id
    ///   (chained tool.result/tool.error now carry it), resolve only if it matches
    ///   the pending slot — so an unrelated tool.result can't steal the ack. A nil
    ///   componentId (timeout, or a server outcome without one) resolves the slot.
    func resolveUIActionAck(success: Bool, result: String?, error: String?, componentId: String? = nil, viaTimeout: Bool = false) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.resolveUIActionAck(success: success, result: result, error: error, componentId: componentId, viaTimeout: viaTimeout)
            }
            return
        }
        guard let pending = pendingUIActionAck else { return }
        if let cid = componentId, cid != pending.componentId { return }   // not this card's outcome
        pendingUIActionAck = nil
        pendingUIActionAckTimeout?.cancel()
        pendingUIActionAckTimeout = nil
        if viaTimeout {
            AppLogger.shared.warn("[Realtime] UI action \(pending.componentId) ack timed out — resolving as failed (action did not run)")
        } else {
            AppLogger.shared.debug("[Realtime] UI action \(pending.componentId) resolved (success: \(success))")
        }
        pending.continuation.resume(returning: UIActionOutcome(success: success, result: result, error: error))
    }

    /// Pre-flight check: a cloud provider that requires an API key must have a
    /// non-empty one before we send. Surfaces `ClientError.missingAPIKey` to the
    /// user via the persistent error banner (with a jump to Models settings) and
    /// returns `false` so the caller bails WITHOUT sending an empty key over the
    /// wire. Local/Ollama (`requiresAPIKey == false`) always pass.
    /// - Returns: `true` if it is safe to send, `false` if the send was blocked.
    private func ensureAPIKeyPresent() -> Bool {
        let provider = ChatProvider.current
        guard provider.requiresAPIKey else { return true }
        let key = KeychainStore.get(forAccount: provider.apiKeyStorageKey) ?? ""
        guard key.isEmpty else { return true }

        let clientError = ClientError.missingAPIKey(provider.displayName)
        // A missing key is a settings state the banner below resolves, not a
        // settings state, not a fault — warn avoids noisy error-level logs.
        AppLogger.shared.warn("[Realtime] Blocked send — \(clientError)")
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .showErrorBanner,
                object: ChatBannerError(
                    code: "missing_api_key",
                    message: clientError.errorDescription ?? "No API key configured.",
                    actionLabel: "Open Settings",
                    action: .openModelsSettings
                )
            )
        }
        return false
    }

    /// Sends a typed text message through the WebSocket.
    /// Used when realtime mode is enabled and user types in the chat input.
    /// - Parameter text: The user's message text.
    func sendTextMessage(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Block before any reconnect/send if the active cloud provider has no key.
        guard ensureAPIKeyPresent() else { return }

        if !isConnected {
            AppLogger.shared.info("[Realtime] Not connected, attempting reconnect before sending text")
            connect()
            waitForConnection { [weak self] connected in
                guard let self, connected else { return }
                self.sendTextMessage(text)
            }
            return
        }

        // Clear previous state
        currentTranscript = ""
        currentResponse = ""

        // Track conversation for persistence
        if conversationId == nil {
            conversationId = MessageStore.shared.currentConversationId
        }

        // A response is now expected — set the guard so a mid-flight reconnect
        // doesn't tear down the socket before response.done arrives. Cleared on
        // response.done / error / abort.
        isResponding = true
        turnStartTime = Date()
        sendJSON([
            "type": "text.message",
            "text": text
        ])
        AppLogger.shared.info("[Realtime] Sent text message (\(text.count) chars)")
    }

    /// Sends a multimodal message (text + images) over WebSocket for vision chat.
    func sendMultimodalMessage(text: String, images: [String]) {
        guard !images.isEmpty else {
            sendTextMessage(text)
            return
        }

        // Block before any reconnect/send if the active cloud provider has no key.
        guard ensureAPIKeyPresent() else { return }

        if !isConnected {
            AppLogger.shared.info("[Realtime] Not connected, attempting reconnect before sending multimodal")
            connect()
            waitForConnection { [weak self] connected in
                guard let self, connected else { return }
                self.sendMultimodalMessage(text: text, images: images)
            }
            return
        }

        currentTranscript = ""
        currentResponse = ""

        if conversationId == nil {
            conversationId = MessageStore.shared.currentConversationId
        }

        // Wire shape is flat: server's buildUserContent() owns the text/image
        // ordering and multi-image prefix. Swift just ships the raw inputs.
        let payload: [String: Any] = [
            "type": "text.message",
            "text": text,
            "images": images,
        ]
        // A response is now expected — guard against mid-flight reconnect teardown.
        isResponding = true
        sendJSON(payload)
        AppLogger.shared.info("[Realtime] Sent multimodal message: \(images.count) images + text")
    }

    // MARK: - Message Persistence

    /// Persists a user transcript message to the local MessageStore.
    func persistUserMessage(_ text: String) {
        guard !text.isEmpty else { return }
        DispatchQueue.main.async {
            let message = ChatMessage(text: text, isUser: true)
            MessageStore.shared.addMessage(message)
        }
    }
}
