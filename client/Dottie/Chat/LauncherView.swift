//
//  LauncherView.swift
//  Dottie
//
//  Created by Steve Derico on 2/26/26.
//

import SwiftUI
import AppKit

/// Spotlight-style launcher view with HUD blur background and inline response streaming.
/// Auto-resizes based on response content: 60px idle → 500px max with scrolling.
/// Renders rich content: thinking badges, tool call badges, markdown text.
struct LauncherView: View {
    @ObservedObject private var globalRecorder = GlobalRecorder.shared
    @ObservedObject private var messageStore = MessageStore.shared
    @ObservedObject private var launcherManager = LauncherManager.shared
    @ObservedObject private var gateway = GatewayClient.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var updateChecker = UpdateChecker.shared
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var appState: AppState
    @FocusState private var isTextFieldFocused: Bool
    @AppStorage("launcher.draft") private var inputText: String = ""
    @State private var isLoading: Bool = false
    @State private var lastSendTime: Date = Date.distantPast
    @State private var isSpeaking: Bool = false
    @State private var isGeneratingAudio: Bool = false
    @State private var historyIndex: Int = -1
    @ObservedObject private var configStore = ConfigStore.shared
    @State private var activeAssistantMessageId: UUID?
    @State private var launcherBanner: ChatBannerError?
    @State private var showingSystemReport: Bool = false
    /// Counts the engine_down banner down from 10s, then clears it and auto-resends
    /// the last user message. Cancelled when the banner leaves the engine_down state.
    @State private var engineDownCountdownTask: Task<Void, Never>? = nil
    /// Per-message UI state for the multi-turn history (launcher-native rendering).
    @State private var copiedMessageId: UUID?
    @State private var speakingMessageId: UUID?
    @State private var expandedThinking: Set<UUID> = []
    /// Manually attached images (file picker / paste) sent with the next message.
    @State private var pendingImages: [AttachedImage] = []
    /// Local Cmd+V monitor: pastes an image from the clipboard as an attachment
    /// (leaves text paste untouched). Removed on disappear.
    @State private var pasteMonitor: Any?
    private var isAnyProcessing: Bool {
        globalRecorder.isRecording || globalRecorder.isTranscribing || isLoading
    }

    /// Live loading label. Always "Thinking" — the tool pills below already show
    /// which tool is running (spinner) or done (✓), so naming the tool here too
    /// just duplicated the pill ("Using web search" next to a "web search" pill).
    private var loadingLabel: String { "Thinking" }

    /// Calculates the content height based on current state.
    /// Accounts for rich content: thinking badge, tool calls, markdown, images.
    /// Whether the launcher has response content visible below the input.
    private var hasResponseContent: Bool {
        !messageStore.currentMessages.isEmpty || launcherBanner != nil
    }

    /// Panel height. Idle = input only (capsule). Once a conversation has any
    /// messages the panel jumps to a FIXED expanded height and stays there — the
    /// message history scrolls inside it, so sending another turn never shrinks
    /// or resizes the box (the input row stays put while you type). Reset to idle
    /// only when the conversation is emptied (/clear, /new).
    private var calculatedHeight: CGFloat {
        messageStore.currentMessages.isEmpty ? 80 : expandedHeight
    }

    /// Fixed height of the expanded chat box (history scroll area + input row).
    private let expandedHeight: CGFloat = 560

    var body: some View {
        launcherStack
            .frame(width: 700)
            .fixedSize(horizontal: false, vertical: true)
            .background(launcherBackground)
            .clipShape(hasResponseContent ? RoundedRectangle(cornerRadius: 24) : RoundedRectangle(cornerRadius: 999))
            .overlay(launcherBorder)
            .overlay(alignment: .topLeading) { menuOverlay }
    }

    /// Background blur (capsule when collapsed, rounded rect when expanded).
    private var launcherBackground: some View {
        VisualEffectBlur(
            material: colorScheme == .dark ? .hudWindow : .popover,
            cornerRadius: hasResponseContent ? 24 : 0,
            capsule: !hasResponseContent
        )
    }

    @ViewBuilder private var launcherBorder: some View {
        if hasResponseContent {
            RoundedRectangle(cornerRadius: 24).stroke(Color.primary.opacity(0.1), lineWidth: 1)
        } else {
            Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 1)
        }
    }

    /// 3-dot menu, expanded state only (top-left of the chat container).
    @ViewBuilder private var menuOverlay: some View {
        if !messageStore.currentMessages.isEmpty {
            launcherMenu
                .padding(.top, 12)
                .padding(.leading, 14)
        }
    }

    private var launcherStack: some View {
        VStack(spacing: 0) {
            // System-problem banner — shown when the local stack is broken
            // (agent failed to start / crashed, or the engine process failed).
            // Most critical, so it sits above all other banners.
            // The whole banner group is indented when the 3-dot menu overlay is
            // visible (messages present) so banner icon/text never sit under it.
            Group {
                if hasSystemProblem {
                    systemProblemBanner
                }

                // App update banner.
                if updateChecker.updatePhase.shouldShowBanner {
                    updateBanner
                }

                // Error / resilience banner (no silent failures).
                if let banner = launcherBanner {
                    launcherBannerView(banner)
                }
            }
            .padding(.leading, messageStore.currentMessages.isEmpty ? 0 : 26)

            // Chat layout: the full conversation history renders ABOVE (scrollable)
            // and the input row stays pinned at the bottom. History
            // lives in messageStore.currentMessages so it persists across turns and
            // never resets/shrinks when a new message is sent. Initial empty state
            // shows only the input (capsule).
            if !messageStore.currentMessages.isEmpty {
                messageHistoryArea
            }

            // Manually attached images (file picker / paste) pending the next send.
            if !pendingImages.isEmpty {
                pendingImagesBar
            }

            // Input area (always visible) — bottom-anchored when messages are present.
            inputArea
        }
        .onChange(of: calculatedHeight) { _, newHeight in
            launcherManager.updateHeight(newHeight)
        }
        .onChange(of: globalRecorder.isRecording) { _, newValue in
            appState.isRecording = newValue
            if newValue {
                appState.recordingRequested = false
            }
        }
        .onAppear {
            focusTextField()
            installPasteMonitor()
        }
        .onDisappear {
            removePasteMonitor()
        }
        .onReceive(messageStore.objectWillChange) { _ in
            DispatchQueue.main.async {
                syncFromMessageStore()
            }
        }
        .onChange(of: isAnyProcessing) { _, newValue in
            if newValue {
                appState.startProcessing()
            } else {
                appState.stopProcessing()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherFocusTextField)) { _ in
            focusTextField()
        }
        .sheet(isPresented: $showingSystemReport) {
            SystemHealthSheet(isPresented: $showingSystemReport)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleRecording)) { _ in
            toggleRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sendChatMessage)) { notification in
            if let userInfo = notification.userInfo,
               let text = userInfo["text"] as? String {
                inputText = text
                sendChatMessage()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showErrorBanner)) { note in
            if let banner = note.object as? ChatBannerError {
                launcherBanner = banner
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clearErrorBanner)) { note in
            // Clear if the code matches (or no code specified).
            let code = note.userInfo?["code"] as? String
            if code == nil || code == launcherBanner?.code {
                launcherBanner = nil
            }
        }
        .onReceive(RealtimeClient.shared.eventPublisher) { event in
            handleRealtimeEvent(event)
        }
        .onChange(of: launcherBanner?.code) { _, newCode in
            // The countdown belongs to the engine_down banner only — stop it the
            // moment the banner is dismissed or replaced.
            if newCode != "engine_down" { cancelEngineDownCountdown() }
        }
    }

    private func handleRealtimeEvent(_ event: RealtimeEvent) {
        // Capture the agent's followup suggestion so the input placeholder shows it
        // and Tab accepts it (the WS path never set this — only the SSE path did).
        if case .followup(let text) = event {
            messageStore.suggestedFollowup = text
            return
        }
        guard case .structuredError(let code, let message, _, _) = event else { return }
        switch code {
        case "engine_down", "not_connected":
            // not_connected = the realtime WS wasn't up when the send fired (cold
            // launch / dropped socket). Route it through the engine_down path so it
            // gets the countdown + auto-retry instead of an infinite "Thinking…"
            // spinner (previously it hit `default` and spun ~8 min until
            // max_retries_exceeded). Finalize the stuck placeholder first.
            isLoading = false
            if let id = activeAssistantMessageId {
                messageStore.removeMessage(id: id)
                activeAssistantMessageId = nil
            }
            launcherBanner = ChatBannerError(
                code: "engine_down",
                message: engineDownMessage(10),
                actionLabel: "Restart Dottie",
                action: .restartAgent
            )
            startEngineDownCountdown()
        case "connection_failed", "max_retries_exceeded":
            isLoading = false
            launcherBanner = ChatBannerError(
                code: "engine_down",
                message: message,
                actionLabel: "Restart Dottie",
                action: .restartAgent
            )
        case "empty_response", "llm_error":
            // Never suppress: surface a banner with Retry, and finalize the stuck
            // placeholder so the "Thinking" spinner stops (AgentStateCoordinator
            // intentionally leaves empty_response placeholders loading for an
            // inline retry UI, which the launcher doesn't have).
            isLoading = false
            if let id = activeAssistantMessageId {
                messageStore.removeMessage(id: id)
                activeAssistantMessageId = nil
            }
            launcherBanner = ChatBannerError(
                code: code,
                message: code == "empty_response"
                    ? (message.isEmpty ? "No response — the model returned nothing." : message)
                    : message,
                actionLabel: "Retry",
                action: .retryLastMessage,
                // A cloud provider that is misconfigured / rate-limited fails the
                // same way on every retry (field: 105 llm_error events from one
                // install). Offer the fix — the provider + key + model live in
                // Settings → Models — next to the retry that won't help.
                secondaryLabel: code == "llm_error" ? "Open Settings" : nil,
                secondaryAction: code == "llm_error" ? .openModelsSettings : nil
            )
        case "xai_voice_unavailable", "xai_voice_error":
            // Grok Voice mint/stream failed; the gateway falls back to the local
            // STT+TTS pipeline so the turn still completes. Previously this hit
            // `default: break` and the user got a silent voice downgrade with no
            // explanation. Not a chat failure — leave any in-flight text turn alone.
            launcherBanner = ChatBannerError(
                code: "xai_voice_unavailable",
                message: "Grok Voice is unavailable. Using local voice instead.",
                actionLabel: "Open Settings",
                action: .openModelsSettings
            )
        default:
            break
        }
    }

    /// True when the local stack is broken badly enough that nothing works:
    /// the agent failed to start / crashed (`.error`), or talk failed.
    /// Normal startup states (`.starting`/`.stopped`) do NOT trigger it,
    /// so the banner only appears on real failures, not cold-launch warmup.
    private var hasSystemProblem: Bool {
        if case .error = agentManager.status { return true }
        if gateway.services["talk"]?.state == "failed" { return true }
        return false
    }

    /// Critical system-failure banner. Surfaces the same `SystemHealthSheet`
    /// the Settings "System Health" button opens, so the user can see exactly
    /// what's down and file a report without leaving the launcher.
    private var systemProblemBanner: some View {
        // Surface talk damage/re-download copy when present; otherwise generic.
        let talkErr = gateway.services["talk"]?.error ?? ""
        let modelDamaged = talkErr.localizedCaseInsensitiveContains("damaged")
            || talkErr.localizedCaseInsensitiveContains("re-download")
        return HStack(spacing: 8) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundColor(.dottieError)
                .font(.system(size: 13))
            Text(modelDamaged ? talkErr : "System problem — Dottie isn't running")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if modelDamaged {
                Button("Open Settings") {
                    NotificationCenter.default.post(name: .openSettingsWindow, object: nil, userInfo: ["section": "models"])
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.dottieError)
            } else {
                Button("Show System Report") { showingSystemReport = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.dottieError)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.dottieError.opacity(0.08))
        .cornerRadius(8)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 2)
    }

    private func launcherBannerView(_ banner: ChatBannerError) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 12))
            Text(banner.message)
                .font(.system(size: 13))
                .foregroundColor(Color.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let label = banner.secondaryLabel, let action = banner.secondaryAction {
                Button(label) {
                    performBannerAction(action)
                    launcherBanner = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color.primary.opacity(0.6))
            }
            if let label = banner.actionLabel, let action = banner.action {
                Button(label) {
                    performBannerAction(action)
                    launcherBanner = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.orange)
            }
            Button(action: { launcherBanner = nil }) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.primary.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 2)
    }

    /// App-update banner.
    @ViewBuilder private var updateBanner: some View {
        UpdatePhaseControls(style: .banner)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 2)
    }

    private func engineDownMessage(_ secondsLeft: Int) -> String {
        "The local model isn't running yet — I'm starting it. Retrying in \(secondsLeft)s…"
    }

    /// 10s engine_down countdown: ticks the banner message down, then clears it and
    /// auto-resends the last user message. Cancelled if the banner leaves engine_down.
    private func startEngineDownCountdown() {
        engineDownCountdownTask?.cancel()
        engineDownCountdownTask = Task { @MainActor in
            for n in stride(from: 9, through: 1, by: -1) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                guard launcherBanner?.code == "engine_down" else { return }
                launcherBanner = ChatBannerError(
                    code: "engine_down",
                    message: engineDownMessage(n),
                    actionLabel: "Restart Dottie",
                    action: .restartAgent
                )
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
            guard launcherBanner?.code == "engine_down" else { return }
            launcherBanner = nil
            resendLastUserMessage()
        }
    }

    private func cancelEngineDownCountdown() {
        engineDownCountdownTask?.cancel()
        engineDownCountdownTask = nil
    }

    /// Re-dispatches the most recent user message (used by the engine_down auto-retry).
    private func resendLastUserMessage() {
        guard let lastUser = messageStore.currentMessages.last(where: { $0.isUser }) else { return }
        isLoading = true
        dispatchLauncherSend(message: lastUser.text, images: lastUser.attachedImages ?? [])
    }

    private func performBannerAction(_ action: ChatBannerError.BannerAction) {
        switch action {
        case .restartAgent:
            AgentManager.shared.startAgent()
        case .openSystemSettingsPane(let urlString):
            if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
        case .openModelsSettings:
            launcherManager.hide()
            NotificationCenter.default.post(name: .openSettingsWindow, object: nil, userInfo: ["section": "models"])
        case .retryLastMessage:
            launcherBanner = nil
            resendLastUserMessage()
        }
    }

    // MARK: - Response Area

    /// Scrollable conversation history rendered in the launcher's OWN style:
    /// each turn uses the native launcher look — a
    /// right-aligned user bubble, thinking badge, 17pt markdown, tool pills with a
    /// stats line, and image thumbnails. Pinned to a fixed height so the box never
    /// resizes per turn; auto-scrolls to the newest message as it streams.
    private var messageHistoryArea: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(messageStore.currentMessages) { message in
                        launcherTurnView(message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
            .frame(height: expandedHeight - 88)
            .onChange(of: messageStore.currentMessages.count) { _, _ in
                scrollHistoryToBottom(proxy)
            }
            .onChange(of: messageStore.currentMessages.last?.text) { _, _ in
                scrollHistoryToBottom(proxy)
            }
            .onAppear { scrollHistoryToBottom(proxy) }
        }
    }

    /// Recent conversations (most-recent first) for the switcher submenu.
    private var recentConversations: [Conversation] {
        messageStore.conversations.sorted { $0.lastMessageAt > $1.lastMessageAt }
    }

    /// Small ellipsis (3-dot) menu shown top-left of the expanded launcher.
    private var launcherMenu: some View {
        Menu {
            Button("New Chat") {
                messageStore.createNewConversation(withGreeting: true)
                clearResponse()
                launcherManager.focusPanel()
            }
            Button("Clear") {
                messageStore.clearCurrentConversation()
                clearResponse()
                launcherManager.focusPanel()
            }

            // Switch sessions visually.
            if recentConversations.count > 1 {
                Menu("Switch Conversation") {
                    ForEach(recentConversations) { conv in
                        Button {
                            messageStore.switchConversation(conv.id)
                            clearResponse()
                            launcherManager.focusPanel()
                        } label: {
                            if conv.id == messageStore.currentConversationId {
                                Label(conv.title, systemImage: "checkmark")
                            } else {
                                Text(conv.title)
                            }
                        }
                    }
                }
            }

            Divider()
            Button("Attach Image…") { attachImageFromPicker() }
            Button("Export Conversation…") { exportConversation() }
                .disabled(messageStore.currentMessages.isEmpty)

            Divider()
            Button("Models…") {
                // Floating launcher would cover Settings — hide it first.
                launcherManager.hide()
                NotificationCenter.default.post(name: .openSettingsWindow, object: nil, userInfo: ["section": "models"])
            }
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color.primary.opacity(0.55))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Image attach / paste / export

    /// Opens a file picker and attaches the chosen image(s) to the next message.
    private func attachImageFromPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let ns = NSImage(contentsOf: url), let img = AttachedImage.from(ns) {
                pendingImages.append(img)
            }
        }
        isTextFieldFocused = true
    }

    /// Attaches an image from the clipboard if one is present (no-op otherwise).
    @discardableResult
    private func pasteImageFromClipboard() -> Bool {
        guard let objs = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
              let ns = objs.first, let img = AttachedImage.from(ns) else { return false }
        pendingImages.append(img)
        isTextFieldFocused = true
        return true
    }

    /// Registers a local Cmd+V monitor that pastes a clipboard image as an
    /// attachment, leaving normal text paste untouched (returns the event so the
    /// TextField still handles text). Idempotent.
    private func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let isPaste = event.modifierFlags.contains(.command)
                && event.charactersIgnoringModifiers?.lowercased() == "v"
            if isPaste,
               NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil),
               pasteImageFromClipboard() {
                return nil // consume — an image was pasted as an attachment
            }
            return event // text paste (and everything else) flows through
        }
    }

    private func removePasteMonitor() {
        if let m = pasteMonitor { NSEvent.removeMonitor(m); pasteMonitor = nil }
    }

    /// Exports the current conversation as Markdown via a save panel, including
    /// per-message thought duration and each tool call's input + output.
    private func exportConversation() {
        var blocks: [String] = []
        for msg in messageStore.currentMessages where !msg.isSystemMessage {
            var b = "**\(msg.isUser ? "You" : "Dottie")**"
            if let dur = msg.thinkingDuration, dur > 0 {
                b += "\n\n_Thought for \(formatThoughtDuration(dur * 1000))_"
            }
            if !msg.text.isEmpty { b += "\n\n\(msg.text)" }
            for tool in (msg.toolCalls ?? []) where tool.name != "tool_search" {
                b += "\n\n🔧 **\(tool.name)**"
                if let input = tool.input,
                   let data = try? JSONEncoder().encode(input),
                   let s = String(data: data, encoding: .utf8) {
                    b += "\nInput: `\(s)`"
                }
                if let result = tool.result, !result.isEmpty {
                    b += "\nOutput:\n```\n\(result)\n```"
                }
            }
            blocks.append(b)
        }
        let md = blocks.joined(separator: "\n\n---\n\n")
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "conversation.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? md.data(using: .utf8)?.write(to: url)
    }

    private func scrollHistoryToBottom(_ proxy: ScrollViewProxy) {
        guard let last = messageStore.currentMessages.last else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    /// Binding into the per-message thinking-expand set so each turn's badge
    /// expands independently per turn.
    private func thinkingExpanded(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedThinking.contains(id) },
            set: { isOn in
                if isOn { expandedThinking.insert(id) } else { expandedThinking.remove(id) }
            }
        )
    }

    /// One conversation turn in the launcher's native style, sourced from the
    /// message (so history persists across turns instead of single-turn @State).
    @ViewBuilder
    private func launcherTurnView(_ message: ChatMessage) -> some View {
        if message.isUser {
            // User message — right-aligned chat bubble.
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .font(.system(size: 15))
                    .foregroundColor(Color.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            let tools = (message.toolCalls ?? []).filter { $0.name != "tool_search" }
            let thinking = message.thinkingContent ?? ""
            VStack(alignment: .leading, spacing: 16) {
                // Loading spinner (assistant side) while waiting for the stream.
                if message.isLoading && message.text.isEmpty {
                    HStack(spacing: 8) {
                        PulsingDots()
                        Text(verbatim: loadingLabel)
                            .font(.system(size: 14))
                            .foregroundColor(Color.primary.opacity(0.6))
                    }
                }

                // 1. Thinking badge (after streaming completes for this turn).
                if !thinking.isEmpty && !message.isLoading {
                    ThinkingContentBadgeView(
                        content: thinking,
                        isExpanded: thinkingExpanded(message.id),
                        isThinkingActive: false,
                        displayDurationMs: message.thinkingDuration ?? 0,
                        isLoading: false
                    )
                }

                // 2. Markdown answer (streams token-by-token).
                if !message.text.isEmpty {
                    MarkdownText(message.text, fontSize: 17, textColor: Color.primary.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // 3. Tool pills + controls/stats line.
                if !tools.isEmpty || (!message.isLoading && !message.text.isEmpty) {
                    HStack(spacing: 8) {
                        ForEach(tools) { call in
                            ToolCallBadgeView(toolCall: call)
                        }
                        if !message.isLoading && !message.text.isEmpty {
                            controlButtons(for: message)
                        }
                    }
                }

            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Per-message control row (launcher style): copy, retry, read-aloud.
    @ViewBuilder private func controlButtons(for message: ChatMessage) -> some View {
        Button(action: { copyText(message) }) {
            Image(systemName: copiedMessageId == message.id ? "checkmark" : "doc.on.doc").font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundColor(Color.primary.opacity(0.6))

        Button(action: { retryAssistant(message) }) {
            Image(systemName: "arrow.clockwise").font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundColor(Color.primary.opacity(0.6))

        Button(action: {
            if speakingMessageId == message.id {
                stopSpeaking()
            } else {
                speak(message)
            }
        }) {
            if isGeneratingAudio && speakingMessageId == message.id {
                WhiteSpinner(isDark: colorScheme == .dark).frame(width: 12, height: 12)
            } else {
                // Bordered speaker when idle, filled while this message is playing.
                Image(systemName: speakingMessageId == message.id ? "speaker.2.fill" : "speaker.2")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color.primary.opacity(0.7))
            }
        }
        .buttonStyle(.plain)
    }

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Copy a specific turn's text and flash the checkmark on that turn.
    private func copyText(_ message: ChatMessage) {
        copyText(message.text)
        copiedMessageId = message.id
        let id = message.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedMessageId == id { copiedMessageId = nil }
        }
    }

    /// Resend the user message that preceded this assistant turn.
    private func retryAssistant(_ message: ChatMessage) {
        guard !isLoading else { return }
        let msgs = messageStore.currentMessages
        guard let idx = msgs.firstIndex(where: { $0.id == message.id }) else { return }
        if let priorUser = msgs[..<idx].last(where: { $0.isUser }) {
            inputText = priorUser.text
            pendingImages = priorUser.attachedImages ?? []
            sendChatMessage()
        }
    }

    private func speak(_ message: ChatMessage) {
        guard !message.text.isEmpty else { return }
        RealtimeClient.shared.stopTTS()
        speakingMessageId = message.id
        isGeneratingAudio = true
        isSpeaking = true
        RealtimeClient.shared.speakText(
            message.text,
            isAutoSpeak: false,
            onComplete: { _ in
                DispatchQueue.main.async {
                    isSpeaking = false
                    isGeneratingAudio = false
                    speakingMessageId = nil
                }
            }
        )
        if isSpeaking { isGeneratingAudio = false }
    }

    // MARK: - Input Area

    /// Thumbnails of manually-attached images awaiting send, each removable.
    private var pendingImagesBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingImages) { img in
                    ZStack(alignment: .topTrailing) {
                        Image(nsImage: img.nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Button {
                            pendingImages.removeAll { $0.id == img.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.white)
                                .background(Circle().fill(Color.black.opacity(0.5)))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 4, y: -4)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 6)
        }
    }

    private var inputArea: some View {
        HStack(alignment: .center, spacing: 12) {
            centerContent
            trailingButton
        }
        .padding(.vertical, 18)
        // Extra leading inset so text clears the capsule's rounded corner.
        .padding(.leading, 28)
        .padding(.trailing, 20)
    }

    private var centerContent: some View {
        Group {
            if globalRecorder.isRecording {
                HStack(spacing: 10) {
                    AuroraSpectrumCompactView(analyzer: globalRecorder.spectrumAnalyzer)
                    Text("Listening...")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundColor(Color.primary.opacity(0.8))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if globalRecorder.isTranscribing {
                HStack(spacing: 10) {
                    WhiteSpinner(isDark: colorScheme == .dark)
                        .frame(width: 20, height: 20)
                    Text("Thinking...")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundColor(Color.primary.opacity(0.8))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                inputTextField
            }
        }
    }

    private var inputTextField: some View {
        let placeholder = messageStore.suggestedFollowup ?? "How can I help you today?"

        return TextField("", text: $inputText, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 22, weight: .regular))
            .foregroundColor(Color.primary)
            .frame(maxWidth: .infinity, minHeight: 28)
            .lineLimit(1...8)
            .focused($isTextFieldFocused)
            .onHover { hovering in
                if hovering {
                    NSCursor.iBeam.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onKeyPress(keys: [.return], phases: .down) { press in
                // Enter submits; Shift+Enter falls through to the vertical-axis
                // TextField's native newline-at-cursor behavior.
                if press.modifiers.contains(.shift) { return .ignored }
                sendChatMessage()
                return .handled
            }
            .accessibilityLabel("Ask Dottie")
            .placeholder(when: inputText.isEmpty) {
                Text(placeholder)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundColor(Color.primary.opacity(0.35))
            }
            .onKeyPress(.tab) {
                // Tab accepts the followup suggestion
                if let followup = messageStore.suggestedFollowup, inputText.isEmpty {
                    inputText = followup
                    messageStore.suggestedFollowup = nil
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.upArrow) {
                // Up arrow cycles through user message history (newest to oldest)
                let userMessages = messageStore.currentMessages.filter { $0.isUser }
                guard !userMessages.isEmpty else { return .ignored }

                let nextIndex = historyIndex + 1
                if nextIndex < userMessages.count {
                    historyIndex = nextIndex
                    inputText = userMessages[userMessages.count - 1 - nextIndex].text
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.downArrow) {
                // Down arrow goes forward in history, back to empty
                if historyIndex > 0 {
                    let userMessages = messageStore.currentMessages.filter { $0.isUser }
                    let nextIndex = historyIndex - 1
                    let arrayIndex = userMessages.count - 1 - nextIndex
                    // Conversation may have changed since the last keypress; if the
                    // index now falls outside the current history, reset rather than crash.
                    guard arrayIndex >= 0 && arrayIndex < userMessages.count else {
                        historyIndex = -1
                        inputText = ""
                        return .handled
                    }
                    historyIndex = nextIndex
                    inputText = userMessages[arrayIndex].text
                    return .handled
                } else if historyIndex == 0 {
                    historyIndex = -1
                    inputText = ""
                    return .handled
                }
                return .ignored
            }
            .onChange(of: inputText) { oldValue, newValue in
                // Clear followup when user starts typing
                if !newValue.isEmpty {
                    messageStore.suggestedFollowup = nil
                }

                // Auto-capitalize first letter
                if oldValue.isEmpty && newValue.count == 1 {
                    let capitalized = newValue.prefix(1).uppercased() + newValue.dropFirst()
                    if capitalized != newValue {
                        inputText = capitalized
                    }
                }
            }
    }


    private var trailingButton: some View {
        Group {
            if isLoading {
                // Loading: show a stop-generation button.
                Button(action: { stopGenerating() }) {
                    ZStack {
                        Circle().fill(Color.gray.opacity(0.3))
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Color.primary)
                    }
                    .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            } else if !inputText.isEmpty {
                // Has text: show send button
                Button(action: { sendChatMessage() }) {
                    ZStack {
                        Circle().fill(Color.gray.opacity(0.3))
                        Image(systemName: "arrow.up")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(Color.primary)
                    }
                    .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            } else {
                // No text: show mic button
                Button(action: { toggleRecording() }) {
                    ZStack {
                        Circle()
                            .fill(globalRecorder.isRecording ? Color.red.opacity(0.2) : Color.gray.opacity(0.3))
                        Image(systemName: globalRecorder.isRecording ? "stop.fill" : "mic")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(globalRecorder.isRecording ? .red : Color.primary)
                    }
                    .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .disabled(globalRecorder.isTranscribing)
            }
        }
    }

    // MARK: - Actions

    private func focusTextField() {
        // Immediate — the callers (panel show notification, onAppear) already
        // run after the view is mounted; the old extra 100ms defer stacked on
        // the panel's own focus delay and kept the caret dead ~200ms per open.
        if !appState.recordingRequested && !appState.isRecording {
            isTextFieldFocused = true
        }
    }

    private func clearResponse() {
        isSpeaking = false
        isGeneratingAudio = false
        speakingMessageId = nil
        historyIndex = -1
    }

    /// Stops the in-flight generation: stops TTS, clears the loading state, and
    /// marks the streaming assistant message as user-stopped.
    private func stopGenerating() {
        RealtimeClient.shared.stopTTS()
        isLoading = false
        if let last = messageStore.currentMessages.last, !last.isUser, last.isLoading {
            var stoppedTools = last.toolCalls ?? []
            for i in stoppedTools.indices where stoppedTools[i].status == .running {
                stoppedTools[i].status = .error
            }
            messageStore.updateMessage(id: last.id, text: last.text, isLoading: false, toolCalls: stoppedTools, isStreaming: false)
            messageStore.markStopped(id: last.id)
        }
    }

    /// Handles `/clear`, `/new`, `/model` locally. Returns true if the input was a
    /// recognized command and should NOT be sent to the model.
    private func handleSlashCommand(_ command: String) -> Bool {
        switch command.lowercased().trimmingCharacters(in: .whitespaces) {
        case "/clear":
            messageStore.clearCurrentConversation()
            clearResponse()
            return true
        case "/new":
            messageStore.createNewConversation(withGreeting: true)
            clearResponse()
            isTextFieldFocused = true
            return true
        case "/model":
            NotificationCenter.default.post(name: .openSettingsWindow, object: nil, userInfo: ["section": "models"])
            return true
        default:
            return false
        }
    }

    func toggleRecording() {
        AppLogger.shared.info("LauncherView toggleRecording, state=\(RealtimeClient.shared.conversationState)")
        clearResponse()
        RealtimeClient.shared.toggleConversation()
    }

    private func sendChatMessage() {
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Prevent duplicate sends within 100ms
        let now = Date()
        guard now.timeIntervalSince(lastSendTime) > 0.1 else { return }
        lastSendTime = now

        // Stop any playing audio
        RealtimeClient.shared.stopTTS()

        let message = inputText

        // Slash commands — handled locally, not sent to the model.
        if handleSlashCommand(message) {
            inputText = ""
            historyIndex = -1
            return
        }

        isLoading = true

        // Clear input
        inputText = ""
        historyIndex = -1

        // Create conversation if needed
        if messageStore.currentMessages.isEmpty {
            messageStore.createNewConversation()
        }

        // Manually-attached images (file picker / paste) go with the message;
        // otherwise send plain text. Screen capture is on-demand via mac-use tools.
        let manualImages = pendingImages
        pendingImages = []
        dispatchLauncherSend(message: message, images: manualImages)
    }

    @MainActor
    private func dispatchLauncherSend(message: String, images: [AttachedImage]) {
        let userMessage = ChatMessage(text: message, isUser: true, attachedImages: images.isEmpty ? nil : images)
        messageStore.addMessage(userMessage)

        let placeholder = ChatMessage(text: "", isUser: false, isLoading: true, thinkingStartedAt: Date())
        messageStore.addMessage(placeholder)
        activeAssistantMessageId = placeholder.id


        AgentStateCoordinator.shared.setRealtimeMessageId(placeholder.id)

        if images.isEmpty {
            RealtimeClient.shared.sendTextMessage(message)
        } else {
            RealtimeClient.shared.sendMultimodalMessage(text: message, images: images.map(\.base64DataURI))
        }
    }

    /// Watches the active assistant placeholder for completion so loading UI clears.
    private func syncFromMessageStore() {
        guard let msgId = activeAssistantMessageId,
              let msg = messageStore.currentMessages.first(where: { $0.id == msgId }) else { return }

        if !msg.isLoading && isLoading {
            isLoading = false
            isTextFieldFocused = true
            // Auto-speak is server-side via RealtimeClient `autoSpeak` — do not
            // also speak client-side here (would double-play).
            activeAssistantMessageId = nil
        }
    }

    private func stopSpeaking() {
        RealtimeClient.shared.stopTTS()
        isSpeaking = false
        isGeneratingAudio = false
        speakingMessageId = nil
    }
}

// MARK: - View Extensions

extension View {
    /// Overlays a placeholder view when `shouldShow` is true.
    func placeholder<Content: View>(
        when shouldShow: Bool,
        alignment: Alignment = .leading,
        @ViewBuilder placeholder: () -> Content) -> some View {

        ZStack(alignment: alignment) {
            placeholder().opacity(shouldShow ? 1 : 0)
            self
        }
    }
}
