//
//  UpdateChecker.swift
//  Dottie
//
//  Checks GitHub releases for app updates and handles automatic download/installation.
//

import Foundation
import AppKit
import Security

/// Update lifecycle phases.
enum UpdatePhase: Equatable {
    case idle
    case checking
    case available
    case downloading(progress: Double)
    case extracting
    case verifying
    case readyToInstall
    case installing
    case error(message: String)

    var isInProgress: Bool {
        switch self {
        case .downloading, .extracting, .verifying, .installing:
            return true
        default:
            return false
        }
    }

    /// Returns true if the update banner should be visible.
    var shouldShowBanner: Bool {
        switch self {
        case .idle, .checking:
            return false
        default:
            return true
        }
    }
}

/// Singleton that checks GitHub releases for updates and handles auto-installation.
class UpdateChecker: NSObject, ObservableObject {
    static let shared = UpdateChecker()

    // MARK: - Published Properties

    @Published var updateAvailable = false
    @Published var latestVersion: String?
    @Published var downloadURL: String?
    @Published var updatePhase: UpdatePhase = .idle
    @Published var statusMessage: String = ""

    // MARK: - Private Properties

    private let expectedTeamID = ProcessInfo.processInfo.environment["DOTTIE_SIGNING_TEAM_ID"] ?? ""
    private var downloadTask: URLSessionDownloadTask?
    private var tempDirectory: URL?
    private var downloadSession: URLSession?
    private var recheckTimer: Timer?

    /// How often a running app re-queries GitHub. Dottie is a menu-bar app that
    /// stays up for weeks, so a launch-only check leaves those installs pinned to
    /// whatever shipped the day they last quit.
    static let recheckInterval: TimeInterval = 6 * 60 * 60

    private override init() {
        super.init()
    }

    // MARK: - Update Check

    /// Current app version from the bundle.
    private var currentAppVersion: String {
        DottieAPIClient.appVersion
    }

    /// Checks now and every `recheckInterval` thereafter. Call once on app launch.
    ///
    /// The repeat only refreshes state (banner + menu item); the prompt window still
    /// opens at most once per launch per version, so a long session never gets a
    /// modal thrown at it twice for the same release.
    func startPeriodicChecks() {
        checkForUpdate()
        guard recheckTimer == nil else { return }
        recheckTimer = Timer.scheduledTimer(withTimeInterval: Self.recheckInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Never restart a check on top of a download/verify/install in flight.
            guard !self.updatePhase.isInProgress, self.updatePhase != .readyToInstall else { return }
            self.checkForUpdate()
        }
    }

    /// Checks GitHub Releases for a newer release. Call on app launch.
    ///
    /// Hits GitHub directly — not the local gateway — so updates still work when the
    /// gateway failed to start (the exact failure mode most stuck users hit).
    ///
    /// - Parameter userInitiated: true when the user picked "Check For Updates…".
    ///   Those checks bypass the once-per-launch prompt policy and report "up to
    ///   date" / failures instead of finishing silently.
    func checkForUpdate(userInitiated: Bool = false) {
        guard let url = URL(string: "https://api.github.com/repos/stevederico/dottie-desktop-releases/releases/latest") else { return }

        DispatchQueue.main.async {
            self.updatePhase = .checking
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Dottie/\(currentAppVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                AppLogger.shared.warn("[UpdateChecker] checkForUpdate network error: \(error.localizedDescription)")
                self.finishCheck(userInitiated: userInitiated, failure: error.localizedDescription)
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                AppLogger.shared.warn("[UpdateChecker] checkForUpdate: HTTP \(http.statusCode)")
                self.finishCheck(userInitiated: userInitiated, failure: "GitHub returned HTTP \(http.statusCode).")
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                AppLogger.shared.warn("[UpdateChecker] checkForUpdate: malformed response")
                self.finishCheck(userInitiated: userInitiated, failure: "Could not read the release feed.")
                return
            }

            let tag = (json["tag_name"] as? String) ?? ""
            let latestVersion = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
            guard !latestVersion.isEmpty else {
                self.finishCheck(userInitiated: userInitiated, failure: "Could not read the release feed.")
                return
            }

            if Self.isNewer(latestVersion, than: self.currentAppVersion) {
                let downloadURL = Self.pickZipAssetURL(from: json) ?? (json["html_url"] as? String)
                DispatchQueue.main.async {
                    self.updateAvailable = true
                    self.latestVersion = latestVersion
                    self.downloadURL = downloadURL
                    self.updatePhase = .available
                    AppLogger.shared.info("[UpdateChecker] Update available: \(self.currentAppVersion) → \(latestVersion)")
                    // The launcher banner only renders inside the Cmd+K panel, so on
                    // its own it never reaches a user who doesn't open the launcher.
                    // Raise a real window too — once per launch, per UpdatePrompt.
                    MainActor.assumeIsolated {
                        if userInitiated {
                            UpdatePrompt.recordPrompted(latestVersion)
                            UpdatePromptWindow.present(version: latestVersion)
                        } else {
                            UpdatePromptWindow.presentIfNeeded(version: latestVersion)
                        }
                    }
                }
            } else {
                self.finishCheck(userInitiated: userInitiated, failure: nil)
            }
        }.resume()
    }

    /// Terminal path for a check that produced no update. Silent for the automatic
    /// launch check; user-initiated checks always get an answer.
    private func finishCheck(userInitiated: Bool, failure: String?) {
        DispatchQueue.main.async {
            self.updatePhase = .idle
            guard userInitiated else { return }
            MainActor.assumeIsolated {
                let alert = NSAlert()
                if let failure = failure {
                    alert.messageText = "Could Not Check For Updates"
                    alert.informativeText = failure
                    alert.alertStyle = .warning
                } else {
                    alert.messageText = "Dottie Is Up To Date"
                    alert.informativeText = "You are running \(self.currentAppVersion), the latest version."
                    alert.alertStyle = .informational
                }
                alert.addButton(withTitle: "OK")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    /// Returns true if `candidate` is strictly newer than `current`. Compares numeric
    /// dot-separated parts (e.g. "9.60" > "9.24"). Non-numeric parts become 0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        let len = max(a.count, b.count)
        for i in 0..<len {
            let ai = i < a.count ? a[i] : 0
            let bi = i < b.count ? b[i] : 0
            if ai > bi { return true }
            if ai < bi { return false }
        }
        return false
    }

    /// Pick the first `.zip` asset from a GitHub release JSON, falling back to the
    /// first asset if none matches.
    private static func pickZipAssetURL(from json: [String: Any]) -> String? {
        guard let assets = json["assets"] as? [[String: Any]] else { return nil }
        let zip = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".zip") == true }
        return (zip?["browser_download_url"] as? String) ?? (assets.first?["browser_download_url"] as? String)
    }

    /// Opens the download URL in the browser (fallback).
    func openDownloadPage() {
        guard let urlString = downloadURL, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Clears an `.error` phase so the banner/prompt can hide or return to `.available`.
    func dismissError() {
        DispatchQueue.main.async {
            if self.updateAvailable, self.latestVersion != nil {
                self.updatePhase = .available
                self.statusMessage = ""
            } else {
                self.updatePhase = .idle
                self.statusMessage = ""
            }
        }
    }

    // MARK: - Download Update

    /// Starts downloading the update.
    func downloadUpdate() {
        guard let urlString = downloadURL, let url = URL(string: urlString) else {
            setError("Invalid download URL")
            return
        }
        // Create temp directory
        let uuid = UUID().uuidString
        guard let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            setError("Cannot access caches directory")
            return
        }
        tempDirectory = cachesURL.appendingPathComponent("DottieUpdate-\(uuid)")

        do {
            guard let tempDir = tempDirectory else {
                setError("Temp directory not initialized")
                return
            }
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            setError("Failed to create temp directory: \(error.localizedDescription)")
            return
        }

        DispatchQueue.main.async {
            self.updatePhase = .downloading(progress: 0)
            self.statusMessage = "Starting download..."
        }

        // Create session with delegate for progress tracking
        let config = URLSessionConfiguration.default
        downloadSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)

        var request = URLRequest(url: url)
        request.setValue("DottieApp", forHTTPHeaderField: "User-Agent")

        downloadTask = downloadSession?.downloadTask(with: request)
        downloadTask?.resume()

        AppLogger.shared.info("[UpdateChecker] Started downloading update from \(urlString)")
    }

    /// Cancels the current download and cleans up.
    func cancelUpdate() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadSession?.invalidateAndCancel()
        downloadSession = nil

        cleanup()

        DispatchQueue.main.async {
            self.updatePhase = .available
            self.statusMessage = ""
        }

        AppLogger.shared.info("[UpdateChecker] Update cancelled")
    }

    // MARK: - Install Update

    /// Installs the downloaded update.
    func installUpdate() {
        guard let tempDir = tempDirectory else {
            setError("No update downloaded")
            return
        }

        let zipPath = tempDir.appendingPathComponent("Dottie.zip")
        guard FileManager.default.fileExists(atPath: zipPath.path) else {
            setError("Update file not found")
            return
        }

        DispatchQueue.main.async {
            self.updatePhase = .installing
            self.statusMessage = "Installing update..."
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performInstallation(zipPath: zipPath, tempDir: tempDir)
        }
    }

    private func performInstallation(zipPath: URL, tempDir: URL) {
        let fm = FileManager.default
        let appURL = URL(fileURLWithPath: "/Applications/Dottie.app")
        let backupURL = URL(fileURLWithPath: "/Applications/Dottie.app.backup")
        let extractedAppURL = tempDir.appendingPathComponent("Dottie.app")

        do {
            // Step 1: Backup existing app
            DispatchQueue.main.async {
                self.statusMessage = "Creating backup..."
            }

            if fm.fileExists(atPath: backupURL.path) {
                try fm.removeItem(at: backupURL)
            }

            if fm.fileExists(atPath: appURL.path) {
                try fm.moveItem(at: appURL, to: backupURL)
            }

            // Step 2: Move new app to /Applications
            DispatchQueue.main.async {
                self.statusMessage = "Installing new version..."
            }

            try fm.moveItem(at: extractedAppURL, to: appURL)

            // Step 3: Clear quarantine xattr
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            process.arguments = ["-dr", "com.apple.quarantine", appURL.path]
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                AppLogger.shared.warn("[UpdateChecker] xattr quarantine removal (install) failed: \(error.localizedDescription)")
            }

            // Step 4: Remove backup
            if fm.fileExists(atPath: backupURL.path) {
                try? fm.removeItem(at: backupURL)
            }

            // Cleanup temp directory
            cleanup()

            AppLogger.shared.info("[UpdateChecker] Update installed successfully")

            // Restart the app
            restartApp()

        } catch {
            AppLogger.shared.error("[UpdateChecker] Installation failed: \(error)")

            // Rollback
            if fm.fileExists(atPath: backupURL.path) && !fm.fileExists(atPath: appURL.path) {
                try? fm.moveItem(at: backupURL, to: appURL)
                AppLogger.shared.info("[UpdateChecker] Rolled back to previous version")
            }

            DispatchQueue.main.async {
                self.setError("Installation failed: \(error.localizedDescription)")
            }
        }
    }

    private func restartApp() {
        // Relaunch only AFTER this process has fully exited. A fixed `sleep 2`
        // races the app's teardown (>2s in practice): `open` then sees the still-live
        // process, the single-instance guard activates the stale copy and terminates the
        // relaunch, so the user is left on the old version (or no app at all). Poll the
        // current PID with `kill -0` until it dies, then `open`. A 30s ceiling guards
        // against a hung/zombie process so we don't loop forever.
        let appPath = "/Applications/Dottie.app"
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        for i in $(seq 1 300); do
          kill -0 \(pid) 2>/dev/null || break
          sleep 0.1
        done
        open "\(appPath)"
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]

        do {
            try process.run()
            AppLogger.shared.info("[UpdateChecker] Scheduled app restart")

            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        } catch {
            AppLogger.shared.error("[UpdateChecker] Failed to schedule restart: \(error)")
            DispatchQueue.main.async {
                self.setError("Update installed. Please restart Dottie manually.")
            }
        }
    }

    // MARK: - Extraction

    private func extractUpdate(zipURL: URL) {
        guard let tempDir = tempDirectory else {
            setError("Temp directory not available")
            return
        }

        DispatchQueue.main.async {
            self.updatePhase = .extracting
            self.statusMessage = "Extracting update..."
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-xk", zipURL.path, tempDir.path]

            do {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus != 0 {
                    DispatchQueue.main.async {
                        self?.setError("Extraction failed (exit code \(process.terminationStatus))")
                    }
                    return
                }

                // Find extracted Dottie.app
                let extractedApp = tempDir.appendingPathComponent("Dottie.app")
                guard FileManager.default.fileExists(atPath: extractedApp.path) else {
                    DispatchQueue.main.async {
                        self?.setError("Dottie.app not found in update")
                    }
                    return
                }

                AppLogger.shared.info("[UpdateChecker] Extraction complete")

                // Remove quarantine xattr before verification (prevents errSecCSBadResource)
                let xattrProcess = Process()
                xattrProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                xattrProcess.arguments = ["-dr", "com.apple.quarantine", extractedApp.path]
                do {
                    try xattrProcess.run()
                    xattrProcess.waitUntilExit()
                } catch {
                    AppLogger.shared.warn("[UpdateChecker] xattr quarantine removal (extract) failed: \(error.localizedDescription)")
                }

                // Verify signature
                self?.verifySignature(appURL: extractedApp)

            } catch {
                DispatchQueue.main.async {
                    self?.setError("Extraction failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Signature Verification

    private func verifySignature(appURL: URL) {
        DispatchQueue.main.async {
            self.updatePhase = .verifying
            self.statusMessage = "Verifying code signature..."
        }

        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode)

        guard createStatus == errSecSuccess, let code = staticCode else {
            setError("Failed to read code signature")
            return
        }

        // Enforce a valid code seal. When DOTTIE_SIGNING_TEAM_ID is set, also require
        // Apple notarization + that Developer ID team (distribution builds). OSS /
        // local unsigned trees leave the env unset and only check a basic seal.
        let requirementText: String
        if expectedTeamID.isEmpty {
            requirementText = "anchor apple generic"
            AppLogger.shared.warn("[UpdateChecker] DOTTIE_SIGNING_TEAM_ID unset — using basic signature check only")
        } else {
            requirementText =
                "anchor apple generic and " +
                "certificate leaf[field.1.2.840.113635.100.6.1.13] exists and " +
                "certificate 1[field.1.2.840.113635.100.6.2.6] exists and " +
                "certificate leaf[subject.OU] = \"\(expectedTeamID)\""
        }

        var requirement: SecRequirement?
        let reqStatus = SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
        guard reqStatus == errSecSuccess, let codeRequirement = requirement else {
            setError("Signature verification failed: could not build requirement")
            return
        }

        let checkStatus = SecStaticCodeCheckValidity(code, SecCSFlags(), codeRequirement)
        guard checkStatus == errSecSuccess else {
            setError("Signature verification failed: bundle is not validly signed/notarized")
            AppLogger.shared.error("[UpdateChecker] SecStaticCodeCheckValidity failed: \(checkStatus)")
            return
        }

        AppLogger.shared.info("[UpdateChecker] Code signature verified (notarized, Team ID: \(expectedTeamID))")

        // Download + verification succeeded — release the delegate session/socket.
        finishSession()

        DispatchQueue.main.async {
            self.updatePhase = .readyToInstall
            self.statusMessage = "Ready to install v\(self.latestVersion ?? "")"
        }
    }

    // MARK: - Helpers

    private func setError(_ message: String) {
        AppLogger.shared.error("[UpdateChecker] \(message)")
        finishSession()
        DispatchQueue.main.async {
            self.updatePhase = .error(message: message)
            self.statusMessage = message
        }
    }

    /// Invalidates the delegate-based download session so its strong reference to `self`
    /// (and the underlying socket) is released. Must be called on every terminal path —
    /// success and error — otherwise each retry of downloadUpdate() leaks one URLSession.
    private func finishSession() {
        downloadTask = nil
        downloadSession?.finishTasksAndInvalidate()
        downloadSession = nil
    }

    private func cleanup() {
        if let tempDir = tempDirectory {
            try? FileManager.default.removeItem(at: tempDir)
            tempDirectory = nil
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension UpdateChecker: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let tempDir = tempDirectory else {
            setError("Temp directory not available")
            return
        }

        let destinationURL = tempDir.appendingPathComponent("Dottie.zip")

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)

            AppLogger.shared.info("[UpdateChecker] Download complete: \(destinationURL.path)")

            // Start extraction
            extractUpdate(zipURL: destinationURL)

        } catch {
            setError("Failed to save download: \(error.localizedDescription)")
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0

        DispatchQueue.main.async {
            self.updatePhase = .downloading(progress: progress)
            self.statusMessage = "\(ClientManager.formatBytes(totalBytesWritten)) / \(ClientManager.formatBytes(totalBytesExpectedToWrite))"
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as NSError?, error.code != NSURLErrorCancelled {
            setError("Download failed: \(error.localizedDescription)")
        }
    }
}

