//
//  ConfigStore.swift
//  Dottie
//
//  Fetches runtime config from the gateway's /v1/config/resolved endpoint.
//  Replaces hardcoded permission scopes, TTS voice maps, and STT model lists.
//

import Foundation

/// Caches server-driven config (permission scopes, TTS voices, STT models)
/// so Swift never hardcodes model metadata. Falls back to built-in defaults
/// when the gateway is unreachable (e.g., during startup before agent is ready).
class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    // Permission scopes are server-driven only — the gateway's /v1/config/resolved
    // response is the single source of truth. Starts empty; the Permissions UI
    // shows a loading state until the first fetch lands (see `hasFetched` /
    // `permissionsLoaded`).
    @Published var permissionScopes: [String] = []
    @Published var ttsVoices: [String] = ConfigStore.defaultTTSVoices
    /// Model currently serving chat. Chat is cloud-only, so this starts as the
    /// user's selected cloud model and is overwritten only if the gateway names
    /// one in /v1/config/resolved.
    @Published var activeModel: String = UserDefaults.standard.string(forKey: DefaultsKeys.selectedCloudModel.rawValue) ?? ""
    /// Whether the active model can see images (a cloud vision provider).

    /// True once the gateway has returned at least one permission scope.
    /// The Permissions settings section uses this to distinguish "still loading"
    /// from "genuinely no scopes" so it never renders an empty list mid-startup.
    var permissionsLoaded: Bool { !permissionScopes.isEmpty }

    private var hasFetched = false

    private init() {}

    /// Fetches resolved config from the gateway. Safe to call multiple times;
    /// only fetches once unless `force` is true.
    func fetchIfNeeded(force: Bool = false) {
        guard !hasFetched || force else { return }

        guard let url = URL(string: "http://127.0.0.1:\(AppPorts.agentServer)/v1/config/resolved") else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        ClientManager.setAgentAuth(on: &request)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                // WARN not ERROR — expected on launch before gateway is ready.
                AppLogger.warn("[ConfigStore] fetch failed: \(error.localizedDescription)")
                return
            }
            guard let data = data,
                  (response as? HTTPURLResponse)?.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                AppLogger.warn("[ConfigStore] fetch: HTTP \(code)")
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                AppLogger.error("[ConfigStore] fetch: malformed JSON response")
                return
            }

            DispatchQueue.main.async {
                self.hasFetched = true

                // Sync active model from gateway (single source of truth)
                if let model = json["activeModel"] as? String, !model.isEmpty {
                    self.activeModel = model
                    UserDefaults.standard.set(model, forKey: DefaultsKeys.selectedModel.rawValue)
                }
                if let scopes = json["permissionScopes"] as? [String], !scopes.isEmpty {
                    let wasEmpty = self.permissionScopes.isEmpty
                    self.permissionScopes = scopes
                    // buildPermissions() iterates permissionScopes, so before this
                    // fetch lands it returns {} — and any config pushed in that
                    // window told the gateway the user had granted nothing. The
                    // gateway keeps that map for the rest of the session (it only
                    // changes on the next push), so a launch with no Settings
                    // interaction left every scoped tool denied: the agent would
                    // answer "that feature is disabled" for permissions the user
                    // had actually granted. Observed as "permissions=0 categories"
                    // on every warmup in gateway.log. Re-push now that the scope
                    // list exists.
                    if wasEmpty {
                        AppLogger.info("[ConfigStore] permission scopes arrived (\(scopes.count)) — re-pushing config")
                        NotificationCenter.default.post(name: .permissionsChanged, object: nil)
                    }
                }

                if let voices = json["ttsVoices"] as? [String], !voices.isEmpty {
                    self.ttsVoices = voices
                }
            }
        }.resume()
    }

    /// Builds permission dictionary from UserDefaults using server-provided scopes.
    func buildPermissions() -> [String: Bool] {
        var permissions: [String: Bool] = [:]
        for scope in permissionScopes {
            permissions[scope] = UserDefaults.standard.bool(forKey: "permission.\(scope)")
        }
        return permissions
    }

    // MARK: - Built-in Defaults (used before gateway is reachable)

    private static let defaultTTSVoices = [
        "af_heart", "af_nova", "af_bella", "af_nicole", "af_sarah", "af_sky",
        "am_adam", "am_michael",
        "bf_emma", "bf_isabella",
        "bm_george", "bm_lewis",
    ]
}
