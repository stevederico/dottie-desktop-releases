import Foundation

extension GatewayClient {
    /// Fire-and-forget agent REST request. Encodes (already-prepared) `body`, sets auth,
    /// and reports success when the response status is in `acceptedStatuses`.
    /// Behavior mirrors the hand-written closures: main-thread completion(false) on bad URL,
    /// main-thread completion(false) on nil body when a body was required.
    private func performBoolRequest(
        url: URL,
        method: String,
        body: Data?,
        acceptedStatuses: Set<Int> = [200],
        completion: @escaping (Bool) -> Void
    ) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        ClientManager.setAgentAuth(on: &request)
        ClientManager.shared.urlSession.dataTask(with: request) { _, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let isSuccess = acceptedStatuses.contains(status)
            DispatchQueue.main.async { completion(isSuccess) }
        }.resume()
    }

    /// Path-based convenience over `performBoolRequest(url:…)`: builds the agent
    /// URL for `path`, or reports failure on the main queue when it can't — the
    /// same guard every task/trigger/memory/preference/job mutation used to inline.
    private func performBoolRequest(
        path: String,
        method: String,
        body: Data?,
        acceptedStatuses: Set<Int> = [200],
        completion: @escaping (Bool) -> Void
    ) {
        guard let url = URL(string: "http://127.0.0.1:\(AppPorts.agentServer)\(path)") else {
            AppLogger.error("GatewayClient: invalid URL for \(path)")
            DispatchQueue.main.async { completion(false) }
            return
        }
        performBoolRequest(url: url, method: method, body: body, acceptedStatuses: acceptedStatuses, completion: completion)
    }

    // MARK: - Tasks API

    /// Task data model for display in UI.
    struct AgentTask: Identifiable, Codable {
        let id: String
        let description: String
        let status: String
        let progress: Int
        let category: String
        let priority: String
        let mode: String
        let steps: [TaskStep]?

        struct TaskStep: Codable {
            let text: String
            let isDone: Bool

            enum CodingKeys: String, CodingKey {
                case text
                case isDone = "done"
            }
        }

        var statusIcon: String {
            switch status {
            case "completed": return "checkmark.circle.fill"
            case "in_progress": return "play.circle.fill"
            default: return "circle"
            }
        }

        var statusColor: String {
            switch status {
            case "completed": return "green"
            case "in_progress": return "blue"
            default: return "secondary"
            }
        }
    }

    /// Fetch tasks from agent service.
    func fetchTasks(completion: @escaping (Result<[AgentTask], Error>) -> Void) {
        Task {
            do {
                let response: TasksResponse = try await performDecodableFetch("/v1/tasks")
                await MainActor.run { completion(.success(response.tasks)) }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    fileprivate struct TasksResponse: Codable {
        let tasks: [AgentTask]
    }

    /// Delete a task by ID.
    func deleteTask(id: String, completion: @escaping (Bool) -> Void) {
        performBoolRequest(path: "/v1/tasks/\(id)", method: "DELETE", body: nil, completion: completion)
    }

    /// Input struct for creating a task.
    struct TaskInput: Codable {
        var description: String
        var steps: [String]?
        var category: String?
        var priority: String?
        var deadline: String?
        var mode: String?
    }

    /// Create a new task.
    func createTask(_ input: TaskInput, completion: @escaping (Bool) -> Void) {
        let bodyData: Data
        do {
            bodyData = try JSONEncoder().encode(input)
        } catch {
            AppLogger.error("GatewayClient: failed to encode task input: \(error)")
            DispatchQueue.main.async { completion(false) }
            return
        }
        performBoolRequest(path: "/v1/tasks", method: "POST", body: bodyData, acceptedStatuses: [200, 201], completion: completion)
    }

    /// Update a task by ID.
    func updateTask(id: String, updates: [String: Any], completion: @escaping (Bool) -> Void) {
        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: updates)
        } catch {
            AppLogger.error("GatewayClient: failed to serialize task updates: \(error)")
            DispatchQueue.main.async { completion(false) }
            return
        }
        performBoolRequest(path: "/v1/tasks/\(id)", method: "PUT", body: bodyData, completion: completion)
    }

    // MARK: - User Memory API

    /// Fetch user memory content from agent service.
    func fetchUserMemory(completion: @escaping (Result<String, Error>) -> Void) {
        Task {
            do {
                let response: UserMemoryResponse = try await performDecodableFetch("/v1/user-memory")
                await MainActor.run { completion(.success(response.content)) }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    fileprivate struct UserMemoryResponse: Codable {
        let content: String
    }

    /// Update user memory content.
    func updateUserMemory(content: String, completion: @escaping (Bool) -> Void) {
        let bodyData: Data
        do {
            bodyData = try JSONEncoder().encode(["content": content])
        } catch {
            AppLogger.error("GatewayClient: failed to encode user memory content: \(error)")
            DispatchQueue.main.async { completion(false) }
            return
        }
        performBoolRequest(path: "/v1/user-memory", method: "POST", body: bodyData, completion: completion)
    }

    // MARK: - SQLite Memories API

    /// Memory entry from the SQLite knowledge graph.
    struct Memory: Identifiable, Codable {
        let key: String
        let value: AnyCodable
        let updatedAt: String?

        var id: String { key }

        enum CodingKeys: String, CodingKey {
            case key, value
            case updatedAt = "updated_at"
        }

        /// Format the value as a displayable string.
        var displayValue: String {
            let v = value.value
            switch v {
            case let s as String: return s
            case let i as Int: return String(i)
            case let d as Double: return String(d)
            case let b as Bool: return b ? "true" : "false"
            case is NSNull: return "null"
            default: return formatJSON(v)
            }
        }

        private func formatJSON(_ value: Any) -> String {
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: .prettyPrinted),
                  let string = String(data: data, encoding: .utf8) else {
                return String(describing: value)
            }
            return string
        }
    }

    fileprivate struct MemoriesResponse: Codable {
        let memories: [Memory]
    }

    /// Fetch all memories from the SQLite knowledge graph.
    func fetchMemories(completion: @escaping (Result<[Memory], Error>) -> Void) {
        Task {
            do {
                let response: MemoriesResponse = try await performDecodableFetch("/v1/memory")
                await MainActor.run { completion(.success(response.memories)) }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    /// Delete a memory by key.
    func deleteMemory(key: String, completion: @escaping (Bool) -> Void) {
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        performBoolRequest(path: "/v1/memory/\(encodedKey)", method: "DELETE", body: nil, completion: completion)
    }

    /// Create a new memory.
    func createMemory(key: String, value: String, completion: @escaping (Bool) -> Void) {
        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: ["key": key, "value": value])
        } catch {
            AppLogger.error("GatewayClient: failed to serialize memory data: \(error)")
            DispatchQueue.main.async { completion(false) }
            return
        }
        performBoolRequest(path: "/v1/memory", method: "POST", body: bodyData, acceptedStatuses: [200, 201], completion: completion)
    }

    /// Update a memory by key.
    func updateMemory(key: String, value: String, completion: @escaping (Bool) -> Void) {
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: ["value": value])
        } catch {
            AppLogger.error("GatewayClient: failed to serialize memory update: \(error)")
            DispatchQueue.main.async { completion(false) }
            return
        }
        performBoolRequest(path: "/v1/memory/\(encodedKey)", method: "PUT", body: bodyData, completion: completion)
    }

    // MARK: - Preferences API

    /// Agent preferences including name and personality.
    struct AgentPreferences: Codable {
        var agentName: String?
        var agentPersonality: String?
    }

    fileprivate struct PreferencesResponse: Codable {
        let preferences: AgentPreferences
    }

    /// Fetch agent preferences from the agent service.
    func fetchPreferences(completion: @escaping (Result<AgentPreferences, Error>) -> Void) {
        Task {
            do {
                let prefs: AgentPreferences = try await performDecodableFetch("/v1/preferences")
                await MainActor.run { completion(.success(prefs)) }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    /// Update agent preferences.
    func updatePreferences(_ prefs: AgentPreferences, completion: @escaping (Bool) -> Void) {
        let bodyData: Data
        do {
            bodyData = try JSONEncoder().encode(prefs)
        } catch {
            AppLogger.error("GatewayClient: failed to encode preferences: \(error)")
            DispatchQueue.main.async { completion(false) }
            return
        }
        performBoolRequest(path: "/v1/preferences", method: "PUT", body: bodyData, completion: completion)
    }

}
