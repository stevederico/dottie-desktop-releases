//
//  AvatarPanel.swift
//  Dottie
//
//  Chromeless floating panel for Metal / Galaxy / Web / Logo avatar styles.
//  Embeds SwiftUI avatar content via NSHostingView.
//

import AppKit
import SwiftUI

// MARK: - Avatar Panel ViewModel

/// Observable state bridge for AvatarPanel content.
final class AvatarPanelViewModel: ObservableObject {
    @Published var agentState: AgentState = .idle
    @Published var audioLevel: Float = 0
    @Published var isHovering: Bool = false
}

// MARK: - Avatar Panel Content

/// SwiftUI wrapper that displays avatar inside the floating panel.
/// Shows Metal / Galaxy / Web / Logo avatar based on avatarStyle setting.
struct AvatarPanelContent: View {
    @ObservedObject var viewModel: AvatarPanelViewModel
    @AppStorage(DefaultsKeys.avatarStyle.rawValue) private var avatarStyle: String = ModelDefaults.avatarStyle

    var body: some View {
        // Keep listening/speaking so hover does not hide the hear-me meter.
        let displayState: AgentState = {
            switch viewModel.agentState {
            case .listening, .speaking: return viewModel.agentState
            default: return viewModel.isHovering ? .hover : viewModel.agentState
            }
        }()

        GeometryReader { geo in
            ZStack {
                if viewModel.agentState == .listening {
                    ListeningHearRing(level: viewModel.audioLevel)
                }
                Group {
                    if avatarStyle == "metal" {
                        MetalAvatarView(agentState: displayState, audioLevel: viewModel.audioLevel, size: 160)
                            .allowsHitTesting(false)
                    } else if avatarStyle == "agent" {
                        AgentOrbAvatarView(agentState: displayState, audioLevel: viewModel.audioLevel, size: 160)
                            .allowsHitTesting(false)
                    } else if avatarStyle == "webview" {
                        WebAvatarView(agentState: displayState, audioLevel: viewModel.audioLevel, size: 160)
                            .allowsHitTesting(false)
                    } else {
                        LogoAvatarView(size: 160)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Rings around the orb that swell with mic level so you can see it hears you.
private struct ListeningHearRing: View {
    let level: Float

    var body: some View {
        let l = CGFloat(min(1, max(0, level)))
        ZStack {
            Circle()
                .stroke(Color.dottieAccentGlow.opacity(0.18 + l * 0.55), lineWidth: 2 + l * 5)
                .frame(width: 152 + l * 30, height: 152 + l * 30)
            Circle()
                .stroke(Color.dottieAccent.opacity(0.22 + l * 0.5), lineWidth: 1.5)
                .frame(width: 172 + l * 40, height: 172 + l * 40)
        }
        .animation(.easeOut(duration: 0.08), value: level)
        .allowsHitTesting(false)
    }
}

// MARK: - Logo Avatar

/// App icon avatar with breathing pulse, hover scale, and state-driven glow.
struct LogoAvatarView: View {
    var agentState: AgentState = .idle
    var size: CGFloat = 128

    @State private var isHovered = false

    private var effectiveState: AgentState {
        isHovered ? .hover : agentState
    }

    private var style: AvatarStateStyle {
        AvatarStateStyle.style(for: effectiveState)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let seconds = timeline.date.timeIntervalSinceReferenceDate
            let pulse = sin(seconds * (2.0 * .pi / style.pulseDuration))
            let pulseScale = 1.0 + (pulse * 0.03)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: size, height: size)
                .scaleEffect(x: -1, y: 1)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
                .scaleEffect(pulseScale * style.scale)
                .shadow(color: style.shadowColor, radius: style.shadowRadius)
        }
        .animation(.easeInOut(duration: 0.3), value: effectiveState)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Avatar Panel

/// Non-activating floating panel that hosts the selected avatar style for rendering
/// a web-based avatar. Uses NSHostingView to embed SwiftUI content with
/// transparent background for desktop overlay.
final class AvatarPanel: BaseOverlayPanel {

    /// Default panel dimensions (extra large to accommodate glow effects without clipping).
    static let defaultSize = NSSize(width: 360, height: 360)

    /// Margin from screen edges when positioning bottom-right.
    static let screenMargin: CGFloat = 5

    private var hostingView: NSHostingView<AvatarPanelContent>!
    private let viewModel = AvatarPanelViewModel()
    private var trackingArea: NSTrackingArea?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    /// Creates a new avatar panel with the given dimensions.
    /// - Parameter size: Panel dimensions. Defaults to ``defaultSize`` (280x280).
    init(size: NSSize = AvatarPanel.defaultSize) {
        // BaseOverlayPanel provides the borderless/non-activating/transparent
        // setup. .statusBar puts the panel above plain .floating windows (e.g.
        // the FullScreenSpectrumOverlay also at .floating) so the orb sits at
        // the top of the z-stack while the user has the avatar enabled.
        // Mouse events stay enabled (ignoresMouse: false) because the panel
        // toggles ignoresMouseEvents dynamically via updatePassthrough().
        super.init(size: size, level: .statusBar, ignoresMouse: false, hasShadow: false)

        // .stationary stops the orb from following the active Space when you
        // switch. BaseOverlayPanel only adds .stationary for ignoresMouse panels,
        // so re-apply the full avatar collection behavior here. .canJoinAllSpaces
        // keeps the orb visible across Spaces; .fullScreenAuxiliary keeps it on
        // top when another app is full-screen.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        setupHostingView()
        setupTrackingArea()
        positionBottomRight()
        // Note: the global mouse monitor is NOT installed here. It's started in
        // orderFront(_:) and torn down in orderOut(_:) so a hidden/off-screen
        // panel doesn't run updatePassthrough() on every system-wide mouse move.
    }

    deinit {
        teardownPassthroughMonitor()
    }

    // MARK: - Hosting View Setup

    /// Configures an NSHostingView wrapping the SwiftUI avatar content.
    private func setupHostingView() {
        let content = AvatarPanelContent(viewModel: viewModel)
        hostingView = NSHostingView(rootView: content)
        hostingView.frame = contentRect(forFrameRect: frame)
        hostingView.autoresizingMask = [.width, .height]

        // Make hosting view transparent
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        contentView = hostingView
    }

    // MARK: - Tracking Area Setup

    /// Configures an NSTrackingArea for hover detection at the panel level.
    /// This avoids WKWebView mouse event handling issues that cause freezing.
    private func setupTrackingArea() {
        guard let contentView = contentView else { return }
        trackingArea = NSTrackingArea(
            rect: contentView.bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        contentView.addTrackingArea(trackingArea!)
    }

    /// Radius (in points) of the interactive circle around the avatar center.
    /// The panel itself is larger to accommodate glow rendering without clipping,
    /// but only clicks within this radius activate the avatar.
    private static let interactiveRadius: CGFloat = 85

    /// Returns true if the given window-coordinate point is within the avatar's interactive circle.
    private func isPointInAvatar(_ point: NSPoint) -> Bool {
        let center = NSPoint(x: frame.width / 2, y: frame.height / 2)
        let dx = point.x - center.x
        let dy = point.y - center.y
        return (dx * dx + dy * dy) <= (Self.interactiveRadius * Self.interactiveRadius)
    }

    // MARK: - Mouse Passthrough
    //
    // The panel's contentView spans 360x360 to give the orb's glow room to
    // render without clipping, but only the central interactiveRadius circle
    // is meant to be clickable. Returning early in mouseDown for outer
    // points isn't enough — NSWindow still *swallows* the click and prevents
    // it from reaching whatever app is underneath. Toggling
    // `ignoresMouseEvents` in real-time based on cursor position is the only
    // way to get true click-through behavior on the glow padding.

    private func setupPassthroughMonitor() {
        // Idempotent: only installs the monitors once. Called from orderFront(_:)
        // each time the panel is shown.
        if globalMouseMonitor == nil {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                self?.updatePassthrough()
            }
        }
        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                self?.updatePassthrough()
                return event
            }
        }
    }

    private func teardownPassthroughMonitor() {
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m); localMouseMonitor = nil }
    }

    // Tie the global mouse monitor to panel visibility. When hidden via
    // orderOut(_:), the monitor is removed so a hidden/off-screen panel doesn't
    // run updatePassthrough() on every system-wide mouse move (wasted wakeups).
    override func orderFront(_ sender: Any?) {
        super.orderFront(sender)
        setupPassthroughMonitor()
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        teardownPassthroughMonitor()
    }

    private func updatePassthrough() {
        let mouseLoc = NSEvent.mouseLocation
        let pointInWindow = NSPoint(
            x: mouseLoc.x - frame.origin.x,
            y: mouseLoc.y - frame.origin.y
        )
        let shouldIgnore = !isPointInAvatar(pointInWindow)
        if ignoresMouseEvents != shouldIgnore {
            ignoresMouseEvents = shouldIgnore
            if shouldIgnore && viewModel.isHovering {
                viewModel.isHovering = false
            }
        }
    }

    override func mouseEntered(with event: NSEvent) {
        // Hover is driven by mouseMoved so we only hover over the actual avatar
    }

    override func mouseExited(with event: NSEvent) {
        viewModel.isHovering = false
    }

    override func mouseMoved(with event: NSEvent) {
        // Only show hover state when cursor is over the avatar itself (not the glow padding)
        guard viewModel.agentState == .idle else {
            if viewModel.isHovering { viewModel.isHovering = false }
            return
        }
        let inside = isPointInAvatar(event.locationInWindow)
        if inside != viewModel.isHovering {
            viewModel.isHovering = inside
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Ignore clicks that land in the panel's glow-padding area outside the avatar circle
        guard isPointInAvatar(event.locationInWindow) else {
            AppLogger.shared.debug("[AvatarPanel] Click outside avatar radius - ignored")
            return
        }

        // Check default interaction preference
        let defaultInteraction = UserDefaults.standard.string(forKey: "defaultInteraction") ?? "voice"

        if defaultInteraction == "text" {
            // Text mode: open the launcher
            AppLogger.shared.info("[AvatarPanel] Clicked - opening launcher (text mode)")
            LauncherManager.shared.show()
        } else {
            AppLogger.shared.info("[AvatarPanel] Clicked - orb, state=\(RealtimeClient.shared.conversationState)")
            RealtimeClient.shared.handleOrbClick()
        }
    }

    // MARK: - Positioning

    /// Places the panel in the bottom-right corner of the main screen.
    func positionBottomRight() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        // Position avatar near bottom-right corner with room for glow
        let origin = NSPoint(
            x: screenFrame.maxX - 320,
            y: screenFrame.minY - 60
        )
        setFrameOrigin(origin)
    }

    // MARK: - State Updates

    /// Updates the avatar agent state.
    /// - Parameter state: One of "idle", "hover", "thinking", "listening", "speaking".
    func setAgentState(_ state: String) {
        DispatchQueue.main.async { [weak self] in
            self?.viewModel.agentState = AgentState(rawValue: state) ?? .idle
        }
    }

    /// Updates the avatar audio level for animation.
    /// - Parameter level: Normalized audio level (0.0 - 1.0).
    func setAudioLevel(_ level: Float) {
        DispatchQueue.main.async { [weak self] in
            self?.viewModel.audioLevel = level
        }
    }

    /// Reloads the avatar content. No-op for embedded web avatars
    /// (WebView recreated on next state change).
    func reload() {
        // Force SwiftUI to recreate the WebView by toggling state
        let current = viewModel.agentState
        viewModel.agentState = .idle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.viewModel.agentState = current
        }
    }
}

// MARK: - Avatar Panel Manager

/// Singleton that manages the lifecycle and state of the AvatarPanel.
/// Also observes system events for proactive orb behavior:
/// - Full-screen app detection → auto-dim panel
/// - App activation → notification pulse via proactiveGlow
final class AvatarPanelManager {
    static let shared = AvatarPanelManager()

    private var panel: AvatarPanel?

    private init() {
        observeWorkspaceEvents()
    }

    /// Whether the avatar panel is currently on screen.
    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    /// Creates the panel if needed and brings it on screen.
    ///
    /// No-op when the Floating Avatar setting is off. The gate lives here rather
    /// than at each call site because the panel doubles as the conversation UI:
    /// startConversation() and the menu-bar voice click both used to show it
    /// unconditionally, so turning the setting off still put an avatar on screen
    /// the moment voice started.
    func show() {
        guard UserDefaults.standard.bool(forKey: "floatingAvatarEnabled") else {
            AppLogger.shared.debug("[AvatarPanelManager] show() ignored — floating avatar disabled")
            return
        }
        if UserDefaults.standard.string(forKey: DefaultsKeys.avatarStyle.rawValue) == "webview" {
            AvatarFileManager.ensureAvatarFiles(caller: "AvatarPanelManager")
        }
        if panel == nil {
            panel = AvatarPanel()
        }
        panel?.positionBottomRight()
        panel?.orderFront(nil)
        AppLogger.shared.debug("[AvatarPanelManager] Panel shown")
    }

    /// Hides the panel without destroying it.
    func hide() {
        panel?.orderOut(nil)
        AppLogger.shared.debug("[AvatarPanelManager] Panel hidden")
    }

    /// Updates the avatar state using the AgentState enum.
    /// - Parameter state: The current agent state to display.
    func updateState(_ state: AgentState) {
        panel?.setAgentState(state.rawValue)
    }

    /// Forwards an audio level to the panel for animation.
    /// - Parameter level: Normalized audio level (0.0 - 1.0).
    func updateAudioLevel(_ level: Float) {
        panel?.setAudioLevel(level)
    }

    /// Reloads the avatar HTML from disk.
    func reload() {
        panel?.reload()
    }

    // MARK: - Proactive Orb: Workspace Observers

    /// Observes NSWorkspace events for the app-switch glow pulse. (Full-screen
    /// dimming was removed — when the floating-avatar setting is on, the orb
    /// stays at full alpha across spaces, full-screen apps, and sleep/wake.)
    private func observeWorkspaceEvents() {
        let workspace = NSWorkspace.shared
        let nc = workspace.notificationCenter

        nc.addObserver(
            self, selector: #selector(handleAppActivation(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
    }

    /// Handles app activation — triggers the subtle notification pulse on app switch.
    @objc private func handleAppActivation(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }

        // Skip if the activated app is Dottie itself
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return }

        NotificationCenter.default.post(name: .triggerProactiveGlow, object: nil)
        AppLogger.shared.debug("[AvatarPanelManager] Proactive glow: app switch to \(app.localizedName ?? "unknown")")
    }
}
