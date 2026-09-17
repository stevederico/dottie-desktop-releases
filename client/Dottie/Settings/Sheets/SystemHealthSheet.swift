import SwiftUI
import AVFoundation
import Speech
import AppKit

/// One-tap System Health overview: a single panel that checks every moving part
/// of the local stack — supervised servers, OS permissions, and disk headroom —
/// so the user can answer "is everything OK?" without hunting through sections.
///
/// Live server/agent/realtime state comes from the shared `@ObservedObject`
/// singletons (already kept fresh by their own pollers); permissions and disk
/// are snapshotted on appear and re-snapshotted by the Re-check button.
struct SystemHealthSheet: View {
    @Binding var isPresented: Bool

    @ObservedObject private var gateway = GatewayClient.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var realtimeClient = RealtimeClient.shared
    @ObservedObject private var accessibility = AccessibilityPermissionManager.shared
    @State private var micGranted = false
    @State private var speechGranted = false
    @State private var diskFreeBytes: Int64 = 0

    /// A single health verdict. Colors follow DESIGN.md semantic tokens
    /// (success/warning/error); `.unknown` falls back to muted text.
    enum Health {
        case ok, warn, bad, unknown

        var color: Color {
            switch self {
            case .ok: return .green
            case .warn: return .yellow
            case .bad: return .red
            case .unknown: return .secondary
            }
        }

        var symbol: String {
            switch self {
            case .ok: return "checkmark.circle.fill"
            case .warn: return "exclamationmark.triangle.fill"
            case .bad: return "xmark.circle.fill"
            case .unknown: return "questionmark.circle"
            }
        }
    }

    // MARK: - Derived health

    private func health(for service: ServiceStatus?) -> Health {
        guard let service = service else { return .unknown }
        if service.isRunning { return .ok }
        if service.state == "starting" { return .warn }
        return .bad
    }

    private func health(for status: AgentStatus) -> Health {
        switch status {
        case .running: return .ok
        case .starting, .stopping: return .warn
        case .stopped, .error: return .bad
        }
    }

    private var serverHealths: [Health] {
        [
            health(for: gateway.services["talk"]),
            health(for: gateway.services["macuse"]),
            health(for: agentManager.status),
            realtimeClient.isConnected ? .ok : .bad,
        ]
    }

    private var permissionHealths: [Health] {
        [
            micGranted ? .ok : .warn,
            speechGranted ? .ok : .warn,
            accessibility.accessibilityPermissionGranted ? .ok : .warn,
        ]
    }

    private var diskHealth: Health {
        if diskFreeBytes == 0 { return .unknown }
        if diskFreeBytes < 2_000_000_000 { return .bad }      // < 2 GB
        if diskFreeBytes < 10_000_000_000 { return .warn }    // < 10 GB
        return .ok
    }

    /// Overall verdict across every checked item.
    private var allHealths: [Health] {
        serverHealths + permissionHealths + [diskHealth]
    }

    private var issueCount: Int { allHealths.filter { $0 == .bad }.count }
    private var attentionCount: Int { allHealths.filter { $0 == .warn }.count }

    private var overall: (Health, String) {
        if issueCount > 0 {
            return (.bad, "\(issueCount) issue\(issueCount == 1 ? "" : "s") need attention")
        }
        if attentionCount > 0 {
            return (.warn, "\(attentionCount) item\(attentionCount == 1 ? "" : "s") could be improved")
        }
        if allHealths.contains(.unknown) {
            return (.unknown, "Checking…")
        }
        return (.ok, "All systems healthy")
    }

    private func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    summaryCard
                    serversCard
                    permissionsCard
                    diskCard
                }
                .padding(20)
            }
        }
        .frame(width: 460, height: 560)
        .onAppear(perform: refresh)
    }

    private var header: some View {
        HStack {
            Text("System Health")
                .font(.headline)
            Spacer()
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .help("Re-check everything")
            Button("Done") { isPresented = false }
                .keyboardShortcut(.escape)
        }
        .padding()
    }

    private var summaryCard: some View {
        let (health, message) = overall
        return HStack(spacing: 12) {
            Image(systemName: health.symbol)
                .font(.system(size: 28))
                .foregroundColor(health.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("Servers · Permissions · Disk")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(health.color.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Servers

    private var serversCard: some View {
        card(title: "Servers") {
            inferenceRow("Talk", "talk", gateway.services["talk"])
            divider
            inferenceRow("Mac", "macuse", gateway.services["macuse"])
            divider
            agentRow
            divider
            realtimeRow
        }
    }

    /// Supervised-service row (talk/macuse) with a Start/Stop action.
    private func inferenceRow(_ label: String, _ key: String, _ status: ServiceStatus?) -> some View {
        row(health(for: status), label, status?.state ?? "unknown") {
            if status?.isRunning == true {
                Button("Stop") { Task { try? await gateway.stopService(key) } }
                    .buttonStyle(.bordered).controlSize(.small)
            } else {
                Button("Start") { gateway.startServices() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    private var agentRow: some View {
        row(health(for: agentManager.status), "Agent", agentManager.status.displayName) {
            if agentManager.status.isRunning {
                Button("Stop") { agentManager.stopAgent() }
                    .buttonStyle(.bordered).controlSize(.small)
            } else if agentManager.status == .starting {
                VStack(alignment: .trailing, spacing: 4) {
                    ProgressView(value: agentManager.startupProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 120)
                    if !agentManager.startupMessage.isEmpty {
                        Text(agentManager.startupMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } else if agentManager.status == .stopping {
                ProgressView().controlSize(.small)
            } else {
                Button("Start") { agentManager.startAgent() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    private var realtimeRow: some View {
        row(realtimeClient.isConnected ? .ok : .bad, "Realtime",
            realtimeClient.isConnected ? "connected" : "disconnected") {
            if realtimeClient.isConnected {
                Button("Reconnect") {
                    realtimeClient.disconnect()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        realtimeClient.connect()
                    }
                }
                .buttonStyle(.bordered).controlSize(.small)
            } else {
                Button("Connect") { realtimeClient.connect() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    // MARK: - Permissions

    private var permissionsCard: some View {
        card(title: "Permissions") {
            permissionRow(micGranted, "Microphone", "Privacy_Microphone")
            divider
            permissionRow(speechGranted, "Speech Recognition", "Privacy_SpeechRecognition")
            divider
            permissionRow(accessibility.accessibilityPermissionGranted, "Accessibility", "Privacy_Accessibility")
        }
    }

    private func permissionRow(_ granted: Bool, _ label: String, _ pane: String) -> some View {
        row(granted ? .ok : .warn, label, granted ? "granted" : "not granted") {
            if !granted {
                Button("Open Settings") { openPrivacy(pane) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Disk

    private var diskCard: some View {
        card(title: "Disk") {
            row(diskHealth, "Free space",
                diskFreeBytes == 0 ? "unknown" : "\(bytes(diskFreeBytes)) available")
        }
    }

    // MARK: - Row + card primitives

    private var divider: some View { Divider() }

    /// Status row with no trailing action.
    private func row(_ health: Health, _ label: String, _ detail: String) -> some View {
        row(health, label, detail) { EmptyView() }
    }

    /// Status row with a trailing action slot.
    private func row<Trailing: View>(
        _ health: Health, _ label: String, _ detail: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: health.symbol)
                .font(.system(size: 15))
                .foregroundColor(health.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)
            VStack(spacing: 0) { content() }
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
        }
    }

    // MARK: - Refresh

    private func refresh() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized

        let home = FileManager.default.homeDirectoryForCurrentUser
        if let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            diskFreeBytes = capacity
        }

        Task {
            await gateway.pollStatus()
        }
    }

    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
