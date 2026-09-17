//
//  SettingsView.swift
//  Dottie
//
//  Created by Steve Derico on 6/29/25.
//

import SwiftUI
import AppKit
import AVFoundation
import Contacts
import ServiceManagement

// MARK: - Settings Section Enum
/// Identifies the available settings sidebar sections with associated display names and SF Symbols.
enum SettingsSectionType: String, CaseIterable, Identifiable {
    case agent = "Agent"
    case appearance = "Appearance"
    case advanced = "System"
    case models = "Models"
    case permissions = "Permissions"
    case voice = "Voice"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .agent: return "sparkles"
        case .appearance: return "paintbrush"
        case .advanced: return "hammer"
        case .models: return "square.stack.3d.up"
        case .permissions: return "lock.shield"
        case .voice: return "waveform"
        }
    }

    /// Resolves deep-link section names, including legacy aliases from removed sidebar items.
    static func fromDeepLink(_ name: String) -> SettingsSectionType? {
        switch name.lowercased() {
        case "account", "inference", "usage": return .agent
        case "developer", "advanced": return .advanced
        case "shortcuts": return .voice
        default: return SettingsSectionType(rawValue: name.capitalized)
        }
    }
}

/// Mutually exclusive voice conversation styles in Settings → Voice → Conversation.
enum VoiceConversationMode: String, CaseIterable, Identifiable {
    case bargeIn = "bargeIn"
    case turnBased = "turnBased"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bargeIn: return "Barge-in"
        case .turnBased: return "Turn-based"
        }
    }

    static func load() -> VoiceConversationMode {
        UserDefaults.standard.bool(forKey: "conversationTurnBased") ? .turnBased : .bargeIn
    }

    func persist() {
        let turnBased = self == .turnBased
        UserDefaults.standard.set(turnBased, forKey: "conversationTurnBased")
    }
}

/// Root settings window with a sidebar for section navigation and a scrollable detail pane.
struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    @AppStorage("selectedVoice") private var selectedVoice: String = ModelDefaults.voice
    @AppStorage("selectedSpeed") private var selectedSpeed: Double = ModelDefaults.speed
    @AppStorage(DefaultsKeys.chatProvider.rawValue) private var chatProviderRaw: String = "dottiepro"
    @AppStorage(DefaultsKeys.selectedCloudModel.rawValue) private var selectedCloudModel: String = ""
    @State private var selectedSection: SettingsSectionType? = .agent
    @State private var searchText: String = ""

    /// Maps keywords to their associated settings sections for search filtering.
    /// Keywords include: setting titles, descriptions, picker values, common synonyms, and related terms.
    private static let sectionKeywords: [SettingsSectionType: [String]] = [
        .agent: [
            // Account (folded into Agent)
            "account", "your name", "email", "user", "registration", "who am i", "sign in", "identity",
            // Usage (provider / Pro billing — was Settings → Models → Inference)
            "usage", "inference", "ai", "provider", "api key", "key", "cloud", "openai", "anthropic", "xai", "grok", "cerebras", "ollama", "dottie local", "llama",
            "dottie pro", "subscribe", "billing", "pro billing", "free usage", "stripe",
            // Profile settings
            "profile", "assistant name", "agent name", "personality", "professional", "friendly", "concise", "creative", "technical",
            "greeting", "greet", "new chat",
            // Behavior
            // Memory + tasks
            "resources", "tasks", "target", "progress",
            "memory", "about me", "learned memories", "memories", "personal context", "user memory", "ai memories", "remember", "knowledge", "brain"
        ],
        .appearance: [
            // Theme
            "appearance", "theme", "color scheme", "dark mode", "light mode", "dark", "light", "system",
            // Avatar
            "avatar", "logo", "webview", "web", "icon", "metal", "galaxy", "agent orb", "talking head",
            // Floating
            "floating avatar", "floating", "corner", "pip"
        ],
        .advanced: [
            // Connections
            "connections", "server", "servers", "advanced", "developer", "stt server", "tts server", "audio server", "agent server",
            "port", "\(AppPorts.audioServer)", "\(AppPorts.agentServer)", "127.0.0.1", "localhost", "http",
            "start", "stop", "restart", "reinstall", "running", "status",
            // Logs
            "logs", "log", "view logs", "app.log", "gateway.log", "talk.log", "macuse.log",
            // Testing
            "testing", "debug", "debug mode", "json", "sse", "streaming",
            "test",
            "setup", "installation", "onboarding", "wizard", "walkthrough",
            // Security
            "security", "token", "agent token", "bearer", "copy", "regenerate",
            // Data
            "data", "clear history", "delete", "conversations",
            // About
            "about", "version", "info",
            "privacy"
        ],
        .permissions: [
            // General
            "permissions", "privacy", "personal context", "data access", "grant", "allow", "deny",
            // Categories
            "contacts", "address book", "people",
            "calendar", "events", "appointments",
            "reminders", "tasks", "todos", "to-do",
            "mail", "email", "send mail", "inbox",
            "notes", "note",
            "safari", "browser", "tabs", "bookmarks", "open url", "navigate",
            "files", "folder", "documents", "finder",
            "photos", "images", "pictures", "photo library",
            "music", "apple music", "itunes", "playback", "control",
            "screenshot", "screenshots", "capture", "screen capture",
            "code", "javascript", "run code", "execute",
            // Actions
            "read", "write", "edit", "send", "destructive", "apps", "installed apps"
        ],
        .models: [
            // General
            "models", "model",
            // Speech / local STT+TTS / Grok Voice
            "speech", "voice", "voices", "tts", "text-to-speech", "text to speech", "kokoro", "speech synthesis", "speed", "rate",
            "stt", "speech-to-text", "speech to text", "parakeet", "transcription", "speech recognition",
            "grok voice", "mode"
        ],
        .voice: [
            "auto-speak", "auto speak", "automatic", "autoplay",
            // Conversation
            "conversation", "barge-in", "barge in", "interrupt",
            // VoiceWake
            "voicewake", "voice wake", "wake word", "hey dottie", "hey dodi", "dottie", "dodi",
            "trigger phrase", "activation", "listening", "always listening",
            "enable", "status", "speech recognition",
            // Shortcuts (folded into Voice)
            "setup", "setup wizard", "onboarding", "microphone", "mic", "permission", "accessibility", "ax", "system settings",
            "shortcuts", "dictate", "dictation", "push-to-type", "ptt", "keyboard", "key", "hotkey", "option", "space", "option+space",
            "hold", "hold duration", "threshold", "ms", "milliseconds",
            "cursor", "paste", "type at cursor",
            "escape", "esc", "stop", "stop everything", "cancel",
            "speak selected", "speak selected text", "read aloud", "selected text",
            "listen", "voice mode", "tap to record", "send to ai",
            "quick launcher", "launcher", "spotlight", "input bar", "command palette",
            "right click", "right click menu", "context menu", "services", "speak text", "stop speaking"
        ]
    ]

    /// Returns sections that match the current search query.
    /// Searches section names, keywords, AND actual row titles/descriptions.
    private var filteredSections: [SettingsSectionType] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return SettingsSectionType.allCases }

        return SettingsSectionType.allCases.filter { section in
            // Match section name
            if section.rawValue.lowercased().contains(query) { return true }
            // Match keywords
            if let keywords = Self.sectionKeywords[section] {
                if keywords.contains(where: { $0.contains(query) }) { return true }
            }
            // Match actual row titles
            if settingsRowTitles(for: section).contains(where: { $0.lowercased().contains(query) }) { return true }
            return false
        }
    }

    /// Returns the row titles for a given section (for search matching and scroll targeting).
    private func settingsRowTitles(for section: SettingsSectionType) -> [String] {
        switch section {
        case .agent:
            return ["Usage", "Billing", "Provider", "API Key", "Model", "Subscribe To Dottie Pro", "Your Name", "Email", "Assistant Name", "Personality", "About Me", "Learned Memories", "Tasks"]
        case .appearance:
            return ["Theme", "Avatar", "Orb Color", "Floating Avatar", "Default Interaction", "Default View"]
        case .advanced:
            return ["System Health", "Agent Token", "Logs", "Debug Mode", "Onboarding", "Clear History", "Reset App", "Version"]
        case .models:
            return ["Speech", "Mode", "Voice", "TTS", "STT"]
        case .permissions:
            return ["Accessibility", "Calendar", "Reminders", "Contacts", "Mail", "Notes", "Safari", "Files", "Photos", "Music", "Screenshot", "Messages", "Phone", "Code", "App Control"]
        case .voice:
            return ["Auto-Speak", "Conversation", "Mode", "Barge-in", "Turn-based", "VoiceWake", "Setup", "Microphone", "Accessibility", "Dictate Key", "Speed", "TTS playback speed", "Stop Everything", "Read Aloud", "Listen", "Quick Launcher", "Speak Selected Text", "Dictation", "Polish dictation", "Custom words", "Voice replaces mouse & keyboard", "mouse", "keyboard", "replace input"]
        }
    }

    private var voices: [String] {
        ConfigStore.shared.ttsVoices
    }

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(spacing: 0) {
                // Search field
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search...", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

                List(filteredSections, selection: $selectedSection) { section in
                    Label(section.rawValue, systemImage: section.icon)
                        .tag(section)
                }
                .listStyle(.sidebar)
                .onChange(of: searchText) { _, _ in
                    // Auto-select first match when search changes
                    if let firstMatch = filteredSections.first, !filteredSections.contains(where: { $0 == selectedSection }) {
                        selectedSection = firstMatch
                    }
                }
            }
            .frame(width: 200)

            Divider()

            // Detail
            if let section = selectedSection {
                ScrollViewReader { proxy in
                    ScrollView {
                        SettingsViewContent(
                            appState: appState,
                            selectedVoice: $selectedVoice,
                            selectedSpeed: $selectedSpeed,
                            chatProviderRaw: $chatProviderRaw,
                            selectedCloudModel: $selectedCloudModel,
                            selectedSection: $selectedSection,
                            voices: voices,
                            currentSection: section
                        )
                        .environment(\.settingsSearchText, searchText)
                    }
                    .onChange(of: searchText) { _, newValue in
                        // Scroll to first matching row
                        let query = newValue.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !query.isEmpty else { return }
                        if let match = settingsRowTitles(for: section).first(where: {
                            $0.lowercased().contains(query)
                        }) {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo("settings-row-\(match)", anchor: .center)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                Text("Select a section")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 700, idealWidth: 800, maxWidth: 900, minHeight: 500, idealHeight: 600, maxHeight: 800)
        .onChange(of: appState.targetSettingsSection) { _, newSection in
            if let sectionName = newSection,
               let section = SettingsSectionType.fromDeepLink(sectionName) {
                selectedSection = section
                appState.targetSettingsSection = nil  // Reset after navigating
            }
        }
    }
}


/// Contains the detail content for each settings section, managing all preferences, model lists,
/// permissions, and agent configuration state.
struct SettingsViewContent: View {
    @ObservedObject var appState: AppState
    @Binding var selectedVoice: String
    @Binding var selectedSpeed: Double
    @Binding var chatProviderRaw: String
    @Binding var selectedCloudModel: String
    @Binding var selectedSection: SettingsSectionType?
    @AppStorage("autoSpeak") private var autoSpeak: Bool = false
    /// Replace-input mode — voice drives raw mouse/keyboard events. Off by
    /// default: it makes the model act on every utterance without confirming.
    @AppStorage("replaceInputEnabled") private var replaceInputEnabled: Bool = false
    @AppStorage("musicDuckingEnabled") private var musicDuckingEnabled: Bool = true
    @AppStorage("dictationFormatEnabled") private var dictationFormatEnabled: Bool = false
    @AppStorage("dictationCustomWords") private var dictationCustomWords: String = ""
    @AppStorage("dictationReplacements") private var dictationReplacements: String = ""
    @AppStorage("dictationLanguageMode") private var dictationLanguageMode: String = "english"
    @State private var conversationMode: VoiceConversationMode = VoiceConversationMode.load()
    @State private var apiKey: String = ""
    @State private var ollamaModels: [(id: String, name: String)] = []
    @AppStorage(DefaultsKeys.dottieLocalBaseUrl.rawValue) private var dottieLocalBaseUrl: String = "http://127.0.0.1:1318"
    @AppStorage("selectedXaiVoice") private var selectedXaiVoice: String = "eve"
    @AppStorage("xaiVoiceModel") private var xaiVoiceModel: String = "grok-voice-think-fast-2.0"
    // Provider connection test: nil = untested, true = ok, false = failed
    @State private var testResult: Bool? = nil
    /// Extra status under Test (e.g. Free Usage Depleted from 429).
    @State private var testStatusLabel: String? = nil
    @State private var isTesting: Bool = false
    // Cloud-privacy consent: switching to a cloud vendor (BYOK or Dottie Pro)
    // sends conversations + shared screen content off the Mac, so the first
    // opt-in is gated behind an explicit dialog. Consent is remembered once granted.
    @AppStorage("cloudProviderConsent") private var cloudProviderConsent: Bool = false
    @State private var showCloudConsentAlert: Bool = false
    @State private var pendingCloudProvider: ChatProvider? = nil
    // Dottie Pro requires ~/.dottie/api_token (registration). Surface a clear
    // error instead of a silent first-chat 404 when the token is missing.
    @State private var proSetupError: String? = nil
    /// Live Pro entitlement from GET /api/pro/status (paid / free-credit).
    @State private var proStatus: ProStatus? = nil
    @State private var proBillingBusy: Bool = false
    @State private var showRefundAlert = false
    @State private var proRefundMessage: String? = nil
    // Debounce tasks for keystroke/drag-driven config pushes — cancel-previous,
    // 400ms, so the gateway isn't hit on every keystroke or slider tick.
    @State private var apiKeyPushDebounce: Task<Void, Never>? = nil
    @State private var localUrlPushDebounce: Task<Void, Never>? = nil
    @State private var speedPushDebounce: Task<Void, Never>? = nil
    @ObservedObject private var messageStore = MessageStore.shared
    @ObservedObject private var gateway = GatewayClient.shared
    @State private var showingClearAlert: Bool = false
    @State private var showingResetAlert: Bool = false
    @State private var showingLogs: Bool = false
    // Launch at login — SMAppService is the source of truth, not UserDefaults;
    // seeded on appear and re-read after each register/unregister.
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    // Contacts nudge (dictation vocab silently no-ops when unauthorized).
    @State private var contactsAuthStatus: CNAuthorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
    @State private var showingSystemHealth: Bool = false
    @ObservedObject private var voiceWakeManager = VoiceWakeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var realtimeClient = RealtimeClient.shared
    // Personal Context Permissions (all default to false for privacy).
    // Scopes are server-driven (ConfigStore.permissionScopes ← gateway
    // /v1/config/resolved); there are no per-scope @AppStorage properties. Toggle
    // state is held in `permissionStates`, seeded from / written through to
    // UserDefaults under the `permission.<scope>` keys (same keys @AppStorage
    // used, so persistence semantics are unchanged). The dictionary exists only
    // so SwiftUI re-renders a toggle on change — UserDefaults is the store.
    @ObservedObject private var configStore = ConfigStore.shared
    @State private var permissionStates: [String: Bool] = [:]

    @State private var tasks: [GatewayClient.AgentTask] = []
    @State private var isLoadingTasks: Bool = false
    // Agent Profile
    @AppStorage(DefaultsKeys.avatarStyle.rawValue) private var avatarStyle: String = ModelDefaults.avatarStyle
    @AppStorage("metalOrbHue") private var metalOrbHue: Double = 200.0
    @AppStorage("floatingAvatarEnabled") private var floatingAvatarEnabled: Bool = true
    @AppStorage(DefaultsKeys.appColorScheme.rawValue) private var appColorScheme: String = "dark"
    @AppStorage("defaultInteraction") private var defaultInteraction: String = "voice"
    // Guards against the revert-on-failure write re-firing .onChange and looping forever
    // when the gateway is down. Set true around the programmatic revert in updateX, false after.
    @State private var agentName: String = "Dottie"
    @State private var agentPersonality: String = ""
    @State private var isLoadingPrefs: Bool = false
    // User Memory Editor (single document)
    @State private var showUserMemoryEditor: Bool = false
    @State private var userMemoryContent: String = ""
    @State private var isLoadingUserMemory: Bool = false
    @State private var userMemorySaveStatus: String = ""
    // SQLite Memories Browser
    @State private var showMemoriesBrowser: Bool = false
    @State private var showTasksBrowser: Bool = false
    @State private var memories: [GatewayClient.Memory] = []
    @State private var isLoadingMemories: Bool = false
    @State private var micPermissionGranted: Bool = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    let voices: [String]
    let currentSection: SettingsSectionType

    var body: some View {
        VStack(spacing: 24) {
            sectionContent(for: currentSection)
        }
        .padding()
        .padding(.top, 8)
        .alert("Clear Chat History", isPresented: $showingClearAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                messageStore.clearAllConversations()
            }
        } message: {
            Text("Are you sure you want to clear all chat history? This action cannot be undone.")
        }
        .alert("Reset Dottie?", isPresented: $showingResetAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reset & Relaunch", role: .destructive) { performReset() }
        } message: {
            Text("Wipes chat history, preferences, caches, cookies, and macOS permission grants. Model weights, adapters, and the Python venv are preserved. Relaunches the app. Cannot be undone.")
        }
        .alert(cloudConsentTitle, isPresented: $showCloudConsentAlert) {
            Button("Cancel", role: .cancel) { pendingCloudProvider = nil }
            Button("Enable") {
                cloudProviderConsent = true
                if let provider = pendingCloudProvider {
                    chatProviderRaw = provider.rawValue  // re-applies; consent now granted
                }
                pendingCloudProvider = nil
            }
        } message: {
            Text(cloudConsentMessage)
        }
        .alert("Request A Refund?", isPresented: $showRefundAlert) {
            Button("Keep Subscription", role: .cancel) { }
            Button("Request Refund", role: .destructive) {
                Task { await requestProRefund() }
            }
        } message: {
            Text("Sends a refund request for your latest payment. We review each one and reply by email; if approved, the subscription is canceled and the payment refunded. To cancel without a refund, use Manage Billing.")
        }
        .alert("Refund Requested", isPresented: Binding(
            get: { proRefundMessage != nil },
            set: { if !$0 { proRefundMessage = nil } }
        )) {
            Button("OK", role: .cancel) { proRefundMessage = nil }
        } message: {
            Text(proRefundMessage ?? "")
        }
        .alert("Dottie Pro unavailable", isPresented: Binding(
            get: { proSetupError != nil },
            set: { if !$0 { proSetupError = nil } }
        )) {
            Button("OK", role: .cancel) { proSetupError = nil }
        } message: {
            Text(proSetupError ?? "")
        }
        .sheet(isPresented: $showingLogs) {
            UnifiedLogViewerView()
        }
        .sheet(isPresented: $showingSystemHealth) {
            SystemHealthSheet(isPresented: $showingSystemHealth)
        }
        .sheet(isPresented: $showUserMemoryEditor) {
            userMemoryEditorSheet()
        }
        .sheet(isPresented: $showMemoriesBrowser) {
            MemoriesBrowserSheet(
                isPresented: $showMemoriesBrowser,
                memories: $memories,
                isLoading: $isLoadingMemories
            )
        }
        .sheet(isPresented: $showTasksBrowser) {
            TasksBrowserSheet(
                isPresented: $showTasksBrowser,
                tasks: $tasks,
                isLoading: $isLoadingTasks
            )
        }
    }

    // MARK: - User Memory Editor
    @ViewBuilder
    private func userMemoryEditorSheet() -> some View {
        VStack(spacing: 16) {
            HStack {
                Text("Personal Context")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    showUserMemoryEditor = false
                }
                .keyboardShortcut(.escape)
            }
            .padding(.horizontal)
            .padding(.top)

            Text("Add information about yourself that Dottie will remember across all conversations.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            if isLoadingUserMemory {
                Spacer()
                ProgressView()
                Spacer()
            } else {
                TextEditor(text: $userMemoryContent)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(8)
                    .padding(.horizontal)
            }

            HStack {
                Button("Reload") {
                    loadUserMemory()
                }
                .buttonStyle(.bordered)

                Spacer()

                if !userMemorySaveStatus.isEmpty {
                    Text(userMemorySaveStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button("Save") {
                    saveUserMemory()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .frame(width: 500, height: 400)
        .onAppear {
            loadUserMemory()
        }
    }

    private func loadUserMemory() {
        isLoadingUserMemory = true
        userMemorySaveStatus = ""
        GatewayClient.shared.fetchUserMemory { result in
            isLoadingUserMemory = false
            switch result {
            case .success(let content):
                userMemoryContent = content
            case .failure(let error):
                userMemorySaveStatus = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func saveUserMemory() {
        userMemorySaveStatus = "Saving..."
        GatewayClient.shared.updateUserMemory(content: userMemoryContent) { success in
            userMemorySaveStatus = success ? "Saved" : "Failed to save"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if userMemorySaveStatus == "Saved" {
                    userMemorySaveStatus = ""
                }
            }
        }
    }


    // MARK: - Memories
    private func loadMemories() {
        GatewayClient.shared.fetchMemories { result in
            if case .success(let mems) = result {
                memories = mems
            }
        }
    }

    // MARK: - Section Router
    @ViewBuilder
    private func sectionContent(for section: SettingsSectionType) -> some View {
        switch section {
        case .agent:
            agentSection()
        case .appearance:
            appearanceSection()
        case .advanced:
            advancedSection()
        case .models:
            modelsSection()
        case .permissions:
            permissionsSection()
        case .voice:
            voiceSection()
        }
    }

    /// The currently selected provider derived from the raw string binding
    private var currentProvider: ChatProvider {
        if chatProviderRaw == "local" { return .dottiePro }
        return ChatProvider(rawValue: chatProviderRaw) ?? .dottiePro
    }

    private var cloudConsentTitle: String {
        "Enable \(pendingCloudProvider?.displayName ?? "Cloud Provider")?"
    }

    private var cloudConsentMessage: String {
        let vendor = pendingCloudProvider?.cloudVendor ?? "a third-party service"
        return "In this mode your messages — and any screen content you share — are sent to \(vendor) for processing. This data leaves your Mac."
    }

    /// Fetches the list of models from Ollama or dottie-local (`/api/tags`).
    private func fetchLocalTagModelList() {
        let finish: (Result<[(id: String, name: String)], Error>) -> Void = { result in
            switch result {
            case .success(let models):
                ollamaModels = models
                if selectedCloudModel.isEmpty, let first = models.first {
                    selectedCloudModel = first.id
                }
            case .failure(let error):
                AppLogger.warn("[Settings] Local model list fetch failed: \(error.localizedDescription)")
                ollamaModels = []
            }
        }
        if currentProvider == .dottieLocal {
            ClientManager.shared.fetchDottieLocalModels(completion: finish)
        } else {
            ClientManager.shared.fetchOllamaModels(completion: finish)
        }
    }

    /// Response shape for POST /v1/provider/test.
    private struct ProviderTestResponse: Decodable {
        let ok: Bool
        let status: Int?
        let error: String?
    }

    /// Finishes a non-Pro provider switch (key load, model default, config push).
    private func applyProviderSelection(_ provider: ChatProvider, from previousRaw: String? = nil) {
        let from = previousRaw ?? chatProviderRaw
        if provider.requiresAPIKey {
            apiKey = KeychainStore.get(forAccount: provider.apiKeyStorageKey) ?? ""
        }
        if !provider.usesDynamicLocalModels {
            if selectedCloudModel.isEmpty || !provider.availableModels.contains(where: { $0.id == selectedCloudModel }) {
                selectedCloudModel = provider.availableModels.first?.id ?? ""
            }
        }
        if provider.usesDynamicLocalModels { fetchLocalTagModelList() }
        GatewayClient.shared.pushChatConfig()
        // Live conversation: provider also drives Grok Voice Agent on/off.
        RealtimeClient.shared.sendConfig()
        NotificationCenter.default.post(name: .chatConfigChanged, object: nil)
        testResult = nil
    }

    /// Speech mode picker: Dottie Pro / BYOK (Grok Voice). On-device Parakeet+Kokoro
    /// still used when Provider is OpenAI/Anthropic/Ollama/Cerebras.
    private var speechModeRaw: String {
        switch currentProvider {
        case .dottiePro: return ChatProvider.dottiePro.rawValue
        case .xai: return ChatProvider.xai.rawValue
        default: return ChatProvider.dottiePro.rawValue
        }
    }

    /// Apply Speech picker (Dottie Pro | BYOK) via the same consent/pro paths as Provider.
    private func applySpeechMode(_ newRaw: String) {
        let provider = ChatProvider(rawValue: newRaw) ?? .dottiePro
        if provider.cloudVendor != nil && !cloudProviderConsent {
            pendingCloudProvider = provider
            showCloudConsentAlert = true
            return
        }
        if provider == .dottiePro {
            chatProviderRaw = provider.rawValue
            applyDottieProSelection()
            return
        }
        let previous = chatProviderRaw
        chatProviderRaw = provider.rawValue
        applyProviderSelection(provider, from: previous)
    }

    /// Dottie Pro: ensure registration token, then commit; otherwise revert + alert.
    private func applyDottieProSelection() {
        let previous = chatProviderRaw
        Task {
            await RegistrationManager.shared.bootstrapTokenIfNeeded()
            let hasToken = APITokenStore.load() != nil
            await MainActor.run {
                if !hasToken {
                    chatProviderRaw = ChatProvider.dottiePro.rawValue
                    let registered = RegistrationManager.shared.hasSubmittedRegistration
                    proSetupError = registered
                        ? "Couldn't reach Dottie servers — try again."
                        : "Finish account setup to use Dottie Pro."
                    return
                }
                applyProviderSelection(.dottiePro, from: previous)
            }
            await refreshProStatus()
        }
    }

    @MainActor
    private func refreshProStatus() async {
        do {
            let status = try await DottieAPIClient.shared.fetchProStatus()
            proStatus = status
        } catch {
            AppLogger.shared.debug("[Settings] pro status: \(error)")
            // Keep last known status; description falls back to Loading on first fail.
            if proStatus == nil {
                proStatus = ProStatus(
                    enabled: false,
                    paid: false,
                    freeCreditExhausted: false,
                    freeTokensUsed: 0,
                    freeTokensLimit: 0,
                    freeRequestsUsed: 0,
                    freeRequestsLimit: 0,
                    requestsToday: 0,
                    requestsLimit: 0
                )
            }
        }
    }

    @MainActor
    private func openProCheckout() async {
        proBillingBusy = true
        defer { proBillingBusy = false }
        let ok = await ProPaywall.openCheckout()
        if !ok {
            proSetupError = "Couldn't open Subscribe — check network or Stripe config."
        }
        await refreshProStatus()
    }

    @MainActor
    private func requestProRefund() async {
        proBillingBusy = true
        defer { proBillingBusy = false }
        if let message = await ProPaywall.requestRefund() {
            proRefundMessage = message
        } else {
            proSetupError = "Couldn't send the refund request — check network, or email support@dottie.ai."
        }
        await refreshProStatus()
    }

    @MainActor
    private func openProPortal() async {
        proBillingBusy = true
        defer { proBillingBusy = false }
        let ok = await ProPaywall.openPortal()
        if !ok {
            proSetupError = "Couldn't open Manage Billing — subscribe first or try again."
        }
        await refreshProStatus()
    }

    private var testConnectionDescription: String {
        if currentProvider.requiresAPIKey && apiKey.isEmpty { return "API Key Required" }
        if currentProvider == .ollama && ollamaModels.isEmpty { return "Start Ollama and pull a model" }
        if currentProvider == .dottieLocal && ollamaModels.isEmpty { return "Start Dottie Local" }
        if let label = testStatusLabel, !label.isEmpty { return label }
        return ""
    }

    /// Tests the active provider via the gateway (`/v1/provider/test`) — one
    /// round-trip with whatever provider/model/key is selected right now. BYOK
    /// providers need a key; Dottie Pro is keyless (gateway injects the
    /// registration token). Sends provider/model/apiKey inline so the test
    /// never races a debounced `/v1/config` push.
    private func testProviderConnection() {
        if currentProvider.requiresAPIKey && apiKey.isEmpty { return }
        isTesting = true
        testResult = nil
        testStatusLabel = nil
        Task {
            var ok = false
            var statusLabel: String? = nil
            if let url = URL(string: "http://127.0.0.1:\(AppPorts.agentServer)/v1/provider/test"),
               let body = try? JSONSerialization.data(withJSONObject: GatewayClient.shared.chatConfigBody()) {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                ClientManager.setAgentAuth(on: &request)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
                request.timeoutInterval = 10
                if let (data, response) = try? await URLSession.shared.data(for: request),
                   (response as? HTTPURLResponse)?.statusCode == 200,
                   let parsed = try? JSONDecoder().decode(ProviderTestResponse.self, from: data) {
                    ok = parsed.ok
                    if !ok {
                        // Prefer clear usage status over a silent red X.
                        if parsed.status == 429 {
                            await refreshProStatus()
                            let paid = await MainActor.run { proStatus?.paid == true }
                            statusLabel = paid ? "Daily Limit Reached" : "Free Usage Depleted"
                        } else if let code = parsed.status {
                            statusLabel = "Failed · HTTP \(code)"
                        } else if let err = parsed.error, !err.isEmpty {
                            statusLabel = err
                        } else {
                            statusLabel = "Connection Failed"
                        }
                    } else {
                        statusLabel = "Connected"
                    }
                } else {
                    statusLabel = "Gateway Unreachable"
                }
            }
            await MainActor.run {
                withAnimation {
                    testResult = ok
                    testStatusLabel = statusLabel
                }
                isTesting = false
                if currentProvider == .xai {
                }
            }
        }
    }

    // MARK: - Appearance Section
    @ViewBuilder
    private func appearanceSection() -> some View {
        SettingsSection(title: "Appearance") {
            VStack(spacing: 0) {
                SettingsRow(title: "Theme", description: "", icon: "moon.fill") {
                    Picker("Theme", selection: $appColorScheme) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                    .onChange(of: appColorScheme) { _, _ in
                        NotificationCenter.default.post(name: .themeChanged, object: nil)
                    }
                }
                Divider()
                SettingsRow(title: "Avatar", description: "", icon: "person.crop.circle") {
                    Picker("Avatar", selection: $avatarStyle) {
                        Text("Metal Orb").tag("metal")
                        Text("Galaxy Orb").tag("agent")
                        Text("Logo").tag("logo")
                        Text("Web").tag("webview")
                    }
                    .pickerStyle(MenuPickerStyle())
                    .labelsHidden()
                    .frame(width: 120)
                }
                if avatarStyle == "metal" {
                    Divider()
                    SettingsRow(title: "Orb Color", description: "Shifts UI accent with orb", icon: "paintpalette") {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color(hue: metalOrbHue / 360.0, saturation: 0.6, brightness: 0.5))
                                .frame(width: 20, height: 20)
                            Slider(value: $metalOrbHue, in: 0...360)
                                .frame(width: 120)
                        }
                    }
                }
                Divider()
                SettingsRow(title: "Floating Avatar", description: "", icon: "pip") {
                    Toggle("", isOn: $floatingAvatarEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: floatingAvatarEnabled) { _, enabled in
                            if enabled {
                                AvatarPanelManager.shared.show()
                            } else {
                                AvatarPanelManager.shared.hide()
                            }
                        }
                }
                Divider()
                SettingsRow(title: "Default Interaction", description: "", icon: "hand.tap") {
                    Picker("Default Interaction", selection: $defaultInteraction) {
                        Text("Voice").tag("voice")
                        Text("Text").tag("text")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 140)
                }
                Divider()
                SettingsRow(title: "Start at Login", description: "Open Dottie automatically so push-to-talk is always ready", icon: "power") {
                    Toggle("", isOn: $launchAtLogin)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: launchAtLogin) { _, enabled in
                            do {
                                if enabled {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                            } catch {
                                AppLogger.shared.error("[Settings] launch-at-login \(enabled ? "register" : "unregister") failed: \(error)")
                            }
                            // Re-read the real state — a failed call reverts the toggle.
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                }
            }
        }
    }

    // MARK: - Voice Section
    @ViewBuilder
    private func voiceSection() -> some View {
        VStack(spacing: 16) {
            // Conversation — full-duplex voice
            SettingsSection(title: "Conversation") {
                VStack(spacing: 0) {
                    SettingsRow(title: "Auto-Speak", description: "Speak responses automatically", icon: "speaker.wave.2") {
                        Toggle("Auto-Speak", isOn: $autoSpeak)
                            .toggleStyle(SwitchToggleStyle())
                            .labelsHidden()
                            .onChange(of: autoSpeak) { _, _ in
                                // Re-push WS config so the server picks up the new flag mid-session.
                                // realtime.js caches `cfg.autoSpeak` from the initial config message
                                // and only re-reads on session.update; without this the toggle silently
                                // does nothing until the user reconnects.
                                NotificationCenter.default.post(name: .permissionsChanged, object: nil)
                            }
                    }

                    Divider()

                    SettingsRow(title: "Duck other audio while talking", description: "Lowers music & video from other apps during dictation and speech", icon: "speaker.wave.1") {
                        Toggle("Duck other audio while talking", isOn: $musicDuckingEnabled)
                            .toggleStyle(SwitchToggleStyle())
                            .labelsHidden()
                    }

                    Divider()

                    SettingsRow(
                        title: "Mode",
                        description: conversationMode == .turnBased
                            ? "Re-trigger after each turn"
                            : "Interrupt Dottie by speaking",
                        icon: "waveform.badge.mic"
                    ) {
                        Picker("", selection: $conversationMode) {
                            ForEach(VoiceConversationMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .labelsHidden()
                        .frame(width: 120)
                        .onChange(of: conversationMode) { _, newValue in
                            newValue.persist()
                            NotificationCenter.default.post(name: .permissionsChanged, object: nil)
                        }
                    }

                    Divider()

                    SettingsRow(
                        title: "Voice replaces mouse & keyboard",
                        description: "Say \"move left\", \"click\", \"type hello\" — acts immediately, no confirmation. Needs App Control.",
                        icon: "cursorarrow.motionlines"
                    ) {
                        Toggle("", isOn: $replaceInputEnabled)
                            .toggleStyle(SwitchToggleStyle())
                            .labelsHidden()
                            .onChange(of: replaceInputEnabled) { _, _ in
                                // Re-push WS config: the server preloads the input
                                // primitives on the flip, so without this the toggle
                                // does nothing until the next reconnect.
                                NotificationCenter.default.post(name: .permissionsChanged, object: nil)
                            }
                    }

                }
            }

            // VoiceWake Settings
            SettingsSection(title: "VoiceWake") {
                VStack(spacing: 0) {
                    SettingsRow(title: "Enable", description: "Say \"Hey Dottie\" to activate", icon: "waveform.circle") {
                        Toggle("", isOn: $voiceWakeManager.isEnabled)
                            .toggleStyle(SwitchToggleStyle())
                            .labelsHidden()
                    }

                    Divider()

                    SettingsRow(title: "Status", description: voiceWakeManager.isListening ? "Listening" : "Not listening", icon: "ear") {
                        if voiceWakeManager.permissionStatus == .authorized {
                            Circle()
                                .fill(voiceWakeManager.isListening ? Color.green : Color.gray)
                                .frame(width: 10, height: 10)
                        } else {
                            Button("Grant Permission") {
                                voiceWakeManager.requestPermission { _ in }
                            }
                            .buttonStyle(.bordered)
                            .font(.caption)
                        }
                    }

                    Divider()

                    SettingsRow(title: "Trigger Phrase", description: "", icon: "text.quote") {
                        TextField("Trigger phrase", text: $voiceWakeManager.triggerPhrase)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                    }

                }
            }

            // Dictation — local transcript cleanup
            SettingsSection(title: "Dictation") {
                VStack(spacing: 0) {
                    SettingsRow(title: "Language", description: "English streams live partials; Multilingual auto-detects 25 languages (no live preview)", icon: "globe") {
                        Picker("Language", selection: $dictationLanguageMode) {
                            Text("English").tag("english")
                            Text("Multilingual").tag("multilingual")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 180)
                    }

                    Divider()

                    SettingsRow(title: "Text replacements", description: "shortcut=expansion, comma-separated — say \"addr\", type your address", icon: "arrow.left.arrow.right") {
                        TextField("addr=123 Main St, eml=me@mac.com", text: $dictationReplacements)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                    }

                    Divider()

                    SettingsRow(title: "Polish dictation", description: "Local AI fixes names, terms & punctuation — more accurate but ~1s slower", icon: "text.badge.checkmark") {
                        Toggle("", isOn: $dictationFormatEnabled)
                            .toggleStyle(SwitchToggleStyle())
                            .labelsHidden()
                    }

                    if dictationFormatEnabled {
                        Divider()

                        SettingsRow(title: "Custom words", description: "Names/brands to spell right, comma-separated", icon: "character.book.closed") {
                            TextField("Kokoros, Dottie, …", text: $dictationCustomWords)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                        }

                    }

                    // Contacts nudge: contact names are the best vocab source for
                    // the polish pass, but DictationVocabulary silently no-ops
                    // when unauthorized — surface the fix here. Shown regardless
                    // of the polish toggle so it's discoverable before opting in.
                    if contactsAuthStatus != .authorized {
                        Divider()

                        SettingsRow(title: "Contacts access", description: "Spell your contacts' names right (used by Polish dictation) — read locally, nothing leaves your Mac", icon: "person.crop.circle.badge.checkmark") {
                            if contactsAuthStatus == .notDetermined {
                                Button("Enable") {
                                    CNContactStore().requestAccess(for: .contacts) { _, _ in
                                        DispatchQueue.main.async {
                                            contactsAuthStatus = CNContactStore.authorizationStatus(for: .contacts)
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                            } else {
                                Button("Open System Settings") {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }

            shortcutsContent()
        }
        .onAppear {
            hotKeyManager.checkAccessibilityPermission()
            contactsAuthStatus = CNContactStore.authorizationStatus(for: .contacts)
        }
        .onDisappear {
            hotKeyManager.stopPermissionPolling()
        }
    }

    // MARK: - Models Section
    @ViewBuilder
    private func modelsSection() -> some View {
        VStack(spacing: 16) {
            HStack {
                Text("Models")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .textSelection(.enabled)
                Spacer()
            }

            SettingsSection(title: "Speech") {
                // Grok Voice on Pro/BYOK. On-device Parakeet+Kokoro when Provider is
                // OpenAI/Anthropic/etc. Local LLM chat path gated off.
                let voiceAgent = currentProvider.usesGrokVoiceAgent
                VStack(spacing: 0) {
                    SettingsRow(
                        title: "Mode",
                        description: voiceAgent
                            ? (currentProvider == .dottiePro
                                ? "Grok Voice via Pro · bills while talking"
                                : "Grok Voice on your key · ~$0.08/min while talking")
                            : "On-device Parakeet + Kokoro · free",
                        icon: "waveform.badge.mic"
                    ) {
                        Picker("Speech Mode", selection: Binding(
                            get: { speechModeRaw },
                            set: { applySpeechMode($0) }
                        )) {
                            Text("Dottie Pro").tag(ChatProvider.dottiePro.rawValue)
                            Text("BYOK").tag(ChatProvider.xai.rawValue)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 200)
                    }
                    Divider()
                    SettingsRow(title: "TTS",
                                description: voiceAgent
                                    ? "Grok Voice · in-socket"
                                    : "Kokoro 82M · bundled",
                                icon: "waveform") {
                        Text(voiceAgent ? "grok-voice" : "kokoro")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Divider()
                    SettingsRow(title: "STT",
                                description: voiceAgent
                                    ? "Grok Voice · in-socket"
                                    : "Parakeet TDT v3 · bundled",
                                icon: "mic") {
                        Text(voiceAgent ? "grok-voice" : "parakeet")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Shortcuts Section
    @ObservedObject private var hotKeyManager = HotKeyManager.shared

    private var shortcutsPermissionsGranted: Bool {
        micPermissionGranted && hotKeyManager.accessibilityPermissionGranted
    }

    @ViewBuilder
    private func shortcutsContent() -> some View {
        VStack(spacing: 16) {
            if !shortcutsPermissionsGranted {
            SettingsSection(title: "Setup") {
                VStack(spacing: 0) {
                    // Step 1: Microphone
                    HStack(spacing: 12) {
                        Image(systemName: micPermissionGranted ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20))
                            .foregroundColor(micPermissionGranted ? .green : .secondary)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Microphone")
                                .font(.headline)
                                .foregroundColor(.primary)
                            Text(micPermissionGranted ? "Permission granted" : "Required for voice dictation")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if !micPermissionGranted {
                            Button("Allow") {
                                RecordingPermissionManager.requestMicrophonePermission { granted in
                                    micPermissionGranted = granted
                                    NSApp.activate(ignoringOtherApps: true)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    Divider()

                    // Step 2: Accessibility
                    HStack(spacing: 12) {
                        Image(systemName: hotKeyManager.accessibilityPermissionGranted ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20))
                            .foregroundColor(hotKeyManager.accessibilityPermissionGranted ? .green : .secondary)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Accessibility")
                                .font(.headline)
                                .foregroundColor(.primary)
                            Text(hotKeyManager.accessibilityPermissionGranted ? "Permission granted" : "Required for dictation and paste at cursor")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if !hotKeyManager.accessibilityPermissionGranted {
                            Button("Open Settings") {
                                hotKeyManager.openAccessibilitySettings()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            }

            SettingsSection(title: "Shortcuts") {
                VStack(spacing: 0) {
                    SettingsRow(title: "Listen", description: "Toggle voice listening", icon: "brain") {
                        Picker("", selection: $hotKeyManager.agentShortcut) {
                            ForEach(AgentShortcut.allCases) { shortcut in
                                Text(shortcut.displayName).tag(shortcut)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .labelsHidden()
                        .frame(width: 120)
                    }

                    Divider()

                    SettingsRow(title: "Read Aloud", description: "Tap to speak selection (or clipboard). Second tap stops.", icon: "speaker.wave.2") {
                        Picker("", selection: $hotKeyManager.speakShortcut) {
                            ForEach(SpeakShortcut.allCases) { shortcut in
                                Text(shortcut.displayName).tag(shortcut)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .labelsHidden()
                        .frame(width: 160)
                    }

                    Divider()

                    SettingsRow(title: "Quick Launcher", description: "Spotlight-style input bar", icon: "magnifyingglass") {
                        Picker("", selection: $hotKeyManager.launcherShortcut) {
                            ForEach(LauncherShortcut.allCases) { shortcut in
                                Text(shortcut.displayName).tag(shortcut)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .labelsHidden()
                        .frame(width: 120)
                    }

                    Divider()

                    SettingsRow(title: "Dictate Key", description: "Hold to dictate, release to type at cursor", icon: "keyboard") {
                        Picker("", selection: $hotKeyManager.activationKey) {
                            ForEach(ActivationKey.allCases) { key in
                                Text(key.displayName).tag(key)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .labelsHidden()
                        .frame(width: 180)
                    }

                    Divider()

                    SettingsRow(title: "Voice", description: "Kokoro speaker", icon: "person.wave.2") {
                        Picker("Voice", selection: $selectedVoice) {
                            ForEach(voices, id: \.self) { voice in
                                let displayName = voice.components(separatedBy: "_").last ?? voice
                                Text(displayName.capitalized).tag(voice)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .labelsHidden()
                        .frame(width: 150)
                        .onChange(of: selectedVoice) { _, newVoice in
                            RealtimeClient.shared.stopTTS()
                            let displayName = newVoice.components(separatedBy: "_").last ?? newVoice
                            RealtimeClient.shared.speakText("Hi, I'm \(displayName.capitalized)", voice: newVoice)
                        }
                    }

                    Divider()

                    SettingsRow(title: "Speed", description: "TTS playback speed", icon: "speedometer") {
                        HStack(spacing: 8) {
                            Slider(value: $selectedSpeed, in: 0.5...2.0, step: 0.1)
                                .frame(width: 120)
                                .onChange(of: selectedSpeed) { _, _ in
                                    speedPushDebounce?.cancel()
                                    speedPushDebounce = Task {
                                        try? await Task.sleep(for: .milliseconds(400))
                                        guard !Task.isCancelled else { return }
                                        GatewayClient.shared.pushChatConfig()
                                        NotificationCenter.default.post(name: .chatConfigChanged, object: nil)
                                    }
                                }
                            Text("\(selectedSpeed, specifier: "%.1f")x")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }

                    Divider()

                    SettingsRow(title: "Stop Everything", description: "Press ESC to stop recording, audio, or TTS", icon: "escape") {
                        Text("⎋")
                            .font(.system(size: 18, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }

            SettingsSection(title: "Speak Selected Text") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Right-click selected text in any app, then choose Services to hear it with Dottie.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. Open Keyboard Shortcuts → Services")
                        Text("2. Enable Text → Dottie: Speak Text")
                        Text("3. Optionally enable General → Dottie: Stop Speaking")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    Button("Open Keyboard Shortcuts") {
                        openKeyboardShortcuts()
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    /// Opens System Settings to the Keyboard Shortcuts pane via AppleScript, with a URL scheme fallback.
    private func openKeyboardShortcuts() {
        let script = """
        tell application "System Settings"
            activate
            reveal anchor "Shortcuts" of pane id "com.apple.Keyboard-Settings.extension"
        end tell
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)

            if let error = error {
                AppLogger.shared.log("AppleScript error opening Keyboard Shortcuts: \(error)", level: .error)
                // Fallback to URL scheme
                if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    // MARK: - Usage Section (Settings → Agent, top)

    /// Provider first, then Pro free-usage / billing / cloud model. Top of Agent.
    @ViewBuilder
    private func usageSection() -> some View {
        SettingsSection(title: "Usage") {
            VStack(spacing: 0) {
                // Provider at top — choose brain before billing/usage details.
                SettingsRow(title: "Provider", description: "Chat runs in the cloud", icon: "cloud") {
                    Picker("Provider", selection: $chatProviderRaw) {
                        ForEach(ChatProvider.chatPickerCases) { provider in
                            Text(provider.displayName).tag(provider.rawValue)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .labelsHidden()
                    .frame(width: 180)
                    .onChange(of: chatProviderRaw) { oldValue, newValue in
                        // Legacy `local` prefs migrate to Pro (picker never offered it).
                        if newValue == "local" {
                            chatProviderRaw = ChatProvider.dottiePro.rawValue
                            return
                        }
                        let provider = ChatProvider(rawValue: newValue) ?? .dottiePro
                        // Privacy gate: ANY cloud vendor (keyed or Dottie Pro)
                        // transmits conversations + shared screen content
                        // off-device. Gate the first opt-in behind explicit
                        // consent. Ollama runs on-device, never gated.
                        if provider.cloudVendor != nil && !cloudProviderConsent {
                            pendingCloudProvider = provider
                            showCloudConsentAlert = true
                            chatProviderRaw = ChatProvider.dottiePro.rawValue
                            return
                        }
                        // Dottie Pro needs a registration bearer before chat
                        // works — bootstrap async, then commit or revert.
                        if provider == .dottiePro {
                            applyDottieProSelection()
                            return
                        }
                        applyProviderSelection(provider, from: oldValue)
                    }
                }

                // Billing + free credit when on Dottie Pro (under Provider).
                if currentProvider == .dottiePro {
                    Divider()
                    SettingsRow(
                        title: "Billing",
                        description: "",
                        icon: "creditcard"
                    ) {
                        HStack(spacing: 8) {
                            if proBillingBusy {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            if proStatus?.paid == true {
                                Button("Manage Billing") {
                                    Task { await openProPortal() }
                                }
                                .buttonStyle(.bordered)
                                .disabled(proBillingBusy)
                                Button("Request Refund") {
                                    showRefundAlert = true
                                }
                                .buttonStyle(.bordered)
                                .tint(.red)
                                .disabled(proBillingBusy)
                            } else {
                                Button("Subscribe To Dottie Pro") {
                                    Task { await openProCheckout() }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.accentColor)
                                .disabled(proBillingBusy)
                            }
                        }
                    }
                    .task(id: chatProviderRaw) {
                        guard currentProvider == .dottiePro else { return }
                        await refreshProStatus()
                    }

                    Divider()
                    // Free-usage meter under billing.
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            Image(systemName: "gauge.with.dots.needle.33percent")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.accentColor)
                                .frame(width: 20)
                            Text("Free Credit")
                                .font(.headline)
                            Spacer(minLength: 8)
                            if let s = proStatus {
                                Text(s.usageTrailingLabel)
                                    .font(.system(size: 13))
                                    .foregroundStyle(s.isUsageDepleted ? Color.red : Color.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            Button {
                                Task { await refreshProStatus() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                            .disabled(proBillingBusy)
                            .help("Refresh Usage")
                        }
                        if let s = proStatus, !s.paid, s.freeTokensLimit > 0 {
                            FreeUsageMeter(usedFraction: s.freeTokensUsedFraction)
                                .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color(NSColor.controlBackgroundColor))
                }

                if currentProvider.requiresAPIKey {
                    Divider()
                    SettingsRow(title: "API Key", description: apiKey.isEmpty ? "" : "...\(String(apiKey.suffix(4)))", icon: "key") {
                        SecureField("Enter API Key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                            .onChange(of: apiKey) { _, newValue in
                                // Persist + reset the test badge immediately; debounce
                                // the network push so typing a key doesn't POST /v1/config
                                // and re-sync the WS on every keystroke. Keys go to the
                                // macOS Keychain, never plaintext UserDefaults.
                                KeychainStore.set(newValue, forAccount: currentProvider.apiKeyStorageKey)
                                testResult = nil
                                apiKeyPushDebounce?.cancel()
                                apiKeyPushDebounce = Task {
                                    try? await Task.sleep(for: .milliseconds(400))
                                    guard !Task.isCancelled else { return }
                                    GatewayClient.shared.pushChatConfig()
                                    NotificationCenter.default.post(name: .chatConfigChanged, object: nil)
                                }
                            }
                    }
                }

                if currentProvider == .dottieLocal {
                    Divider()
                    SettingsRow(
                        title: "Endpoint",
                        description: "Host And Port For Dottie Local",
                        icon: "network"
                    ) {
                        TextField("http://127.0.0.1:1318", text: $dottieLocalBaseUrl)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .onChange(of: dottieLocalBaseUrl) { _, _ in
                                testResult = nil
                                localUrlPushDebounce?.cancel()
                                localUrlPushDebounce = Task {
                                    try? await Task.sleep(for: .milliseconds(400))
                                    guard !Task.isCancelled else { return }
                                    GatewayClient.shared.pushChatConfig()
                                    fetchLocalTagModelList()
                                    NotificationCenter.default.post(name: .chatConfigChanged, object: nil)
                                }
                            }
                    }
                }

                // BYOK clouds + local providers — `/v1/provider/test` is provider-agnostic.
                // Pro is excluded: keyless; uses Usage refresh above instead.
                if currentProvider.requiresAPIKey || currentProvider.usesDynamicLocalModels {
                    Divider()
                    SettingsRow(
                        title: "Test Connection",
                        description: testConnectionDescription,
                        icon: "checkmark.shield"
                    ) {
                        HStack(spacing: 8) {
                            if let testResult = testResult {
                                Image(systemName: testResult ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundColor(testResult ? .green : .red)
                                    .transition(.opacity)
                            }
                            Button(action: testProviderConnection) {
                                if isTesting {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Text("Test")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled((currentProvider.requiresAPIKey && apiKey.isEmpty) || isTesting)
                        }
                    }
                }

                // xAI TTS voice (BYOK xai AND Dottie Pro).
                if currentProvider == .xai || currentProvider == .dottiePro {
                    Divider()
                    SettingsRow(title: "Voice", description: "", icon: "person.wave.2") {
                        Picker("Voice", selection: $selectedXaiVoice) {
                            Text("Ara").tag("ara")
                            Text("Eve").tag("eve")
                            Text("Leo").tag("leo")
                            Text("Rex").tag("rex")
                            Text("Sal").tag("sal")
                        }
                        .pickerStyle(MenuPickerStyle())
                        .labelsHidden()
                        .frame(width: 150)
                        .onChange(of: selectedXaiVoice) { _, _ in
                            GatewayClient.shared.pushChatConfig()
                            NotificationCenter.default.post(name: .chatConfigChanged, object: nil)
                        }
                    }
                }

                // Model picker — cloud / Ollama / dottie-local.
                Divider()
                SettingsRow(title: "Model", description: "", icon: "cube") {
                    let models: [(id: String, name: String)] = currentProvider.usesDynamicLocalModels
                        ? ollamaModels
                        : currentProvider.availableModels
                    Picker("Model", selection: $selectedCloudModel) {
                        if models.isEmpty {
                            Text(currentProvider.usesDynamicLocalModels ? "No Models Found" : "—").tag("")
                        } else {
                            ForEach(models, id: \.id) { m in
                                Text(m.name).tag(m.id)
                            }
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .labelsHidden()
                    .frame(width: 220)
                    .disabled(models.isEmpty)
                    .onChange(of: selectedCloudModel) { _, _ in
                        GatewayClient.shared.pushChatConfig()
                    }
                }

                // Dynamic local providers with nothing to select is a dead end.
                if currentProvider == .ollama && ollamaModels.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.secondary)
                        Text("Ollama isn't reachable, or has no models. Start it with `ollama serve`, pull a model (`ollama pull llama3.2`), then reopen Settings.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
                if currentProvider == .dottieLocal && ollamaModels.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.secondary)
                        Text("Dottie Local isn't reachable, or has no models. Install llama-server, run `dottie-local start`, then reopen Settings.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }

                // Standing cloud-privacy disclosure — shown the whole time a
                // cloud vendor is active, not just at opt-in.
                if let vendor = currentProvider.cloudVendor {
                    Divider()
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.shield")
                            .foregroundColor(.secondary)
                        Text("Messages and any shared screen content are sent to \(vendor) for processing — this leaves your Mac.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    // MARK: - Agent Section

    /// Builds the Agent settings section with profile, tasks, and memory.
    private func agentSection() -> some View {
        let userName = RegistrationManager.shared.userName
        let userEmail = RegistrationManager.shared.userEmail
        return VStack(spacing: 16) {
            // Usage first — provider, Pro meter/billing, cloud model (was Models → Inference).
            usageSection()

            SettingsSection(title: "Profile") {
                VStack(spacing: 0) {
                    SettingsRow(title: "Your Name", description: "Registered with this install", icon: "person.crop.circle") {
                        Text(userName.isEmpty ? "Not set" : userName)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }

                    Divider()

                    SettingsRow(title: "Email", description: "", icon: "envelope") {
                        Text(userEmail.isEmpty ? "Not set" : userEmail)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }

                    Divider()

                    SettingsRow(title: "Assistant Name", description: "", icon: "sparkles") {
                        TextField("Assistant name", text: $agentName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                            .onSubmit { savePreferences() }
                            .onChange(of: agentName) { _, _ in savePreferences() }
                    }
                    Divider()
                    SettingsRow(title: "Personality", description: "", icon: "theatermasks") {
                        Picker("Personality", selection: $agentPersonality) {
                            Text("None").tag("")
                            Text("Professional").tag("Professional")
                            Text("Friendly").tag("Friendly")
                            Text("Concise").tag("Concise")
                            Text("Creative").tag("Creative")
                            Text("Technical").tag("Technical")
                        }
                        .pickerStyle(MenuPickerStyle())
                        .labelsHidden()
                        .frame(width: 150)
                        .onChange(of: agentPersonality) { _, _ in savePreferences() }
                    }
                }
            }


            SettingsSection(title: "Memory") {
                VStack(spacing: 0) {
                    SettingsRow(
                        title: "About Me",
                        description: userMemoryContent.isEmpty ? "Facts you want Dottie to remember" : "\(userMemoryContent.split(separator: " ").count) words",
                        icon: "person.text.rectangle"
                    ) {
                        Button("Edit") {
                            showUserMemoryEditor = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Divider()
                    SettingsRow(
                        title: "Learned Memories",
                        description: "\(memories.count) memor\(memories.count == 1 ? "y" : "ies") from conversations",
                        icon: "brain"
                    ) {
                        Button("Browse") {
                            showMemoriesBrowser = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            SettingsSection(title: "") {
                VStack(spacing: 0) {
                    SettingsRow(
                        title: "Tasks",
                        description: isLoadingTasks ? "Loading..." : "\(tasks.count) task\(tasks.count == 1 ? "" : "s")",
                        icon: "target"
                    ) {
                        Button("Manage") {
                            showTasksBrowser = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .onAppear {
            // Load API key for current provider (Keychain, with legacy UserDefaults migration)
            if currentProvider.requiresAPIKey {
                apiKey = KeychainStore.get(forAccount: currentProvider.apiKeyStorageKey) ?? ""
            }
            if currentProvider.usesDynamicLocalModels { fetchLocalTagModelList() }
            // Always load agent data - API endpoints are available even during startup
            loadPreferences()
            loadTasks()
            loadMemories()
            loadUserMemory()
        }
    }

    private func loadPreferences() {
        isLoadingPrefs = true
        GatewayClient.shared.fetchPreferences { result in
            isLoadingPrefs = false
            if case .success(let prefs) = result {
                agentName = prefs.agentName ?? "Dottie"
                UserDefaults.standard.set(agentName, forKey: "agentName")
                agentPersonality = prefs.agentPersonality ?? ""
            }
        }
    }

    private func savePreferences() {
        UserDefaults.standard.set(agentName, forKey: "agentName")
        let prefs = GatewayClient.AgentPreferences(
            agentName: agentName,
            agentPersonality: agentPersonality
        )
        GatewayClient.shared.updatePreferences(prefs) { _ in }
    }

    // MARK: - Permissions Section

    /// Data model for a personal context permission category with sub-toggles.
    private struct PersonalContextCategory: Identifiable {
        let id: String
        let label: String
        let icon: String
        let items: [(title: String, scope: String)]
    }

    /// Presentation metadata for a single permission scope. The gateway serves
    /// only the scope key (e.g. `calendar.destructive`); label/icon/item-title
    /// are pure UI and live here, keyed by scope. Scopes with no entry still
    /// render with a derived label so a newly-added server scope never vanishes.
    private struct ScopePresentation {
        let category: String   // groups scopes into one SettingsSection
        let label: String      // category header (first scope in a group wins)
        let icon: String
        let itemTitle: String  // per-toggle row title
    }

    private static let scopePresentation: [String: ScopePresentation] = [
        "contacts.read": .init(category: "contacts", label: "Contacts", icon: "person.crop.circle", itemTitle: "Read"),
        "phone.call": .init(category: "phone", label: "Phone", icon: "phone", itemTitle: "Audio & Video Calls"),
        "calendar.read": .init(category: "calendar", label: "Calendar", icon: "calendar", itemTitle: "Read"),
        "calendar.destructive": .init(category: "calendar", label: "Calendar", icon: "calendar", itemTitle: "Edit"),
        "reminders.read": .init(category: "reminders", label: "Reminders", icon: "checklist", itemTitle: "Read"),
        "reminders.destructive": .init(category: "reminders", label: "Reminders", icon: "checklist", itemTitle: "Edit"),
        "mail.read": .init(category: "mail", label: "Mail", icon: "envelope", itemTitle: "Read"),
        "mail.send": .init(category: "mail", label: "Mail", icon: "envelope", itemTitle: "Send"),
        "messages.read": .init(category: "messages", label: "Messages", icon: "message", itemTitle: "Read"),
        "messages.send": .init(category: "messages", label: "Messages", icon: "message", itemTitle: "Send"),
        "notes.read": .init(category: "notes", label: "Notes", icon: "note.text", itemTitle: "Read"),
        "notes.write": .init(category: "notes", label: "Notes", icon: "note.text", itemTitle: "Write"),
        "safari.read": .init(category: "safari", label: "Safari", icon: "safari", itemTitle: "Tabs"),
        "safari.control": .init(category: "safari", label: "Safari", icon: "safari", itemTitle: "Open URLs (any browser)"),
        "code.execute": .init(category: "code", label: "Code", icon: "chevron.left.forwardslash.chevron.right", itemTitle: "Execute"),
        "files.read": .init(category: "files", label: "Files", icon: "folder", itemTitle: "Read"),
        "clipboard.read": .init(category: "clipboard", label: "Clipboard", icon: "doc.on.clipboard", itemTitle: "Read Clipboard & Selection"),
        "photos.read": .init(category: "photos", label: "Photos", icon: "photo.on.rectangle", itemTitle: "Read"),
        "music.read": .init(category: "music", label: "Music", icon: "music.note.list", itemTitle: "Read"),
        "music.control": .init(category: "music", label: "Music", icon: "music.note.list", itemTitle: "Control"),
        "screenshot": .init(category: "screenshots", label: "Screenshots", icon: "camera.viewfinder", itemTitle: "Capture"),
        "accessibility.read": .init(category: "accessibility", label: "App Control", icon: "accessibility", itemTitle: "Read UI"),
        "accessibility.execute": .init(category: "accessibility", label: "App Control", icon: "accessibility", itemTitle: "Click & Type"),
    ]

    /// Builds the displayed categories by grouping the gateway-served scopes
    /// (`configStore.permissionScopes`) — never a hardcoded scope list. Group
    /// order follows first appearance of each category in the served order.
    private var personalContextCategories: [PersonalContextCategory] {
        var order: [String] = []
        var grouped: [String: [(title: String, scope: String)]] = [:]
        var meta: [String: (label: String, icon: String)] = [:]

        for scope in configStore.permissionScopes {
            let pres = Self.scopePresentation[scope]
            // Fallback for an unmapped (newly-added) server scope: derive a
            // category from the prefix and titles from the scope itself.
            let category = pres?.category ?? String(scope.split(separator: ".").first ?? Substring(scope))
            let label = pres?.label ?? category.capitalized
            let icon = pres?.icon ?? "lock.shield"
            let itemTitle = pres?.itemTitle
                ?? (scope.split(separator: ".").last.map { $0.capitalized } ?? scope.capitalized)

            if grouped[category] == nil {
                order.append(category)
                meta[category] = (label, icon)
            }
            grouped[category, default: []].append((itemTitle, scope))
        }

        return order.map { category in
            PersonalContextCategory(
                id: category,
                label: meta[category]?.label ?? category.capitalized,
                icon: meta[category]?.icon ?? "lock.shield",
                items: grouped[category] ?? []
            )
        }
    }

    /// Dictionary-backed binding for a permission scope. Reads from
    /// `permissionStates` (seeded from UserDefaults `permission.<scope>` on
    /// appear) and on set writes through to UserDefaults under the SAME key
    /// @AppStorage used before, then posts `.permissionsChanged` so
    /// GatewayClient / RealtimeClient re-sync the agent's `lastChatConfig` and
    /// re-fire its KV cache warmup for the new tool list. Persistence semantics
    /// are unchanged — only the storage indirection moved.
    private func permissionBinding(for scope: String) -> Binding<Bool> {
        Binding(
            get: { permissionStates[scope] ?? UserDefaults.standard.bool(forKey: "permission.\(scope)") },
            set: { newValue in
                permissionStates[scope] = newValue
                UserDefaults.standard.set(newValue, forKey: "permission.\(scope)")
                NotificationCenter.default.post(name: .permissionsChanged, object: nil)
            }
        )
    }

    /// Seeds `permissionStates` from UserDefaults for every served scope, so the
    /// dictionary mirrors persisted values and the toggles render correctly.
    private func loadPermissionStates() {
        var states: [String: Bool] = [:]
        for scope in configStore.permissionScopes {
            states[scope] = UserDefaults.standard.bool(forKey: "permission.\(scope)")
        }
        permissionStates = states
    }

    /// Builds the Permissions settings section with grouped personal context toggles and per-app grants.
    @ViewBuilder
    private func permissionsSection() -> some View {
        VStack(spacing: 16) {
            if !configStore.permissionsLoaded {
                // Server scopes haven't arrived yet (gateway still starting).
                // Show a loading state rather than an empty pane.
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading permissions…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                // One row per category: the category label sits at the leading
                // edge of the row (folded in from the old standalone header) and
                // its read/edit toggles render inline on the trailing side.
                SettingsSection(title: "Permissions") {
                    VStack(spacing: 0) {
                        ForEach(Array(personalContextCategories.enumerated()), id: \.element.id) { categoryIndex, category in
                            if categoryIndex > 0 { Divider() }
                            SettingsRow(title: category.label, description: "", icon: category.icon) {
                                HStack(spacing: 16) {
                                    ForEach(Array(category.items.enumerated()), id: \.offset) { _, item in
                                        HStack(spacing: 6) {
                                            Text(item.title)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            Toggle("", isOn: permissionBinding(for: item.scope))
                                                .toggleStyle(.switch)
                                                .labelsHidden()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            // Ensure scopes are fetched even if the user reaches this pane before
            // GatewayClient.connect() ran (no-op once fetched).
            configStore.fetchIfNeeded()
            loadPermissionStates()
        }
        .onChange(of: configStore.permissionScopes) { _, _ in loadPermissionStates() }
    }

    // MARK: - Data Loading
    private func loadTasks() {
        isLoadingTasks = true
        GatewayClient.shared.fetchTasks { result in
            isLoadingTasks = false
            if case .success(let fetched) = result {
                tasks = fetched
            }
        }
    }

    private func advancedSection() -> some View {
        VStack(spacing: 16) {
            // System Health Section — one-tap overview of servers, permissions, disk.
            SettingsSection(title: "System Health") {
                VStack(spacing: 0) {
                    SettingsRow(
                        title: "System Health",
                        description: "Check all servers, permissions, and disk at a glance",
                        icon: "stethoscope"
                    ) {
                        Button("Open") {
                            showingSystemHealth = true
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Divider()

                    SettingsRow(
                        title: "View Logs",
                        description: "App, gateway, talk, and mac-use logs",
                        icon: "doc.text"
                    ) {
                        Button("View Logs") {
                            showingLogs = true
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            // Testing Section
            SettingsSection(title: "Testing") {
                VStack(spacing: 0) {
                    SettingsRow(
                        title: "Debug Mode",
                        description: "Verbose agent logging (restarts gateway)",
                        icon: "ladybug"
                    ) {
                        Toggle("", isOn: Binding(
                            get: { UserDefaults.standard.bool(forKey: "DebugMode") },
                            set: {
                                UserDefaults.standard.set($0, forKey: "DebugMode")
                                // DEBUG_AGENT is captured at gateway boot, so restart
                                // the agent to pick up the new verbose-logging state.
                                AgentManager.shared.restartAgent()
                            }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }


                }
            }

            // Security Section
            SettingsSection(title: "Security") {
                VStack(spacing: 0) {
                    SettingsRow(
                        title: "Agent Token",
                        description: agentManager.agentToken.isEmpty
                            ? "No token generated"
                            : String(agentManager.agentToken.prefix(12)) + "••••••••",
                        icon: "lock.shield"
                    ) {
                        HStack(spacing: 8) {
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(agentManager.agentToken, forType: .string)
                            }
                            .buttonStyle(.bordered)
                            .disabled(agentManager.agentToken.isEmpty)

                            Button("Regenerate") {
                                agentManager.regenerateAgentToken()
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                }
            }

            // Data Section
            SettingsSection(title: "Data") {
                VStack(spacing: 0) {
                    SettingsRow(title: "Clear History", description: "Delete all chat conversations", icon: "trash") {
                        Button("Clear History") { showingClearAlert = true }
                            .buttonStyle(.bordered)
                    }
                    Divider()
                    SettingsRow(title: "Reset App", description: "Wipe all data, settings, caches, permissions; relaunch", icon: "arrow.counterclockwise") {
                        Button("Reset App") { showingResetAlert = true }
                            .buttonStyle(.bordered)
                    }
                }
            }

            // About Section
            SettingsSection(title: "About") {
                VStack(spacing: 0) {
                    if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                        SettingsRow(title: "Version", description: "", icon: "info.circle") {
                            Text(version)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    /// Wipes local Dottie state (matches gateway/scripts/reset.sh) and relaunches the app.
    /// Preserves STT/TTS model weights: ~/.dottie/{models,checkpoints,data}.
    /// Source of truth for the file list: docs/config-files.md.
    private func performReset() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let bundleID = Bundle.main.bundleIdentifier ?? "com.example.dottie"
        let library = home.appendingPathComponent("Library")
        let dottieDir = home.appendingPathComponent(".dottie")
        let preserve = ["models", "checkpoints", "data"]

        // Move preserved dirs to a temp location, wipe ~/.dottie, restore.
        let tmp = home.appendingPathComponent(".dottie.reset-tmp-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        for name in preserve {
            let src = dottieDir.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path) {
                try? fm.moveItem(at: src, to: tmp.appendingPathComponent(name))
            }
        }
        try? fm.removeItem(at: dottieDir)
        try? fm.createDirectory(at: dottieDir, withIntermediateDirectories: true)
        for name in preserve {
            let src = tmp.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path) {
                try? fm.moveItem(at: src, to: dottieDir.appendingPathComponent(name))
            }
        }
        try? fm.removeItem(at: tmp)

        try? fm.removeItem(at: library.appendingPathComponent("Caches/\(bundleID)"))
        try? fm.removeItem(at: library.appendingPathComponent("HTTPStorages/\(bundleID)"))

        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        UserDefaults.standard.synchronize()

        // Detached shell so it survives our termination: reset TCC perms, then relaunch.
        let bundlePath = Bundle.main.bundlePath
        let cmd = "tccutil reset All \(bundleID); sleep 1; open '\(bundlePath)'"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", cmd]
        try? task.run()

        NSApp.terminate(nil)
    }

}

/// Custom used-fill meter (system ProgressView leaves a gray track and never looks fully red).
private struct FreeUsageMeter: View {
    let usedFraction: Double

    private var fraction: Double {
        min(1, max(0, usedFraction))
    }

    private var fill: Color {
        if fraction >= 1 { return .red }
        if fraction >= 0.85 { return .orange }
        return .accentColor
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(fraction >= 1 ? Color.red.opacity(0.35) : Color.primary.opacity(0.12))
                Capsule()
                    .fill(fill)
                    .frame(width: fraction >= 1 ? geo.size.width : max(geo.size.width * fraction, fraction > 0 ? 3 : 0))
            }
        }
        .frame(height: 6)
        .accessibilityLabel("Free Usage Used")
        .accessibilityValue("\(Int((fraction * 100).rounded())) Percent")
    }
}

#Preview {
    SettingsView()
}
