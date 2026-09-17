import Foundation

final class RegistrationManager: ObservableObject {
    static let shared = RegistrationManager()

    private let defaults = UserDefaults.standard
    private let bootstrapLock = NSLock()
    private var bootstrapTask: Task<Void, Never>?

    private enum Keys {
        static let hasSubmitted = "hasSubmittedRegistration"
        static let confirmed = "registrationConfirmed"
        static let name = "userName"
        static let email = "userEmail"
        static let installID = "installID"
    }

    var hasSubmittedRegistration: Bool {
        get { defaults.bool(forKey: Keys.hasSubmitted) }
        set { defaults.set(newValue, forKey: Keys.hasSubmitted) }
    }

    var isRegistrationConfirmed: Bool {
        get { defaults.bool(forKey: Keys.confirmed) }
        set { defaults.set(newValue, forKey: Keys.confirmed) }
    }

    var userName: String { defaults.string(forKey: Keys.name) ?? "" }
    var userEmail: String { defaults.string(forKey: Keys.email) ?? "" }

    var installID: String {
        if let existing = defaults.string(forKey: Keys.installID), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: Keys.installID)
        return fresh
    }

    private init() {}

    /// Save the user's registration locally and fire the server POST in the background.
    /// Returns immediately — caller can close the gate as soon as this returns.
    func submit(name: String, email: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces).lowercased()
        defaults.set(trimmedName, forKey: Keys.name)
        defaults.set(trimmedEmail, forKey: Keys.email)
        hasSubmittedRegistration = true
        isRegistrationConfirmed = false
        Task.detached { [installID] in
            await Self.attemptRegister(name: trimmedName, email: trimmedEmail, installID: installID, isRetry: false)
        }
    }

    /// Retry the registration POST if it was never confirmed. Safe to call on every launch.
    func retryIfNeeded() {
        guard hasSubmittedRegistration, !isRegistrationConfirmed else { return }
        let name = userName
        let email = userEmail
        let id = installID
        guard !name.isEmpty, !email.isEmpty else { return }
        Task.detached {
            await Self.attemptRegister(name: name, email: email, installID: id, isRetry: true)
        }
    }

    /// Ensures `~/.dottie/api_token` exists by silently re-registering if missing.
    /// Idempotent on the server (upsert by email preserves the existing token), so
    /// safe to call from multiple boot paths. Concurrent callers share one in-flight
    /// register Task so we never exceed the server's 10/min/IP register rate limit.
    /// Best-effort — never throws; on failure the caller proceeds without auth and
    /// a guarded endpoint will 404, which the in-call retry path catches.
    /// Pass `force: true` from a 404 retry path to re-register even when a stale
    /// token file is on disk — server upsert preserves the row's real token, so
    /// we self-heal whenever the local file got out of sync.
    ///
    /// Mint the bearer for an already-registered install (Pro relay + guarded APIs).
    func bootstrapTokenIfNeeded(force: Bool = false) async {
        if !force, APITokenStore.load() != nil { return }
        guard hasSubmittedRegistration else { return }
        let name = userName, email = userEmail, id = installID
        guard !name.isEmpty, !email.isEmpty else { return }

        bootstrapLock.lock()
        if let inFlight = bootstrapTask {
            bootstrapLock.unlock()
            await inFlight.value
            return
        }
        let task = Task<Void, Never> {
            do {
                try await DottieAPIClient.shared.register(name: name, email: email, installID: id)
                AppLogger.shared.info("[Registration] bootstrapped api_token")
            } catch {
                AppLogger.shared.warn("[Registration] api_token bootstrap failed: \(error)")
            }
        }
        bootstrapTask = task
        bootstrapLock.unlock()
        await task.value
        bootstrapLock.lock()
        bootstrapTask = nil
        bootstrapLock.unlock()
    }

    private static func attemptRegister(name: String, email: String, installID: String, isRetry: Bool) async {
        do {
            try await DottieAPIClient.shared.register(name: name, email: email, installID: installID)
            await MainActor.run {
                RegistrationManager.shared.isRegistrationConfirmed = true
            }
            AppLogger.shared.info("[Registration] confirmed by server")
        } catch {
            // A failed first attempt is usually just no network during
            // onboarding and self-heals next launch; only a failed retry is
            // signal. Bucket the error instead of shipping the raw description
            // (URLError text can carry the request URL).
            if isRetry {
                AppLogger.shared.warn("[Registration] retry failed: \(error)")
            }
            AppLogger.shared.info("[Registration] server not confirmed yet: \(error) — will retry next launch")
        }
    }

    /// Email validation matching backend regex: /^[^\s@]+@[^\s@]+\.[^\s@]+$/
    static func isValidEmail(_ email: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 320 else { return false }
        let pattern = #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#
        return trimmed.range(of: pattern, options: .regularExpression) != nil
    }
}
