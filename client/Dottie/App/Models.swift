//
//  Models.swift
//  Dottie
//
//  Shared data models for chat, messages, and app state.
//

import Foundation
import SwiftUI

// MARK: - Agent State

/// Represents the current state of the AI agent for visual feedback.
enum AgentState: String {
    case idle
    case hover
    case thinking
    case listening
    case speaking
}

// MARK: - State Style Configuration

/// Visual configuration for each agent state.
struct AvatarStateStyle {
    let scale: CGFloat
    let outerOpacity: Double
    let midOpacity: Double
    let innerFrom: Color
    let innerTo: Color
    let shadowRadius: CGFloat
    let shadowColor: Color
    let pulseDuration: Double

    static let idle = AvatarStateStyle(
        scale: 1.0,
        outerOpacity: 0.3,
        midOpacity: 0.5,
        innerFrom: Color(hex: "67e8f9"),
        innerTo: Color(hex: "3b82f6"),
        shadowRadius: 20,
        shadowColor: Color(hex: "22d3ee").opacity(0.2),
        pulseDuration: 3.0
    )

    static let hover = AvatarStateStyle(
        scale: 1.15,
        outerOpacity: 0.5,
        midOpacity: 0.7,
        innerFrom: Color(hex: "a5f3fc"),
        innerTo: Color(hex: "6366f1"),
        shadowRadius: 35,
        shadowColor: Color(hex: "6366f1").opacity(0.5),
        pulseDuration: 1.5
    )

    static let thinking = AvatarStateStyle(
        scale: 1.05,
        outerOpacity: 0.6,
        midOpacity: 0.7,
        innerFrom: Color(hex: "facc15"),
        innerTo: Color(hex: "f97316"),
        shadowRadius: 30,
        shadowColor: Color(hex: "facc15").opacity(0.4),
        pulseDuration: 0.8
    )

    static let listening = AvatarStateStyle(
        scale: 1.03,
        outerOpacity: 0.4,
        midOpacity: 0.6,
        innerFrom: Color(hex: "34d399"),
        innerTo: Color(hex: "06b6d4"),
        shadowRadius: 25,
        shadowColor: Color(hex: "22d3ee").opacity(0.3),
        pulseDuration: 1.5
    )

    static let speaking = AvatarStateStyle(
        scale: 1.05,
        outerOpacity: 0.45,
        midOpacity: 0.6,
        innerFrom: Color(hex: "f472b6"),
        innerTo: Color(hex: "a855f7"),
        shadowRadius: 28,
        shadowColor: Color(hex: "a855f7").opacity(0.35),
        pulseDuration: 0.8
    )

    /// Returns the visual style configuration for the given agent state.
    static func style(for state: AgentState) -> AvatarStateStyle {
        switch state {
        case .idle: return .idle
        case .hover: return .hover
        case .thinking: return .thinking
        case .listening: return .listening
        case .speaking: return .speaking
        }
    }
}

// MARK: - AnyCodable

/// Type-erased Codable wrapper for heterogeneous JSON values.
/// Used to represent arbitrary tool input parameters (strings, numbers, booleans, arrays, objects).
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported AnyCodable value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Unsupported AnyCodable value"))
        }
    }
}

// MARK: - Agent Tool Call

/// Represents a tool invocation by the agent during processing.
/// The `id` is a provider-assigned string (not a UUID) matching the agent message standard format.
struct ToolCall: Identifiable, Codable {
    let id: String
    let name: String
    var status: ToolCallStatus
    var result: String?
    var input: [String: AnyCodable]?

    /// - Parameters:
    ///   - id: Provider-assigned tool call ID. Defaults to a generated UUID string if not provided.
    ///   - name: Tool name (e.g. "web_search", "read_file").
    ///   - status: Current execution status.
    ///   - result: Tool execution result text, populated on completion.
    ///   - input: Tool input arguments as a heterogeneous dictionary.
    init(id: String? = nil, name: String, status: ToolCallStatus = .running, result: String? = nil, input: [String: AnyCodable]? = nil) {
        self.id = id ?? UUID().uuidString
        self.name = name
        self.status = status
        self.result = result
        self.input = input
    }

}

/// Status of a tool call during agent processing.
enum ToolCallStatus: String, Codable {
    case running
    case completed
    case error
}

// MARK: - Tool confirm payload

/// Envelope for tool `_ui` payloads (confirmation dialogs).
struct ToolConfirmPayload: Codable {
    let component: String
    let version: Int
    let id: String?
    let data: AnyCodable
    let actions: [UIAction]?
    let fallback: String
}

/// Wrapper to detect and parse _ui payloads from tool results.
struct ToolResultEnvelope: Codable {
    let ui: ToolConfirmPayload?
    enum CodingKeys: String, CodingKey { case ui = "_ui" }
}

// MARK: - UI Actions

/// Action definition for interactive UI components.
/// Defines a button or trigger that can execute a tool or dismiss the component.
struct UIAction: Codable, Identifiable {
    let id: String
    let label: String
    let style: String?
    let tool: String?
    let input: [String: AnyCodable]?
}

// MARK: - Interactive Component Data

/// Confirmation dialog data for destructive operations.
struct ConfirmationDialogData: Codable {
    let title: String
    let message: String
    let destructive: Bool?
}

// MARK: - Attached Image

/// Represents a user-attached image for vision chat (drag-drop or paste).
/// Transient — not persisted to SQLite. Kept in memory for the current session only.
struct AttachedImage: Identifiable {
    let id = UUID()
    let nsImage: NSImage
    let base64DataURI: String

    /// Resizes and compresses an NSImage to a base64 data URI suitable for vision APIs.
    /// Max 1024px on longest edge, JPEG at 0.7 quality.
    static func from(_ image: NSImage) -> AttachedImage? {
        let maxDim: CGFloat = 1024
        let size = image.size
        let scale = min(maxDim / max(size.width, size.height), 1.0)
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)

        let resized = NSImage(size: newSize)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: size),
                   operation: .copy, fraction: 1.0)
        resized.unlockFocus()

        guard let tiff = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            return nil
        }
        let b64 = jpeg.base64EncodedString()
        return AttachedImage(nsImage: resized, base64DataURI: "data:image/jpeg;base64,\(b64)")
    }
}

// MARK: - Chat Provider

/// Represents available AI providers for chat completions.
/// Local and Ollama require no API key; xAI, OpenAI, and Anthropic require Bearer/x-api-key auth.
/// Grok model ids, verified against https://docs.x.ai/llms.txt (2026-08-27).
/// Defined once so a model bump is a single edit instead of a grep across the
/// picker, onboarding, and the launch-time default. Every id here must also be
/// in the relay's `ALLOWED_MODELS` (dottie-pro) or Dottie Pro
/// requests 400 with `invalid_model` — deploy the server side first.
enum GrokModel {
    /// xAI's own recommendation for chat and code: "the most intelligent and
    /// fastest model we've built". What every "pick a sensible cloud model"
    /// path writes.
    static let flagship = "grok-4.6"

    /// Allowlisted by the Dottie Pro relay (api.dottie.ai/api/pro).
    static let pro: [(id: String, name: String)] = [
        ("grok-4.6", "Grok 4.6"),
        ("grok-4.5", "Grok 4.5"),
        ("grok-4.3", "Grok 4.3"),
    ]

    /// BYOK xAI adds the 4.20 pair. 4.3 and 4.20 carry a 1M context at half the
    /// token price of 4.5/4.6's 500k, so they stay listed as the long-context
    /// and cheap picks rather than as legacy. grok-3 / grok-4 / grok-4-fast /
    /// grok-4-1-fast were retired 2026-05-15 (slugs now redirect to grok-4.3 at
    /// grok-4.3 pricing) and are deliberately absent.
    static let xai: [(id: String, name: String)] = pro + [
        ("grok-4.20-0309-reasoning", "Grok 4.20 Reasoning"),
        ("grok-4.20-0309-non-reasoning", "Grok 4.20"),
    ]
}

/// Server-driven model list and default provider, cached from `/api/version`.
///
/// The server serves the exact list `/api/pro/*` enforces, so retiring or
/// adding a model is a `PRO_MODELS` env edit on dottie-pro — no app
/// update, and the picker can never offer something the relay would 400. The
/// last good response is cached in UserDefaults so a launch with no network
/// still renders a picker; if nothing was ever cached, `GrokModel` is the
/// compiled-in floor.
enum RemoteConfig {
    private static let modelsKey = "remoteConfig.cloudModels"
    private static let providerKey = "remoteConfig.defaultProvider"
    private static let byokKey = "remoteConfig.providerModels"

    /// Persist whatever the server sent. Absent fields leave the cache alone —
    /// an older server that omits them must not wipe a good list.
    static func store(_ info: VersionInfo) {
        let defaults = UserDefaults.standard
        if let models = info.models, !models.isEmpty {
            let pairs = models.map { [$0.id, $0.name] }
            defaults.set(pairs, forKey: modelsKey)
        }
        if let provider = info.default_provider, ChatProvider(rawValue: provider) != nil {
            defaults.set(provider, forKey: providerKey)
        }
        if let byok = info.provider_models, !byok.isEmpty {
            let encoded = byok.compactMapValues { models -> [[String]]? in
                let pairs = models.filter { !$0.id.isEmpty }.map { [$0.id, $0.name] }
                return pairs.isEmpty ? nil : pairs
            }
            if !encoded.isEmpty { defaults.set(encoded, forKey: byokKey) }
        }
    }

    /// Cached BYOK picker for a provider, or nil when the server never sent one.
    static func byokModels(for provider: ChatProvider) -> [(id: String, name: String)]? {
        guard let all = UserDefaults.standard.dictionary(forKey: byokKey) as? [String: [[String]]],
              let raw = all[provider.rawValue] else { return nil }
        let models = raw.compactMap { pair -> (id: String, name: String)? in
            guard pair.count == 2, !pair[0].isEmpty else { return nil }
            return (pair[0], pair[1])
        }
        return models.isEmpty ? nil : models
    }

    /// Cached list, or nil when nothing valid has been fetched yet.
    static var cloudModels: [(id: String, name: String)]? {
        guard let raw = UserDefaults.standard.array(forKey: modelsKey) as? [[String]] else { return nil }
        let models = raw.compactMap { pair -> (id: String, name: String)? in
            guard pair.count == 2, !pair[0].isEmpty else { return nil }
            return (pair[0], pair[1])
        }
        return models.isEmpty ? nil : models
    }

    /// Model to select by default: the server's first entry, else the
    /// compiled-in flagship. Every "pick a sensible cloud model" path uses this.
    static var defaultCloudModel: String {
        cloudModels?.first?.id ?? GrokModel.flagship
    }

    /// Provider a fresh install should adopt, when the server named a known one.
    static var defaultProvider: ChatProvider? {
        guard let raw = UserDefaults.standard.string(forKey: providerKey) else { return nil }
        return ChatProvider(rawValue: raw)
    }
}

enum ChatProvider: String, CaseIterable, Identifiable {
    /// Keyless Grok via Dottie's own relay (api.dottie.ai/api/pro) — the server
    /// holds the xAI key; auth is the per-install registration token, read by
    /// the gateway from ~/.dottie/api_token.
    case dottiePro = "dottiepro"
    case xai
    case openai
    case anthropic
    case ollama
    /// On-device llama.cpp via dottie-local façade (`:1318`).
    case dottieLocal = "dottielocal"
    case cerebras

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dottiePro: return "Dottie Pro — Grok"
        case .xai: return "xAI (Grok)"
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .ollama: return "Ollama"
        case .dottieLocal: return "Dottie Local (llama.cpp)"
        case .cerebras: return "Cerebras"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .ollama, .dottieLocal, .dottiePro: return false
        case .xai, .openai, .anthropic, .cerebras: return true
        }
    }

    /// Chat stays on this Mac (Ollama or dottie-local).
    var isOnDeviceChat: Bool { self == .ollama || self == .dottieLocal }

    /// Live `/api/tags` model list (no static catalog).
    var usesDynamicLocalModels: Bool { self == .ollama || self == .dottieLocal }

    /// Grok speech-to-speech for this provider (no separate toggle).
    /// OpenAI / Ollama / etc. use on-device STT+TTS; Pro + BYOK xAI use Grok Voice.
    var usesGrokVoiceAgent: Bool {
        switch self {
        case .xai, .dottiePro: return true
        case .openai, .anthropic, .ollama, .dottieLocal, .cerebras: return false
        }
    }

    var apiKeyStorageKey: String {
        switch self {
        case .xai: return "xaiAPIKey"
        case .openai: return "openaiAPIKey"
        case .anthropic: return "anthropicAPIKey"
        case .cerebras: return "cerebrasAPIKey"
        default: return ""
        }
    }

    /// Company the request is transmitted to, for the cloud-privacy disclosure.
    /// nil for on-device providers — nothing leaves the Mac.
    var cloudVendor: String? {
        switch self {
        case .dottiePro: return "xAI (via Dottie Pro)"
        case .xai: return "xAI"
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .cerebras: return "Cerebras"
        case .ollama, .dottieLocal: return nil
        }
    }

    /// Static model list for cloud providers (synced with gateway AI_PROVIDERS).
    /// Ollama / dottie-local models come from live `/api/tags`, not this list.
    var availableModels: [(id: String, name: String)] {
        switch self {
        case .ollama, .dottieLocal:
            return []
        case .dottiePro:
            return RemoteConfig.cloudModels ?? GrokModel.pro
        case .xai:
            return RemoteConfig.cloudModels ?? GrokModel.xai
        case .openai:
            return RemoteConfig.byokModels(for: self) ?? [
                ("gpt-5", "GPT-5"),
                ("gpt-5-mini", "GPT-5 Mini"),
                ("gpt-5-nano", "GPT-5 Nano"),
                ("gpt-4o", "GPT-4o"),
                ("gpt-4o-mini", "GPT-4o Mini"),
                ("gpt-4.1", "GPT-4.1"),
                ("gpt-4.1-mini", "GPT-4.1 Mini"),
                ("gpt-4.1-nano", "GPT-4.1 Nano"),
                ("o3-mini", "o3-mini"),
            ]
        case .anthropic:
            return RemoteConfig.byokModels(for: self) ?? [
                ("claude-opus-5", "Claude Opus 5"),
                ("claude-sonnet-5", "Claude Sonnet 5"),
                ("claude-fable-5", "Claude Fable 5"),
                ("claude-haiku-4-5-20251001", "Claude Haiku 4.5"),
            ]
        case .cerebras:
            return RemoteConfig.byokModels(for: self) ?? [
                ("llama3.1-8b", "Llama 3.1 8B"),
                ("qwen-3-235b-a22b-instruct-2507", "Qwen 3 235B"),
                ("gpt-oss-120b", "GPT-OSS 120B"),
                ("zai-glm-4.7", "ZAI GLM 4.7"),
            ]
        }
    }

    /// Returns the current provider from UserDefaults.
    /// Missing or legacy `local` → Dottie Pro.
    static var current: ChatProvider {
        let raw = UserDefaults.standard.string(forKey: DefaultsKeys.chatProvider.rawValue)
        if raw == "local" { return .dottiePro }
        if let raw, let p = ChatProvider(rawValue: raw) { return p }
        return .dottiePro
    }

    /// Providers shown in Settings → Agent chat picker.
    static var chatPickerCases: [ChatProvider] { allCases }

    /// Cloud-first default + migrate legacy `local` at launch (DottieApp).
    static func resolveDefaultProviderIfUnset() {
        let defaults = UserDefaults.standard
        let existing = defaults.string(forKey: DefaultsKeys.chatProvider.rawValue)

        if existing == "local" {
            defaults.set(ChatProvider.dottiePro.rawValue, forKey: DefaultsKeys.chatProvider.rawValue)
            defaults.set(RemoteConfig.defaultCloudModel, forKey: DefaultsKeys.selectedCloudModel.rawValue)
            defaults.set(true, forKey: "cloudProviderConsent")
            AppLogger.info("[Models] chatProvider local → Dottie Pro (bundled LLM removed)")
            return
        }

        guard existing == nil else { return }

        if RemoteConfig.defaultProvider == .dottiePro, APITokenStore.load() != nil {
            defaults.set(ChatProvider.dottiePro.rawValue, forKey: DefaultsKeys.chatProvider.rawValue)
            defaults.set(RemoteConfig.defaultCloudModel, forKey: DefaultsKeys.selectedCloudModel.rawValue)
            defaults.set(true, forKey: "cloudProviderConsent")
            AppLogger.info("[Models] chatProvider unset + registration token — defaulting to Dottie Pro (server default)")
            return
        }

        let hasKey = !(KeychainStore.get(forAccount: ChatProvider.xai.apiKeyStorageKey) ?? "").isEmpty
        let hasConsent = defaults.bool(forKey: "cloudProviderConsent")
        if hasKey, hasConsent {
            defaults.set(ChatProvider.xai.rawValue, forKey: DefaultsKeys.chatProvider.rawValue)
            AppLogger.info("[Models] chatProvider unset + xAI key on file — defaulting to cloud (Grok)")
            return
        }

        defaults.set(ChatProvider.dottiePro.rawValue, forKey: DefaultsKeys.chatProvider.rawValue)
        defaults.set(RemoteConfig.defaultCloudModel, forKey: DefaultsKeys.selectedCloudModel.rawValue)
        defaults.set(true, forKey: "cloudProviderConsent")
        AppLogger.info("[Models] chatProvider unset — defaulting to Dottie Pro (cloud-first)")
    }
}


// MARK: - ChatMessage

/// A single chat message (user or assistant) with optional streaming state, thinking
/// content, and tool call badges.
struct ChatMessage: Identifiable, Codable {
    let id: UUID
    var text: String
    let isUser: Bool
    let timestamp: Date
    var isLoading: Bool
    var isStreaming: Bool
    var thinkingContent: String?
    var thinkingStartedAt: Date?
    /// Duration the model spent in the thinking/reasoning phase, in milliseconds.
    /// Stored as ms so the UI can show sub-second precision (e.g. "843ms")
    /// for fast model responses without losing resolution. Display layer in
    /// MessageBubble uses a smart formatter (ms < 1s, decimal s 1-10s, integer s 10s+).
    var thinkingDuration: Int?
    var toolCalls: [ToolCall]?
    var isSystemMessage: Bool
    /// True when the user clicked stop-generating mid-stream; distinguishes a
    /// truncated-but-intentional response from an errored one at render time.
    var wasStopped: Bool = false
    /// User-attached images for vision chat (transient, not persisted).
    var attachedImages: [AttachedImage]?

    enum CodingKeys: String, CodingKey {
        case id, text, isUser, timestamp, isLoading, isStreaming
        case thinkingContent, thinkingStartedAt, thinkingDuration
        case toolCalls, isSystemMessage, wasStopped
        // attachedImages excluded — transient, not serialized
        // Legacy keys (images, stats, isHeartbeat, feedback, textFeedback) ignored on decode.
    }

    /// Creates a new chat message with a generated UUID and current timestamp.
    init(text: String, isUser: Bool, isLoading: Bool = false, isStreaming: Bool = false, thinkingContent: String? = nil, thinkingStartedAt: Date? = nil, thinkingDuration: Int? = nil, toolCalls: [ToolCall]? = nil, isSystemMessage: Bool = false, attachedImages: [AttachedImage]? = nil) {
        self.id = UUID()
        self.text = text
        self.isUser = isUser
        self.timestamp = Date()
        self.isLoading = isLoading
        self.isStreaming = isStreaming
        self.thinkingContent = thinkingContent
        self.thinkingStartedAt = thinkingStartedAt
        self.thinkingDuration = thinkingDuration
        self.toolCalls = toolCalls
        self.isSystemMessage = isSystemMessage
        self.attachedImages = attachedImages
    }

    /// Custom decoder to handle conversations saved before new fields were added.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        isUser = try container.decode(Bool.self, forKey: .isUser)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        isLoading = try container.decode(Bool.self, forKey: .isLoading)
        isStreaming = try container.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        thinkingContent = try container.decodeIfPresent(String.self, forKey: .thinkingContent)
        thinkingStartedAt = try container.decodeIfPresent(Date.self, forKey: .thinkingStartedAt)
        thinkingDuration = try container.decodeIfPresent(Int.self, forKey: .thinkingDuration)
        toolCalls = try container.decodeIfPresent([ToolCall].self, forKey: .toolCalls)
        isSystemMessage = try container.decodeIfPresent(Bool.self, forKey: .isSystemMessage) ?? false
        wasStopped = try container.decodeIfPresent(Bool.self, forKey: .wasStopped) ?? false
        attachedImages = nil
    }
}

extension ChatMessage {
    /// Number of screenshots/images sent with this user turn, parsed from the
    /// trailing `[N image(s)]` marker the gateway appends when it flattens a
    /// multimodal turn for persistence (`flattenMultimodalMessages`). This is the
    /// only image record that survives a reload — the raw data URIs are stripped
    /// on persist — so it's what drives the "screen shared" badge for voice /
    /// Vision-Mode turns and reloaded conversations.
    var screenshotMarkerCount: Int {
        guard let m = text.range(of: #"\[(\d+) images?\]\s*$"#, options: .regularExpression) else { return 0 }
        let digits = text[m].filter(\.isNumber)
        return Int(digits) ?? 0
    }

    /// `text` with the trailing `[N image(s)]` marker removed, for display. The
    /// badge conveys the attachment; the marker itself shouldn't clutter the bubble.
    var displayText: String {
        text.replacingOccurrences(
            of: #"\s*\[\d+ images?\]\s*$"#, with: "", options: .regularExpression
        )
    }
}

// MARK: - Conversation

/// A named conversation containing an ordered array of chat messages.
/// Loaded from agent SQLite store via REST API.
struct Conversation: Identifiable, Codable {
    let id: UUID
    var title: String
    let createdAt: Date
    var lastMessageAt: Date
    var messages: [ChatMessage]

    /// Creates a new conversation with a generated UUID and current timestamp.
    /// - Parameters:
    ///   - title: Display title; defaults to "New conversation" until LLM generates one.
    ///   - messages: Initial messages; defaults to empty.
    init(title: String = "New conversation", messages: [ChatMessage] = []) {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.lastMessageAt = Date()
        self.messages = messages
    }

    /// Creates a conversation with an explicit ID (for API sync).
    /// - Parameters:
    ///   - id: UUID matching the agent session ID.
    ///   - title: Display title.
    ///   - messages: Messages array.
    ///   - createdAt: Creation timestamp.
    ///   - lastMessageAt: Last update timestamp.
    init(id: UUID, title: String, messages: [ChatMessage], createdAt: Date, lastMessageAt: Date) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.lastMessageAt = lastMessageAt
    }

    /// A truncated preview of the first user message, used as a fallback sidebar title.
    var preview: String {
        if let firstUserMessage = messages.first(where: { $0.isUser }) {
            let text = firstUserMessage.text
            return text.count > 50 ? String(text.prefix(50)) + "..." : text
        }
        return "New conversation"
    }
}

// MARK: - Full Agent Session API Models (for canonical storage)

/// Message format from agent SQLite store (standard format).
struct FullAgentMessage: Codable {
    let role: String
    let content: String
    var id: String?
    var toolCalls: [FullAgentToolCall]?
    var thinkingContent: String?

    enum CodingKeys: String, CodingKey {
        case role, content, id
        case toolCalls = "tool_calls"
        case thinkingContent = "thinking_content"
    }
}

/// Tool call format from agent SQLite store.
struct FullAgentToolCall: Codable {
    let id: String
    let name: String
    var status: String?
    var result: String?
    var input: [String: AnyCodable]?
}

/// Session from agent SQLite store with full message history.
/// Different from GatewayClient.AgentSession which is a minimal listing format.
struct FullAgentSession: Codable, Identifiable {
    let id: String
    let owner: String
    var title: String
    var messages: [FullAgentMessage]
    var model: String
    var provider: String
    let createdAt: Date
    var updatedAt: Date
    var messageCount: Int?

    /// Convert to Swift Conversation model.
    func toConversation() -> Conversation {
        var chatMessages: [ChatMessage] = []

        // Convert agent messages to ChatMessages
        for msg in messages {
            // Skip system messages (first message is usually system prompt)
            if msg.role == "system" { continue }

            let isUser = msg.role == "user"
            let toolCalls: [ToolCall]? = msg.toolCalls?.map { tc in
                ToolCall(
                    id: tc.id,
                    name: tc.name,
                    status: ToolCallStatus(rawValue: tc.status ?? "completed") ?? .completed,
                    result: tc.result,
                    input: tc.input
                )
            }

            // Strip inline reasoning/followup tags from stored content. Handles
            // complete and truncated <think>/<thinking>/<followup> blocks. The
            // model's reasoning belongs in `thinkingContent` (separate UI), not
            // raw in the chat bubble.
            let cleanContent = msg.content
                .replacingOccurrences(of: "<?/?followup>[\\s\\S]*?<?/?followup>|<?/?followup>[\\s\\S]*$|<?/?followup>|<?/?follow[a-z]*>?$", with: "", options: .regularExpression)
                // Gemma 4 reasoning/tool blocks (content included) + bare control tokens leaked
                // by a bad GGUF export / tokenizer mismatch (llama.cpp #23252, #21365).
                .replacingOccurrences(of: "<\\|channel>[\\s\\S]*?<channel\\|>|<\\|tool_call>[\\s\\S]*?<tool_call\\|>|<\\|tool_response>[\\s\\S]*?<tool_response\\|>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "<\\|turn>(system|user|model)?|<\\|(turn|channel|tool_response|tool_call|tool)>|<(turn|channel|tool_response|tool_call|tool)\\|>|<\\|(think|image|audio|\")\\|>|</?(start_of_turn|end_of_turn|start_of_image|end_of_image|start_of_audio|end_of_audio|bos|eos|pad|unk)>|<unused[0-9]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "<think>[\\s\\S]*?</think>|<think>[\\s\\S]*$", with: "", options: .regularExpression)
                .replacingOccurrences(of: "<thinking>[\\s\\S]*?</thinking>|<thinking>[\\s\\S]*$", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let chatMessage = ChatMessage(
                text: cleanContent,
                isUser: isUser,
                isLoading: false,
                isStreaming: false,
                thinkingContent: msg.thinkingContent,
                toolCalls: toolCalls
            )
            chatMessages.append(chatMessage)
        }

        return Conversation(title: title.isEmpty ? "New conversation" : title, messages: chatMessages)
    }
}

/// Response wrapper for session list endpoint.
struct FullSessionListResponse: Codable {
    let sessions: [FullAgentSession]
}

/// Response wrapper for single session endpoint.
struct FullSessionResponse: Codable {
    let session: FullAgentSession
}

// MARK: - Notification Names

extension Notification.Name {
    // Chat
    static let sendChatMessage = Notification.Name("sendChatMessage")
    static let openSettingsWindow = Notification.Name("openSettingsWindow")

    // Recording
    static let toggleRecording = Notification.Name("toggleRecording")

    // Connection / streaming (legacy name: heartbeatEventReceived)
    static let heartbeatEventReceived = Notification.Name("heartbeatEventReceived")

    // Appearance
    static let themeChanged = Notification.Name("themeChanged")

    // Chat config (provider / model / API key changed — re-sync live realtime session)
    static let chatConfigChanged = Notification.Name("chatConfigChanged")

    // Proactive Orb
    static let triggerProactiveGlow = Notification.Name("triggerProactiveGlow")

    // Launcher
    static let launcherFocusTextField = Notification.Name("launcherFocusTextField")

    // Permissions
    static let permissionsChanged = Notification.Name("permissionsChanged")

    // Persistent error banner
    static let showErrorBanner = Notification.Name("showErrorBanner")
    static let clearErrorBanner = Notification.Name("clearErrorBanner")

    // ToolSearch dev overlay (debug builds only)
    static let toolContextChanged = Notification.Name("toolContextChanged")
    /// Final cursor-mode dictation transcript (userInfo `text: String`).
    /// Onboarding tryout listens so text lands without relying on Cmd+V + focus.
    static let dictationTranscript = Notification.Name("dictationTranscript")
}

// MARK: - Error Banner

/// Payload for the persistent chat error banner. Posted via `.showErrorBanner`
/// notification; dismissed on user action, on a matching `.clearErrorBanner`
/// notification (same `code`), or when another banner with the same code arrives
/// and replaces it.
struct ChatBannerError: Equatable {
    /// Stable identifier (e.g., "engine_down", "screen_recording_denied", "stt_unavailable").
    /// Used for replace/clear semantics so duplicate errors don't stack.
    let code: String

    /// User-facing message. Short, actionable ("Dottie's agent isn't responding" is better than raw error text).
    let message: String

    /// Optional button label + action. `nil` = dismiss-only banner.
    let actionLabel: String?
    let action: BannerAction?

    /// Optional second button, shown left of the primary one. Used when the
    /// primary action can't actually fix the error on its own (e.g. `llm_error`
    /// offers Retry, but a misconfigured cloud provider needs Settings).
    var secondaryLabel: String? = nil
    var secondaryAction: BannerAction? = nil

    enum BannerAction: Equatable {
        case restartAgent
        case openSystemSettingsPane(String)
        case openModelsSettings
        case retryLastMessage
    }
}

// MARK: - Chat Color Theme

/// Adaptive color theme for chat UI supporting light and dark modes.
struct ChatColorTheme {
    let chatBackground: Color
    let cardBackground: Color
    let accentBackground: Color
    let primaryText: Color
    let mutedText: Color
    let dimText: Color
    let runningBlue: Color
    let runningBlueText: Color
    let doneGray: Color
    let doneGrayText: Color
    let errorRed: Color
    let errorRedText: Color

    static let dark = ChatColorTheme(
        chatBackground: Color(red: 0.04, green: 0.04, blue: 0.04),
        cardBackground: Color.white.opacity(0.10),
        accentBackground: Color(red: 0.09, green: 0.09, blue: 0.09),
        primaryText: .white,
        mutedText: Color(white: 0.64),
        dimText: Color(white: 0.45),
        runningBlue: Color.blue.opacity(0.1),
        runningBlueText: Color(red: 0.23, green: 0.51, blue: 0.96),
        doneGray: Color.white.opacity(0.05),
        doneGrayText: Color(white: 0.64),
        errorRed: Color.red.opacity(0.1),
        errorRedText: .red
    )

    static let light = ChatColorTheme(
        chatBackground: Color(red: 0.96, green: 0.96, blue: 0.96),
        cardBackground: Color.black.opacity(0.06),
        accentBackground: Color(red: 0.91, green: 0.91, blue: 0.91),
        primaryText: Color(white: 0.08),
        mutedText: Color(white: 0.28),
        dimText: Color(white: 0.40),
        runningBlue: Color.blue.opacity(0.1),
        runningBlueText: Color(red: 0.23, green: 0.51, blue: 0.96),
        doneGray: Color.black.opacity(0.05),
        doneGrayText: Color(white: 0.40),
        errorRed: Color.red.opacity(0.1),
        errorRedText: .red
    )
}

/// Factory for retrieving the appropriate chat color theme based on the current color scheme.
enum ChatColors {
    static func theme(for scheme: ColorScheme) -> ChatColorTheme {
        scheme == .dark ? .dark : .light
    }
}
