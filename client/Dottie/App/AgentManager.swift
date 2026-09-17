//
//  AgentManager.swift
//  Dottie
//
//  Lifecycle management for the Node.js agent service on port 1317.
//  Handles start/stop/health checks for the agent process.
//

import Foundation
import Security
import Combine

// MARK: - Agent Status

/// Represents the lifecycle state of the agent service (port 1317).
enum AgentStatus: Equatable {
    case stopped
    case starting
    case running
    case stopping
    case error(String)

    var displayName: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting..."
        case .running: return "Running"
        case .stopping: return "Stopping..."
        case .error(let message): return "Error: \(message)"
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

// MARK: - Agent Manager

/// Manages the lifecycle of the Node.js agent service (port 1317).
/// Start, stop, health check, and status monitoring.
class AgentManager: ObservableObject {
    static let shared = AgentManager()

    @Published var status: AgentStatus = .stopped
    @Published var startupProgress: Double = 0.0  // 0.0 to 1.0
    @Published var startupMessage: String = ""
    @Published var agentToken: String = ""

    private var agentProcess: Process?
    private var statusCheckTimer: Timer?
    private var healthStreamTask: Task<Void, Never>?
    private var lastHealthEventAt: Date?

    /// Serializes ``ensureAgentToken()`` so concurrent callers can't each
    /// generate-and-write a different token (check-then-generate-then-write
    /// is otherwise a race). One winner generates+writes; later callers
    /// re-read the file the winner produced.
    private let tokenLock = NSLock()

    private lazy var healthCheckSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 5
        return URLSession(configuration: config)
    }()

    /// Long-lived session for SSE health stream — no request timeout so the
    /// stream can stay open for the life of the agent process.
    private lazy var healthStreamSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0
        config.timeoutIntervalForResource = 0
        return URLSession(configuration: config)
    }()

    private let dottieDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".dottie")

    private var tokenFilePath: URL {
        dottieDir.appendingPathComponent("agent_token")
    }

    /// CFBundleShortVersionString of the running app. Stamped into the gateway
    /// process as DOTTIE_APP_VERSION at spawn and compared against the adopted
    /// gateway's `/health` `app_version` on every launch. Nil only if the key is
    /// absent from Info.plist, in which case the comparison is skipped entirely
    /// rather than respawning a healthy gateway on every launch.
    private static let appVersion: String? = {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return (value?.isEmpty == false) ? value : nil
    }()

    private init() {
        startStatusChecking()
        if let token = AgentToken.load() {
            agentToken = token
        }
    }

    deinit {
        stopStatusChecking()
        healthStreamTask?.cancel()
        healthCheckSession.invalidateAndCancel()
        healthStreamSession.invalidateAndCancel()
        if let process = agentProcess, process.isRunning {
            process.terminate()
        }
    }

    // MARK: - Token Management

    /// Reads the agent token from disk, generating one if it doesn't exist.
    /// Token is a 64-character hex string (32 random bytes). File is written with 0600 permissions.
    @discardableResult
    func ensureAgentToken() -> String {
        // Serialize the whole check-then-generate-then-write sequence so two
        // concurrent callers can't generate different tokens. The lock is held
        // across the disk read+write (sub-millisecond, no network/IPC).
        tokenLock.lock()
        defer { tokenLock.unlock() }

        // Try to read existing token (re-checked under the lock — a caller that
        // blocked here while another won the race now sees the written token).
        if let existing = AgentToken.load() {
            DispatchQueue.main.async { self.agentToken = existing }
            return existing
        }

        // Generate 32 random bytes -> 64 hex chars
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()

        // Ensure directory exists
        do {
            try FileManager.default.createDirectory(at: dottieDir, withIntermediateDirectories: true)
        } catch {
            AppLogger.error("Failed to create .dottie directory for agent token: \(error.localizedDescription)")
        }

        // Write with restrictive permissions (owner read/write only)
        let path = dottieDir.appendingPathComponent("agent_token")
        guard let tokenData = token.data(using: .utf8) else {
            AppLogger.error("Failed to encode agent token as UTF-8")
            return token
        }
        // If the write fails (disk full, unwritable ~/.dottie, sandbox), no token file
        // exists on disk: MacUseService reads nil and deny-by-default 401s every AX request
        // with no other signal, so surface it loudly via log.
        let wrote = FileManager.default.createFile(atPath: path.path, contents: tokenData, attributes: [.posixPermissions: 0o600])
        if !wrote {
            AppLogger.error("Failed to write agent token to \(path.path) — AX requests will 401 until a token file exists")
        }

        AppLogger.info("Generated new agent token")
        DispatchQueue.main.async { self.agentToken = token }
        return token
    }

    /// Deletes the current agent token, generates a fresh one, and restarts the agent service
    /// if it was running so the new token takes effect. The published ``agentToken`` property
    /// is updated on the main queue after generation. `GatewayClient`'s in-memory token is
    /// refreshed unconditionally so 1317 HTTP calls don't 401 with the stale token when the
    /// agent isn't running (the restart path only reloads it via `connect()` when running).
    func regenerateAgentToken() {
        try? FileManager.default.removeItem(at: tokenFilePath)
        // ensureAgentToken already schedules `self.agentToken = <token>` on the
        // main queue (both the existing-token and freshly-generated paths), so a
        // second main-queue assignment here was redundant.
        _ = ensureAgentToken()
        AppLogger.info("Regenerated agent token")

        // GatewayClient.agentToken is now a computed property that reads the token
        // fresh from disk on every request, so it picks up the regenerated token
        // automatically — no manual refresh poke needed even when the agent is down.

        // Restart agent to pick up new token. Chain the start on the stop's
        // completion callback (which fires after teardown settles status at
        // .stopped, ~2.1s) instead of a fixed 2.0s delay — the old delay could
        // fire before performAgentStop finished, interleaving stop and start.
        // The callback already runs on the main queue, which is required because
        // startAgent() mutates @Published state synchronously.
        if status.isRunning {
            stopAgent { [weak self] in
                self?.startAgent()
            }
        }
    }

    /// Restarts the agent service without rotating the token. Used when an env
    /// flag captured at gateway boot changes (e.g. Debug Mode → DEBUG_AGENT).
    func restartAgent() {
        guard status.isRunning else { return }
        stopAgent { [weak self] in
            self?.startAgent()
        }
    }

    /// Last time a 401 triggered a respawn — rate-limits the self-heal.
    private var lastAuthRespawn = Date.distantPast

    /// The gateway answered 401 to a request carrying the token we just read
    /// from disk. Both sides read `~/.dottie/agent_token`, so a persistent 401
    /// means the running gateway holds a different token than the file (a
    /// survivor from before the file was rewritten). Respawning is the only fix
    /// — it re-reads the file at boot. Field 2026.8: one install logged 39
    /// consecutive `agent_sync_failed http_401` + 34 WS -1011 with no recovery.
    /// At most one respawn per 5 minutes so a genuinely broken token file
    /// can't turn into a restart storm.
    func handleGatewayAuthRejected(source: String) {
        DispatchQueue.main.async {
            guard self.status.isRunning,
                  Date().timeIntervalSince(self.lastAuthRespawn) > 300 else { return }
            self.lastAuthRespawn = Date()
            // Re-verify off-main before paying for a respawn (model reload):
            // a WS -1011 or a one-off 401 mid-restart must not bounce a gateway
            // that accepts the token on the very next request.
            DispatchQueue.global(qos: .utility).async {
                guard !self.isAgentAuthAccepted() else { return }
                AppLogger.warn("Gateway rejects the current agent token (\(source)) — respawning so it re-reads agent_token")
                DispatchQueue.main.async { self.restartAgent() }
            }
        }
    }

    // MARK: - Start / Stop

    /// Starts the agent service using the start script in ~/.dottie/gateway/.
    func startAgent() {
        guard !status.isRunning, status != .starting else {
            AppLogger.warn("startAgent() called but status is \(status)")
            return
        }

        AppLogger.info("Starting agent service")
        status = .starting
        startupProgress = 0.0
        startupMessage = ""

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performAgentStart()
        }
    }

    /// Stops the agent service by terminating its process and killing port 1317.
    /// `onStopped` (if provided) runs on the main queue AFTER teardown completes
    /// and status has settled at `.stopped` — used by `regenerateAgentToken()` to
    /// chain a restart without racing the stop. If the guard rejects the call,
    /// `onStopped` is invoked immediately so callers never hang waiting for it.
    func stopAgent(onStopped: (() -> Void)? = nil) {
        guard status.isRunning || status == .starting else {
            AppLogger.warn("stopAgent() called but status is \(status)")
            if let onStopped = onStopped {
                DispatchQueue.main.async { onStopped() }
            }
            return
        }

                AppLogger.info("Stopping agent service")
        status = .stopping
        startupProgress = 0.0
        startupMessage = ""

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performAgentStop(onStopped: onStopped)
        }
    }

    private func performAgentStart() {
        let startTime = Date()
        AppLogger.info("Agent start requested")

        // If agent is already healthy, adopt it instead of killing mid-request.
        // BUT: skip adoption when the runtime mirror at ~/.dottie/gateway/
        // is stale vs the current bundle. Local deploy (`pkill -9 Dottie` + cp
        // + open) can leave a prior `dottie-gateway` on :1317 — adoption would
        // silently keep running stale code.
        if isAgentHealthy() {
            if isAgentMirrorStale() {
                AppLogger.warn("Agent healthy but runtime mirror is stale vs bundle — forcing respawn")
            } else if !isAgentAuthAccepted() {
                // /health is auth-exempt, so a healthy survivor whose cached
                // token predates the current agent_token file passes every
                // check above and then 401s every real request all session.
                AppLogger.warn("Agent healthy but rejects the current agent token — forcing respawn")
            } else {
                AppLogger.info("Agent already running and healthy — adopting existing instance")
                DispatchQueue.main.async {
                    self.status = .running
                    self.startupProgress = 1.0
                    self.startupMessage = "Ready"
                }
                return
            }
        }

        // Not healthy — kill any zombie process and start fresh.
        // killPort() already escalates (TERM, sleep 1, KILL) and waitUntilExit()s
        // internally, so the port is freed by the time it returns — the extra
        // 0.5s pre-sleep was redundant and just delayed every cold launch.
        killPort(AppPorts.agentServer)

        // Longer timeout when talk/mac-use node_modules missing (dev npm install).
        let gatewayHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dottie/gateway")
        let talkMods = gatewayHome.appendingPathComponent("dottie-talk/node_modules")
        let macMods = gatewayHome.appendingPathComponent("dottie-mac-use/node_modules")
        let isFirstTimeSetup = !FileManager.default.fileExists(atPath: talkMods.path)
            || !FileManager.default.fileExists(atPath: macMods.path)
        let maxAttempts = isFirstTimeSetup ? 30 : 10  // 60s vs 20s

        AppLogger.info("Agent startup mode: \(isFirstTimeSetup ? "first-time setup" : "normal") (timeout: \(maxAttempts * 2)s)")

        let startScript = getScriptPath("start_gateway.sh")

        guard FileManager.default.fileExists(atPath: startScript.path) else {
            AppLogger.error("start_gateway.sh not found at \(startScript.path)")
            DispatchQueue.main.async {
                self.status = .error("Start script not found")
                self.startupProgress = 0.0
            }
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [startScript.path]

        // Ensure the token file exists on disk before spawning — the gateway
        // reads it directly from ~/.dottie/agent_token (agent_token.js). We do
        // NOT pass it via the AGENT_TOKEN env var: start_gateway.sh never
        // references that var and nothing in the gateway consumes it, so the
        // injection was dead code.
        ensureAgentToken()
        process.environment = ProcessInfo.processInfo.environment
        // Inject bin directory into environment
        if let binDir = Bundle.main.resourceURL?.appendingPathComponent("bin").path,
           FileManager.default.fileExists(atPath: binDir) {
            process.environment?["DOTTIE_BIN_DIR"] = binDir
        }
        // Stamps the gateway with the bundle version that spawned it so
        // isAgentHealthy() can refuse to adopt a survivor from a previous build
        // (see appVersion). start_gateway.sh doesn't reference this — bash and
        // the node child inherit it from this environment.
        if let appVersion = Self.appVersion {
            process.environment?["DOTTIE_APP_VERSION"] = appVersion
        }
        // Debug Mode (Settings → Testing) drives the gateway's verbose logging.
        // DEBUG_AGENT is captured at process boot, so the toggle takes effect on
        // the next agent launch — same lifecycle as the old debug_agent.sh script.
        if UserDefaults.standard.bool(forKey: "DebugMode") {
            process.environment?["DEBUG_AGENT"] = "true"
        }

        // Set up pipe draining to prevent deadlock (cap at 1 MB to prevent unbounded growth)
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let maxBufferSize = 1_048_576
        var outputData = Data()
        var errorData = Data()

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if outputData.count < maxBufferSize {
                outputData.append(chunk)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if errorData.count < maxBufferSize {
                errorData.append(chunk)
            }
        }

        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Update startup message
        DispatchQueue.main.async {
            if isFirstTimeSetup {
                self.startupMessage = "First-time setup - installing dependencies..."
            } else {
                self.startupMessage = "Starting server..."
            }
        }

        do {
            try process.run()
            self.agentProcess = process
            AppLogger.info("Agent process launched (PID: \(process.processIdentifier))")

            // Poll for health with adaptive timeout. Each `attempt` is a 2s
            // progress tick (preserves the maxAttempts*2s timeout window and the
            // progress/message semantics below), but within each tick we poll
            // health every 250ms instead of once at the end — so a gateway that
            // comes up mid-tick is detected up to ~1.75s sooner on cold launch.
            let pollsPerTick = 8                       // 8 * 0.25s == 2.0s/tick
            let pollInterval: TimeInterval = 0.25
            for attempt in 1...maxAttempts {
                // Update progress + message at the start of each tick.
                let progress = Double(attempt) / Double(maxAttempts)
                DispatchQueue.main.async {
                    self.startupProgress = progress

                    // Update message based on progress
                    if isFirstTimeSetup {
                        if attempt <= 10 {
                            self.startupMessage = "Installing dependencies..."
                        } else if attempt <= 20 {
                            self.startupMessage = "Starting server..."
                        } else {
                            self.startupMessage = "Waiting for health check..."
                        }
                    } else {
                        if attempt <= 5 {
                            self.startupMessage = "Starting server..."
                        } else {
                            self.startupMessage = "Waiting for health check..."
                        }
                    }
                }

                var healthyThisTick = false
                for _ in 0..<pollsPerTick {
                    Thread.sleep(forTimeInterval: pollInterval)
                    if isAgentHealthy() { healthyThisTick = true; break }
                }

                if healthyThisTick {
                    let duration = Date().timeIntervalSince(startTime)
                    AppLogger.info("Agent started successfully in \(String(format: "%.1f", duration))s (attempt \(attempt)/\(maxAttempts))")

                    // Clean up pipe handlers — close handles first to prevent race
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    try? outputPipe.fileHandleForReading.close()
                    try? errorPipe.fileHandleForReading.close()

                    let startedDuration = Date().timeIntervalSince(startTime)
                    DispatchQueue.main.async {
                        self.status = .running
                        self.startupProgress = 1.0
                        self.startupMessage = "Ready"
                        GatewayClient.shared.connect()
                    }
                    return
                }
            }

            // Timeout - parse logs for specific errors. The timeout itself is
            // already telemetered as gateway.start_failed {reason: startup_timeout};
            // demote the bare log so we don't double-count.
            let duration = Date().timeIntervalSince(startTime)
            AppLogger.warn("Agent start timeout after \(String(format: "%.1f", duration))s")

            let logContents = readGatewayLog()
            let errorMessage = parseAgentStartupError(logContents)

            // Clean up pipe handlers — close handles first to prevent race
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()

            DispatchQueue.main.async {
                self.status = .error(errorMessage)
                self.startupProgress = 0.0
                self.startupMessage = ""
            }
        } catch {
            AppLogger.error("Failed to launch start script: \(error.localizedDescription)")

            // Clean up pipe handlers — close handles first to prevent race
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()

            DispatchQueue.main.async {
                self.status = .error(error.localizedDescription)
                self.startupProgress = 0.0
                self.startupMessage = ""
            }
        }
    }

    /// Reads the gateway log once for the user-facing startup error message.
    /// Empty when absent/unreadable.
    private func readGatewayLog() -> String {
        let logPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dottie/logs/gateway.log")
        return (try? String(contentsOf: logPath, encoding: .utf8)) ?? ""
    }

    /// Parses the agent service log to extract specific error context.
    private func parseAgentStartupError(_ logContents: String) -> String {
        guard !logContents.isEmpty else {
            return "Timeout waiting for agent"
        }

        let lines = logContents.components(separatedBy: .newlines)
        let lastLines = lines.suffix(20).joined(separator: "\n")

        // Check for common failure patterns
        if lastLines.contains("npm WARN") || lastLines.contains("npm ERR!") {
            return "Timeout waiting for agent (npm installation failed - check logs)"
        } else if lastLines.contains("EADDRINUSE") {
            return "Timeout waiting for agent (Port 1317 already in use)"
        } else if lastLines.contains("Cannot find module") {
            return "Timeout waiting for agent (Missing dependencies - check logs)"
        } else if lastLines.contains("MongoError") {
            return "Timeout waiting for agent (MongoDB connection failed)"
        }

        return "Timeout waiting for agent (check logs for details)"
    }

    private func performAgentStop(onStopped: (() -> Void)? = nil) {
        AppLogger.info("Agent stop requested")

        // Terminate tracked process and wait for exit to avoid pipe handler races
        if let process = agentProcess, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        agentProcess = nil

        // Kill anything on port 1317
        killPort(AppPorts.agentServer)

        Thread.sleep(forTimeInterval: 1.0)

        DispatchQueue.main.async {
            self.status = .stopped
            AppLogger.info("Agent stopped")
            onStopped?()
        }
    }

    // MARK: - Health Check

    /// Synchronous health check against the agent's /health endpoint. Returns
    /// false (treated as "not healthy" by callers, which then respawn) when the
    /// gateway answering on 1317 belongs to a different build than the running
    /// app. Two independent staleness signals (each logged on mismatch):
    ///
    /// - `app_version` ≠ this bundle's CFBundleShortVersionString — the upgrade-in-place case: the detached
    ///   gateway survives replacing /Applications/Dottie.app and keeps executing
    ///   the old bundle's JS from unlinked inodes.
    /// - `bin_dir` ≠ this bundle's Resources/bin path — a gateway from a different bundle
    ///   *location* (e.g. ~/Downloads/Dottie.app in a try-before-install flow)
    ///   still listening with a now-broken DOTTIE_BIN_DIR.
    ///
    /// A missing field means a pre-fix gateway and also forces a respawn.
    /// Must NOT be called from the main thread (blocks up to 3s with semaphore).
    func isAgentHealthy() -> Bool {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard let url = URL(string: "http://127.0.0.1:\(AppPorts.agentServer)/health") else {
            AppLogger.error("AgentManager: invalid health URL")
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0

        let semaphore = DispatchSemaphore(value: 0)
        var healthy = false
        var responseData: Data?

        let task = healthCheckSession.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                healthy = true
                responseData = data
            }
            semaphore.signal()
        }
        task.resume()

        let result = semaphore.wait(timeout: .now() + 3.0)
        if result == .timedOut { task.cancel() }

        guard healthy else { return false }

        // Decode once — both staleness guards below read the same payload.
        let payload: [String: Any]? = {
            guard let data = responseData else { return nil }
            do {
                return try JSONSerialization.jsonObject(with: data) as? [String: Any]
            } catch {
                AppLogger.error("AgentManager: failed to decode /health response, forcing respawn: \(error)")
                return nil
            }
        }()

        // Verify the running gateway was spawned by THIS app version. An
        // upgrade-in-place replaces /Applications/Dottie.app but leaves the
        // detached gateway alive on 1317 running the previous bundle's JS from
        // unlinked inodes — and its bin_dir still matches, so the check below
        // can't catch it. Missing field means a pre-fix build: also respawn.
        if let expectedVersion = Self.appVersion {
            let reportedVersion = payload?["app_version"] as? String
            if reportedVersion != expectedVersion {
                AppLogger.warn("AgentManager: adopted gateway app_version mismatch (expected=\(expectedVersion), actual=\(reportedVersion ?? "<missing>")) — forcing respawn")
                return false
            }
        }

        // Verify the running gateway's bin_dir matches the current bundle.
        // If the field is missing (pre-fix gateway) OR mismatched, treat as
        // unhealthy so the caller respawns instead of adopting.
        guard let expected = Bundle.main.resourceURL?.appendingPathComponent("bin").path else {
            return true
        }
        let actual = payload?["bin_dir"] as? String
        if actual == nil || actual != expected {
            AppLogger.warn("AgentManager: adopted gateway bin_dir mismatch (expected=\(expected), actual=\(actual ?? "<missing>")) — forcing respawn")
            return false
        }
        return true
    }

    /// Cheapest authed round-trip: does the running gateway accept the token in
    /// `~/.dottie/agent_token`? Anything but 401 counts as accepted — a
    /// transport failure here must not force a respawn of a gateway that just
    /// passed /health.
    func isAgentAuthAccepted() -> Bool {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard let url = URL(string: "http://127.0.0.1:\(AppPorts.agentServer)/system/errors?limit=1") else { return true }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0
        ClientManager.setAgentAuth(on: &request)
        let semaphore = DispatchSemaphore(value: 0)
        var rejected = false
        let task = healthCheckSession.dataTask(with: request) { _, response, _ in
            rejected = (response as? HTTPURLResponse)?.statusCode == 401
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 3.0) == .timedOut { task.cancel() }
        return !rejected
    }

    /// Historical: compared bundle gateway JS to `~/.dottie/gateway/` mirror.
    /// Since 2026.5.12 `start_gateway.sh` runs the **bundled** gateway only and
    /// deletes the legacy mirror (`rm -rf ~/.dottie/gateway`). Missing mirror
    /// files are normal — treating them as "stale" forced mid-session kill +
    /// respawn (field: Clownboy 8GB `gateway.mirror_stale_respawn` → TTS
    /// SIGABRT). Always false; real binary drift is `bin_dir` health checks.
    private func isAgentMirrorStale() -> Bool {
        false
    }

    // MARK: - Status Polling

    /// Subscribes to /system/health/stream for real-time agent-service liveness
    /// (any SSE message or heartbeat confirms the service is up). Falls back
    /// to a one-shot HTTP poll only if no SSE event has arrived in 60s —
    /// handles the case where the stream endpoint is wedged but the process is
    /// still serving other requests.
    private func startStatusChecking() {
        startHealthStream()
        statusCheckTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.checkStatusIfStale()
        }
    }

    private func stopStatusChecking() {
        statusCheckTimer?.invalidate()
        statusCheckTimer = nil
        healthStreamTask?.cancel()
        healthStreamTask = nil
    }

    /// Opens a long-lived SSE connection to /system/health/stream. On any
    /// received event or heartbeat comment, marks the agent running and
    /// refreshes ``lastHealthEventAt``. On connection end/error, schedules
    /// a retry with backoff.
    private func startHealthStream() {
        healthStreamTask?.cancel()
        healthStreamTask = Task { [weak self] in
            guard let self = self else { return }
            var backoff: UInt64 = 1_000_000_000 // 1s
            while !Task.isCancelled {
                await self.runHealthStreamOnce()
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: backoff)
                backoff = min(backoff * 2, 30_000_000_000) // cap at 30s
            }
        }
    }

    private func runHealthStreamOnce() async {
        guard let url = URL(string: "http://127.0.0.1:\(AppPorts.agentServer)/system/health/stream") else {
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0
        let token = agentToken.isEmpty ? ensureAgentToken() : agentToken
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        do {
            let (bytes, response) = try await healthStreamSession.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                AppLogger.debug("AgentManager: health stream non-200")
                return
            }

            await MainActor.run { self.markStreamEvent() }

            for try await line in bytes.lines {
                if Task.isCancelled { break }
                // Any SSE traffic (data: ..., : ping) proves the server is alive.
                if line.hasPrefix(":") || line.hasPrefix("data:") {
                    await MainActor.run { self.markStreamEvent() }
                }
            }
        } catch {
            AppLogger.debug("AgentManager: health stream ended (\(error.localizedDescription))")
        }
    }

    /// Called on the main actor whenever any SSE frame arrives.
    private func markStreamEvent() {
        lastHealthEventAt = Date()
        if !status.isRunning, status != .starting, status != .stopping {
            AppLogger.debug("AgentManager: health stream live — marking running")
            status = .running
            GatewayClient.shared.connect()
        }
    }

    /// Backstop: if no SSE event in 60s, do one HTTP poll.
    private func checkStatusIfStale() {
        guard status != .starting, status != .stopping else { return }
        if let last = lastHealthEventAt, Date().timeIntervalSince(last) < 60 {
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let healthy = self.isAgentHealthy()
            DispatchQueue.main.async {
                if healthy && !self.status.isRunning {
                    self.status = .running
                    GatewayClient.shared.connect()
                } else if !healthy && self.status.isRunning {
                    AppLogger.warn("AgentManager: backstop poll failed — marking stopped")
                    self.status = .stopped
                }
            }
        }
    }

    // MARK: - Script Resolution

    /// Locates a script by searching bundle resources and development paths.
    private func getScriptPath(_ scriptName: String) -> URL {
        let baseName = scriptName.replacingOccurrences(of: ".sh", with: "")
        let ext = scriptName.contains(".") ? String(scriptName.split(separator: ".").last!) : nil

        let possiblePaths: [URL?] = [
            Bundle.main.url(forResource: baseName, withExtension: ext),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/gateway/scripts/\(scriptName)"),
            Bundle.main.resourceURL?.appendingPathComponent("gateway/scripts/\(scriptName)"),
            Bundle.main.bundleURL.appendingPathComponent("gateway/scripts/\(scriptName)"),
            Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("gateway/scripts/\(scriptName)"),
            findScriptInDevelopmentLocations(scriptName)
        ]

        for path in possiblePaths {
            if let path = path, FileManager.default.fileExists(atPath: path.path) {
                AppLogger.debug("Found script at: \(path.path)")
                return path
            }
        }

        AppLogger.warn("Script \(scriptName) not found in any search path")
        return Bundle.main.resourceURL?.appendingPathComponent("gateway/scripts/\(scriptName)") ??
               Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/gateway/scripts/\(scriptName)")
    }

    /// Searches common Xcode development build directory structures for scripts.
    private func findScriptInDevelopmentLocations(_ scriptName: String) -> URL? {
        let bundleDir = Bundle.main.bundleURL.deletingLastPathComponent()
        let searchPaths = [
            bundleDir.deletingLastPathComponent().appendingPathComponent("gateway/scripts/\(scriptName)"),
            bundleDir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("gateway/scripts/\(scriptName)"),
            bundleDir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("gateway/scripts/\(scriptName)")
        ]

        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path.path) {
                return path
            }
        }
        return nil
    }

    // MARK: - Utility

    private func killPort(_ port: Int) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", """
            PIDS=$(lsof -ti TCP:\(port) -sTCP:LISTEN 2>/dev/null || true)
            if [ -n "$PIDS" ]; then
                for pid in $PIDS; do
                    kill -TERM $pid 2>/dev/null || true
                done
                sleep 1
                REMAINING=$(lsof -ti TCP:\(port) -sTCP:LISTEN 2>/dev/null || true)
                for pid in $REMAINING; do
                    kill -9 $pid 2>/dev/null || true
                done
            fi
        """]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            AppLogger.error("Error killing port \(port): \(error.localizedDescription)")
        }
    }
}
