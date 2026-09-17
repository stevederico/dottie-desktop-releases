//
//  UpdateAvailableView.swift
//  Dottie
//
//  The soft-update prompt: a real window (not just the launcher banner) that
//  announces a new release and drives the download → verify → install flow to
//  completion without the user having to open the launcher.
//

import SwiftUI
import AppKit

struct UpdateAvailableView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var updateChecker = UpdateChecker.shared
    let latestVersion: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Dottie \(latestVersion) Is Available")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .downloading(let progress) = updateChecker.updatePhase {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                    Text(updateChecker.statusMessage)
                        .font(.system(size: 11))
                        .foregroundColor(Color.primary.opacity(0.5))
                        .monospacedDigit()
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Spacer()
                UpdatePhaseControls(style: .window, onDismiss: onDismiss)
            }
        }
        .padding(32)
        .frame(width: 480, height: 240)
        .background(
            VisualEffectBlur(
                material: colorScheme == .dark ? .hudWindow : .popover,
                cornerRadius: 16
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var subtitle: String {
        switch updateChecker.updatePhase {
        case .extracting, .verifying, .installing:
            return updateChecker.statusMessage
        case .readyToInstall:
            return "Downloaded and verified. Dottie will restart to finish."
        case .error(let message):
            return message
        default:
            return "You are on \(DottieAPIClient.appVersion). The update downloads and installs itself, then restarts Dottie."
        }
    }
}

/// Owns the single prompt window. Keeps window plumbing out of UpdateChecker (which
/// stays a testable, UI-free state machine) and out of DottieApp.
@MainActor
enum UpdatePromptWindow {
    private static var window: NSWindow?

    /// Shows the prompt for `version` if the policy allows it.
    static func presentIfNeeded(version: String) {
        guard UpdatePrompt.shouldPrompt(latest: version, current: DottieAPIClient.appVersion) else { return }
        UpdatePrompt.recordPrompted(version)
        present(version: version)
    }

    /// Shows the prompt unconditionally (used by "Check For Updates…").
    static func present(version: String) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = KeyableBorderlessWindow.makeFloating(size: NSSize(width: 480, height: 240))
        window.title = "Update Available"
        let hosting = NSHostingController(
            rootView: UpdateAvailableView(latestVersion: version, onDismiss: { close() })
        )
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentViewController = hosting
        window.centerOnMainScreen()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    static func close() {
        window?.orderOut(nil)
        window = nil
    }
}
