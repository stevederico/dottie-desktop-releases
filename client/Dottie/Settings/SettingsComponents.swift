//
//  SettingsComponents.swift
//  Dottie
//
//  Reusable building blocks used by SettingsView: SettingsSection card,
//  SettingsRow item, ServerStatusIndicator dot, and the search-text
//  environment key that lets rows highlight against the search field.
//

import SwiftUI
import AppKit

/// Reusable container that renders a titled card with a rounded border, used to group related settings rows.
struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content
    let statusIndicator: ServerStatusIndicator?

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
        self.statusIndicator = nil
    }

    init(title: String, statusIndicator: ServerStatusIndicator, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
        self.statusIndicator = statusIndicator
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !title.isEmpty {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .textSelection(.enabled)

                    if let statusIndicator = statusIndicator {
                        Circle()
                            .fill(statusIndicator.color)
                            .frame(width: 8, height: 8)
                    }
                }
            }

            VStack(spacing: 0) {
                content
            }
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
        }
    }
}

/// Maps server/agent/store statuses to a colored dot indicator for the connections UI.
enum ServerStatusIndicator {
    case running
    case stopped
    case error
    case starting

    var color: Color {
        switch self {
        case .running:
            return .green
        case .stopped:
            return .red
        case .error:
            return .orange
        case .starting:
            return .yellow
        }
    }

    /// Maps an AgentStatus to a ServerStatusIndicator for consistent color rendering.
    static func from(_ agentStatus: AgentStatus) -> ServerStatusIndicator {
        switch agentStatus {
        case .running:
            return .running
        case .starting, .stopping:
            return .starting
        case .stopped:
            return .stopped
        case .error:
            return .error
        }
    }
}

/// A single settings row with an optional icon, title, description, and trailing content slot.
struct SettingsRow<Content: View>: View {
    let title: String
    let description: String
    let content: Content
    let isClickableURL: Bool
    let icon: String?
    let iconColor: Color?
    @Environment(\.settingsSearchText) private var searchText

    init(title: String, description: String, isClickableURL: Bool = false, icon: String? = nil, iconColor: Color? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.description = description
        self.isClickableURL = isClickableURL
        self.icon = icon
        self.iconColor = iconColor
        self.content = content()
    }

    /// Whether this row matches the current search query.
    private var isMatch: Bool {
        let query = searchText.lowercased()
        guard !query.isEmpty else { return false }
        return title.lowercased().contains(query) || description.lowercased().contains(query)
    }

    /// Highlights matching substring in text with accent background.
    private func highlighted(_ text: String, font: Font, color: Color) -> Text {
        let query = searchText.lowercased()
        guard !query.isEmpty, let range = text.lowercased().range(of: query) else {
            return Text(text).font(font).foregroundColor(color)
        }
        let before = String(text[text.startIndex..<range.lowerBound])
        let match = String(text[range])
        let after = String(text[range.upperBound...])
        return Text(before).font(font).foregroundColor(color)
            + Text(match).font(font).foregroundColor(.white).bold()
            + Text(after).font(font).foregroundColor(color)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(iconColor ?? .accentColor)
                    .frame(width: 20)
                    .symbolRenderingMode(.monochrome)
            }

            if description.isEmpty {
                highlighted(title, font: .headline, color: .primary)
                    .textSelection(.enabled)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    highlighted(title, font: .headline, color: .primary)
                        .textSelection(.enabled)

                    if isClickableURL && !description.isEmpty {
                        Button(description) {
                            if let url = URL(string: description) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundColor(.blue)
                        .underline()
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        highlighted(description, font: .caption, color: .secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
            }

            Spacer()

            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(isMatch ? Color.accentColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
        .id("settings-row-\(title)")
    }
}

// MARK: - Search Text Environment Key

private struct SettingsSearchTextKey: EnvironmentKey {
    static let defaultValue: String = ""
}

extension EnvironmentValues {
    var settingsSearchText: String {
        get { self[SettingsSearchTextKey.self] }
        set { self[SettingsSearchTextKey.self] = newValue }
    }
}
