import SwiftUI

struct TasksBrowserSheet: View {
    @Binding var isPresented: Bool
    @Binding var tasks: [GatewayClient.AgentTask]
    @Binding var isLoading: Bool

    @State private var selectedId: String? = nil
    @State private var toDelete: String? = nil
    @State private var isEditing: Bool = false
    @State private var editingId: String? = nil
    @State private var editingDescription: String = ""
    @State private var editingCategory: String = "general"
    @State private var editingPriority: String = "medium"
    @State private var editingMode: String = "manual"

    var body: some View {
        ResourceBrowserSheet(
            isPresented: $isPresented,
            items: $tasks,
            isLoading: $isLoading,
            selection: $selectedId,
            title: "Tasks",
            emptyIcon: "target",
            countLabel: { "\($0) task\($0 == 1 ? "" : "s")" },
            emptyText: "No tasks",
            emptyHint: "Click + to create one",
            createHelp: "Create new task",
            width: 650,
            height: 450,
            toDelete: $toDelete,
            deleteTitle: "Delete Task",
            deleteMessage: "Are you sure you want to delete this task?",
            onConfirmDelete: { id in
                deleteTask(id)
                if selectedId == id { selectedId = nil }
                toDelete = nil
            },
            onCreate: { startCreating() },
            onRefresh: { load() },
            onAppearLoad: {
                load()
                if selectedId == nil, let first = tasks.first {
                    selectedId = first.id
                }
            },
            tag: { $0.id },
            row: { task in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(task.description)
                            .font(.system(.body, design: .default))
                            .lineLimit(1)
                        Spacer()
                        Circle()
                            .fill(task.status == "active" ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                    }
                    Text("\(task.progress)% • \(task.category)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 2)
            },
            rightPane: { rightPane }
        )
    }

    @ViewBuilder
    private var rightPane: some View {
        if isEditing {
            editForm
        } else if let taskId = selectedId, let task = tasks.first(where: { $0.id == taskId }) {
            detailView(for: task)
        } else {
            ResourceBrowserPlaceholder(icon: "target", text: "Select a task to view")
        }
    }

    @ViewBuilder
    private func detailView(for task: GatewayClient.AgentTask) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.description)
                            .font(.title2)
                            .fontWeight(.semibold)
                        HStack(spacing: 8) {
                            Text(task.category)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(4)
                            Text(task.status.capitalized)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(task.status == "active" ? Color.green.opacity(0.2) : Color.gray.opacity(0.2))
                                .cornerRadius(4)
                        }
                    }
                    Spacer()
                    Button(action: { startEditing(task) }) {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.bordered)
                    .help("Edit task")
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Progress")
                        .font(.headline)
                    ProgressView(value: Double(task.progress) / 100.0)
                        .progressViewStyle(.linear)
                    Text("\(task.progress)% complete")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let steps = task.steps, !steps.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Steps")
                            .font(.headline)
                        ForEach(steps, id: \.text) { step in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: step.isDone ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(step.isDone ? .green : .secondary)
                                Text(step.text)
                                    .font(.body)
                                    .foregroundColor(step.isDone ? .secondary : .primary)
                            }
                        }
                    }
                }

                Spacer()

                HStack {
                    Button(role: .destructive) {
                        toDelete = task.id
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private var editForm: some View {
        VStack(spacing: 0) {
            HStack {
                Text(editingId == nil ? "New Task" : "Edit Task")
                    .font(.headline)
                Spacer()
                Button("Cancel") { cancelEditing() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(editingDescription.isEmpty)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Description")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        TextField("Task description", text: $editingDescription)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Category")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Picker("", selection: $editingCategory) {
                            Text("General").tag("general")
                            Text("Work").tag("work")
                            Text("Personal").tag("personal")
                            Text("Fitness").tag("fitness")
                            Text("Learning").tag("learning")
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Priority")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Picker("", selection: $editingPriority) {
                            Text("Low").tag("low")
                            Text("Medium").tag("medium")
                            Text("High").tag("high")
                        }
                        .pickerStyle(.segmented)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mode")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Picker("", selection: $editingMode) {
                            Text("Manual").tag("manual")
                            Text("Auto").tag("auto")
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        }
    }

    private func startCreating() {
        editingId = nil
        editingDescription = ""
        editingCategory = "general"
        editingPriority = "medium"
        editingMode = "manual"
        isEditing = true
    }

    private func startEditing(_ task: GatewayClient.AgentTask) {
        editingId = task.id
        editingDescription = task.description
        editingCategory = task.category
        editingPriority = task.priority
        editingMode = task.mode
        isEditing = true
    }

    private func cancelEditing() {
        isEditing = false
        editingId = nil
    }

    private func save() {
        if let taskId = editingId {
            let updates: [String: Any] = [
                "description": editingDescription,
                "category": editingCategory,
                "priority": editingPriority,
                "mode": editingMode
            ]
            GatewayClient.shared.updateTask(id: taskId, updates: updates) { success in
                if success { load() }
                cancelEditing()
            }
        } else {
            let input = GatewayClient.TaskInput(
                description: editingDescription,
                steps: nil,
                category: editingCategory,
                priority: editingPriority,
                deadline: nil,
                mode: editingMode
            )
            GatewayClient.shared.createTask(input) { success in
                if success { load() }
                cancelEditing()
            }
        }
    }

    private func deleteTask(_ id: String) {
        GatewayClient.shared.deleteTask(id: id) { success in
            if success { load() }
        }
    }

    private func load() {
        isLoading = true
        GatewayClient.shared.fetchTasks { result in
            isLoading = false
            if case .success(let fetched) = result {
                tasks = fetched
            }
        }
    }
}
