//
//  MessageStore.swift
//  Dottie
//
//  Created by Steve Derico on 6/29/25.
//

import Foundation

// MARK: - Debouncer

/// Simple debouncer to avoid excessive saves.
/// Delays execution until the specified interval elapses without a new call.
class Debouncer {
    private let delay: TimeInterval
    private var workItem: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.example.dottie.debouncer")

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func debounce(action: @escaping () -> Void) {
        queue.sync {
            workItem?.cancel()
            let item = DispatchWorkItem(block: action)
            self.workItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    func cancel() {
        queue.sync {
            workItem?.cancel()
            workItem = nil
        }
    }

    /// Executes any pending work immediately, then cancels.
    func flush() {
        queue.sync {
            if let work = workItem {
                work.perform()
                workItem = nil
            }
        }
    }
}

// MARK: - Message Store

/// Singleton that owns all conversation data.
/// Loads conversations from the agent SQLite store via REST API.
/// The agent service is the single source of truth for message CONTENT
/// (role/content/toolCalls/thinking/stats/timestamp): the realtime streaming
/// pipeline upserts every user + assistant message server-side as it streams.
/// Swift is a thin UI client — it reads that content back on load and only
/// PUSHES metadata the server does not author from the stream: the title, and
/// a one-time safety sync of messages that exist ONLY in Swift memory and were
/// never streamed (e.g. cleared conversations). Swift never re-PUTs the full
/// message array on its routine debounced/streaming-end syncs, so it can no
/// longer clobber what the server just wrote.
/// Throttles SwiftUI view updates during streaming to ~20/sec.
class MessageStore: ObservableObject {
    static let shared = MessageStore()

    var conversations: [Conversation] = []
    var currentConversationId: UUID?
    @Published var suggestedFollowup: String?
    @Published var isLoading: Bool = true

    private let maxMessagesPerConversation = 500
    private let syncDebouncer = Debouncer(delay: 0.5)

    /// Throttle state for streaming updates (~20 updates/sec)
    private var streamThrottleItem: DispatchWorkItem?
    private var lastViewUpdate: Date = .distantPast
    private let throttleInterval: TimeInterval = 0.05

    // Computed property for current conversation's messages
    var currentMessages: [ChatMessage] {
        guard let id = currentConversationId,
              let conversation = conversations.first(where: { $0.id == id }) else {
            return []
        }
        return conversation.messages
    }

    private init() {
        // Create an initial conversation immediately so user can start chatting
        // Sessions will load in background and merge/replace as needed
        let initial = Conversation()
        conversations = [initial]
        currentConversationId = initial.id
    }

    // MARK: - API Loading

    /// Loads conversations from agent SQLite store with retry until ready.
    /// Retries with exponential backoff (1s, 2s, 4s, 8s, 16s) until sessions endpoint is ready.
    ///
    /// - Parameter completion: Called when loading completes (success or failure).
    func loadConversationsFromAPI(completion: @escaping () -> Void = {}) {
        isLoading = true
        loadWithRetry(attempt: 0, maxAttempts: 6, completion: completion)
    }

    /// Internal retry loop for loading sessions.
    /// Waits for sessionsReady=true before fetching, with exponential backoff.
    private func loadWithRetry(attempt: Int, maxAttempts: Int, completion: @escaping () -> Void) {
        // First check if sessions endpoint is ready
        GatewayClient.shared.checkSessionsReady { [weak self] ready in
            guard let self = self else {
                completion()
                return
            }

            if !ready && attempt < maxAttempts {
                // Not ready yet — retry with exponential backoff
                let delay = pow(2.0, Double(attempt))  // 1, 2, 4, 8, 16, 32 seconds
                AppLogger.shared.debug("[MessageStore] Sessions not ready, retry \(attempt + 1)/\(maxAttempts) in \(delay)s")
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self.loadWithRetry(attempt: attempt + 1, maxAttempts: maxAttempts, completion: completion)
                }
                return
            }

            // Either ready or exhausted retries — fetch sessions
            self.fetchAndLoadSessions(completion: completion)
        }
    }

    /// Fetches sessions from agent and populates conversations array.
    /// Always launches on a fresh empty chat (the initial conversation from init);
    /// prior sessions go into the sidebar below.
    private func fetchAndLoadSessions(completion: @escaping () -> Void) {
        GatewayClient.shared.fetchAgentSessions { [weak self] sessions in
            guard let self = self else {
                completion()
                return
            }

            // Re-read the current id/conversation INSIDE the callback. The fetch
            // (with up to 32s of retry backoff) ran while the user could still
            // create conversations — e.g. LauncherView.sendMessage doesn't gate
            // on isLoading and calls createNewConversation()/addMessage()
            // directly. Capturing these before the async call and doing a
            // wholesale `self.conversations = loaded` would silently drop any
            // conversation created during the fetch window. Snapshotting now,
            // then merging below, preserves them.
            let currentId = self.currentConversationId
            let currentConv = self.conversations.first { $0.id == currentId }

            if sessions.isEmpty {
                // No saved sessions — keep the initial conversation
                self.isLoading = false
                self.objectWillChange.send()
                completion()
                return
            }

            // Convert FullAgentSessions to Conversations
            var loadedConversations = sessions.compactMap { session -> Conversation? in
                guard let uuid = UUID(uuidString: session.id) else {
                    // Voice sessions use `realtime_<ts>` ids (not UUIDs) and are
                    // intentionally not surfaced in the sidebar — they still live
                    // in agent.db. Debug-level so this doesn't flood the log with
                    // ~25 warn lines on every fetch.
                    AppLogger.shared.debug("[MessageStore] Skipping non-UUID session: \(session.id)")
                    return nil
                }
                let conv = session.toConversation()
                return Conversation(id: uuid, title: session.title, messages: conv.messages, createdAt: session.createdAt, lastMessageAt: session.updatedAt)
            }

            // Preserve any in-memory conversation that isn't represented in the
            // fetched server set — these were created during the fetch window
            // (e.g. via the launcher) and may carry a just-typed user message
            // not yet persisted server-side. Without this merge the wholesale
            // assignment below would discard them and lose that message.
            let loadedIds = Set(loadedConversations.map { $0.id })
            let inMemoryOnly = self.conversations.filter { !loadedIds.contains($0.id) && $0.id != currentConv?.id }
            loadedConversations.append(contentsOf: inMemoryOnly)

            // Sort by most recent first
            loadedConversations.sort { $0.lastMessageAt > $1.lastMessageAt }

            // Keep the in-memory empty initial conversation as current so
            // relaunch shows a fresh chat; prior sessions populate the sidebar
            // below. Empty conversations don't persist (nothing is written
            // server-side until the first user message), so this doesn't
            // accumulate empty rows.
            if let conv = currentConv {
                loadedConversations.removeAll { $0.id == conv.id }
                loadedConversations.insert(conv, at: 0)
                self.conversations = loadedConversations
                self.currentConversationId = conv.id
            } else {
                self.conversations = loadedConversations
                self.currentConversationId = loadedConversations.first?.id
            }

            self.cleanupStuckLoadingMessages()

            self.isLoading = false
            self.objectWillChange.send()
            completion()
        }
    }

    /// Removes any messages with `isLoading` still true from all conversations.
    /// These can persist if the app crashes or is force-quit during streaming.
    private func cleanupStuckLoadingMessages() {
        var didCleanup = false
        for i in 0..<conversations.count {
            let before = conversations[i].messages.count
            conversations[i].messages.removeAll { $0.isLoading }
            if conversations[i].messages.count < before {
                didCleanup = true
            }
        }
        if didCleanup {
            // Stuck-loading rows are CONTENT we are removing from the server's
            // stored array, so this is one of the explicit content-mutating
            // syncs that must push the (reduced) messages, not a metadata sync.
            for conversation in conversations where !conversation.messages.isEmpty {
                pushMessagesToServer(id: conversation.id)
            }
        }
    }

    // MARK: - Conversation Management

    /// Creates a new empty conversation, inserts it at the top, and switches to it.
    /// Stops any playing audio before creating. Optionally requests a greeting.
    /// Syncs the new session to the agent SQLite store.
    ///
    /// - Parameter withGreeting: If true, fires `conversation_started` event to generate a greeting.
    func createNewConversation(withGreeting: Bool = false) {
        RealtimeClient.shared.stopTTS()
        let performCreate = {
            let newConversation = Conversation()
            self.conversations.insert(newConversation, at: 0)
            self.currentConversationId = newConversation.id
            self.objectWillChange.send()

            // Rotate the realtime WebSocket onto the new conversation. Without this
            // the socket keeps its old conversation_id query param and every message
            // persists to the stale session, leaking state across chats.
            RealtimeClient.shared.switchConversation(to: newConversation.id)

            // Create session in agent SQLite store
            GatewayClient.shared.createAgentSession(id: newConversation.id, title: newConversation.title) { _ in
                // Fire and forget — session will be created
            }

            // Request greeting if enabled
            if withGreeting {
                self.requestGreeting()
            }
        }

        if Thread.isMainThread {
            performCreate()
        } else {
            DispatchQueue.main.async {
                performCreate()
            }
        }
    }

    /// Fires the `conversation_started` trigger to generate a greeting message.
    /// Creates a loading placeholder, streams the response, and updates the message.
    /// Waits briefly for agent service to be ready before requesting.
    func requestGreeting() {
        // Delay slightly to ensure agent service is ready after app launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.performGreetingRequest()
        }
    }

    /// Internal method that performs the actual greeting request. Retries while
    /// the agent is still coming up (common on cold launch) instead of silently
    /// dropping the greeting — previously any New Chat/`/new` during startup
    /// just never got one.
    private func performGreetingRequest(attempt: Int = 0) {
        let maxAttempts = 5
        GatewayClient.shared.checkAgentHealth { [weak self] isHealthy in
            guard isHealthy else {
                guard attempt + 1 < maxAttempts else {
                    AppLogger.shared.warn("[MessageStore] Agent not healthy after \(maxAttempts) checks — skipping greeting")
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self?.performGreetingRequest(attempt: attempt + 1)
                }
                return
            }

            DispatchQueue.main.async {
                self?.startGreetingStream()
            }
        }
    }

    /// Streams a greeting from the gateway via SSE.
    private func startGreetingStream() {
        let greetingMessage = ChatMessage(text: "", isUser: false, isLoading: true)
        let messageId = greetingMessage.id
        // Capture the conversation the greeting streams into. If the user
        // switches conversations before onComplete fires, `currentMessages`
        // would resolve against the NEW conversation and the lookup would miss,
        // leaving the placeholder stuck with isLoading=true forever. Looking up
        // by the captured conversation id keeps finalization correct.
        let greetingConvId = currentConversationId
        addMessage(greetingMessage)

        GatewayClient.shared.fireEvent("conversation_started", conversationId: currentConversationId) { [weak self] text in
            DispatchQueue.main.async {
                // Deltas go through updateMessage (throttled ~20/sec). It now
                // resolves the target by message id across conversations, so even
                // if the user switches mid-stream the deltas still land on the
                // greeting placeholder. The onComplete finalizer below also
                // targets the captured conversation, so finalization is correct
                // regardless of which conversation is active.
                self?.updateMessage(id: messageId, text: text, isLoading: true, isStreaming: true)
            }
        } onComplete: { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success:
                    let existingText = greetingConvId
                        .flatMap { id in self.conversations.first(where: { $0.id == id }) }?
                        .messages.first(where: { $0.id == messageId })?.text ?? ""
                    self.updateGreetingMessage(convId: greetingConvId, messageId: messageId, text: existingText, isLoading: false, isStreaming: false)
                case .failure(let error):
                    AppLogger.warn("[MessageStore] greeting stream failed, using fallback text: \(error)")
                    self.updateGreetingMessage(convId: greetingConvId, messageId: messageId, text: "Hello! How can I help?", isLoading: false, isStreaming: false)
                }
            }
        }
    }

    /// Updates the greeting placeholder in the conversation it was created in,
    /// regardless of which conversation is currently active. `updateMessage`
    /// always targets `currentConversationId`, so it can't be used once the user
    /// has switched away mid-greeting.
    private func updateGreetingMessage(convId: UUID?, messageId: UUID, text: String, isLoading: Bool, isStreaming: Bool) {
        guard let convId = convId,
              let convIndex = conversations.firstIndex(where: { $0.id == convId }),
              let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == messageId }) else { return }
        conversations[convIndex].messages[msgIndex].text = text
        conversations[convIndex].messages[msgIndex].isLoading = isLoading
        conversations[convIndex].messages[msgIndex].isStreaming = isStreaming
        objectWillChange.send()
    }

    /// Switches the active conversation to the one matching `id`.
    /// Stops any playing audio before switching.
    /// - Parameter id: The conversation UUID to switch to.
    func switchConversation(_ id: UUID) {
        RealtimeClient.shared.stopTTS()
        let performSwitch = {
            guard self.conversations.contains(where: { $0.id == id }) else { return }
            self.currentConversationId = id
            self.objectWillChange.send()
            RealtimeClient.shared.switchConversation(to: id)
        }

        if Thread.isMainThread {
            performSwitch()
        } else {
            DispatchQueue.main.async {
                performSwitch()
            }
        }
    }

    /// Deletes all conversations and creates a single fresh one.
    func clearAllConversations() {
        let performClear = {
            self.syncDebouncer.cancel()

            // Delete all sessions from agent store
            let ids = self.conversations.map { $0.id }
            for id in ids {
                GatewayClient.shared.deleteAgentSession(id) { _ in }
            }

            self.conversations.removeAll()

            // Create a fresh conversation
            self.createNewConversation()
            self.objectWillChange.send()
        }

        if Thread.isMainThread {
            performClear()
        } else {
            DispatchQueue.main.async {
                performClear()
            }
        }
    }

    /// Sets an immediate 50-char preview title, then asynchronously generates
    /// a 2-5 word LLM title via the agent service and updates on success.
    /// Syncs title to agent SQLite store.
    func generateTitle(for conversationId: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationId }) else { return }

        guard let firstUserMessage = conversations[index].messages.first(where: { $0.isUser }) else { return }
        let text = firstUserMessage.text

        // Immediate preview fallback
        let previewTitle = text.count > 50 ? String(text.prefix(50)) + "..." : text
        conversations[index].title = previewTitle

        // Sync preview title to agent store
        GatewayClient.shared.updateAgentSessionTitle(id: conversationId, title: previewTitle) { _ in }

        // Async LLM title generation
        GatewayClient.shared.generateConversationTitle(for: text) { [weak self] title in
            guard let title = title else { return }
            DispatchQueue.main.async {
                guard let self = self,
                      let idx = self.conversations.firstIndex(where: { $0.id == conversationId }) else { return }
                self.conversations[idx].title = title
                self.objectWillChange.send()

                // Sync final title to agent store
                GatewayClient.shared.updateAgentSessionTitle(id: conversationId, title: title) { _ in }
            }
        }
    }

    /// Updates the title of a conversation and syncs to agent store.
    ///
    /// - Parameters:
    ///   - conversationId: The UUID of the conversation to update.
    ///   - title: The new title to set.
    func updateConversationTitle(_ conversationId: UUID, title: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationId }) else { return }
        conversations[index].title = title
        objectWillChange.send()
        GatewayClient.shared.updateAgentSessionTitle(id: conversationId, title: title) { _ in }
    }

    /// Clears all messages in the current conversation.
    func clearCurrentConversation() {
        let performClear = {
            guard let conversationId = self.currentConversationId,
                  let index = self.conversations.firstIndex(where: { $0.id == conversationId }) else { return }
            self.conversations[index].messages.removeAll()
            self.conversations[index].title = "New conversation"
            self.suggestedFollowup = nil
            self.objectWillChange.send()

            // Persist the cleared state through the server, the writer-of-record
            // for message content. The realtime WS is bound to the current
            // conversation, and its `conversation.clear` handler resets both the
            // in-memory history and the DB row via clearSession. We can't clear
            // via an empty-array PUT anymore — the server rejects empty arrays to
            // prevent stray syncs from blanking populated rows, and there is no
            // dedicated REST clear endpoint, so the WS is the only path.
            //
            // `sendJSON` is a silent no-op when the socket is nil/dead, which
            // would drop the clear and let the conversation reappear on next
            // load. If we're disconnected, reconnect first (the socket is bound
            // to this conversation, so the reconnect preserves the binding) and
            // send the clear once connected — mirroring sendTextMessage's
            // reconnect-then-send pattern.
            let convIdToClear = conversationId
            if RealtimeClient.shared.isConnected {
                RealtimeClient.shared.sendJSON(["type": "conversation.clear"])
            } else {
                RealtimeClient.shared.connect()
                RealtimeClient.shared.waitForConnection { connected in
                    guard connected else { return }
                    // Only send if the socket is still bound to the conversation
                    // we cleared — if the user switched while we reconnected, the
                    // server-side clear would target the wrong session.
                    guard RealtimeClient.shared.conversationId == convIdToClear else { return }
                    RealtimeClient.shared.sendJSON(["type": "conversation.clear"])
                }
            }
        }

        if Thread.isMainThread {
            performClear()
        } else {
            DispatchQueue.main.async {
                performClear()
            }
        }
    }

    /// Adds a system message (e.g., compaction notification) to the current conversation.
    func addSystemMessage(_ text: String) {
        let systemMessage = ChatMessage(text: text, isUser: false, isSystemMessage: true)
        addMessage(systemMessage)
    }

    /// Resolves the conversation index that actually contains `messageId`.
    ///
    /// Streaming updates and finalization are keyed by message id, not by which
    /// conversation happens to be active. If the user switches conversations
    /// mid-response, the in-flight placeholder still lives in the conversation it
    /// was created in — but `currentConversationId` now points elsewhere. Looking
    /// the message up across conversations (current first, then a scan) keeps
    /// those updates landing on the right placeholder instead of silently
    /// no-op-ing and stranding it with `isLoading == true` forever.
    private func conversationIndex(containingMessage messageId: UUID) -> Int? {
        // Fast path: the common case is the message is in the active conversation.
        if let convId = currentConversationId,
           let index = conversations.firstIndex(where: { $0.id == convId }),
           conversations[index].messages.contains(where: { $0.id == messageId }) {
            return index
        }
        // Fallback: the user switched conversations while a response was in
        // flight — find whichever conversation owns this message id.
        return conversations.firstIndex { $0.messages.contains(where: { $0.id == messageId }) }
    }

    /// Removes a message by ID (e.g., to clean up a loading placeholder on error).
    func removeMessage(id: UUID) {
        // Resolve across conversations: an error cleanup can fire after the user
        // has switched away from the conversation the placeholder lives in.
        guard let index = conversationIndex(containingMessage: id) else { return }
        let convId = conversations[index].id
        conversations[index].messages.removeAll { $0.id == id }
        objectWillChange.send()
        // Removing a message mutates CONTENT the server stored, so push the
        // reduced array (only when non-empty — the server rejects empty arrays,
        // and a bare loading placeholder was never persisted server-side anyway).
        if !conversations[index].messages.isEmpty {
            pushMessagesToServer(id: convId)
        }
    }

    // MARK: - Message Management

    /// Appends a message to the current conversation.
    /// Triggers title generation on the first user message and trims oldest messages
    /// when the conversation exceeds `maxMessagesPerConversation`.
    /// Syncs to agent SQLite store via API.
    /// - Parameter message: The message to append.
    func addMessage(_ message: ChatMessage) {
        let performAdd = {
            // Auto-create conversation if none exists (handles heartbeat race condition)
            if self.currentConversationId == nil || self.conversations.isEmpty {
                let newConversation = Conversation()
                self.conversations.insert(newConversation, at: 0)
                self.currentConversationId = newConversation.id
                self.isLoading = false  // Clear loading overlay so UI shows messages
                GatewayClient.shared.createAgentSession(id: newConversation.id, title: newConversation.title) { _ in }
            }

            guard let convId = self.currentConversationId,
                  let index = self.conversations.firstIndex(where: { $0.id == convId }) else { return }

            self.conversations[index].messages.append(message)
            self.conversations[index].lastMessageAt = Date()

            // Generate title from first user message
            if message.isUser && self.conversations[index].title == "New conversation" {
                self.generateTitle(for: self.conversations[index].id)
            }

            // Trim old messages if we exceed the limit
            if self.conversations[index].messages.count > self.maxMessagesPerConversation {
                let excess = self.conversations[index].messages.count - self.maxMessagesPerConversation
                self.conversations[index].messages.removeFirst(excess)
            }

            self.objectWillChange.send()

            // No-loss safety net for the brand-new-conversation gap. The server
            // is the writer-of-record for message content and upserts the user
            // message before the LLM call — but the very FIRST user message of a
            // brand-new conversation has, for a brief window, only ever lived in
            // Swift RAM. If the WS turn were never sent (e.g. the socket failed
            // to send and the user quit), that message would be lost on relaunch.
            //
            // So for the first user message ONLY, push the array once,
            // immediately (no debounce). At that instant the array is exactly
            // [user] — there is no assistant content yet, anywhere — so this push
            // cannot clobber any server-written assistant message. The server's
            // own per-turn upsert (realtime.js, before the LLM call) writes the
            // same [user] and then [user, assistant]; either write order is
            // lossless for the user message.
            //
            // For all subsequent messages (assistant content, or later user
            // turns in an existing conversation), Swift does NOT push the array:
            // the realtime stream is the writer-of-record and pushing a stale
            // Swift snapshot could clobber a just-written assistant turn. Only
            // metadata (title) is synced.
            let isFirstUserMessage = message.isUser
                && self.conversations[index].messages.filter({ $0.isUser }).count == 1
            if isFirstUserMessage {
                self.pushMessagesToServer(id: convId)
            } else {
                self.syncDebouncer.debounce {
                    self.syncConversation(id: convId)
                }
            }
        }

        if Thread.isMainThread {
            performAdd()
        } else {
            DispatchQueue.main.async {
                performAdd()
            }
        }
    }

    /// Updates an existing message in the current conversation by ID.
    /// Throttles SwiftUI `objectWillChange` notifications to ~20/sec during streaming.
    /// Syncs to agent SQLite store via API (debounced).
    /// - Parameters:
    ///   - id: Message UUID to update.
    ///   - text: Replacement response text.
    ///   - isLoading: Whether the message is still waiting for content.
    ///   - thinkingContent: Optional thinking/reasoning text from the model.
    ///   - toolCalls: Optional updated tool call state array.
    ///   - isStreaming: Whether tokens are still arriving; controls throttling.
    func updateMessage(id: UUID, text: String, isLoading: Bool, thinkingContent: String? = nil, toolCalls: [ToolCall]? = nil, isStreaming: Bool? = nil) {
        let performUpdate = {
            // Resolve by message id across conversations, not by the active one.
            // A streaming delta or finalization can arrive after the user has
            // switched conversations; the placeholder still lives in the
            // conversation it was created in. Keying off currentConversationId
            // would miss it and leave the placeholder stuck at isLoading == true.
            guard let convIndex = self.conversationIndex(containingMessage: id) else { return }
            if let msgIndex = self.conversations[convIndex].messages.firstIndex(where: { $0.id == id }) {
                self.conversations[convIndex].messages[msgIndex].text = text
                self.conversations[convIndex].messages[msgIndex].isLoading = isLoading
                if let streaming = isStreaming {
                    self.conversations[convIndex].messages[msgIndex].isStreaming = streaming
                }
                if let thinking = thinkingContent {
                    self.conversations[convIndex].messages[msgIndex].thinkingContent = thinking
                    // Set thinkingStartedAt when thinking content first appears
                    if !thinking.isEmpty && self.conversations[convIndex].messages[msgIndex].thinkingStartedAt == nil {
                        self.conversations[convIndex].messages[msgIndex].thinkingStartedAt = Date()
                    }
                }
                // Record TOTAL round-trip duration (send → done) when the message
                // completes — `thinkingStartedAt` is stamped at placeholder creation
                // (send time). This mirrors LauncherView's `totalElapsedMs` so both
                // surfaces report the same end-to-end number, not the old
                // send→first-token span.
                if isLoading == false,
                   let startedAt = self.conversations[convIndex].messages[msgIndex].thinkingStartedAt,
                   self.conversations[convIndex].messages[msgIndex].thinkingDuration == nil {
                    self.conversations[convIndex].messages[msgIndex].thinkingDuration = Int(Date().timeIntervalSince(startedAt) * 1000)
                }
                if let toolCalls = toolCalls {
                    self.conversations[convIndex].messages[msgIndex].toolCalls = toolCalls
                }

                // Throttle SwiftUI view updates during streaming (~20/sec)
                let isCurrentlyStreaming = isStreaming == true

                if isCurrentlyStreaming {
                    let now = Date()
                    let elapsed = now.timeIntervalSince(self.lastViewUpdate)
                    if elapsed >= self.throttleInterval {
                        self.lastViewUpdate = now
                        self.objectWillChange.send()
                    } else {
                        // Schedule trailing update to flush final state
                        self.streamThrottleItem?.cancel()
                        let item = DispatchWorkItem { [weak self] in
                            guard let self else { return }
                            self.lastViewUpdate = Date()
                            self.objectWillChange.send()
                        }
                        self.streamThrottleItem = item
                        DispatchQueue.main.asyncAfter(deadline: .now() + self.throttleInterval, execute: item)
                    }
                } else {
                    // Not streaming — flush immediately
                    self.streamThrottleItem?.cancel()
                    self.streamThrottleItem = nil
                    self.objectWillChange.send()
                }

                // No message sync here. The realtime stream is the
                // writer-of-record for assistant content: it upserts the
                // completed assistant message (content + toolCalls + thinking +
                // stats) server-side on response.done. Swift used to re-PUT its
                // entire in-memory array on stream-end, which raced and clobbered
                // exactly that server write — the bug this change removes.
            }
        }

        if Thread.isMainThread {
            performUpdate()
        } else {
            DispatchQueue.main.async {
                performUpdate()
            }
        }
    }

    /// Marks a message as stopped by the user mid-stream. Renders a visible
    /// "stopped" tag in the bubble so truncated responses are distinguishable
    /// from errors.
    ///
    /// `wasStopped` is Swift-only UI state: the standard-format normalizer
    /// strips it and the read model never decodes it back, so it was never
    /// durable across relaunch. We therefore do NOT sync it — the truncated
    /// assistant text the user stopped at IS persisted by the realtime stream
    /// (response.done fires with whatever was generated), only the "stopped"
    /// tag itself is ephemeral. No server write here.
    func markStopped(id: UUID) {
        let perform = {
            guard let convId = self.currentConversationId,
                  let convIndex = self.conversations.firstIndex(where: { $0.id == convId }),
                  let msgIndex = self.conversations[convIndex].messages.firstIndex(where: { $0.id == id }) else { return }
            self.conversations[convIndex].messages[msgIndex].wasStopped = true
            self.objectWillChange.send()
        }
        if Thread.isMainThread { perform() } else { DispatchQueue.main.async { perform() } }
    }

    // MARK: - API Sync

    /// Routine metadata sync for a conversation.
    ///
    /// The agent service's realtime streaming pipeline is the writer-of-record
    /// for message CONTENT (role/content/toolCalls/thinking/stats/timestamp) —
    /// it upserts every user + assistant message server-side as it streams. So
    /// this routine sync NO LONGER sends the messages array; doing so was the
    /// race that let Swift's in-memory copy clobber the server's freshly-written
    /// history (last-write-wins on the shared `messages` column).
    ///
    /// What still flows Swift→server here is metadata the server does not author
    /// from the stream: the conversation title. wasStopped is Swift-only UI state
    /// that the standard-format normalizer strips and the read model never
    /// decodes — nothing to push here.
    ///
    /// For the cases that genuinely MUTATE content from the Swift side (clearing
    /// a conversation, removing/cleaning up a message), call
    /// `pushMessagesToServer(id:)` explicitly — that is the only remaining path
    /// that replaces the server's messages array, and the server rejects an
    /// empty array so it can never blank a populated row.
    ///
    /// - Parameter id: Conversation UUID to sync.
    private func syncConversation(id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let title = conversations[index].title

        // Title is the only field the server stream does not own that we still
        // push routinely. Skip the placeholder so we don't overwrite a
        // server-/LLM-derived title with "New conversation".
        guard title != "New conversation" else { return }
        GatewayClient.shared.updateAgentSessionTitle(id: id, title: title) { success in
            if !success {
                AppLogger.warn("[MessageStore] failed to sync conversation title for \(id)")
            }
        }
    }

    /// Serializes the Swift in-memory message array to standard format.
    /// Used only by the explicit content-mutating sync (`pushMessagesToServer`)
    /// and the brand-new-conversation safety net — NOT by routine syncs.
    private func serializeMessages(_ conversation: Conversation) -> [[String: Any]] {
        return conversation.messages.compactMap { msg -> [String: Any]? in
            // Skip system messages (greeting marker, compaction notices). The
            // read path (FullAgentSession.toConversation) drops every
            // role=="system" message on reload, so writing them as role
            // "system" produced a write/read asymmetry: the server stored an
            // announcement that vanished after relaunch, and a system message at
            // index 0 could shift the rest of the array. Not serializing them
            // keeps write and read symmetric — the announcement was never
            // durable anyway, so nothing user-visible is lost.
            if msg.isSystemMessage { return nil }
            var dict: [String: Any] = [
                "role": msg.isUser ? "user" : "assistant",
                "content": msg.text,
                "id": msg.id.uuidString
            ]

            // Include tool calls if present
            if let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                dict["tool_calls"] = toolCalls.map { tc -> [String: Any] in
                    var tcDict: [String: Any] = [
                        "id": tc.id,
                        "name": tc.name,
                        "status": tc.status.rawValue
                    ]
                    if let result = tc.result { tcDict["result"] = result }
                    if let input = tc.input {
                        tcDict["input"] = input.mapValues { $0.value }
                    }
                    return tcDict
                }
            }

            // Include thinking content if present
            if let thinking = msg.thinkingContent, !thinking.isEmpty {
                dict["thinking_content"] = thinking
            }

            return dict
        }
    }

    /// Explicitly replaces the server's stored message array with the Swift
    /// in-memory copy. Reserved for the cases where Swift mutates CONTENT the
    /// server didn't (clearing a conversation, removing/cleaning up a message,
    /// or the brand-new-conversation safety net for a message that was never
    /// streamed). Routine streaming/markStopped paths must NOT call
    /// this — the realtime stream already persisted that content.
    ///
    /// The server rejects an empty messages array (it would otherwise blank a
    /// populated row), so callers that intend to truly empty a conversation
    /// should rely on the realtime `conversation.clear` path / delete instead.
    private func pushMessagesToServer(id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let conversation = conversations[index]
        let messages = serializeMessages(conversation)

        // Get current provider info. Resolve the model with the SAME logic the
        // real chat path uses (GatewayClient.chatConfigBody) so the session
        // metadata records the model that actually served the turn — for cloud
        // providers that means honoring the user's selectedCloudModel, falling
        // back to the first available model only when it's unset or no longer
        // valid for the current provider. Using availableModels.first here would
        // mislabel every cloud session with the wrong model.
        let provider = ChatProvider.current
        let cloudModel = UserDefaults.standard.string(forKey: DefaultsKeys.selectedCloudModel.rawValue) ?? ""
        let model: String
        if provider == .ollama || provider == .dottieLocal {
            // Same pass-through as chatConfigBody — no static catalog.
            model = cloudModel
        } else {
            let validForProvider = provider.availableModels.contains { $0.id == cloudModel }
            model = validForProvider ? cloudModel : (provider.availableModels.first?.id ?? "")
        }

        GatewayClient.shared.syncAgentSession(
            id: id,
            messages: messages,
            model: model,
            provider: provider.rawValue
        ) { success, status, error in
            if !success {
                AppLogger.shared.warn("[MessageStore] Failed to push messages for conversation \(id) to agent store (status: \(status))")
                if status == 401 { AgentManager.shared.handleGatewayAuthRejected(source: "session_sync") }
            }
        }
    }

    /// Flushes any pending debounced syncs immediately.
    /// Call this before app termination to ensure no messages are lost.
    func flushPendingSyncs() {
        syncDebouncer.flush()
    }
}
