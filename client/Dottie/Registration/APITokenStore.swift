import Foundation

/// Persists the per-install Pro/register API bearer at `~/.dottie/api_token` (mode 0600).
/// Issued by `api.dottie.ai/api/register`; mirrors the trust boundary of `~/.dottie/agent_token`.
enum APITokenStore {
    static var path: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dottie/api_token")
    }

    static func load() -> String? {
        let raw: String
        do {
            raw = try String(contentsOf: path, encoding: .utf8)
        } catch {
            // Missing file is the expected first-run state; only a real read
            // failure on an existing file breaks auth and warrants an error.
            if FileManager.default.fileExists(atPath: path.path) {
                AppLogger.error("[APITokenStore] failed to read api token, auth will fail: \(error)")
            }
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func save(_ token: String) {
        let dir = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = token.data(using: .utf8) else {
            AppLogger.warn("[APITokenStore] failed to encode token as UTF-8")
            return
        }
        let created = FileManager.default.createFile(
            atPath: path.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        )
        if !created {
            AppLogger.error("[APITokenStore] failed to write api token to \(path.path), auth will fail")
        }
    }
}
