//
//  LauncherPanel.swift
//  Dottie
//
//  Created by Steve Derico on 2/26/26.
//

import SwiftUI
import AppKit

/// Custom overlay panel for the Spotlight-style launcher with blur-through glass effect.
/// Configured as a HUD window that floats above other content and accepts keyboard input.
/// Inherits the borderless / non-activating / transparent / canJoinAllSpaces setup from
/// `BaseOverlayPanel`; overrides `canBecomeKey`/`canBecomeMain` to `true` (the launcher,
/// unlike a passive overlay, takes keyboard focus) and adds launcher-specific window flags.
class LauncherPanel: BaseOverlayPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init() {
        // BaseOverlayPanel applies: borderless + nonactivatingPanel styleMask,
        // isOpaque=false, backgroundColor=.clear, and
        // collectionBehavior=[.canJoinAllSpaces, .fullScreenAuxiliary].
        // hasShadow=false because AppKit draws a rectangular shadow at the window
        // bounds; the SwiftUI capsule renders its own shadow instead.
        // `.normal` level so the launcher behaves like an ordinary app window —
        // other windows can cover it and it doesn't float on top.
        super.init(size: NSSize(width: 700, height: 80), level: .normal, hasShadow: false)

        // Drop `.nonactivatingPanel` so the launcher activates Dottie like a normal
        // window — clicking it makes the app frontmost in the Dock (the base overlay
        // is non-activating so a passive HUD never steals focus; the launcher does).
        styleMask.remove(.nonactivatingPanel)

        // Normal-window space behavior: drop the base overlay's `.canJoinAllSpaces`
        // / `.fullScreenAuxiliary` (those made it appear on every Space and hover
        // over full-screen apps — the "always on top" feel the user didn't want).
        collectionBehavior = [.moveToActiveSpace]

        // Launcher-specific flags not covered by the base overlay setup.
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = true

        // Force contentView layer background to clear so nothing rectangular leaks
        // behind the SwiftUI capsule.
        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }
}

/// Singleton manager for the launcher panel lifecycle.
/// Handles show/hide/toggle, click-outside dismissal, and dynamic height resizing.
class LauncherManager: NSObject, ObservableObject {
    static let shared = LauncherManager()

    private var panel: LauncherPanel?
    private var clickOutsideMonitor: Any?
    private var dragMonitor: Any?
    private var escapeMonitor: Any?
    /// Deferred click-outside dismissal, cancellable if the click turns into a
    /// drag (e.g. grabbing a file in Finder to drop on the launcher).
    private var hideWork: DispatchWorkItem?

    @Published var isVisible: Bool = false
    @Published var contentHeight: CGFloat = 80

    /// Gap kept between the panel edge and the edge of the screen when clamping.
    private let topMargin: CGFloat = 24

    private override init() {
        super.init()
    }

    deinit {
        removeMonitors()
    }

    // MARK: - Public API

    /// Shows the launcher panel centered on the screen.
    /// - Parameter persistent: when true, skips the click-outside auto-dismiss so the
    ///   launcher stays up alongside other windows (used by Compare Views). ESC still hides.
    func show(persistent: Bool = false) {
        if panel == nil {
            createPanel()
        }

        guard let panel = panel, let screen = NSScreen.main else { return }

        // Set explicit size to ensure consistent positioning
        panel.setContentSize(NSSize(width: 700, height: 80))

        // Force layout so SwiftUI content is sized before positioning
        panel.contentView?.layoutSubtreeIfNeeded()

        let screenRect = screen.visibleFrame

        // Position: horizontally centered. Vertically, anchor the BOTTOM edge so the
        // expanded box (expandedHeight) fits entirely above it on-screen — collapsed
        // and expanded share this bottom Y, so opening a conversation grows the panel
        // straight up without moving the input or running off the top of the monitor.
        // Position: horizontally centered, vertically ~30% from the top (Spotlight-
        // like). The expanded box grows DOWNWARD from here (top edge stays put), so
        // the collapsed bar keeps its familiar resting spot.
        let x = screenRect.midX - panel.frame.width / 2
        let y = screenRect.maxY - (screenRect.height * 0.30) - panel.frame.height

        panel.setFrameOrigin(NSPoint(x: x, y: y))

        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        isVisible = true
        // Never auto-dismiss on click-away — the launcher stays up until ESC or
        // the toggle hotkey. (`persistent` is now moot; kept for call-site compat.)
        addMonitors(includeClickOutside: false)

        // Focus the text field. 50ms (was 100ms + a second 100ms inside
        // LauncherView.focusTextField — 2026-07-19 speed pass): the panel is
        // already key and laid out synchronously above, so this only needs to
        // clear the current runloop turn; keep a small floor for the
        // become-key → first-responder race.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NotificationCenter.default.post(name: .launcherFocusTextField, object: nil)
        }
    }

    /// Builds the panel + SwiftUI hosting view ahead of first use so the first
    /// Cmd+K doesn't pay hosting construction + first layout inline.
    func prewarm() {
        if panel == nil { createPanel() }
        panel?.contentView?.layoutSubtreeIfNeeded()
    }

    /// Hides the launcher panel.
    func hide() {
        panel?.orderOut(nil)
        isVisible = false
        removeMonitors()

        // Reset height for next show
        contentHeight = 80
        updatePanelHeight(80)
    }

    /// Re-key and re-activate the panel after a menu action that drops focus.
    /// Clicking a SwiftUI Menu item dismisses the NSMenu and resigns the panel's
    /// key status; if the action also collapses the launcher (e.g. Clear), it can
    /// be left visible but unclickable until the user re-activates via the Dock.
    func focusPanel() {
        DispatchQueue.main.async { [weak self] in
            guard let panel = self?.panel else { return }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: .launcherFocusTextField, object: nil)
        }
    }

    /// Toggles the launcher panel visibility.
    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    /// Updates the panel height with animation.
    /// - Parameter height: The new height for the panel content area.
    func updateHeight(_ height: CGFloat) {
        let clampedHeight = min(max(height, 80), 600)
        guard clampedHeight != contentHeight else { return }

        contentHeight = clampedHeight
        updatePanelHeight(clampedHeight)
    }

    // MARK: - Private

    private func createPanel() {
        let panel = LauncherPanel()

        // Create hosting controller with LauncherView
        let launcherView = LauncherView()
            .environmentObject(AppDelegate.shared?.appState ?? AppState())
        let hostingController = NSHostingController(rootView: launcherView)
        panel.contentViewController = hostingController

        // Force the NSHostingView's layer to be fully transparent. By default it can
        // carry a system control backgroundColor that renders as a gray rectangle
        // behind the SwiftUI capsule — this is the "corner bleed" source.
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        hostingController.view.layer?.isOpaque = false

        self.panel = panel
    }

    private func updatePanelHeight(_ height: CGFloat) {
        guard let panel = panel else { return }

        var frame = panel.frame
        let oldHeight = frame.height
        frame.size.height = height
        // Anchor the TOP edge so the box grows DOWNWARD from the launcher's current
        // location. origin.y is the bottom-left in AppKit, so lowering origin.y by
        // the height delta keeps the top fixed and extends the bottom downward.
        frame.origin.y += (oldHeight - height)

        // Safety clamp: if growing downward would push the bottom off the monitor,
        // slide the whole window up just enough to keep it on-screen.
        if let screen = panel.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if frame.origin.y < visible.minY + topMargin {
                frame.origin.y = visible.minY + topMargin
            }
            let top = frame.origin.y + frame.size.height
            if top > visible.maxY - topMargin {
                frame.origin.y = visible.maxY - topMargin - frame.size.height
            }
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func addMonitors(includeClickOutside: Bool = true) {
        // Click outside to dismiss (skipped in persistent/compare mode)
        if includeClickOutside {
            clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self = self, let panel = self.panel else { return }

                // A click inside the panel never dismisses.
                if let clickWindow = event.window, clickWindow == panel { return }

                // Defer the dismissal a beat. If the click turns into a drag
                // (the drag monitor below) or the drag enters the launcher
                // (LauncherView calls cancelPendingHide), we keep the panel up
                // so a Finder drag-and-drop can land. A plain click — down then
                // up, no drag — lets the deferred hide fire.
                self.scheduleHide()
            }

            // A drag beginning anywhere outside means the user may be dragging
            // content toward the launcher — cancel the pending dismissal so the
            // drop target survives the trip from Finder.
            dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
                self?.cancelPendingHide()
            }
        }

        // ESC to dismiss (local monitor for when panel is key)
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // ESC
                self?.hide()
                return nil // Consume the event
            }
            return event
        }
    }

    /// Schedules the click-outside dismissal, replacing any already pending.
    private func scheduleHide() {
        cancelPendingHide()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// Cancels a pending click-outside dismissal. Called when the outside click
    /// becomes a drag, or when a drag enters the launcher (from LauncherView).
    func cancelPendingHide() {
        hideWork?.cancel()
        hideWork = nil
    }

    private func removeMonitors() {
        cancelPendingHide()
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
        if let monitor = dragMonitor {
            NSEvent.removeMonitor(monitor)
            dragMonitor = nil
        }
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }
}

