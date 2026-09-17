//
//  AgentStateCoordinator.swift
//  Dottie
//
//  Singleton that observes all agent activity sources (recording, TTS, thinking)
//  and resolves the current display state using priority:
//  listening > speaking > thinking > idle
//

import Foundation
import Combine

/// Coordinates agent state across multiple signal sources and resolves
/// the highest-priority state for UI display. Also computes a normalized
/// `audioLevel` (0-1) for avatar animation: real spectrum data when listening,
/// sinusoidal simulation when speaking.
final class AgentStateCoordinator: ObservableObject {
    static let shared = AgentStateCoordinator()

    /// The resolved agent state based on current activity.
    @Published private(set) var currentState: AgentState = .idle

    /// Normalized audio level (0.0-1.0) for avatar reactivity.
    /// Derived from spectrum analyzer when listening, sinusoidal oscillation when speaking.
    @Published private(set) var audioLevel: Float = 0

    /// Live transcript text for realtime voice mode (displayed in the voice overlay).
    @Published var liveTranscript: String = ""

    /// True while one-shot voice dictation is armed (user said "start dictation").
    /// Drives an optional "Dictating…" UI hint; cleared when the dictated text
    /// lands at the cursor or the dictation is cancelled.
    @Published var dictationActive: Bool = false

    /// Live thinking text for realtime mode (displayed in thinking badge).
    @Published var liveThinking: String = ""

    /// Live response text for realtime voice mode.
    @Published var liveResponse: String = ""

    /// Message ID for the current realtime streaming response (for heartbeat-style updates).
    private var realtimeMessageId: UUID?
    /// Accumulated tool calls for the current realtime response.
    private var realtimeToolCalls: [ToolCall] = []

    private var cancellables = Set<AnyCancellable>()
    private var audioLevelCancellables = Set<AnyCancellable>()

    /// DisplayLink-driven timer for speaking simulation (~60fps).
    private var speakingTimer: Timer?

    /// Phase accumulator for sinusoidal speaking simulation.
    private var speakingPhase: Double = 0

    private init() {
        // Defer observer setup to avoid Combine firing during init
        DispatchQueue.main.async { [weak self] in
            self?.setupObservers()
            self?.subscribeToRealtimeEvents()
        }
    }

    // MARK: - Observer Setup

    /// Subscribes to GlobalRecorder and RealtimeClient state changes,
    /// and forwards audio level updates to the floating AvatarPanel.
    private func setupObservers() {
        // Observe recording state - dropFirst to skip initial value emission
        GlobalRecorder.shared.$isRecording
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)

        // Observe TTS playback state (unified through RealtimeClient)
        RealtimeClient.shared.$isPlayingTTS
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)

        // Observe TTS generating state (waiting for server to synthesize)
        RealtimeClient.shared.$isGeneratingTTS
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)

        // Observe full-duplex conversation state
        RealtimeClient.shared.$conversationState
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)

        // Forward audio level to floating AvatarPanel (~30fps throttle)
        $audioLevel
            .throttle(for: .milliseconds(33), scheduler: DispatchQueue.main, latest: true)
            .sink { level in
                AvatarPanelManager.shared.updateAudioLevel(level)
            }
            .store(in: &cancellables)
    }

    // MARK: - Audio Level Subscriptions

    /// Subscribes to spectrum analyzer levels (bass-weighted average) for listening state.
    private func startListeningLevels() {
        let analyzer = GlobalRecorder.shared.spectrumAnalyzer
        // Combine bass/mid/treble into a single level, weighting bass higher
        Publishers.CombineLatest3(
            analyzer.$bassLevel,
            analyzer.$midLevel,
            analyzer.$trebleLevel
        )
        .throttle(for: .milliseconds(33), scheduler: DispatchQueue.main, latest: true)
        .sink { [weak self] bass, mid, treble in
            // Weight bass higher for more dramatic mouth/pulse response
            let combined = (bass * 0.5 + mid * 0.3 + treble * 0.2)
            // Gain so quiet speech still moves the orb (was too small vs the
            // old full-screen bass glow).
            self?.audioLevel = min(1.0, max(0.0, combined * 2.2))
        }
        .store(in: &audioLevelCancellables)
    }

    /// Real-time RMS amplitude pushed by `pushSpeakingAudioLevel`. Read from the
    /// speaking timer to modulate the sinusoid's amplitude so the visible pulse
    /// scales with actual TTS volume (loud syllables = bigger pulses; silence =
    /// small pulses). Reset on `stopAudioLevels`.
    private var lastRMSAmplitude: Float = 0
    private var lastRMSAt: Date = .distantPast

    /// Hybrid speaking visualization: a sinusoid drives the *baseline* pulse
    /// rhythm (always visible, never gets stuck at a flat value), and real TTS
    /// RMS pushed via `pushSpeakingAudioLevel` modulates the *amplitude* of
    /// those pulses. So if the AI is speaking loudly, the pulses are big; if
    /// it's pausing or quiet, the pulses shrink. If the RMS push silently fails
    /// (race with state transition, format mismatch, anything), the sinusoid
    /// keeps the line moving — no static-line failure mode.
    private func startSpeakingSimulation() {
        speakingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // No TTS playing → decay toward zero (line falls flat between turns).
            guard RealtimeClient.shared.isPlayingTTS else {
                self.audioLevel = max(0, self.audioLevel - 0.05)
                return
            }
            // Sinusoid baseline (proven-visible from pre-2026.5.2.32).
            let t = Date().timeIntervalSinceReferenceDate
            let sinusoid = 0.4 + 0.3 * sin(t * 8) + 0.15 * sin(t * 13) + 0.1 * sin(t * 21)
            // RMS amplitude scales the sinusoid. If real RMS is fresh (<200ms),
            // use it; otherwise default to 1.0 (full sinusoid amplitude).
            let rmsRecent = Date().timeIntervalSince(self.lastRMSAt) < 0.2
            let amplitude: Float = rmsRecent
                ? min(1.5, max(0.3, self.lastRMSAmplitude * 4.0))
                : 1.0
            let level = Float(sinusoid) * amplitude
            self.audioLevel = min(1.0, max(0.0, level))
        }
    }

    /// Push a real audio level (0-1) sampled from a TTS audio chunk. Stores it
    /// for the next speaking-timer tick to use as the sinusoid's amplitude
    /// scalar. Decoupled from the timer so race conditions can't break it —
    /// the timer reads `lastRMSAmplitude` whenever it next fires.
    func pushSpeakingAudioLevel(_ level: Float) {
        lastRMSAmplitude = level
        lastRMSAt = Date()
    }

    /// Stops all audio level subscriptions and resets level to zero.
    private func stopAudioLevels() {
        audioLevelCancellables.removeAll()
        speakingTimer?.invalidate()
        speakingTimer = nil
        audioLevel = 0
    }

    // MARK: - State Resolution

    /// Resolves current state using priority: listening > speaking > thinking > idle.
    /// Manages audio level subscriptions: starts spectrum listening or speaking
    /// simulation on entry, stops on exit.
    private func recompute() {
        let newState: AgentState

        // Conversation mode states take priority when active
        let convState = RealtimeClient.shared.conversationState
        // The "Dictating…" hint is only valid while a conversation is live. If the
        // conversation ends by any path (avatar toggle, WS disconnect, full ESC),
        // the server has dropped its armed flag — clear the client hint too so it
        // can't stick on with nothing behind it.
        if convState == .inactive && dictationActive {
            dictationActive = false
        }
        if convState != .inactive {
            switch convState {
            case .userSpeaking:
                newState = .listening
            case .processing:
                newState = .thinking
            case .assistantSpeaking:
                newState = .speaking
            case .idle:
                newState = .listening // Subtle listening state — mic is on
            case .inactive:
                newState = .idle
            }
        } else if GlobalRecorder.shared.isRecording {
            newState = .listening
        } else if RealtimeClient.shared.isPlayingTTS {
            newState = .speaking
        } else if RealtimeClient.shared.isGeneratingTTS {
            newState = .thinking
        } else {
            newState = .idle
        }

        guard newState != currentState else { return }

        // Tear down previous audio level source
        stopAudioLevels()

        currentState = newState

        // Start new audio level source based on state
        switch newState {
        case .listening:
            startListeningLevels()
        case .speaking:
            startSpeakingSimulation()
        default:
            break
        }

        AvatarPanelManager.shared.updateState(newState)
        AppLogger.shared.debug("[AgentStateCoordinator] State changed to \(newState.rawValue)")

        // Conversation hear-me lives on the orb. The bottom spectrum is
        // dictation-only (GlobalRecorder). Never pin it to voice session.
        FullScreenSpectrumOverlayManager.shared.hide()
    }

    // MARK: - Realtime Event Subscription

    /// Subscribes to RealtimeClient events and routes them to UI.
    private func subscribeToRealtimeEvents() {
        RealtimeClient.shared.eventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self = self else { return }
                switch event {
                case .transcriptDelta(let delta):
                    self.liveTranscript += delta

                case .transcriptDone(let text):
                    self.liveTranscript = text
                    // User message already persisted by RealtimeClient.persistUserMessage
                    // Create placeholder for streaming response
                    let placeholder = ChatMessage(text: "", isUser: false, isLoading: true, thinkingStartedAt: Date())
                    MessageStore.shared.addMessage(placeholder)
                    self.realtimeMessageId = placeholder.id

                case .thinkingDelta(let delta):
                    self.liveThinking += delta
                    // Update message's thinkingContent for badge display
                    if let msgId = self.realtimeMessageId {
                        MessageStore.shared.updateMessage(id: msgId, text: self.liveResponse, isLoading: true, thinkingContent: self.liveThinking, isStreaming: true)
                    }

                case .responseDelta(let delta):
                    self.liveResponse += delta
                    // Emit heartbeat_delta for launcher streaming
                    if let msgId = self.realtimeMessageId {
                        MessageStore.shared.updateMessage(id: msgId, text: self.liveResponse, isLoading: true, thinkingContent: self.liveThinking.isEmpty ? nil : self.liveThinking, isStreaming: true)
                    }

                case .responseDone(let text):
                    self.liveResponse = text
                    // Finalize the streaming message with all accumulated metadata
                    if let msgId = self.realtimeMessageId {
                        MessageStore.shared.updateMessage(
                            id: msgId,
                            text: text,
                            isLoading: false,
                            thinkingContent: self.liveThinking.isEmpty ? nil : self.liveThinking,
                            toolCalls: self.realtimeToolCalls.isEmpty ? nil : self.realtimeToolCalls,
                            isStreaming: false
                        )
                        NotificationCenter.default.post(
                            name: .heartbeatEventReceived,
                            object: nil,
                            userInfo: ["type": "realtime_done", "text": text]
                        )
                    }
                    self.realtimeMessageId = nil
                    // Clear state for next interaction
                    self.liveTranscript = ""
                    self.liveThinking = ""
                    self.liveResponse = ""
                    self.realtimeToolCalls = []

                case .audioReceived:
                    // Audio playback is handled by RealtimeClient.playPCMAudio()
                    break

                case .connected:
                    AppLogger.shared.info("[AgentStateCoordinator] RealtimeClient connected")

                case .disconnected(let error):
                    if let error = error {
                        AppLogger.shared.warn("[AgentStateCoordinator] RealtimeClient disconnected: \(error)")
                    }

                case .error(let message):
                    AppLogger.shared.error("[AgentStateCoordinator] RealtimeClient error (\(message.count) chars)")

                case .structuredError(let code, let message, let recoverable, _):
                    AppLogger.shared.warn("[AgentStateCoordinator] RealtimeClient error [\(code)] (\(message.count) chars, recoverable: \(recoverable))")
                    // `empty_response` is a soft failure: the model returned
                    // no tokens but the session is healthy. The bubble's own
                    // "No response generated" inline placeholder + the
                    // persistent banner already tell the user what happened.
                    // Nuking the placeholder and adding a system message on
                    // top of those would triple-signal the same fact.
                    if code != "empty_response" {
                        if let msgId = self.realtimeMessageId {
                            MessageStore.shared.removeMessage(id: msgId)
                            MessageStore.shared.addSystemMessage(message)
                            self.realtimeMessageId = nil
                        }
                        self.liveTranscript = ""
                        self.liveThinking = ""
                        self.liveResponse = ""
                        self.realtimeToolCalls = []
                        NotificationCenter.default.post(
                            name: .heartbeatEventReceived,
                            object: nil,
                            userInfo: ["type": "realtime_done", "text": ""]
                        )
                    }

                case .toolStart(let id, let name, _):
                    self.realtimeToolCalls.append(ToolCall(id: id, name: name, status: .running))
                    // Update message with tool state during streaming
                    if let msgId = self.realtimeMessageId {
                        MessageStore.shared.updateMessage(id: msgId, text: self.liveResponse, isLoading: true, toolCalls: self.realtimeToolCalls, isStreaming: true)
                    }

                case .toolResult(_, let name, let result):
                    if let idx = self.realtimeToolCalls.lastIndex(where: { $0.name == name && $0.status == .running }) {
                        self.realtimeToolCalls[idx].status = .completed
                        self.realtimeToolCalls[idx].result = result
                    }
                    if let msgId = self.realtimeMessageId {
                        MessageStore.shared.updateMessage(id: msgId, text: self.liveResponse, isLoading: true, toolCalls: self.realtimeToolCalls, isStreaming: true)
                    }

                case .toolError(_, let name, let error):
                    // Tool re-call / execution failed — stop the spinner and mark the
                    // card failed (carries the error text in `result`).
                    if let idx = self.realtimeToolCalls.lastIndex(where: { $0.name == name && $0.status == .running }) {
                        self.realtimeToolCalls[idx].status = .error
                        self.realtimeToolCalls[idx].result = "Error: \(error)"
                    }
                    if let msgId = self.realtimeMessageId {
                        MessageStore.shared.updateMessage(id: msgId, text: self.liveResponse, isLoading: true, toolCalls: self.realtimeToolCalls, isStreaming: true)
                    }

                case .toolUI(let id, let component, let data, let actions):
                    NotificationCenter.default.post(
                        name: .heartbeatEventReceived,
                        object: nil,
                        userInfo: ["type": "tool_ui", "id": id, "component": component, "data": data, "actions": actions]
                    )

                case .sessionLoaded, .messagePersisted:
                    break

                case .followup(let text):
                    NotificationCenter.default.post(
                        name: .heartbeatEventReceived,
                        object: nil,
                        userInfo: ["type": "followup", "text": text]
                    )

                case .compaction:
                    // Conversation was compacted to fit context window
                    AppLogger.shared.info("[AgentStateCoordinator] Conversation compacted")

                case .sessionTitle(let convId, let title):
                    // Title generated for realtime conversation
                    DispatchQueue.main.async {
                        if let uuid = UUID(uuidString: convId) {
                            MessageStore.shared.updateConversationTitle(uuid, title: title)
                        }
                    }

                case .toolContextChanged:
                    break

                case .dictationArmed:
                    // One-shot dictation armed — show the hint. Must NOT create a
                    // streaming-response placeholder (this turn is not an LLM turn).
                    self.dictationActive = true

                case .dictationText:
                    // Dictated text was captured + pasted at the cursor; clear hint.
                    self.dictationActive = false
                }
            }
            .store(in: &cancellables)
    }

    /// Sets the message ID for realtime response streaming.
    /// Called by the chat UI when routing typed text through realtime WebSocket.
    /// - Parameter messageId: The placeholder message ID to update with response content.
    func setRealtimeMessageId(_ messageId: UUID) {
        realtimeMessageId = messageId
        liveTranscript = ""
        liveResponse = ""
    }
}
