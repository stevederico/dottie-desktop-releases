//
//  AccessibilityPermissionManager.swift
//  Dottie
//
//  Manages Accessibility permission for text cursor tracking during voice recording.
//

import Foundation
import ApplicationServices
import SwiftUI

/// Manages macOS Accessibility permission state for text cursor tracking during voice dictation.
/// Accessibility cannot be requested programmatically -- the user must grant it manually via System Preferences.
class AccessibilityPermissionManager: ObservableObject {
    static let shared = AccessibilityPermissionManager()

    @Published var accessibilityPermissionGranted = false

    /// Lock-free snapshot of the most recent `AXIsProcessTrusted()` result.
    /// Refreshed every 2s by a background timer so AX middleware can check permission
    /// in O(1) without paying for a syscall on every request.
    private(set) var isTrusted: Bool = false

    private var pollTimer: Timer?

    private init() {
        refresh()
        startPolling()
    }

    private func startPolling() {
        // Ensure the timer lives on the main RunLoop so it fires reliably even when the
        // singleton is first touched from a background queue (e.g. MacUseService's work queue).
        let schedule = { [weak self] in
            guard let self = self else { return }
            let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.refresh()
            }
            self.pollTimer = timer
        }
        if Thread.isMainThread {
            schedule()
        } else {
            DispatchQueue.main.async(execute: schedule)
        }
    }

    private var lastReportedTrusted: Bool?

    private func refresh() {
        let trusted = AXIsProcessTrusted()
        let previous = lastReportedTrusted
        isTrusted = trusted
        // Edge-trigger only on false→true (granted) or true→false (revoked).
        // First poll has previous=nil; skip — grant vs pre-existing unknown.
        if let p = previous, p != trusted {
        }
        lastReportedTrusted = trusted
        if Thread.isMainThread {
            accessibilityPermissionGranted = trusted
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.accessibilityPermissionGranted = trusted
            }
        }
    }

    /// Opens System Preferences to the Privacy > Accessibility pane.
    func openSystemPreferences() {
        guard let prefpaneURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            AppLogger.error("AccessibilityPermissionManager: invalid System Preferences URL")
            return
        }
        NSWorkspace.shared.open(prefpaneURL)
    }

    /// Queries `AXIsProcessTrusted`, updates cached state, and returns the result.
    /// Prefer the cached `isTrusted` property for hot paths; this method is for code that
    /// needs an authoritative read right now (e.g. settings UI refresh on appear).
    @discardableResult
    func checkPermission() -> Bool {
        refresh()
        return isTrusted
    }
}
