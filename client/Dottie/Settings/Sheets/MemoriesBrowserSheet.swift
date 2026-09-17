import SwiftUI

struct MemoriesBrowserSheet: View {
    @Binding var isPresented: Bool
    @Binding var memories: [GatewayClient.Memory]
    @Binding var isLoading: Bool

    @State private var selectedKey: String? = nil
    @State private var searchQuery: String = ""
    @State private var toDelete: String? = nil
    @State private var isEditing: Bool = false
    @State private var editingKey: String = ""
    @State private var editingValue: String = ""
    @State private var editingOriginalKey: String? = nil

    private var filtered: [GatewayClient.Memory] {
        if searchQuery.isEmpty { return memories }
        let query = searchQuery.lowercased()
        return memories.filter {
            $0.key.lowercased().contains(query) ||
            $0.displayValue.lowercased().contains(query)
        }
    }

    var body: some View {
        ResourceBrowserSheet(
            isPresented: $isPresented,
            items: $memories,
            isLoading: $isLoading,
            selection: $selectedKey,
            title: "AI Memories",
            emptyIcon: "brain",
            countLabel: { "\($0) memories" },
            emptyText: searchQuery.isEmpty ? "No memories" : "No matches",
            emptyHint: nil,
            createHelp: "Create new memory",
            width: 700,
            height: 500,
            toDelete: $toDelete,
            deleteTitle: "Delete Memory",
            deleteMessage: "Delete \"\(toDelete ?? "")\"? This cannot be undone.",
            onConfirmDelete: { key in
                deleteMemory(key: key)
            },
            onCreate: { startCreating() },
            onRefresh: { load() },
            onAppearLoad: { load() },
            displayedItems: filtered,
            tag: { $0.key },
            toolbar: {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search memories...", text: $searchQuery)
                        .textFieldStyle(.plain)
                    if !searchQuery.isEmpty {
                        Button(action: { searchQuery = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                .padding(.horizontal)
                .padding(.bottom, 8)
            },
            row: { memory in
                VStack(alignment: .leading, spacing: 2) {
                    Text(memory.key)
                        .font(.system(.body, design: .default))
                        .lineLimit(1)
                    if let date = memory.updatedAt {
                        Text(formatDate(date))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 2)
            },
            rightPane: { rightPane }
        )
    }

    @ViewBuilder
    private var rightPane: some View {
        if let key = selectedKey, let memory = memories.first(where: { $0.key == key }) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(memory.key)
                        .font(.headline)
                    if let date = memory.updatedAt {
                        Text("Updated: \(formatDate(date))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Button(action: { startEditing(memory) }) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.bordered)
                .help("Edit memory")
                Button(action: { toDelete = memory.key }) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .help("Delete memory")
            }
            .padding()

            Divider()

            ScrollView {
                Text(memory.displayValue)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        } else if isEditing {
            VStack(spacing: 0) {
                HStack {
                    Text(editingOriginalKey == nil ? "New Memory" : "Edit Memory")
                        .font(.headline)
                    Spacer()
                    Button("Cancel") { cancelEditing() }
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(editingKey.isEmpty || editingValue.isEmpty)
                }
                .padding()
                Divider()
                Form {
                    TextField("Key", text: $editingKey)
                        .disabled(editingOriginalKey != nil)
                    TextEditor(text: $editingValue)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 200)
                }
                .padding()
            }
        } else {
            ResourceBrowserPlaceholder(icon: "brain", text: "Select a memory to view")
        }
    }

    private func startCreating() {
        editingKey = ""
        editingValue = ""
        editingOriginalKey = nil
        isEditing = true
        selectedKey = nil
    }

    private func startEditing(_ memory: GatewayClient.Memory) {
        editingKey = memory.key
        editingValue = memory.displayValue
        editingOriginalKey = memory.key
        isEditing = true
        selectedKey = nil
    }

    private func cancelEditing() {
        isEditing = false
        editingKey = ""
        editingValue = ""
        editingOriginalKey = nil
    }

    private func save() {
        let key = editingKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = editingValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !value.isEmpty else { return }

        if let originalKey = editingOriginalKey {
            GatewayClient.shared.updateMemory(key: originalKey, value: value) { success in
                if success { load() }
                cancelEditing()
            }
        } else {
            GatewayClient.shared.createMemory(key: key, value: value) { success in
                if success { load() }
                cancelEditing()
            }
        }
    }

    private func deleteMemory(key: String) {
        GatewayClient.shared.deleteMemory(key: key) { success in
            if success {
                memories.removeAll { $0.key == key }
                if selectedKey == key {
                    selectedKey = memories.first?.key
                }
            }
            toDelete = nil
        }
    }

    private func load() {
        isLoading = true
        GatewayClient.shared.fetchMemories { result in
            isLoading = false
            switch result {
            case .success(let mems):
                memories = mems
                if selectedKey == nil, let first = mems.first {
                    selectedKey = first.key
                }
            case .failure(let error):
                AppLogger.shared.warn("Failed to load memories: \(error)")
            }
        }
    }

    private func formatDate(_ isoDate: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoDate) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .medium
            displayFormatter.timeStyle = .short
            return displayFormatter.string(from: date)
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: isoDate) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .medium
            displayFormatter.timeStyle = .short
            return displayFormatter.string(from: date)
        }
        return isoDate
    }
}
