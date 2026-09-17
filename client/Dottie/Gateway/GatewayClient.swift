//
//  GatewayClient.swift
//  Dottie
//
//  Thin HTTP/SSE client for the gateway architecture.
//  Swift becomes a pure client — all process management moves to the agent service.
//

import Foundation
import Security
import Combine
import AVFoundation
import AppKit

// MARK: - System Status

/// Overall system health state derived from aggregated service status.
enum SystemStatus: String, Equatable {
    case unknown
    case starting
    case ready       // All services running
    case degraded    // Some services failed
    case down        // No services running
}

// MARK: - Service Status

/// Status of a single managed service (talk, macuse).
struct ServiceStatus: Equatable {
    let name: String
    let port: Int
    var state: String  // "stopped", "starting", "running", "stopping", "failed"
    var error: String?
    var restartCount: Int

    var isRunning: Bool { state == "running" }
    var isFailed: Bool { state == "failed" }
}

// MARK: - Gateway Client

/// Thin HTTP/SSE client for the agent gateway.
/// Swift becomes a pure client — no process management, just REST calls and SSE streaming.
class GatewayClient: ObservableObject {
    static let shared = GatewayClient()

    // MARK: Published State (driven by SSE)

    @Published var systemStatus: SystemStatus = .unknown
    @Published var services: [String: ServiceStatus] = [:]
    @Published var isConnected: Bool = false

    /// The current agent bearer token, read fresh from disk on every access so it
    /// can never go stale. Token generation/persistence is owned by `AgentManager`;
    /// this is the request-auth value used by the `Bearer \(agentToken)` sites and
    /// has no SwiftUI observers (Settings displays `AgentManager.agentToken` instead).
    var agentToken: String { AgentToken.load() ?? "" }

    // MARK: Internal State (cross-file extensions)

    /// Dedicated URLSession for SSE streams. Standard `session` has a 10s
    /// request timeout which kills idle SSE connections — this one is uncapped
    /// and tolerates the long-lived health/install streams (paired with
    /// server-side keepalive pings every 15s in system_routes.js).
    lazy var streamSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = .infinity
        config.timeoutIntervalForResource = .infinity
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()
    var cancellables = Set<AnyCancellable>()

    /// Background poll that clears the `stt_unavailable` banner once the gateway recovers.
    var sttRecoveryPollTimer: Timer?

    /// Last /health probe failure class while waiting for the gateway to bind
    /// (`bucketURLError`). Attached to `port_never_bound` so the event says
    /// refused vs timed out vs reset instead of only "never bound".
    var lastGatewayProbeError: String = ""

    lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    private init() {
        // Derive systemStatus from AgentManager.$status — AgentManager is the sole
        // owner of the /system/health/stream SSE and the sole decider of gateway
        // liveness. GatewayClient used to open a SECOND duplicate stream and decide
        // systemStatus independently from its own services[] poll, which caused the
        // documented .down/.running flapping (two streams, two deciders). Now there
        // is exactly one SSE subscriber (AgentManager) and one liveness signal that
        // both the menu bar (DottieApp.observeMenuBarState) and onboarding
        // (DottieApp.evaluateOnboardingState) read off systemStatus.
        //
        // Installed at init (not in connect()) because AgentManager can reach
        // .running — and the menu bar / onboarding can read systemStatus — before
        // connect() runs. Mapping mirrors the old updateSystemStatus() buckets:
        // .running → .ready, .starting → .starting, .stopped → .down,
        // .error → .degraded, .stopping/other → .unknown.
        AgentManager.shared.$status
            .map { agentStatus -> SystemStatus in
                switch agentStatus {
                case .running: return .ready
                case .starting: return .starting
                case .stopped: return .down
                case .error: return .degraded
                case .stopping: return .unknown
                }
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: \.systemStatus, on: self)
            .store(in: &cancellables)

        // Re-push config to the agent whenever the user toggles a permission in Settings.
        // The agent uses this to re-fire its KV cache warmup for the new tool list, so the
        // next chat doesn't pay an 8s cold prompt reprocess.
        NotificationCenter.default.addObserver(
            forName: .permissionsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.pushChatConfig()
        }

    }

    deinit {
        disconnect()
        session.invalidateAndCancel()
        streamSession.invalidateAndCancel()
        NotificationCenter.default.removeObserver(self)
    }



    // MARK: - Generic Agent Request

    /// Builds an authenticated agent request for `path` and returns the raw
    /// response body plus HTTP status. Centralizes the URL construction, the
    /// `Bearer` auth header (re-read from disk on every call via `setAgentAuth`,
    /// so it can never go stale), the method, the JSON body + `Content-Type`, and
    /// the `HTTPURLResponse` cast that every REST call site used to hand-roll.
    ///
    /// `session` defaults to the standard 10s-timeout `session`; pass
    /// `streamSession` for the uncapped long-running `/system/*` control calls.
    /// `timeout`, when non-nil, overrides the session's per-request timeout.
    ///
    /// Endpoints that don't fit this shape — auth-exempt `/health` probes with
    /// bespoke logging, multipart uploads, the ISO8601 session CRUD, and the
    /// streaming `fireEvent` — are intentionally NOT routed through here.
    func agentData(
        _ path: String,
        method: String = "GET",
        body: Data? = nil,
        session: URLSession? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: "http://127.0.0.1:\(AppPorts.agentServer)\(path)") else {
            AppLogger.error("GatewayClient: invalid URL for \(path)")
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        ClientManager.setAgentAuth(on: &request)
        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        if let timeout = timeout { request.timeoutInterval = timeout }
        let (data, response) = try await (session ?? self.session).data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401 { AgentManager.shared.handleGatewayAuthRejected(source: path) }
        return (data, http)
    }

    // MARK: - Generic Decodable Fetch

    /// Runs `agentData` on the standard `ClientManager` session and JSON-decodes
    /// the response body into `T`. Shared by the `fetch*` REST wrappers so each one
    /// no longer hand-rolls URL construction, the `Bearer` header, the URLSession
    /// call, and the JSONDecoder.
    func performDecodableFetch<T: Decodable>(
        _ path: String,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> T {
        let (data, _) = try await agentData(
            path, method: method, body: body, session: ClientManager.shared.urlSession
        )
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Event Streaming

    /// Permission scope keys — delegates to ConfigStore (server-driven).
    static var permissionScopes: [String] { ConfigStore.shared.permissionScopes }

    /// Builds permission dictionary — delegates to ConfigStore (server-driven scopes).
    static func buildPermissions() -> [String: Bool] { ConfigStore.shared.buildPermissions() }

}

