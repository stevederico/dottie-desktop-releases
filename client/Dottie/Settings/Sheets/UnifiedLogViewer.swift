//
//  UnifiedLogViewer.swift
//  Dottie
//

import SwiftUI
import AppKit

/// One unified, filterable log stream across App, Agent, Talk, and MacUse —
/// replaces the old five-tab switcher. Every line is tagged with a
/// colored source chip and color-coded by level; filter chips and a search box
/// narrow the stream in place. App + Agent (our own logs) are shown by default;
/// the noisy child-process logs are opt-in.
struct UnifiedLogViewerView: View {
    @StateObject private var reader = MultiLogReader()
    @State private var enabled: Set<LogSource> = [.app, .agent]
    @State private var query: String = ""
    @State private var errorsOnly: Bool = false
    @Environment(\.dismiss) var dismiss

    /// The merged stream after source / level / search filtering.
    private var visible: [LogLine] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return reader.lines.filter { line in
            guard enabled.contains(line.source) else { return false }
            if errorsOnly, line.level != .error, line.level != .warn { return false }
            if !q.isEmpty, !line.text.lowercased().contains(q) { return false }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            controls
            Divider()
            content
        }
        .frame(width: 820, height: 600)
        .onAppear { reader.start() }
        .onDisappear { reader.stop() }
    }

    private var header: some View {
        HStack {
            Text("Logs")
                .font(.headline)
            Spacer()
            Button("Clear") { reader.clearAll() }
                .buttonStyle(.bordered)
            Button("Copy") { reader.copy(visible) }
                .buttonStyle(.bordered)
            Button("Close") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var controls: some View {
        VStack(spacing: 8) {
            // Source filter chips
            HStack(spacing: 6) {
                ForEach(LogSource.allCases) { source in
                    chip(
                        label: source.rawValue,
                        color: source.color,
                        on: enabled.contains(source)
                    ) {
                        if enabled.contains(source) { enabled.remove(source) }
                        else { enabled.insert(source) }
                    }
                }
                Spacer()
                Toggle("Errors only", isOn: $errorsOnly)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                Text("\(visible.count) lines")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if visible.isEmpty {
                        Text("No logs for this session")
                            .foregroundStyle(.secondary)
                            .font(.system(.caption, design: .monospaced))
                            .padding()
                    }
                    ForEach(visible) { line in
                        row(line)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .textSelection(.enabled)
            }
            .background(Color(NSColor.textBackgroundColor))
            .onChange(of: visible.count) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private func row(_ line: LogLine) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(line.source.rawValue)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(line.source.color)
                .frame(width: 38, alignment: .leading)
            Text(line.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(line.level?.color ?? .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A toggleable filter pill.
    private func chip(label: String, color: Color, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(on ? color.opacity(0.22) : Color.gray.opacity(0.12))
                .foregroundStyle(on ? color : .secondary)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(on ? color.opacity(0.5) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
