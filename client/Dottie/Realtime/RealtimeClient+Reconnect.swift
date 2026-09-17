import Foundation
import Combine

extension RealtimeClient {
    // MARK: - Auto-Reconnect

    /// Schedules a reconnect attempt with exponential backoff.
    /// Backoff: 5s, 10s, 20s, 40s, 60s (capped). Preserves conversation_id.
    func scheduleReconnect() {
        guard !intentionalDisconnect else {
            AppLogger.shared.debug("[Realtime] Intentional disconnect, skipping reconnect")
            return
        }

        guard retryCount < Self.maxRetries else {
            AppLogger.shared.warn("[Realtime] Max reconnect attempts (\(Self.maxRetries)) reached")
            let recentlyReported = lastMaxRetriesReport.map { Date().timeIntervalSince($0) < 600 } ?? false
            if !recentlyReported {
                lastMaxRetriesReport = Date()
                var detail = "max_retries=\(Self.maxRetries)"
                if let code = lastCloseCode { detail += " last_close_code=\(code)" }
                if let err = lastSocketError { detail += " last_error=\(err)" }
                AppLogger.shared.warn("[Realtime] reconnect exhausted \(detail)")
            }
            connectionState = .failed(NSError(domain: "RealtimeClient", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Connection lost after \(Self.maxRetries) attempts"]))
            eventPublisher.send(.structuredError(
                code: "max_retries_exceeded",
                message: "Failed to reconnect after \(Self.maxRetries) attempts.",
                recoverable: false,
                info: [:]
            ))
            // stopConversation() requires main; this may already be main, so async not sync.
            if conversationState != .inactive {
                DispatchQueue.main.async { [weak self] in
                    self?.stopConversation()
                }
            }
            return
        }

        retryCount += 1
        let delay = min(Self.baseRetryDelay * pow(2.0, Double(retryCount - 1)), 60.0)
        connectionState = .reconnecting(attempt: retryCount)
        AppLogger.shared.info("[Realtime] Reconnecting in \(delay)s (attempt \(retryCount)/\(Self.maxRetries))")

        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.intentionalDisconnect else { return }
            self.connect()
        }
        reconnectTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Cancels any pending reconnect attempt.
    func cancelReconnect() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
    }

    /// Waits for the WebSocket to connect, then calls the completion handler.
    /// Times out after the specified interval with a structured error.
    func waitForConnection(timeout: TimeInterval = 10, completion: @escaping (Bool) -> Void) {
        var cancellable: AnyCancellable?
        let deadline = DispatchWorkItem { [weak self] in
            cancellable?.cancel()
            self?.eventPublisher.send(.structuredError(
                code: "not_connected",
                message: "Could not connect to server. Please try again.",
                recoverable: true,
                info: [:]
            ))
            completion(false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: deadline)

        cancellable = $isConnected
            .filter { $0 }
            .first()
            .sink { _ in
                deadline.cancel()
                // Defer to the next main-loop tick. @Published emits in willSet, so
                // `isConnected` is still false at this instant; a synchronous completion
                // re-enters sendTextMessage(), which reads the stale `false`, re-queues a
                // new waiter that never gets a fresh `true` emit, and deadlocks until the
                // 10s timeout — the "stuck on Thinking… forever" hang. Running async lets
                // the didSet commit (stored value = true) before the retry reads it.
                DispatchQueue.main.async {
                    completion(true)
                }
            }
    }

    // MARK: - Heartbeat Monitoring

    /// Starts a periodic timer that checks for server silence.
    /// If no message is received within `heartbeatTimeout`, triggers a reconnect.
    func startHeartbeatMonitor() {
        stopHeartbeatMonitor()
        lastMessageTime = Date()

        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self = self, self.isConnected else { return }
            guard let lastTime = self.lastMessageTime else { return }

            let elapsed = Date().timeIntervalSince(lastTime)
            // A streaming response gets a longer grace window — a slow local LLM
            // turn is not a dead connection, and reconnecting mid-turn strands the
            // UI on "Thinking…" when the late response.done hits the stale-task guard.
            let timeout = self.isResponding ? Self.respondingHeartbeatTimeout : Self.heartbeatTimeout
            if elapsed > timeout {
                AppLogger.shared.warn("[Realtime] Heartbeat timeout (\(Int(elapsed))s silence), reconnecting")
                self.webSocketTask?.cancel(with: .goingAway, reason: nil)
                self.webSocketTask = nil
                self.isConnected = false
                // Silence means any in-flight response is dead — clear the guard so the
                // scheduled reconnect's connect() isn't blocked by a stale flag.
                self.isResponding = false
                self.stopHeartbeatMonitor()
                self.stopPingTimer()
                self.eventPublisher.send(.disconnected(nil))
                self.scheduleReconnect()
            }
        }
    }

    /// Stops the heartbeat monitoring timer.
    func stopHeartbeatMonitor() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    // MARK: - Application-Level Ping

    /// Starts a periodic timer that sends JSON pings to keep the connection alive.
    /// The server responds with a pong, which updates `lastMessageTime` via `receiveMessage()`.
    func startPingTimer() {
        stopPingTimer()
        pingTimer = Timer.scheduledTimer(withTimeInterval: Self.pingInterval, repeats: true) { [weak self] _ in
            guard let self = self, self.isConnected else { return }
            self.sendJSON(["type": "ping"])
        }
    }

    /// Stops the application-level ping timer.
    func stopPingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
    }
}
