//
//  SpectrumViews.swift
//  Dottie
//
//  Full-screen edge glow, overlay panel/manager, and compact launcher bars.
//

import SwiftUI
import AppKit

// MARK: - Full Screen Spectrum View (Edge Gradients)

/// Full-screen edge-glow audio visualization. Two independent layers:
/// 1. **Bass glow** (existing): bottom-edge vertical-jumping blue glow during
///    `.listening` only. Driven by `analyzer.bassLevel`. Untouched by the new line.
/// 2. **Bottom line + hot spot** (new): a persistent thin blue line across the
///    bottom of the screen during every conversation state, with a brighter
///    hot spot rendered *inside* the line:
///      - `.thinking`  → hot spot sweeps left↔right (knight-rider)
///      - `.speaking`  → hot spot stationary at center, pulsing with audioLevel
///      - `.listening` → no hot spot (bass glow already conveys user audio)
struct FullScreenSpectrumView: View {
    @ObservedObject var analyzer: AudioSpectrumAnalyzer
    @ObservedObject private var coordinator = AgentStateCoordinator.shared
    @ObservedObject private var recorder = GlobalRecorder.shared

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Layer 1: bass glow (independent — untouched by the new line layer)
                if coordinator.currentState == .listening {
                    bassGlow(geometry: geometry, intensity: CGFloat(analyzer.bassLevel))
                }

                // Layer 2: persistent thin blue line + state-specific hot spot
                if coordinator.currentState != .idle {
                    bottomLine(geometry: geometry)

                    switch coordinator.currentState {
                    case .thinking:
                        ScannerHotSpot()
                    case .speaking:
                        PulseHotSpot(coordinator: coordinator)
                    default:
                        EmptyView()
                    }
                }

                // Layer 3: live dictation transcript — streaming partials while the
                // PTT key is held. Opaque dark pill (the orb is the only glass),
                // head-truncated so the newest words stay visible.
                if recorder.isRecording && !recorder.livePartial.isEmpty {
                    liveTranscriptPill(geometry: geometry, text: recorder.livePartial)
                }
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Live Transcript (Layer 3)

    @ViewBuilder
    private func liveTranscriptPill(geometry: GeometryProxy, text: String) -> some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundColor(Color.dottieTextPrimary)
            .lineLimit(1)
            .truncationMode(.head)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.dottieSurface)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.dottieBorder, lineWidth: 1))
            )
            .frame(maxWidth: geometry.size.width * 0.6)
            .position(x: geometry.size.width / 2, y: geometry.size.height - 56)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.15), value: text)
            .allowsHitTesting(false)
    }

    // MARK: - Bass Glow (Layer 1)

    @ViewBuilder
    private func bassGlow(geometry: GeometryProxy, intensity: CGFloat) -> some View {
        let clamped = max(0, min(1, intensity))
        let minHeight = geometry.size.height * 0.10
        let maxHeight = geometry.size.height * 0.50
        let glowHeight = minHeight + (maxHeight - minHeight) * clamped

        LinearGradient(
            gradient: Gradient(colors: [
                Color.auroraBlue.opacity(0.3 + 0.5 * Double(clamped)),
                Color.auroraBlue.opacity(0.15 + 0.25 * Double(clamped)),
                Color.clear
            ]),
            startPoint: .bottom,
            endPoint: .top
        )
        .frame(width: geometry.size.width, height: glowHeight)
        .blur(radius: 60)
        .position(x: geometry.size.width / 2, y: geometry.size.height - glowHeight / 2)
        .animation(.easeOut(duration: 0.05), value: clamped)
    }

    // MARK: - Bottom Line (Layer 2 base)

    @ViewBuilder
    private func bottomLine(geometry: GeometryProxy) -> some View {
        Rectangle()
            .fill(Color.auroraBlue.opacity(0.45))
            .frame(width: geometry.size.width, height: 8)
            .blur(radius: 3)
            .position(x: geometry.size.width / 2, y: geometry.size.height - 14)
    }
}

// MARK: - Scanner Hot Spot (Thinking)

/// Brighter blue spot that sweeps left↔right *inside* the bottom line every
/// 1.6s. TimelineView drives the position so motion is frame-rate independent.
private struct ScannerHotSpot: View {
    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                let cycle: Double = 1.6
                let t = timeline.date.timeIntervalSince1970
                let phase = (sin(2 * .pi * t / cycle) + 1) / 2  // smooth 0..1 oscillation
                let spotWidth = geometry.size.width * 0.18
                let x = spotWidth / 2 + CGFloat(phase) * (geometry.size.width - spotWidth)

                Capsule()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.clear,
                                Color.auroraBlue.opacity(1.0),
                                Color.clear
                            ]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: spotWidth, height: 20)
                    .blur(radius: 7)
                    .position(x: x, y: geometry.size.height - 14)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Pulse Hot Spot (Speaking)

/// Stationary brighter blue spot at center-bottom that pulses *inside* the
/// bottom line. Width and opacity both bound to `AgentStateCoordinator.audioLevel`
/// (same speaking-simulation sinusoid driving the orb's mouth, so they're synced).
private struct PulseHotSpot: View {
    @ObservedObject var coordinator: AgentStateCoordinator

    var body: some View {
        GeometryReader { geometry in
            let intensity = Double(coordinator.audioLevel)
            // Wider visible swing: 6% baseline → 36% width at peak.
            let spotWidth = geometry.size.width * (0.06 + 0.30 * intensity)
            // Bigger visible swing in opacity too: 0.15 baseline → 1.0 at peak.
            let opacity = 0.15 + 0.85 * intensity

            Capsule()
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color.clear,
                            Color.auroraBlue.opacity(opacity),
                            Color.clear
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: spotWidth, height: 20)
                .blur(radius: 7)
                .position(x: geometry.size.width / 2, y: geometry.size.height - 14)
                // No animation modifier — values arrive every ~30ms from audio
                // chunks + decay timer; chaining easeOuts here lagged the visual
                // behind the data and made the pulse look static.
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Full Screen Spectrum Overlay Panel (Non-Activating, Click-Through)

/// Click-through overlay panel that displays the full-screen spectrum visualization during recording.
/// Inherits from `BaseOverlayPanel` with mouse events disabled so it never steals focus.
class FullScreenSpectrumOverlayPanel: BaseOverlayPanel {
    /// Creates a floating, click-through overlay panel for full-screen spectrum display.
    init() {
        // Use floating level to appear above other app windows during recording
        super.init(size: NSSize(width: 100, height: 100), level: .floating, ignoresMouse: true, hasShadow: false)
    }
}

// MARK: - Manager Singleton

/// Singleton that manages the lifecycle of the full-screen spectrum overlay panel.
/// Call `show(with:)` to display the visualization covering the main screen, and `hide()` to dismiss it.
class FullScreenSpectrumOverlayManager {
    static let shared = FullScreenSpectrumOverlayManager()
    private var panel: FullScreenSpectrumOverlayPanel?
    private var hostingView: NSHostingView<FullScreenSpectrumView>?

    private init() {}

    /// Displays the full-screen spectrum overlay, sizing it to cover the main screen.
    /// Creates the panel lazily on first call and reuses it on subsequent calls.
    /// - Parameter analyzer: The audio analyzer whose bass/mid/treble levels drive the visualization.
    func show(with analyzer: AudioSpectrumAnalyzer) {
        AppLogger.shared.debug("[FullScreenSpectrum] show() called")

        if panel == nil {
            panel = FullScreenSpectrumOverlayPanel()
        }

        guard let panel = panel else { return }

        // Create new view with the analyzer
        let spectrumView = FullScreenSpectrumView(analyzer: analyzer)
        hostingView = NSHostingView(rootView: spectrumView)
        panel.contentView = hostingView

        // Cover entire main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.frame
            panel.setFrame(screenFrame, display: true)
            AppLogger.shared.debug("[FullScreenSpectrum] Panel frame set to: \(screenFrame)")
        }

        // LauncherPanel at .floating is already above this panel at .normal - no manipulation needed

        panel.orderFront(nil)
        AppLogger.shared.debug("[FullScreenSpectrum] Panel ordered front")
    }

    /// Hides the overlay panel by ordering it out of the window list.
    func hide() {
        AppLogger.shared.debug("[FullScreenSpectrum] hide() called")
        panel?.orderOut(nil)

        // Nothing to restore - LauncherPanel level was never changed
    }
}

// MARK: - Aurora Spectrum Compact View (Three animated bars for inline display)

/// Compact three-bar spectrum indicator (pink/purple/cyan) sized for inline display.
/// Bar heights animate proportionally to bass, mid, and treble levels from the analyzer.
struct AuroraSpectrumCompactView: View {
    @ObservedObject var analyzer: AudioSpectrumAnalyzer
    var barWidth: CGFloat = 4
    var spacing: CGFloat = 3
    var maxHeight: CGFloat = 24
    var minHeight: CGFloat = 2

    var body: some View {
        HStack(spacing: spacing) {
            // Bass bar - Pink
            RoundedRectangle(cornerRadius: barWidth / 2)
                .fill(Color.auroraPink)
                .frame(
                    width: barWidth,
                    height: minHeight + CGFloat(analyzer.bassLevel) * (maxHeight - minHeight)
                )
                .animation(.easeOut(duration: 0.05), value: analyzer.bassLevel)

            // Mid bar - Purple
            RoundedRectangle(cornerRadius: barWidth / 2)
                .fill(Color.auroraPurple)
                .frame(
                    width: barWidth,
                    height: minHeight + CGFloat(analyzer.midLevel) * (maxHeight - minHeight)
                )
                .animation(.easeOut(duration: 0.05), value: analyzer.midLevel)

            // Treble bar - Cyan
            RoundedRectangle(cornerRadius: barWidth / 2)
                .fill(Color.auroraCyan)
                .frame(
                    width: barWidth,
                    height: minHeight + CGFloat(analyzer.trebleLevel) * (maxHeight - minHeight)
                )
                .animation(.easeOut(duration: 0.05), value: analyzer.trebleLevel)
        }
        .frame(height: maxHeight)
    }
}
