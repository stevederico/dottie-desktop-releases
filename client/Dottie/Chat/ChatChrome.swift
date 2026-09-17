//
//  ChatChrome.swift
//  Dottie
//
//  Created by Steve Derico on 6/29/25.
//

import SwiftUI
import AppKit

// MARK: - Thinking Content Badge View

/// Live "Thinking..." counter — hides until 1s elapsed, then ticks in whole
/// seconds (`1s`, `2s`, `3s`). Returns empty string for sub-second so the UI
/// just reads "Thinking..." with no number.
func formatThinkingDuration(_ ms: Int) -> String {
    guard ms >= 1000 else { return "" }
    return "\(ms / 1000)s"
}

/// Final "Thought for X" label — millisecond precision. `843ms` for sub-second,
/// `1.4s` for 1–10s, `12s` for 10s+.
func formatThoughtDuration(_ ms: Int) -> String {
    if ms < 1000 { return "\(ms)ms" }
    let seconds = Double(ms) / 1000.0
    if seconds < 10 {
        let tenths = (seconds * 10).rounded()
        if tenths.truncatingRemainder(dividingBy: 10) == 0 {
            return "\(Int(tenths / 10))s"
        }
        return String(format: "%.1fs", tenths / 10)
    }
    return "\(Int(seconds))s"
}

/// Unified thinking status + expandable reasoning content.
/// Shows pulsing dots + "Thinking... 843ms" while active, checkmark + "Thought for 1.4s" when done.
/// Clicking toggles expanded view with auto-scrolling content and blinking cursor.
struct ThinkingContentBadgeView: View {
    let content: String
    @Binding var isExpanded: Bool
    let isThinkingActive: Bool
    /// Duration in milliseconds. Display layer formats via formatThinkingDuration().
    let displayDurationMs: Int
    let isLoading: Bool
    @Environment(\.colorScheme) private var colorScheme
    private var colors: ChatColorTheme { ChatColors.theme(for: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { isExpanded.toggle() }) {
                HStack(spacing: 8) {
                    if isLoading {
                        PulsingDots()
                    } else {
                        Image(systemName: "lightbulb")
                            .font(.system(size: 14))
                            .foregroundColor(colors.dimText.opacity(0.6))
                    }

                    if isLoading {
                        let liveSuffix = formatThinkingDuration(displayDurationMs)
                        Text(liveSuffix.isEmpty ? "Thinking..." : "Thinking... \(liveSuffix)")
                            .font(.system(size: 14))
                    } else {
                        Text("Thought for \(formatThoughtDuration(displayDurationMs))")
                            .font(.system(size: 14))
                    }

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                }
                .foregroundColor(colors.dimText)
            }
            .buttonStyle(.plain)

            if isExpanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(content)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(colors.dimText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if isThinkingActive {
                                ThinkingCursor()
                                    .padding(.top, 2)
                            }

                            Color.clear
                                .frame(height: 1)
                                .id("thinkingBottom")
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 400)
                    .background((colorScheme == .dark ? Color.white : Color.black).opacity(0.05))
                    .cornerRadius(4)
                    .padding(.top, 4)
                    .onChange(of: content) { _, _ in
                        if isThinkingActive {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo("thinkingBottom", anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Error Line Detection

/// Shared utility for detecting error/failure indicators in text lines.
/// Used by `ToolResultText` to highlight failure lines.
struct ErrorLineDetector {
    /// Returns `true` if the line contains error or failure indicators.
    /// Checks prefix patterns (error:, failed:) and substring patterns
    /// (stderr:, exit code 1, permission denied, err_).
    static func isErrorLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        // `hasPrefix("error:")` is subsumed by the `contains("error:")` clause
        // below, so it's omitted. The space-variant prefixes are NOT subsumed
        // (no matching `contains`), so they stay.
        return lower.hasPrefix("error ") ||
               lower.hasPrefix("failed:") ||
               lower.hasPrefix("failed ") ||
               lower.contains("failed to") ||
               lower.contains("error:") ||
               lower.contains("stderr:") ||
               lower.contains("exit code 1") ||
               lower.contains("permission denied") ||
               lower.contains("err_")
    }
}

// MARK: - Tool Result Text View

/// Renders tool result text with error lines highlighted in red.
struct ToolResultText: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme
    private var colors: ChatColorTheme { ChatColors.theme(for: colorScheme) }

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .foregroundColor(ErrorLineDetector.isErrorLine(line) ? colors.errorRedText : colors.dimText)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - Tool Call Badge View

/// Individual rounded pill badge for a tool call (DottieOS style).
/// Auto-expands on error, result text is selectable and scrollable.
/// Shows inline "Grant Permission" button when tool fails due to permission denial.
struct ToolCallBadgeView: View {
    let toolCall: ToolCall
    @State private var isExpanded: Bool
    @State private var permissionGranted: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    private var colors: ChatColorTheme { ChatColors.theme(for: colorScheme) }

    init(toolCall: ToolCall) {
        self.toolCall = toolCall
        // Auto-expand on error for immediate visibility
        _isExpanded = State(initialValue: toolCall.status == .error)
    }

    private var statusColor: Color {
        switch toolCall.status {
        case .running: return colors.runningBlue
        case .completed: return colors.doneGray
        case .error: return colors.errorRed
        }
    }

    private var textColor: Color {
        colors.dimText
    }

    /// Parses permission scope from PERMISSION_REQUIRED error result if present.
    /// Returns tuple of (scope, humanReadableDescription) or nil if not a permission error.
    private func parsePermissionScope(_ result: String?) -> (scope: String, description: String)? {
        guard let result = result else { return nil }
        // Check for PERMISSION_REQUIRED:scope:description format
        if result.hasPrefix("PERMISSION_REQUIRED:") {
            let parts = result.dropFirst("PERMISSION_REQUIRED:".count).split(separator: ":", maxSplits: 1)
            if parts.count >= 1 {
                let scope = String(parts[0])
                let description = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : formatScopeAsTitle(scope)
                return (scope, description)
            }
        }
        return nil
    }

    /// Converts a scope like "calendar.read" to "Calendar Read".
    private func formatScopeAsTitle(_ scope: String) -> String {
        return scope
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { isExpanded.toggle() }) {
                HStack(spacing: 6) {
                    // Spinner while running, ✗ on error, nothing once completed.
                    if toolCall.status == .running {
                        SpinningIcon(systemName: "arrow.trianglehead.2.clockwise")
                    } else if toolCall.status == .error {
                        Image(systemName: "xmark")
                            .font(.system(size: 10))
                    }

                    // Camera glyph so a screen-capture tool is obvious at a glance —
                    // the user needs to know when Dottie looked at their screen.
                    if capturesScreen {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 10))
                    }

                    Text(toolDisplayName)
                        .font(.system(size: 12, weight: .medium))
                        .textCase(.lowercase)

                    if let summary = formatInputSummary(toolCall.input) {
                        Text(summary)
                            .font(.system(size: 11))
                            .opacity(0.6)
                            .lineLimit(1)
                    }
                }
                .foregroundColor(textColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                // Opaque base UNDER the status tint. statusColor is translucent
                // (e.g. doneGray = white.opacity(0.05)); on the launcher's
                // behind-window blur the desktop bled through and the pill color
                // shifted with whatever was behind it. The solid base fixes the color.
                .background(
                    Capsule()
                        .fill(colors.chatBackground)
                        .overlay(Capsule().fill(statusColor))
                )
            }
            .buttonStyle(.plain)

            // Confirmation dialog when a destructive tool returns `_ui`.
            if toolCall.status == .completed,
               let result = toolCall.result,
               result.hasPrefix("{\"_ui\":") {
                ToolConfirmCard(toolCall: toolCall)
                    .environment(\.chatColorTheme, colors)
                    .padding(.top, 8)
            }

            // Expanded details - scrollable and selectable
            if isExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if let input = toolCall.input, !input.isEmpty {
                            ForEach(Array(input.keys.sorted()), id: \.self) { key in
                                Text("\(key): \(String(describing: input[key]?.value ?? ""))")
                                    .textSelection(.enabled)
                            }
                        }
                        if let result = toolCall.result {
                            ToolResultText(text: result)
                                .textSelection(.enabled)

                            // Inline permission grant button
                            if let permission = parsePermissionScope(result) {
                                if permissionGranted {
                                    HStack(spacing: 6) {
                                        Image(systemName: "checkmark.circle.fill")
                                        Text("\(permission.description) Granted")
                                    }
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.green)
                                    .padding(.top, 8)
                                } else {
                                    Button(action: {
                                        UserDefaults.standard.set(true, forKey: "permission.\(permission.scope)")
                                        permissionGranted = true
                                    }) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "checkmark.shield")
                                            Text("Grant \(permission.description)")
                                        }
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(Capsule().fill(Color.green))
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.top, 8)
                                }
                            }
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .padding(8)
                .background((colorScheme == .dark ? Color.white : Color.black).opacity(0.05))
                .cornerRadius(4)
                .padding(.top, 4)
            }
        }
    }

    /// Extracts a short summary from tool input for display in badge.
    private func formatInputSummary(_ input: [String: AnyCodable]?) -> String? {
        guard let input = input else { return nil }
        let key = input["query"]?.value ?? input["url"]?.value ??
                  input["path"]?.value ?? input["name"]?.value
        guard let str = key as? String else { return nil }
        return str.count > 40 ? String(str.prefix(40)) + "..." : str
    }

    /// Pill label. For web tools, show the website DOMAIN being used (e.g.
    /// "wikipedia.org") instead of the generic tool name ("web search") — more
    /// useful at a glance. Falls back to the de-underscored tool name.
    private var toolDisplayName: String {
        if let host = webDomainFromToolCall() { return host }
        return toolCall.name.replacingOccurrences(of: "_", with: " ")
    }

    /// True for tools that capture the screen or a photo, so the badge can flag
    /// that Dottie looked at the user's screen.
    private var capturesScreen: Bool {
        let n = toolCall.name.lowercased()
        return n.contains("screenshot") || n.contains("screen_capture")
            || n.contains("vision") || n.contains("camera") || n.contains("take_photo")
    }

    /// Extracts a domain from an explicit `url` input, or the first URL found in
    /// the tool result (web_search returns its sources in the result body).
    private func webDomainFromToolCall() -> String? {
        if let url = toolCall.input?["url"]?.value as? String, let h = host(from: url) {
            return h
        }
        if let result = toolCall.result, let h = firstHost(in: result) {
            return h
        }
        return nil
    }

    private func firstHost(in text: String) -> String? {
        guard let range = text.range(of: #"https?://[^\s"'<>)\]]+"#, options: .regularExpression) else { return nil }
        return host(from: String(text[range]))
    }

    private func host(from urlString: String) -> String? {
        guard let url = URL(string: urlString), var h = url.host else { return nil }
        if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
        return h
    }
}

/// Continuously spinning icon for loading states.
struct SpinningIcon: View {
    let systemName: String
    @State private var isSpinning = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 10))
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            }
    }
}

/// Animated pulsing dots for thinking indicator.
struct PulsingDots: View {
    @State private var animating = false
    @Environment(\.colorScheme) private var colorScheme
    private var colors: ChatColorTheme { ChatColors.theme(for: colorScheme) }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(colors.dimText)
                    .frame(width: 5, height: 5)
                    .scaleEffect(animating ? 1.0 : 0.5)
                    .opacity(animating ? 1.0 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.6)
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.2),
                        value: animating
                    )
            }
        }
        .onAppear {
            animating = true
        }
    }
}

/// Blinking purple cursor indicating thinking tokens are still arriving.
struct ThinkingCursor: View {
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.purple.opacity(visible ? 0.8 : 0.0))
            .frame(width: 7, height: 14)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    visible.toggle()
                }
            }
    }
}
