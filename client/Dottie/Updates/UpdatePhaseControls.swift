//
//  UpdatePhaseControls.swift
//  Dottie
//
//  Shared soft-update chrome for the prompt window and launcher banner.
//

import SwiftUI

/// Phase-driven controls shared by `UpdateAvailableView` and the launcher banner.
struct UpdatePhaseControls: View {
    enum Style {
        /// Large bordered buttons for the floating prompt window.
        case window
        /// Compact plain buttons + status row for the launcher banner.
        case banner
    }

    let style: Style
    var onDismiss: (() -> Void)? = nil

    @ObservedObject private var updateChecker = UpdateChecker.shared

    var body: some View {
        switch style {
        case .window:
            windowButtons
        case .banner:
            bannerRow
        }
    }

    // MARK: - Window

    @ViewBuilder private var windowButtons: some View {
        switch updateChecker.updatePhase {
        case .downloading:
            Button("Cancel") { updateChecker.cancelUpdate() }
                .buttonStyle(.bordered)
                .controlSize(.large)
        case .extracting, .verifying, .installing:
            ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
        case .readyToInstall:
            Button(action: { updateChecker.installUpdate() }) {
                Text("Install And Restart").frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            Button("Later") { onDismiss?() }
                .buttonStyle(.bordered)
                .controlSize(.large)
        case .error:
            Button(action: { updateChecker.openDownloadPage() }) {
                Text("Download Manually").frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button("Close") { onDismiss?() }
                .buttonStyle(.bordered)
                .controlSize(.large)
        default:
            Button(action: { updateChecker.downloadUpdate() }) {
                Text("Install Update").frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            Button("Later") { onDismiss?() }
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
    }

    // MARK: - Banner

    @ViewBuilder private var bannerRow: some View {
        HStack(spacing: 8) {
            switch updateChecker.updatePhase {
            case .available:
                Image(systemName: "arrow.down.circle.fill").foregroundColor(.blue)
                Text("Update available: v\(updateChecker.latestVersion ?? "")")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Button("Install Update") { updateChecker.downloadUpdate() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundColor(.blue)
            case .downloading(let progress):
                ProgressView(value: progress).progressViewStyle(.linear).frame(width: 100)
                Text(updateChecker.statusMessage).font(.system(size: 12)).foregroundColor(Color.primary.opacity(0.5))
                Spacer()
                Button("Cancel") { updateChecker.cancelUpdate() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundColor(.red)
            case .extracting, .verifying, .installing:
                ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                Text(updateChecker.statusMessage.isEmpty ? "Installing…" : updateChecker.statusMessage)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            case .readyToInstall:
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text("Ready to install v\(updateChecker.latestVersion ?? "")")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Button("Install & Restart") { updateChecker.installUpdate() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundColor(.green)
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                Spacer()
                Button("Download Manually") { updateChecker.openDownloadPage() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundColor(.blue)
                Button("Dismiss") { updateChecker.dismissError() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundColor(Color.primary.opacity(0.5))
            default:
                EmptyView()
            }
        }
    }
}
