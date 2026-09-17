//
//  AppState.swift
//  Dottie
//

import Foundation
import Combine

/// Observable application-wide state shared across views via `@EnvironmentObject`.
/// Tracks recording status, processing state, and settings navigation targets.
class AppState: ObservableObject {
    @Published var isHoldToTalkRecording: Bool = false
    @Published var isProcessing: Bool = false
    @Published var isRecording: Bool = false
    @Published var recordingRequested: Bool = false  // Stays true until recording starts
    @Published var targetSettingsSection: String? = nil  // Section to navigate to in settings

    func startProcessing() {
        isProcessing = true
    }

    func stopProcessing() {
        isProcessing = false
    }
}
