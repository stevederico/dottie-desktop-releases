//
//  UpdatePrompt.swift
//  Dottie
//
//  Decides whether the "update available" prompt should be shown, and remembers
//  what it already prompted for. Split out from UpdateChecker so the decision is a
//  pure function with no AppKit dependency.
//

import Foundation

/// Pure policy + persistence for the soft-update prompt.
///
/// The launcher banner alone was not converting — it only renders inside the
/// Cmd+K panel, so a user who never opens the launcher never learns an update
/// exists. The prompt is a real window, but it must not nag: it fires at most
/// once per app launch, and re-fires on a later launch only after `cooldown`.
enum UpdatePrompt {
    /// Minimum gap between prompts for the SAME version. Long enough that
    /// quitting and relaunching within a work session doesn't re-prompt, short
    /// enough that the next day's launch asks again.
    static let cooldown: TimeInterval = 6 * 60 * 60

    private static let lastPromptedVersionKey = "update.lastPromptedVersion"
    private static let lastPromptedAtKey = "update.lastPromptedAt"

    /// Set in-process once a version has been prompted, so repeat `checkForUpdate()`
    /// calls in a single launch never show the window twice.
    private static var promptedThisLaunch: Set<String> = []

    /// Whether the prompt window should open for `latest`.
    ///
    /// - Parameters:
    ///   - lastPromptedVersion: last version this install was prompted about (nil = never).
    ///   - lastPromptedAt: when that prompt was shown (nil = never).
    ///   - promptedThisLaunch: versions already prompted in the current process.
    static func shouldPrompt(
        latest: String,
        current: String,
        lastPromptedVersion: String?,
        lastPromptedAt: Date?,
        promptedThisLaunch: Set<String> = [],
        now: Date = Date(),
        cooldown: TimeInterval = UpdatePrompt.cooldown
    ) -> Bool {
        guard !latest.isEmpty, UpdateChecker.isNewer(latest, than: current) else { return false }
        if promptedThisLaunch.contains(latest) { return false }
        guard lastPromptedVersion == latest, let at = lastPromptedAt else { return true }
        // A clock that jumped backwards would otherwise mute the prompt forever.
        let elapsed = now.timeIntervalSince(at)
        return elapsed >= cooldown || elapsed < 0
    }

    /// UserDefaults-backed form of `shouldPrompt`.
    static func shouldPrompt(latest: String, current: String, defaults: UserDefaults = .standard) -> Bool {
        let at = defaults.object(forKey: lastPromptedAtKey) as? Date
        return shouldPrompt(
            latest: latest,
            current: current,
            lastPromptedVersion: defaults.string(forKey: lastPromptedVersionKey),
            lastPromptedAt: at,
            promptedThisLaunch: promptedThisLaunch
        )
    }

    /// Records that the user has just been shown the prompt for `version`.
    static func recordPrompted(_ version: String, defaults: UserDefaults = .standard, now: Date = Date()) {
        promptedThisLaunch.insert(version)
        defaults.set(version, forKey: lastPromptedVersionKey)
        defaults.set(now, forKey: lastPromptedAtKey)
    }
}
