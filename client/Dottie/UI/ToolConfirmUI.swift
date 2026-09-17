//
//  ToolConfirmUI.swift
//  Dottie
//
//  In-chat `_ui` confirmation_dialog: parse envelope, render card, WS confirm/cancel.
//

import Foundation
import SwiftUI

// MARK: - Chat theme + card chrome

// MARK: - ChatColorTheme Environment Key

/// Environment key that provides the ChatColorTheme based on the current color scheme.
private struct ChatColorThemeKey: EnvironmentKey {
    static let defaultValue: ChatColorTheme = .light
}

extension EnvironmentValues {
    /// The resolved chat color theme for the current color scheme.
    var chatColorTheme: ChatColorTheme {
        get { self[ChatColorThemeKey.self] }
        set { self[ChatColorThemeKey.self] = newValue }
    }
}

// MARK: - Card Background Modifier

/// Standard card background: 12pt padding with a rounded-rect fill.
struct ToolConfirmCardBackgroundModifier: ViewModifier {
    @Environment(\.chatColorTheme) private var colors

    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(colors.cardBackground))
    }
}

extension View {
    /// Applies the standard confirm-card background (12pt padding, rounded-rect fill).
    func toolConfirmCardBackground() -> some View {
        modifier(ToolConfirmCardBackgroundModifier())
    }
}

// MARK: - Action handler (WS ui.action)

/// Singleton that sends UI action callbacks to the agent service.
/// Interactive components (confirmation dialogs, buttons, forms) call this
/// to trigger tool execution or dismiss actions.
class ToolConfirmActionHandler: ObservableObject {
    /// Shared singleton instance.
    static let shared = ToolConfirmActionHandler()

    private init() {}

    /// Triggers an action callback to the agent service.
    /// Always routes over the realtime WebSocket — there is no HTTP fallback.
    /// - Parameters:
    ///   - componentId: Unique ID of the component instance (from `_ui.id`).
    ///   - actionId: ID of the action triggered (e.g. "confirm", "cancel").
    ///   - payload: Optional additional data (form values, selections).
    /// - Returns: Tool result string (may contain new `_ui` payload for chaining).
    /// - Throws: URLError if the request fails.
    @MainActor
    func triggerAction(componentId: String, actionId: String, payload: [String: Any]? = nil) async throws -> ToolConfirmActionResult {
        let cancelled = actionId == "cancel" || actionId == "dismiss"

        // Cancel/dismiss is resolved entirely client-side (the action never reaches the
        // tool loop), so its result is authoritative — fire-and-forget, return immediately.
        if cancelled {
            RealtimeClient.shared.sendUIAction(componentId: componentId, actionId: actionId, payload: payload)
            return ToolConfirmActionResult(success: true, result: nil, cancelled: true)
        }

        // Confirm-style action: send the ui.action and AWAIT the server's real outcome
        // (the tool re-call's tool.result on success, tool.error / llm_error on failure),
        // with a bounded timeout that resolves optimistically so the UI never hangs.
        // The agent loop pauses on a UI action, so the next server outcome is this action's.
        let outcome = await RealtimeClient.shared.sendUIActionAwaitingOutcome(
            componentId: componentId,
            actionId: actionId,
            payload: payload
        )
        return ToolConfirmActionResult(
            success: outcome.success,
            result: outcome.result,
            cancelled: false,
            error: outcome.success ? nil : (outcome.error ?? "Action failed")
        )
    }
}

/// Result of a UI action callback.
struct ToolConfirmActionResult {
    let success: Bool
    let result: String?
    let cancelled: Bool
    var error: String? = nil
}

// MARK: - Dialog card + buttons

/// Interactive confirmation dialog with customizable actions.
/// Used before destructive operations like delete, reset, clear.
struct ToolConfirmDialogCard: View {
    let data: ConfirmationDialogData
    let componentId: String
    let actions: [UIAction]

    @State private var result: ToolConfirmActionResult?
    @State private var dismissed: Bool = false
    @Environment(\.chatColorTheme) private var colors

    /// Error text for the failure render, falling back to a generic message when the
    /// server outcome carried no specifics.
    private var failureMessage: String {
        if let error = result?.error, !error.isEmpty { return error }
        return "Action failed"
    }

    private var successMessage: String {
        // A chained confirm re-call returns its own _ui envelope as the result
        // string; don't render raw {"_ui":...} JSON in the completion pill.
        if let r = result?.result, !r.isEmpty, !r.hasPrefix("{\"_ui\"") { return r }
        return "Done"
    }

    var body: some View {
        if dismissed {
            // Show completion state — three outcomes: failure (red xmark + error),
            // cancelled (muted xmark), success (green checkmark).
            HStack(spacing: 8) {
                if result?.cancelled == true {
                    // User cancelled/dismissed — never a failure, always muted.
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(colors.mutedText)
                        .accessibilityLabel("Cancelled")
                    Text("Cancelled")
                        .font(.system(size: 13))
                        .foregroundColor(colors.mutedText)
                } else if result?.success == false {
                    // Server-side tool re-call failed — red xmark + the error text.
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                        .accessibilityLabel("Failed")
                    Text(failureMessage)
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .accessibilityLabel("Success")
                    Text(successMessage)
                        .font(.system(size: 13))
                        .foregroundColor(colors.mutedText)
                }
            }
            .toolConfirmCardBackground()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                // Header with icon
                HStack(spacing: 10) {
                    Image(systemName: data.destructive == true ? "exclamationmark.triangle.fill" : "questionmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(data.destructive == true ? .orange : .blue)
                        .accessibilityLabel(data.destructive == true ? "Warning" : "Question")

                    VStack(alignment: .leading, spacing: 2) {
                        Text(data.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(colors.primaryText)

                        Text(data.message)
                            .font(.system(size: 13))
                            .foregroundColor(colors.mutedText)
                    }
                }
                .accessibilityElement(children: .combine)

                // Action buttons
                HStack(spacing: 8) {
                    ForEach(actions) { action in
                        ToolConfirmActionButton(
                            action: action,
                            componentId: componentId,
                            isDestructive: data.destructive == true && action.style == "destructive"
                        ) { actionResult in
                            result = actionResult
                            withAnimation(.easeInOut(duration: 0.2)) {
                                dismissed = true
                            }
                        }
                    }
                }
            }
            .toolConfirmCardBackground()
        }
    }
}

/// Single action button that triggers a UI action callback.
struct ToolConfirmActionButton: View {
    let action: UIAction
    let componentId: String
    let isDestructive: Bool
    let onComplete: (ToolConfirmActionResult) -> Void

    @StateObject private var actionHandler = ToolConfirmActionHandler.shared
    @State private var isLoading: Bool = false
    @Environment(\.chatColorTheme) private var colors

    private var buttonStyle: some View {
        Group {
            if action.style == "destructive" || isDestructive {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.red.opacity(0.15))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.3), lineWidth: 1))
            } else if action.style == "primary" {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.15))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.3), lineWidth: 1))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(colors.cardBackground)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(colors.mutedText.opacity(0.3), lineWidth: 1))
            }
        }
    }

    private var textColor: Color {
        if action.style == "destructive" || isDestructive {
            return .red
        } else if action.style == "primary" {
            return .blue
        } else {
            return colors.primaryText
        }
    }

    var body: some View {
        Button {
            Task {
                isLoading = true
                defer { isLoading = false }

                do {
                    let result = try await actionHandler.triggerAction(
                        componentId: componentId,
                        actionId: action.id
                    )
                    onComplete(result)
                } catch {
                    onComplete(ToolConfirmActionResult(success: false, result: nil, cancelled: false, error: error.localizedDescription))
                }
            }
        } label: {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                }
                Text(action.label)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(textColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(buttonStyle)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}

// MARK: - Envelope router

/// Parses a tool result `_ui` envelope and shows a confirmation dialog when present.
struct ToolConfirmCard: View {
    let toolCall: ToolCall
    @Environment(\.chatColorTheme) private var colors

    var body: some View {
        if let result = toolCall.result,
           result.hasPrefix("{\"_ui\":"),
           let data = result.data(using: .utf8),
           let envelope = try? JSONDecoder().decode(ToolResultEnvelope.self, from: data),
           let payload = envelope.ui {
            if payload.component == "confirmation_dialog",
               let dataJSON = try? JSONEncoder().encode(payload.data),
               let confirmData = try? JSONDecoder().decode(ConfirmationDialogData.self, from: dataJSON) {
                ToolConfirmDialogCard(
                    data: confirmData,
                    componentId: payload.id ?? toolCall.id,
                    actions: payload.actions ?? []
                )
            } else {
                Text(payload.fallback)
                    .font(.system(size: 13))
                    .foregroundColor(colors.mutedText)
            }
        }
    }
}
