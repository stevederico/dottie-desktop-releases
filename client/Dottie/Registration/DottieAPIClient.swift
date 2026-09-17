import Foundation
import CryptoKit
import IOKit

enum DottieAPIError: Error {
    case invalidURL
    case badStatus(Int)
    case decodingFailed
    case network(Error)
}

struct VersionInfo: Decodable {
    let latest: String
    let minimum_required: String
    let download_url: String
    /// Server-driven remote config. Both optional so an older server (or a
    /// trimmed response) still decodes — the client keeps its compiled-in
    /// defaults rather than failing the whole version check.
    let default_provider: String?
    let models: [RemoteModel]?
    /// BYOK pickers keyed by ChatProvider raw value ("openai", "anthropic", …).
    let provider_models: [String: [RemoteModel]]?
}

/// One model offered by the server, mirroring `ProModel` in dottie-pro.
/// The server serves the same list `/api/pro/*` enforces, so adding
/// or retiring a model is a `PRO_MODELS` env edit rather than an app update.
struct RemoteModel: Decodable, Equatable {
    let id: String
    let name: String
}

private struct RegisterResponse: Decodable {
    let ok: Bool
    let token: String
}

final class DottieAPIClient {
    static let shared = DottieAPIClient()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = DottieAPIConfig.requestTimeout
        config.timeoutIntervalForResource = DottieAPIConfig.requestTimeout
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    private func buildRequest(path: String, method: String, body: [String: Any]? = nil) throws -> URLRequest {
        guard let url = URL(string: "\(DottieAPIConfig.baseURL)\(path)") else {
            throw DottieAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token = APITokenStore.load() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    /// Sends a request and, on HTTP 404 (server's silence-is-security signal for an
    /// invalid/missing bearer token), bootstraps a fresh `api_token` and retries once.
    /// Used for guarded Pro endpoints. Public endpoints (`/api/register`, `/api/version`)
    /// skip the retry.
    private func sendWithTokenRetry(buildRequest: () throws -> URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = try buildRequest()
        var (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            await RegistrationManager.shared.bootstrapTokenIfNeeded(force: true)
            request = try buildRequest()
            (data, response) = try await session.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else { throw DottieAPIError.badStatus(0) }
        return (data, http)
    }

    /// SHA-256 hex of the Mac's IOPlatformUUID — a stable per-device id that
    /// survives reinstalls, prefs wipes, and fresh accounts, so the server can
    /// tie the Pro free credit to the machine rather than the email. Hashed so
    /// the raw hardware UUID never leaves the device. Empty on lookup failure.
    static var hashedDeviceID: String {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard entry != 0 else { return "" }
        defer { IOObjectRelease(entry) }
        guard let uuid = IORegistryEntryCreateCFProperty(entry, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String, !uuid.isEmpty else { return "" }
        return SHA256.hash(data: Data(uuid.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func register(name: String, email: String, installID: String) async throws {
        var body: [String: Any] = [
            "name": name,
            "email": email,
            "install_id": installID,
            "version": Self.appVersion,
            "os_version": Self.osVersion
        ]
        let deviceID = Self.hashedDeviceID
        if !deviceID.isEmpty { body["device_id"] = deviceID }
        let request = try buildRequest(path: "/api/register", method: "POST", body: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DottieAPIError.badStatus(0) }
        guard http.statusCode == 200 else { throw DottieAPIError.badStatus(http.statusCode) }
        if let decoded = try? JSONDecoder().decode(RegisterResponse.self, from: data), decoded.ok {
            APITokenStore.save(decoded.token)
            AppLogger.info("[DottieAPIClient] saved api_token from /api/register")
        } else {
            AppLogger.warn("[DottieAPIClient] /api/register returned 200 with no token field")
        }
    }

    func fetchVersion() async throws -> VersionInfo {
        // Public endpoint: build a bare request without an Authorization header.
        guard let url = URL(string: "\(DottieAPIConfig.baseURL)/api/version") else {
            throw DottieAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DottieAPIError.badStatus(0) }
        guard http.statusCode == 200 else { throw DottieAPIError.badStatus(http.statusCode) }
        guard let info = try? JSONDecoder().decode(VersionInfo.self, from: data) else {
            throw DottieAPIError.decodingFailed
        }
        return info
    }

    /// GET /api/pro/status — free credit + paid entitlement (registration bearer).
    func fetchProStatus() async throws -> ProStatus {
        let (data, http) = try await sendWithTokenRetry {
            try self.buildRequest(path: "/api/pro/status", method: "GET")
        }
        guard http.statusCode == 200 else { throw DottieAPIError.badStatus(http.statusCode) }
        return try ProStatus.decode(data)
    }

    /// POST /api/pro/checkout → hosted Stripe Checkout URL (open in browser).
    func createProCheckoutURL() async throws -> URL {
        let (data, http) = try await sendWithTokenRetry {
            try self.buildRequest(path: "/api/pro/checkout", method: "POST", body: [:])
        }
        guard http.statusCode == 200 else { throw DottieAPIError.badStatus(http.statusCode) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlStr = obj["url"] as? String,
              let url = URL(string: urlStr) else {
            throw DottieAPIError.decodingFailed
        }
        return url
    }

    /// POST /api/pro/portal → Stripe Customer Portal URL.
    func createProPortalURL() async throws -> URL {
        let (data, http) = try await sendWithTokenRetry {
            try self.buildRequest(path: "/api/pro/portal", method: "POST", body: [:])
        }
        guard http.statusCode == 200 else { throw DottieAPIError.badStatus(http.statusCode) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlStr = obj["url"] as? String,
              let url = URL(string: urlStr) else {
            throw DottieAPIError.decodingFailed
        }
        return url
    }

    /// POST /api/pro/refund → records a refund request for operator review.
    /// 409 = nothing live at Stripe, or a request is already pending.
    func requestProRefund() async throws -> ProRefundResult {
        let (data, http) = try await sendWithTokenRetry {
            try self.buildRequest(path: "/api/pro/refund", method: "POST", body: [:])
        }
        guard http.statusCode == 200 else { throw DottieAPIError.badStatus(http.statusCode) }
        return try ProRefundResult.decode(data)
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static var osVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    /// Compare version strings like "7.99" < "8.0". Returns true if `a < b`.
    /// Delegates to `UpdateChecker.isNewer` (same dot-split numeric comparator):
    /// `a < b` is equivalent to `b` being strictly newer than `a`.
    static func versionLessThan(_ a: String, _ b: String) -> Bool {
        return UpdateChecker.isNewer(b, than: a)
    }
}
