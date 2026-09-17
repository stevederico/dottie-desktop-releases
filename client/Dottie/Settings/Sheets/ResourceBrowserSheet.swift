import SwiftUI

/// Shared split-view chrome for the Settings resource browsers
/// (Tasks, Triggers, Scheduled Jobs, Memories).
///
/// Owns the common shell: header (title + create + Done), an optional toolbar
/// slot (e.g. the memories search field), the `HSplitView` with a left list
/// pane (count bar + refresh, loading / empty / list states) and a right pane,
/// the fixed frame, the delete confirmation alert, and the `onAppear` load.
///
/// Item-specific bits are supplied by the caller:
///   - `row`      — the list row for one item
///   - `rightPane`— the full right-hand pane (detail / edit form / placeholder),
///                  which the caller owns because its edit-vs-detail logic varies
///   - `toolbar`  — optional content rendered between the header and the divider
private struct IdentifiedItem<Value, ID: Hashable>: Identifiable {
    let id: ID
    let value: Value
}

struct ResourceBrowserSheet<Item, ID: Hashable, Row: View, RightPane: View, Toolbar: View>: View {
    @Binding var isPresented: Bool
    @Binding var items: [Item]
    @Binding var isLoading: Bool

    /// Selection identity shared with the caller (e.g. task id / memory key).
    @Binding var selection: ID?

    let title: String
    /// SF Symbol used for the empty-list and (default) placeholder states.
    let emptyIcon: String
    /// Caption shown in the left-pane count bar (e.g. "3 tasks").
    let countLabel: (Int) -> String
    /// Text shown when the (filtered) list is empty.
    let emptyText: String
    /// Optional secondary line under the empty text (e.g. "Click + to create one").
    let emptyHint: String?
    /// Help text for the create (+) button.
    let createHelp: String
    /// Sheet size.
    let width: CGFloat
    let height: CGFloat

    // Delete confirmation alert.
    @Binding var toDelete: ID?
    let deleteTitle: String
    let deleteMessage: String
    let onConfirmDelete: (ID) -> Void

    let onCreate: () -> Void
    let onRefresh: () -> Void
    let onAppearLoad: () -> Void

    /// The (already filtered) items to render in the list. Defaults to `items`;
    /// callers that filter (e.g. memories search) pass their filtered slice.
    let displayedItems: [Item]
    let tag: (Item) -> ID

    @ViewBuilder let toolbar: () -> Toolbar
    @ViewBuilder let row: (Item) -> Row
    @ViewBuilder let rightPane: () -> RightPane

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Button(action: onCreate) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .help(createHelp)
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.escape)
            }
            .padding()

            toolbar()

            Divider()

            HSplitView {
                VStack(spacing: 0) {
                    HStack {
                        Text(countLabel(displayedItems.count))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(action: onRefresh) {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Divider()

                    if isLoading {
                        Spacer()
                        ProgressView()
                        Spacer()
                    } else if displayedItems.isEmpty {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: emptyIcon)
                                .font(.largeTitle)
                                .foregroundColor(.secondary.opacity(0.5))
                            Text(emptyText)
                                .foregroundColor(.secondary)
                            if let emptyHint {
                                Text(emptyHint)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    } else {
                        List(selection: $selection) {
                            ForEach(displayedItems.map { IdentifiedItem(id: tag($0), value: $0) }) { entry in
                                row(entry.value)
                                    .tag(entry.id)
                            }
                        }
                        .listStyle(.sidebar)
                    }
                }
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)

                VStack(spacing: 0) {
                    rightPane()
                }
                .frame(minWidth: 300)
            }
        }
        .frame(width: width, height: height)
        .alert(deleteTitle, isPresented: Binding(
            get: { toDelete != nil },
            set: { if !$0 { toDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { toDelete = nil }
            Button("Delete", role: .destructive) {
                if let id = toDelete {
                    onConfirmDelete(id)
                }
            }
        } message: {
            Text(deleteMessage)
        }
        .onAppear(perform: onAppearLoad)
    }
}

/// Placeholder shown in the right pane when nothing is selected/being edited.
struct ResourceBrowserPlaceholder: View {
    let icon: String
    let text: String

    var body: some View {
        Spacer()
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundColor(.secondary.opacity(0.5))
            Text(text)
                .foregroundColor(.secondary)
        }
        Spacer()
    }
}

extension ResourceBrowserSheet where Toolbar == EmptyView {
    init(
        isPresented: Binding<Bool>,
        items: Binding<[Item]>,
        isLoading: Binding<Bool>,
        selection: Binding<ID?>,
        title: String,
        emptyIcon: String,
        countLabel: @escaping (Int) -> String,
        emptyText: String,
        emptyHint: String? = nil,
        createHelp: String,
        width: CGFloat,
        height: CGFloat,
        toDelete: Binding<ID?>,
        deleteTitle: String,
        deleteMessage: String,
        onConfirmDelete: @escaping (ID) -> Void,
        onCreate: @escaping () -> Void,
        onRefresh: @escaping () -> Void,
        onAppearLoad: @escaping () -> Void,
        displayedItems: [Item]? = nil,
        tag: @escaping (Item) -> ID,
        @ViewBuilder row: @escaping (Item) -> Row,
        @ViewBuilder rightPane: @escaping () -> RightPane
    ) {
        self.init(
            isPresented: isPresented,
            items: items,
            isLoading: isLoading,
            selection: selection,
            title: title,
            emptyIcon: emptyIcon,
            countLabel: countLabel,
            emptyText: emptyText,
            emptyHint: emptyHint,
            createHelp: createHelp,
            width: width,
            height: height,
            toDelete: toDelete,
            deleteTitle: deleteTitle,
            deleteMessage: deleteMessage,
            onConfirmDelete: onConfirmDelete,
            onCreate: onCreate,
            onRefresh: onRefresh,
            onAppearLoad: onAppearLoad,
            displayedItems: displayedItems ?? items.wrappedValue,
            tag: tag,
            toolbar: { EmptyView() },
            row: row,
            rightPane: rightPane
        )
    }
}
