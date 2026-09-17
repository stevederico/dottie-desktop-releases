import Foundation

extension GatewayClient {
    // MARK: - Title Generation

    /// Generates a 2-5 word conversation title via the agent service.
    func generateConversationTitle(for message: String, completion: @escaping (String?) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:\(AppPorts.agentServer)/v1/title") else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15.0
        ClientManager.setAgentAuth(on: &request)

        let body: [String: String] = ["message": message]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            completion(nil)
            return
        }
        request.httpBody = jsonData

        ClientManager.shared.urlSession.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                guard error == nil,
                      let data = data,
                      let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let title = json["title"] as? String else {
                    completion(nil)
                    return
                }
                completion(title)
            }
        }.resume()
    }

    // MARK: - Sessions Ready

    /// Checks if agent sessions endpoint is ready (store initialized).
    func checkSessionsReady(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:\(AppPorts.agentServer)/health") else {
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3.0

        ClientManager.shared.urlSession.dataTask(with: request) { data, response, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ready = json["sessionsReady"] as? Bool else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            DispatchQueue.main.async { completion(ready) }
        }.resume()
    }

    // MARK: - Session CRUD API

    /// Fetches all sessions from the agent SQLite store.
    func fetchAgentSessions(completion: @escaping ([FullAgentSession]) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:\(AppPorts.agentServer)/v1/sessions") else {
            completion([])
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10.0
        ClientManager.setAgentAuth(on: &request)

        ClientManager.shared.urlSession.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let data = data,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                let detail = error?.localizedDescription ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
                AppLogger.shared.warn("[GatewayClient] fetchAgentSessions failed: \(detail)")
                DispatchQueue.main.async { completion([]) }
                return
            }

            do {
                let decoder = makeISO8601Decoder()
                let wrapper = try decoder.decode(FullSessionListResponse.self, from: data)
                DispatchQueue.main.async { completion(wrapper.sessions) }
            } catch {
                AppLogger.shared.error("[GatewayClient] fetchAgentSessions decode error: \(error)")
                DispatchQueue.main.async { completion([]) }
            }
        }.resume()
    }

    /// Creates a new session in the agent SQLite store.
    func createAgentSession(id: UUID? = nil, title: String? = nil, completion: @escaping (FullAgentSession?) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:\(AppPorts.agentServer)/v1/sessions") else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5.0
        ClientManager.setAgentAuth(on: &request)

        var body: [String: Any] = [:]
        if let id = id { body["id"] = id.uuidString }
        if let title = title { body["title"] = title }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        ClientManager.shared.urlSession.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let data = data,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            do {
                let decoder = makeISO8601Decoder()
                let wrapper = try decoder.decode(FullSessionResponse.self, from: data)
                DispatchQueue.main.async { completion(wrapper.session) }
            } catch {
                AppLogger.shared.error("[GatewayClient] createAgentSession decode error: \(error)")
                DispatchQueue.main.async { completion(nil) }
            }
        }.resume()
    }

    /// Syncs a session to the agent SQLite store (upsert messages). The
    /// completion carries the HTTP status (0 on a transport error) and the
    /// transport error's description (nil on an HTTP response) so the caller
    /// can log diagnosable failure details.
    func syncAgentSession(id: UUID, messages: [[String: Any]], model: String = "", provider: String = "", completion: @escaping (_ success: Bool, _ status: Int, _ error: String?) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:\(AppPorts.agentServer)/v1/sessions/\(id.uuidString)") else {
            completion(false, 0, "invalid_url")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10.0
        ClientManager.setAgentAuth(on: &request)

        let body: [String: Any] = [
            "messages": messages,
            "model": model,
            "provider": provider
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        ClientManager.shared.urlSession.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                completion(status == 200, status, error?.localizedDescription)
            }
        }.resume()
    }

    /// Updates a session's title in the agent SQLite store.
    func updateAgentSessionTitle(id: UUID, title: String, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:\(AppPorts.agentServer)/v1/sessions/\(id.uuidString)") else {
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5.0
        ClientManager.setAgentAuth(on: &request)

        let body: [String: Any] = ["title": title]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        ClientManager.shared.urlSession.dataTask(with: request) { _, response, _ in
            DispatchQueue.main.async {
                let isSuccess = (response as? HTTPURLResponse)?.statusCode == 200
                completion(isSuccess)
            }
        }.resume()
    }

    /// Deletes a session from the agent SQLite store.
    func deleteAgentSession(_ id: UUID, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:\(AppPorts.agentServer)/v1/sessions/\(id.uuidString)") else {
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 5.0
        ClientManager.setAgentAuth(on: &request)

        ClientManager.shared.urlSession.dataTask(with: request) { _, response, _ in
            DispatchQueue.main.async {
                let isSuccess = (response as? HTTPURLResponse)?.statusCode == 200
                completion(isSuccess)
            }
        }.resume()
    }

    // MARK: - Audit Events

    // MARK: - Event Triggers

    /// Fires an event trigger and streams the greeting response.
    /// Pass `conversationId` so the server can speak the greeting through the open
    /// realtime WS for that conversation when autoSpeak is on (greeting endpoint
    /// otherwise only streams SSE text and never triggers TTS).
    func fireEvent(
        _ eventType: String,
        conversationId: UUID? = nil,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let url = URL(string: "http://127.0.0.1:\(AppPorts.agentServer)/v1/events/fire") else {
            onComplete(.failure(ClientError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30.0
        ClientManager.setAgentAuth(on: &request)

        var body: [String: Any] = ["eventType": eventType]
        if let conversationId {
            body["conversationId"] = conversationId.uuidString
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            onComplete(.failure(error))
            return
        }

        AppLogger.shared.info("[GatewayClient] Firing event: \(eventType)")

        // Use a dedicated per-call URLSession rather than the shared `eventSession`
        // property. The old code did `eventSession?.invalidateAndCancel()` at the top
        // of every fireEvent, which could tear down an in-flight greeting stream's
        // placeholder session mid-flight. The local session is kept alive for the
        // stream's lifetime by the `session` capture in the onComplete closure, and
        // invalidated (releasing the delegate) once the stream finishes.
        var session: URLSession?
        let delegate = StreamingDelegate(
            onChunk: { text, _, _ in onChunk(text) },
            onComplete: { result in
                session?.finishTasksAndInvalidate()
                session = nil
                switch result {
                case .success:
                    onComplete(.success(()))
                case .failure(let error):
                    onComplete(.failure(error))
                }
            },
            onFollowup: { _ in },
            onCompaction: {}
        )

        let localSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        session = localSession
        localSession.dataTask(with: request).resume()
    }

    /// Fire an event trigger without waiting for or parsing the response.
    func fireEventSilent(_ eventType: String) {
        guard let url = URL(string: "http://127.0.0.1:\(AppPorts.agentServer)/v1/events/fire") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5.0
        ClientManager.setAgentAuth(on: &request)

        let body: [String: Any] = ["eventType": eventType]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            AppLogger.shared.error("[GatewayClient] Failed to serialize event body: \(error.localizedDescription)")
            return
        }

        AppLogger.shared.info("[GatewayClient] Firing silent event: \(eventType)")
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                AppLogger.shared.warn("[GatewayClient] Silent event \(eventType) failed: \(error.localizedDescription)")
            } else if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                AppLogger.shared.warn("[GatewayClient] Silent event \(eventType): HTTP \(http.statusCode)")
            }
        }.resume()
    }
}
