//
//  DictationSupport.swift
//  Dottie
//
//  Local dictation habit stats + on-device vocabulary / replacements.
//

import AppKit
import Contacts
import Foundation
import ServiceManagement

// MARK: - Dictation Stats

/// Local dictation habit stats: day-keyed word counts in the menu bar, plus a
/// one-time launch-at-login nudge after the habit threshold. UserDefaults only
/// — nothing leaves the machine (no transcript text).
enum DictationStats {
    /// [String: Int] keyed yyyy-MM-dd, pruned to the newest `keptDays` entries.
    private static let countsKey = "dictationDailyWords"
    /// Lifetime successful-dictation count (drives launch-at-login nudge).
    private static let totalKey = "dictationSuccessCount"
    private static let nudgeShownKey = "launchAtLoginNudgeShown"
    private static let keptDays = 14
    /// ~40 wpm average typing speed → "minutes of typing" framing.
    private static let typingWPM = 40
    /// Nudge after the 3rd successful dictation — earn the ask, never at onboarding.
    private static let nudgeThreshold = 3

    private static func dayKey(daysAgo: Int = 0) -> String {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static var counts: [String: Int] {
        (UserDefaults.standard.dictionary(forKey: countsKey) as? [String: Int]) ?? [:]
    }

    static var wordsToday: Int { counts[dayKey()] ?? 0 }

    /// Words over the last 7 calendar days, including today.
    static var wordsThisWeek: Int {
        let c = counts
        return (0..<7).reduce(0) { $0 + (c[dayKey(daysAgo: $1)] ?? 0) }
    }

    static var totalDictations: Int { UserDefaults.standard.integer(forKey: totalKey) }

    static func minutesOfTyping(words: Int) -> Int { max(1, words / typingWPM) }

    /// Records one successful dictation (called from the paste chokepoint).
    /// May show the one-time launch-at-login nudge once the habit threshold is crossed.
    static func record(text: String) {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        guard words > 0 else { return }
        let defaults = UserDefaults.standard
        var c = counts
        c[dayKey(), default: 0] += words
        if c.count > keptDays {
            let keep = Set(c.keys.sorted(by: >).prefix(keptDays))
            c = c.filter { keep.contains($0.key) }
        }
        defaults.set(c, forKey: countsKey)
        let total = defaults.integer(forKey: totalKey) + 1
        defaults.set(total, forKey: totalKey)
        maybeShowLaunchAtLoginNudge(total: total)
    }

    /// One-time nudge to register the app as a login item after the Nth
    /// successful dictation. Skipped forever once shown, and never shown when
    /// launch-at-login is already on. Delayed a beat so it doesn't fight the
    /// paste that just landed in another app.
    private static func maybeShowLaunchAtLoginNudge(total: Int) {
        let defaults = UserDefaults.standard
        guard total >= nudgeThreshold,
              !defaults.bool(forKey: nudgeShownKey),
              SMAppService.mainApp.status != .enabled else { return }
        defaults.set(true, forKey: nudgeShownKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let week = wordsThisWeek
            let alert = NSAlert()
            alert.messageText = "Keep Dottie one key away"
            alert.informativeText = "You've dictated \(week) words this week (~\(minutesOfTyping(words: week)) min of typing). Start Dottie at login so push-to-talk is always ready?"
            alert.addButton(withTitle: "Start at Login")
            alert.addButton(withTitle: "Not Now")
            NSApp.activate(ignoringOtherApps: true)
            let accepted = alert.runModal() == .alertFirstButtonReturn
            if accepted {
                do {
                    try SMAppService.mainApp.register()
                } catch {
                    AppLogger.shared.error("[DictationStats] launch-at-login register failed: \(error)")
                }
            }
        }
    }
}

// MARK: - Dictation Vocabulary

/// Builds the on-device vocabulary + context hints sent with each dictation
/// upload so the gateway's local LLM pass can spell names/brands correctly.
///
/// Sources (all local, zero-setup):
///   - User custom words (Settings → Dictation)
///   - Contact names (only when Contacts is already authorized — never prompts)
///   - Foreground app name (NSWorkspace) for per-app formatting
///
/// Contact names are cached and refreshed lazily; enumeration never blocks a
/// dictation more than once per `cacheTTL`.
enum DictationVocabulary {
    private static let cacheTTL: TimeInterval = 600 // 10 min
    private static let maxTerms = 200

    private static let lock = NSLock()
    private static var cachedContactNames: [String] = []
    private static var cachedAt: Date = .distantPast

    /// Foreground app name (e.g. "Mail", "Slack", "Xcode"), or "".
    static func foregroundApp() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
    }

    /// Text replacements from Settings ("shortcut=expansion", comma/newline
    /// separated). Applied to the final transcript before paste — the Wispr /
    /// SuperWhisper table-stakes feature ("addr" → full address). Whole-word,
    /// case-insensitive; replacement text is inserted verbatim.
    static func applyReplacements(_ text: String, spec: String? = nil) -> String {
        let raw = spec ?? UserDefaults.standard.string(forKey: "dictationReplacements") ?? ""
        guard !raw.isEmpty else { return text }
        var result = text
        for pair in raw.split(whereSeparator: { $0 == "," || $0 == "\n" }) {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let key = pair[..<eq].trimmingCharacters(in: .whitespaces)
            let value = String(pair[pair.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: key))\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: value)
            )
        }
        return result
    }

    /// Custom words from Settings, comma/newline separated.
    private static func customWords() -> [String] {
        (UserDefaults.standard.string(forKey: "dictationCustomWords") ?? "")
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Contact name tokens — cached. Returns [] unless Contacts is already
    /// authorized (we never trigger a permission prompt for dictation).
    private static func contactNames() -> [String] {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return [] }

        lock.lock()
        let fresh = Date().timeIntervalSince(cachedAt) < cacheTTL && !cachedContactNames.isEmpty
        let cached = cachedContactNames
        lock.unlock()
        if fresh { return cached }

        var names: [String] = []
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        do {
            try CNContactStore().enumerateContacts(with: request) { contact, _ in
                for token in [contact.givenName, contact.familyName, contact.organizationName] {
                    let t = token.trimmingCharacters(in: .whitespaces)
                    if t.count > 1 { names.append(t) }
                }
            }
        } catch {
            return cached // keep whatever we had on failure
        }

        let deduped = Array(Set(names)).sorted()
        lock.lock()
        cachedContactNames = deduped
        cachedAt = Date()
        lock.unlock()
        return deduped
    }

    /// Resolved options for the STT upload: master toggle, merged vocabulary,
    /// and foreground-app context. `enabled` defaults on (opt-out).
    static func options() -> (enabled: Bool, vocabulary: String, appContext: String) {
        let enabled = UserDefaults.standard.object(forKey: "dictationFormatEnabled") as? Bool ?? false
        guard enabled else { return (false, "", "") }

        // Priority order: custom words → contacts. Dedup case-insensitively.
        var seen = Set<String>()
        var merged: [String] = []
        for term in customWords() + contactNames() {
            let key = term.lowercased()
            if seen.insert(key).inserted { merged.append(term) }
            if merged.count >= maxTerms { break }
        }

        return (true, merged.joined(separator: ", "), foregroundApp())
    }
}
