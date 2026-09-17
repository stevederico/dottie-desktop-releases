//
//  BaseOverlayPanel.swift
//  Dottie
//
//  Base class for non-activating floating overlay panels
//

import AppKit

// MARK: - Base Overlay Panel

/// Non-activating, borderless `NSPanel` base class for floating overlay UI.
/// Configured as transparent, can join all spaces, and optionally ignores mouse events for click-through behavior.
class BaseOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Creates a borderless, non-activating overlay panel.
    /// - Parameters:
    ///   - size: Initial content size of the panel.
    ///   - level: Window level; defaults to `.floating`.
    ///   - ignoresMouse: When `true`, the panel passes all mouse events through and uses `.stationary` collection behavior.
    ///   - hasShadow: Whether the panel renders a drop shadow.
    init(size: NSSize, level: NSWindow.Level = .floating, ignoresMouse: Bool = false, hasShadow: Bool = true) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = level
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = hasShadow
        self.ignoresMouseEvents = ignoresMouse

        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if ignoresMouse {
            behavior.insert(.stationary)
        }
        self.collectionBehavior = behavior
    }
}
