import AppKit

/// Real NSWindow that can become key/main (pure `.borderless` alone is not
/// enough for text fields — see canBecomeKey override).
final class KeyableBorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Registration / upgrade: **real** window (normal level, titled + fullSizeContentView)
    /// that *looks* borderless (transparent titlebar, traffic lights hidden).
    /// Drags like a normal macOS window; not a floating sticker panel.
    static func makeFloating(size: NSSize) -> KeyableBorderlessWindow {
        let window = KeyableBorderlessWindow(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.titled, .fullSizeContentView, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor.clear
        window.isOpaque = false
        window.hasShadow = true
        // Normal window, not .floating — participates in spaces / Mission Control.
        window.level = .normal
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // Borderless look: hide traffic lights (still a real titled window underneath).
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        if #available(macOS 11.0, *) {
            window.titlebarSeparatorStyle = .none
        }
        return window
    }
}

extension NSWindow {
    /// Positions the window centered within `NSScreen.main`'s visibleFrame using
    /// the window's current frame size. No-op when there is no main screen.
    func centerOnMainScreen() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let x = frame.origin.x + (frame.width - self.frame.width) / 2
        let y = frame.origin.y + (frame.height - self.frame.height) / 2
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
