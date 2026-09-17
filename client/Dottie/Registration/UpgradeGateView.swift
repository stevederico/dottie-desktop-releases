import SwiftUI
import AppKit

struct UpgradeGateView: View {
    @Environment(\.colorScheme) private var colorScheme
    let latestVersion: String
    let downloadURL: String
    weak var window: NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Update Required")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.primary)
                Text("You are on \(DottieAPIClient.appVersion). Update to \(latestVersion) to continue.")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button(action: openDownload) {
                    Text("Download Update")
                        .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                Button(action: quit) {
                    Text("Quit")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding(40)
        .frame(width: 500, height: 260)
        .background(
            VisualEffectBlur(
                material: colorScheme == .dark ? .hudWindow : .popover,
                cornerRadius: 16
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func openDownload() {
        if let url = URL(string: downloadURL) {
            NSWorkspace.shared.open(url)
        }
        NSApp.terminate(nil)
    }

    private func quit() {
        NSApp.terminate(nil)
    }
}
