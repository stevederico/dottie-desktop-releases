//
//  ClientManager.swift
//  Dottie
//
//  Created by Steve Derico on 6/29/25.
//

import Foundation
import AppKit

// MARK: - Centralized Port Configuration

/// Port assignments for each local server process managed by Dottie.
struct AppPorts {
    static let ttsServer: Int = 1314        // koko / Kokoros TTS
    static let audioServer: Int = 1315      // parakeet-server STT
    static let agentServer: Int = 1317      // gateway
    static let axServer: Int = 1319         // in-process AXService
}

// MARK: - Model Defaults

/// Default model identifiers for bundled speech engines (chat is cloud-only).
struct ModelDefaults {
    static let ttsModel = "kokoro-v1.0"
    static let sttModel = "parakeet-tdt-v3"
    static let voice = "af_sarah"
    static let speed = 1.0
    static let avatarStyle = "metal"
}

// MARK: - UserDefaults Keys

/// Persisted @AppStorage / UserDefaults key strings shared across views.
/// rawValue MUST stay byte-identical to the original literals so existing
/// user defaults still load. @AppStorage requires a String key, so call sites
/// use `DefaultsKeys.x.rawValue`.
enum DefaultsKeys: String {
    case avatarStyle = "avatarStyle"
    case selectedModel = "selectedModel"
    case chatProvider = "chatProvider"
    case selectedCloudModel = "selectedCloudModel"
    case appColorScheme = "appColorScheme"
    /// Base URL for dottie-local façade (Settings → Provider → Dottie Local).
    case dottieLocalBaseUrl = "dottieLocalBaseUrl"
}

/// Resolved dottie-local façade base (no trailing slash).
/// Order: non-empty UserDefaults → `DOTTIE_LOCAL_URL` → `http://127.0.0.1:1318`.
enum DottieLocalEndpoint {
    static let defaultBaseURL = "http://127.0.0.1:1318"

    static func resolvedBaseURL(
        defaults: UserDefaults = .standard,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let fromDefaults = defaults.string(forKey: DefaultsKeys.dottieLocalBaseUrl.rawValue)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fromEnv = env["DOTTIE_LOCAL_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var url = !fromDefaults.isEmpty ? fromDefaults : (!fromEnv.isEmpty ? fromEnv : defaultBaseURL)
        while url.hasSuffix("/") { url.removeLast() }
        return url.isEmpty ? defaultBaseURL : url
    }
}

// MARK: - ISO8601 Date Decoder

/// Creates a JSONDecoder configured to handle ISO8601 dates with fractional seconds.
/// JavaScript's toISOString() includes milliseconds (e.g., "2026-03-03T04:53:28.109Z")
/// which Swift's default .iso8601 strategy does not support.
func makeISO8601Decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    let fallbackFormatter = ISO8601DateFormatter()
    fallbackFormatter.formatOptions = [.withInternetDateTime]

    decoder.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let dateString = try container.decode(String.self)

        if let date = formatter.date(from: dateString) {
            return date
        }
        if let date = fallbackFormatter.date(from: dateString) {
            return date
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Cannot decode date: \(dateString)"
            )
        )
    }
    return decoder
}

/// Shared HTTP client for all server communication (audio, LLM, agent, store).
/// Provides TTS generation/playback, STT transcription, chat streaming via SSE,
/// model management, and REST wrappers for the agent service APIs.
class ClientManager: ObservableObject {
    static let shared = ClientManager()

    // Configured URLSession with proper timeouts
    let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30.0  // 30 seconds for request
        configuration.timeoutIntervalForResource = 120.0 // 2 minutes for entire resource (for large AI operations)
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private init() {}

    // MARK: - Agent Auth

    /// Reads the agent token from ~/.dottie/agent_token and sets the Authorization header.
    static func setAgentAuth(on request: inout URLRequest) {
        guard let token = AgentToken.load() else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    // MARK: - Local model tags (Ollama / dottie-local)

    /// Fetches models from an Ollama-shaped `GET /api/tags` endpoint.
    func fetchLocalTagModels(
        baseURL: String,
        completion: @escaping (Result<[(id: String, name: String)], Error>) -> Void
    ) {
        guard let url = URL(string: "\(baseURL)/api/tags") else {
            completion(.failure(ClientError.invalidURL))
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        urlSession.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                if let error = error { completion(.failure(error)); return }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let models = json["models"] as? [[String: Any]] else {
                    completion(.success([])); return
                }
                let result = models.compactMap { m -> (id: String, name: String)? in
                    guard let name = m["name"] as? String else { return nil }
                    return (id: name, name: name)
                }
                completion(.success(result))
            }
        }.resume()
    }

    /// Fetches available Ollama models from the local Ollama daemon.
    func fetchOllamaModels(completion: @escaping (Result<[(id: String, name: String)], Error>) -> Void) {
        fetchLocalTagModels(baseURL: "http://127.0.0.1:11434", completion: completion)
    }

    /// Fetches models from dottie-local façade (Settings URL, else env, else `:1318`).
    func fetchDottieLocalModels(completion: @escaping (Result<[(id: String, name: String)], Error>) -> Void) {
        fetchLocalTagModels(baseURL: DottieLocalEndpoint.resolvedBaseURL(), completion: completion)
    }

    /// Format bytes into human-readable string
    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

}

// MARK: - Streaming Delegate

/// URLSession delegate that parses SSE events from the agent service (port 1317).
/// Event types: thinking, text_delta, tool_start, tool_result, followup, compaction, done, error.
/// Text normalization (tool markers, channel tokens, inline tokens) is handled server-side.
class StreamingDelegate: NSObject, URLSessionDataDelegate {
    /// Streaming error messages already reported this session (see the
    /// agent streaming error log site).
    static var reportedAgentServerErrors = Set<String>()

    private var buffer = ""
    private var thinkingBuffer = ""
    private var responseBuffer = ""
    private var toolCalls: [ToolCall] = []
    private var suggestedFollowup: String?

    private let onChunk: (String, String?, [ToolCall]) -> Void
    private let onComplete: (Result<(String, String?, [ToolCall], String?), Error>) -> Void
    private let onFollowup: ((String) -> Void)?
    private let onCompaction: (() -> Void)?

    init(
        onChunk: @escaping (String, String?, [ToolCall]) -> Void,
        onComplete: @escaping (Result<(String, String?, [ToolCall], String?), Error>) -> Void,
        onFollowup: ((String) -> Void)? = nil,
        onCompaction: (() -> Void)? = nil
    ) {
        self.onChunk = onChunk
        self.onComplete = onComplete
        self.onFollowup = onFollowup
        self.onCompaction = onCompaction
    }

    func reset() {
        buffer = ""
        thinkingBuffer = ""
        responseBuffer = ""
        toolCalls = []
        suggestedFollowup = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let str = String(data: data, encoding: .utf8) else { return }

        buffer += str

        // Parse SSE lines
        while let range = buffer.range(of: "\n\n") {
            let chunk = String(buffer[..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])

            guard chunk.hasPrefix("data: ") else { continue }
            let jsonStr = String(chunk.dropFirst(6))
            if jsonStr == "[DONE]" { continue }

            guard let jsonData = jsonStr.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let eventType = event["type"] as? String else { continue }

            switch eventType {
            case "thinking":
                // Direct thinking events from agent service
                if let content = event["text"] as? String {
                    thinkingBuffer += content
                    let thinking = self.thinkingBuffer
                    let tools = self.toolCalls
                    DispatchQueue.main.async { [weak self] in
                        self?.onChunk("", thinking, tools)
                    }
                }

            case "text_delta":
                // Server normalizes text (strips tool markers, channel tokens, inline tokens)
                if let content = event["text"] as? String {
                    responseBuffer += content
                }
                let response = self.responseBuffer
                let thinking = self.thinkingBuffer.isEmpty ? nil : self.thinkingBuffer
                let tools = self.toolCalls
                DispatchQueue.main.async { [weak self] in
                    self?.onChunk(response, thinking, tools)
                }

            case "tool_start":
                let toolName = event["tool"] as? String ?? event["name"] as? String ?? "tool"
                let toolId = event["id"] as? String ?? event["tool_call_id"] as? String
                var toolInput: [String: AnyCodable]? = nil
                if let inputDict = event["input"] as? [String: Any] {
                    toolInput = inputDict.mapValues { AnyCodable($0) }
                }
                let call = ToolCall(id: toolId, name: toolName, status: .running, input: toolInput)
                toolCalls.append(call)

                AppLogger.shared.info("[AgentStreaming] 🔧 Tool started: \(toolName) (id: \(toolId ?? "nil"))")
                if UserDefaults.standard.bool(forKey: "DebugAgentStreaming"), let input = toolInput {
                    AppLogger.shared.debug("[AgentStreaming] 📥 Tool input: \(input)")
                }

                let response = self.responseBuffer
                let thinking = self.thinkingBuffer.isEmpty ? nil : self.thinkingBuffer
                let tools = self.toolCalls
                DispatchQueue.main.async { [weak self] in
                    self?.onChunk(response, thinking, tools)
                }

            case "tool_result":
                let toolName = event["tool"] as? String ?? event["name"] as? String ?? "tool"
                let toolResultId = event["id"] as? String ?? event["tool_call_id"] as? String
                let resultText = event["result"] as? String
                // Match by ID first (reliable), fall back to name+status match
                let index: Int? = if let toolResultId {
                    toolCalls.lastIndex(where: { $0.id == toolResultId })
                } else {
                    toolCalls.lastIndex(where: { $0.name == toolName && $0.status == .running })
                }
                if let index {
                    // Gateway enriches every tool_result with explicit error flag
                    let isErrorResult = (event["error"] as? Bool) ?? false
                    toolCalls[index].status = isErrorResult ? .error : .completed
                    toolCalls[index].result = resultText

                    let emoji = isErrorResult ? "❌" : "✅"
                    let verb = isErrorResult ? "failed" : "completed"
                    AppLogger.shared.info("[AgentStreaming] \(emoji) Tool \(verb): \(toolName) (id: \(toolResultId ?? "nil"))")
                    if UserDefaults.standard.bool(forKey: "DebugAgentStreaming"), let result = resultText {
                        AppLogger.shared.debug("[AgentStreaming] Tool result (\(result.count) chars)")
                    }
                } else {
                    AppLogger.shared.warn("[AgentStreaming] ⚠️ Tool result received but no matching running tool: \(toolName) (id: \(toolResultId ?? "nil"))")
                }


                let response = self.responseBuffer
                let thinking = self.thinkingBuffer.isEmpty ? nil : self.thinkingBuffer
                let tools = self.toolCalls
                DispatchQueue.main.async { [weak self] in
                    self?.onChunk(response, thinking, tools)
                }

            case "tool_error":
                let toolName = event["tool"] as? String ?? event["name"] as? String ?? "tool"
                let toolErrorId = event["id"] as? String ?? event["tool_call_id"] as? String
                let errorText = event["error"] as? String ?? "Tool failed"
                // Match by ID first (reliable), fall back to name+status match
                let index: Int? = if let toolErrorId {
                    toolCalls.lastIndex(where: { $0.id == toolErrorId })
                } else {
                    toolCalls.lastIndex(where: { $0.name == toolName && $0.status == .running })
                }
                if let index {
                    toolCalls[index].status = .error
                    toolCalls[index].result = errorText

                    AppLogger.shared.info("[AgentStreaming] ❌ Tool error: \(toolName) (id: \(toolErrorId ?? "nil"))")
                    if UserDefaults.standard.bool(forKey: "DebugAgentStreaming") {
                        AppLogger.shared.debug("[AgentStreaming] Tool error (\(errorText.count) chars)")
                    }
                } else {
                    AppLogger.shared.warn("[AgentStreaming] ⚠️ Tool error received but no matching running tool: \(toolName) (id: \(toolErrorId ?? "nil"))")
                }
                let response = self.responseBuffer
                let thinking = self.thinkingBuffer.isEmpty ? nil : self.thinkingBuffer
                let tools = self.toolCalls
                DispatchQueue.main.async { [weak self] in
                    self?.onChunk(response, thinking, tools)
                }

            case "image":
                // Generated-image UI removed; ignore.
                break

            case "followup":
                // Followup suggestion from the agent
                if let text = event["text"] as? String {
                    suggestedFollowup = text
                    DispatchQueue.main.async { [weak self] in
                        self?.onFollowup?(text)
                    }
                }

            case "stats":
                // MessageStats UI removed; ignore.
                break

            case "compaction":
                // History was compressed to fit context window
                AppLogger.shared.debug("[AgentStreaming] 📦 Compaction event received")
                DispatchQueue.main.async { [weak self] in
                    self?.onCompaction?()
                }

            case "error":
                let errorMsg = event["error"] as? String ?? "Agent error"
                // Server-relayed error event — same dedupe pattern as
                // RealtimeClient.handleTextMessage. The detection happened
                // server-side; don't double-count by logging at error here.
                AppLogger.shared.warn("[AgentStreaming] ❌ Error event: \(errorMsg)")
                // Capture the first 120 chars of the server-supplied error so
                // the daily error report shows what actually failed instead of
                // just "source=streaming, count=3" with no signal on the cause.
                // Safe to log: these are gateway/event-bridge internal errors,
                // not user content. Truncate to bound the SQLite props column.
                // Bare "fetch failed" on this path means the local engine wasn't up
                // when the request hit it — almost always a first-launch cold start
                // (model still downloading) or a mid-session engine death already
                // mid-session engine death is logged on the realtime path.
                // Either way it's recoverable noise, not a distinct failure, so skip
                // logging. Any error message with real signal still gets logged once.
                // Once per distinct message per session: 27 rows across 13
                // installs were mostly the same message repeating on every
                // send while a provider was down.
                let msgKey = String(errorMsg.prefix(120))
                let proCap = ProPaywall.classify(message: errorMsg)
                switch proCap {
                case .freeCreditUsed:
                    AppLogger.shared.warn("[ClientManager] pro.cap kind=free_credit source=streaming")
                case .dailyLimit:
                    AppLogger.shared.warn("[ClientManager] pro.cap kind=daily_limit source=streaming")
                case .spendingCap:
                    AppLogger.shared.warn("[ClientManager] pro.cap kind=spending_cap source=streaming")
                case .other:
                    if errorMsg.lowercased() != "fetch failed",
                       Self.reportedAgentServerErrors.insert(msgKey).inserted {
                        AppLogger.shared.warn("[ClientManager] agent error")
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    self?.onComplete(.failure(ClientError.agentError(errorMsg)))
                }

            case "done":
                // Final event — handled in didCompleteWithError
                break

            default:
                break
            }
        }
    }


    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let responseBuffer = self.responseBuffer
        let thinkingBuffer = self.thinkingBuffer
        let toolCalls = self.toolCalls
        let suggestedFollowup = self.suggestedFollowup

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Cancellation is not a failure — the user/app tore down the stream
            // (e.g. ESC, new message). Finalize the placeholder with whatever was
            // accumulated so it isn't left dangling, then return so we don't also
            // hit the success path below (no double-finalize).
            let isCancelled = (error as NSError?)?.code == NSURLErrorCancelled

            if let error = error, !isCancelled {
                self.onComplete(.failure(error))
            } else {
                // Normal completion OR cancellation — server normalizes text,
                // so use the accumulated response directly to finalize.
                let cleanResponse = responseBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                let finalThinking = thinkingBuffer.isEmpty ? nil : thinkingBuffer

                self.onComplete(.success((
                    cleanResponse,
                    finalThinking,
                    toolCalls,
                    suggestedFollowup
                )))
            }
        }
    }

}

// MARK: - Error Types

/// Errors produced by `ClientManager` HTTP operations and response parsing.
enum ClientError: LocalizedError {
    case invalidURL
    case fileTooLarge
    case invalidResponse
    case serverError(Int, String)
    case missingAPIKey(String)
    case noTranscriptionText
    case emptyResponse
    case agentError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid server URL"
        case .fileTooLarge:
            return "File size exceeds 100MB limit"
        case .invalidResponse:
            return "Invalid response from server"
        case .serverError(let code, let provider):
            switch code {
            case 401:
                return "Invalid API key for \(provider). Check your key in Settings → Assistant."
            case 403:
                return "Access denied by \(provider). Your API key may lack permissions."
            case 429:
                return "Rate limited by \(provider). Please wait a moment and try again."
            case 500...599:
                return "The \(provider) service is temporarily unavailable. Try again shortly."
            default:
                return "Server error from \(provider) (status: \(code))"
            }
        case .missingAPIKey(let provider):
            return "No API key configured for \(provider). Add your key in Settings → Assistant."
        case .noTranscriptionText:
            return "No transcription text found in response"
        case .emptyResponse:
            return "Empty response from server"
        case .agentError(let message):
            return message
        }
    }
}

// MARK: - Agent Token

/// Reads the agent bearer token from disk.
/// Token generation and file creation remain in `AgentManager` (the owner).
enum AgentToken {
    /// Loads the agent token from ~/.dottie/agent_token.
    /// Returns nil if the file is missing, empty, or unreadable.
    static func load() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dottie/agent_token")
        guard let token = try? String(contentsOf: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return token
    }
}
