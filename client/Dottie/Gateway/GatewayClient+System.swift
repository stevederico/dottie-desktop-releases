import Foundation

extension GatewayClient {
    // MARK: - Lifecycle

    /// Runs the gateway's one-time client setup: start managed services, push chat
    /// config, prime ConfigStore, and fill the per-service `services` dictionary
    /// (read by Settings) with a single status poll.
    ///
    /// This method does NOT open a `/system/health/stream` socket and does NOT
    /// decide `systemStatus` — `AgentManager` is the sole owner of that SSE stream
    /// and the sole decider of gateway liveness. `systemStatus` is derived from
    /// `AgentManager.$status` via the Combine subscription installed in
    /// `GatewayClient.init`. connect() is only ever invoked by DottieApp's `.running`
    /// readiness sink (fix #6), so the agent is already known healthy here — no
    /// health gate is needed, and `startServices()`'s own `waitForGatewayReady`
    /// probe covers the brief window before :1317 finishes binding.
    func connect() {
        AppLogger.info("GatewayClient: running one-time setup (agent already .running)")
        startServices()
        pushChatConfig()
        ConfigStore.shared.fetchIfNeeded()
        Task {
            await pollStatus()
        }
    }

    // MARK: - Chat Config Push

    /// Pushes the current chat config (provider, model, apiKey, permissions) to the
    /// agent service. Heartbeats and other internal timer-driven flows use the cached
    /// in-memory copy to call the user's selected cloud provider. Call this on connect
    /// and on every Settings change to provider, model, or API key.
    /// Builds the current chat config body ({ provider, model, apiKey, permissions,
    /// speed, xaiVoice }) from UserDefaults. Shared by `pushChatConfig()` (HTTP POST)
    /// and the realtime WebSocket `sendConfig()` so both paths use identical
    /// resolution logic.
    func chatConfigBody() -> [String: Any] {
        let provider = ChatProvider.current
        let model: String
        if provider == .ollama || provider == .dottieLocal {
            // Ollama / dottie-local models come from live /api/tags (Settings picker), not the
            // static catalog — availableModels is always []. Passing
            // through selectedCloudModel was required; catalog validation wiped
            // the pick → empty model → 404 "model not found" (field Michael ×20).
            let cloudModel = UserDefaults.standard.string(forKey: DefaultsKeys.selectedCloudModel.rawValue) ?? ""
            model = cloudModel
        } else {
            let cloudModel = UserDefaults.standard.string(forKey: DefaultsKeys.selectedCloudModel.rawValue) ?? ""
            let validForProvider = provider.availableModels.contains { $0.id == cloudModel }
            model = validForProvider ? cloudModel : (provider.availableModels.first?.id ?? "")
        }
        // API keys live in the macOS Keychain (KeychainStore migrates any legacy
        // plaintext UserDefaults value on first read). Ollama has an empty
        // storage key and resolves to "".
        let apiKey = KeychainStore.get(forAccount: provider.apiKeyStorageKey) ?? ""
        let speed = UserDefaults.standard.object(forKey: "selectedSpeed") == nil
            ? ModelDefaults.speed : UserDefaults.standard.double(forKey: "selectedSpeed")

        var body: [String: Any] = [
            "provider": provider.rawValue,
            "model": model,
            "apiKey": apiKey,
            "permissions": GatewayClient.buildPermissions(),
            "speed": speed,
            "xaiVoice": UserDefaults.standard.string(forKey: "selectedXaiVoice") ?? "eve",
        ]
        if provider == .dottieLocal {
            body["localBaseUrl"] = DottieLocalEndpoint.resolvedBaseURL()
        }
        return body
    }

    func pushChatConfig() {
        Task {
            let body = chatConfigBody()
            let provider = (body["provider"] as? String) ?? ChatProvider.current.rawValue
            let apiKey = (body["apiKey"] as? String) ?? ""

            guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
                AppLogger.error("GatewayClient: pushChatConfig serialization failed")
                return
            }

            do {
                let (_, response) = try await agentData("/v1/config", method: "POST", body: jsonData, timeout: 5)
                let success = response.statusCode == 200
                AppLogger.info("GatewayClient: pushChatConfig \(success ? "ok" : "failed") (provider=\(provider), hasKey=\(!apiKey.isEmpty))")
            } catch {
                AppLogger.warn("GatewayClient: pushChatConfig error: \(error.localizedDescription)")
            }
        }
    }

    /// Disconnects from the gateway: stops services.
    /// Does not touch `systemStatus` — that is owned by the `AgentManager.$status`
    /// Combine subscription, which will report `.down`/`.degraded` once AgentManager
    /// observes the gateway go away.
    func disconnect() {
        AppLogger.info("GatewayClient: disconnecting...")
        stopServices()

        DispatchQueue.main.async { [weak self] in
            self?.isConnected = false
        }
    }

    /// Checks if the agent service is healthy via GET /health on port 1317.
    /// Completion is called on the main queue. This is a stateless one-shot probe
    /// used by callers that need an immediate health answer (`GlobalRecorder`'s STT
    /// recovery poll, `MessageStore`'s greeting gate). It does NOT decide
    /// `systemStatus` — that is derived from `AgentManager.$status`.
    func checkAgentHealth(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:\(AppPorts.agentServer)/health") else {
            AppLogger.error("GatewayClient: invalid health URL")
            DispatchQueue.main.async { completion(false) }
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        session.dataTask(with: request) { data, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode
            let healthy = code == 200
            if !healthy {
                if let error = error {
                    AppLogger.warn("GatewayClient: checkAgentHealth /health failed: \(error.localizedDescription)")
                } else {
                    AppLogger.warn("GatewayClient: checkAgentHealth /health returned HTTP \(code.map(String.init) ?? "<none>")")
                }
            }
            DispatchQueue.main.async { completion(healthy) }
        }.resume()
    }

    // MARK: - Service Control

    /// Buckets a URLSession error into a coarse category for log messages.
    fileprivate func bucketURLError(_ error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return "other" }
        switch nsError.code {
        case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost: return "refused"
        case NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet: return "dropped"
        case NSURLErrorTimedOut: return "timeout"
        case NSURLErrorCancelled: return "cancelled"
        default: return "other"
        }
    }

    /// Polls /health every 200ms for up to `timeout` seconds. Returns the
    /// elapsed milliseconds when the gateway responds 200, or nil on timeout.
    /// Cheap GET, no auth (/health is exempt), tiny payload — round trip is
    /// ~5-15ms once the port is bound, so the probe interval dominates.
    private func waitForGatewayReady(timeoutSec: Double) async -> Int? {
        guard let url = URL(string: "http://127.0.0.1:\(AppPorts.agentServer)/health") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        let start = Date()
        let probeIntervalNs: UInt64 = 200_000_000
        while Date().timeIntervalSince(start) < timeoutSec {
            do {
                let (_, response) = try await session.data(for: request)
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    return Int(Date().timeIntervalSince(start) * 1000)
                }
            } catch {
                // Connection refused / timeout — gateway not bound yet.
                lastGatewayProbeError = bucketURLError(error)
            }
            try? await Task.sleep(nanoseconds: probeIntervalNs)
        }
        return nil
    }

    /// Starts all managed services. Two phases:
    ///   1. Wait for the gateway port to be reachable (/health 200), polling every
    ///      200ms with a 60s budget. /health is auth-exempt so this works pre-token.
    ///   2. POST /system/start exactly once — any HTTP error here is a real failure
    ///      worth surfacing in local logs (port conflict, supervisor crash, etc.).
    ///
    /// Before 2026.5.12 this method did a single retry loop with exponential backoff
    /// on the POST itself, conflating "port not yet bound" (race, recoverable in a
    /// few hundred ms) with "service genuinely broken" (real error). On cold first
    /// launch, the 7s exponential budget timed out six seconds before the gateway
    /// finished binding (field 5.11). The TCP-probe-first split eliminates the race:
    /// the post-bind round-trip is always <50ms, so any -1004 from /system/start
    /// now means the gateway died between probe and POST, which is a real fault.
    func startServices() {
        Task {
            let probeStart = Date()
            guard await waitForGatewayReady(timeoutSec: 60) != nil else {
                AppLogger.warn("GatewayClient: gateway never bound :1317 in 60s probe_error=\(lastGatewayProbeError)")
                return
            }
            AppLogger.info("GatewayClient: gateway ready; POSTing /system/start")

            do {
                let (_, response) = try await agentData("/system/start", method: "POST", session: streamSession, timeout: 60)
                let httpStatus = response.statusCode
                let success = httpStatus == 200
                AppLogger.info("GatewayClient: startServices \(success ? "succeeded" : "failed (\(httpStatus))") after \(Int(Date().timeIntervalSince(probeStart) * 1000))ms total")
                if !success {
                    AppLogger.warn("GatewayClient: startServices HTTP \(httpStatus)")
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await pollStatus()
            } catch {
                AppLogger.warn("GatewayClient: startServices error: \(error.localizedDescription)")
                return
            }
        }
    }

    /// One-shot GET /system/status that fills the per-service `services` dictionary
    /// (read by SettingsView for per-engine status rows). Invoked once from
    /// `connect()` and again on a Settings refresh — it does NOT open a stream and
    /// does NOT decide `systemStatus` (that is derived from `AgentManager.$status`).
    func pollStatus() async {
        do {
            let (data, _) = try await agentData("/system/status")

            let json: [String: Any]
            do {
                guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    AppLogger.warn("[Gateway] pollStatus: response is not a JSON object")
                    return
                }
                json = parsed
            } catch {
                AppLogger.warn("[Gateway] pollStatus: JSON parse failed: \(error.localizedDescription)")
                return
            }
            guard let servicesJson = json["services"] as? [String: [String: Any]] else {
                AppLogger.warn("[Gateway] pollStatus: missing 'services' key in response")
                return
            }

            await MainActor.run {
                for (name, info) in servicesJson {
                    let state = info["state"] as? String ?? "unknown"
                    let port = info["port"] as? Int ?? 0
                    let error = info["error"] as? String

                    self.services[name] = ServiceStatus(
                        name: name,
                        port: port,
                        state: state,
                        error: error,
                        restartCount: info["restartCount"] as? Int ?? 0
                    )
                }
            }
            AppLogger.info("GatewayClient: pollStatus updated \(servicesJson.count) services")
        } catch {
            AppLogger.warn("GatewayClient: pollStatus error: \(error)")
        }
    }

    /// Stops all managed services.
    func stopServices() {
        Task {
            do {
                let (_, response) = try await agentData("/system/stop", method: "POST", session: streamSession, timeout: 60)
                let code = response.statusCode
                if code == 200 {
                    AppLogger.info("GatewayClient: stopServices succeeded")
                } else {
                    AppLogger.error("GatewayClient: stopServices /system/stop returned HTTP \(code)\(code == 401 ? " (auth)" : "")")
                }
            } catch {
                AppLogger.warn("[Gateway] stopServices: \(error.localizedDescription)")
            }
        }
    }

    /// Stops a specific service by name (does NOT restart it).
    func stopService(_ name: String) async throws {
        let (_, response) = try await agentData("/system/services/\(name)/stop", method: "POST", session: streamSession, timeout: 60)
        let code = response.statusCode
        guard code == 200 else {
            AppLogger.error("GatewayClient: stop \(name) /stop returned HTTP \(code)\(code == 401 ? " (auth)" : "")")
            throw URLError(.badServerResponse)
        }
        AppLogger.info("GatewayClient: stop \(name) succeeded")
    }
}
