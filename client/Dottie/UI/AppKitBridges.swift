//
//  AppKitBridges.swift
//  Dottie
//
//  NSViewRepresentable bridges: VisualEffectBlur + WhiteSpinner.
//

import SwiftUI
import AppKit

// MARK: - Visual effect blur

/// SwiftUI wrapper for `NSVisualEffectView` that renders a system-blurred glass background.
/// Uses the `.hudWindow` material for a dark translucent appearance similar to Spotlight/MacClaw.
///
/// `cornerRadius` and `capsule` clip the underlying `NSVisualEffectView` via `maskImage`.
/// SwiftUI's `.clipShape` and CALayer `cornerRadius` do NOT clip the blur when the blending
/// mode is `.behindWindow` — that blur is composed in the window server, outside the CALayer
/// mask. `maskImage` is the documented way to produce a non-rectangular blur region.
struct VisualEffectBlur: NSViewRepresentable {
    /// The material appearance to use. Defaults to `.hudWindow` for dark translucent blur.
    var material: NSVisualEffectView.Material = .hudWindow
    /// The blending mode for the blur. Defaults to `.behindWindow` for blur-through effect.
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    /// The visual state. Defaults to `.active` for always-on blur regardless of window focus.
    var state: NSVisualEffectView.State = .active
    /// Static corner radius for the blur mask. Ignored when `capsule` is true.
    var cornerRadius: CGFloat = 0
    /// When true, the blur is clipped to a capsule shape (cornerRadius = height / 2) that
    /// updates on every frame change.
    var capsule: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = true
        view.postsFrameChangedNotifications = true
        context.coordinator.attach(view, capsule: capsule, fixedRadius: cornerRadius)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
        context.coordinator.update(view: nsView, capsule: capsule, fixedRadius: cornerRadius)
    }

    /// Observes `frameDidChange` on the hosted `NSVisualEffectView` and regenerates its
    /// `maskImage` — either at a fixed corner radius or at `bounds.height / 2` for a capsule.
    final class Coordinator {
        private weak var view: NSVisualEffectView?
        private var capsule: Bool = false
        private var fixedRadius: CGFloat = 0
        private var lastMaskedSize: CGSize = .zero
        private var lastMaskedRadius: CGFloat = -1
        private var observer: NSObjectProtocol?

        func attach(_ view: NSVisualEffectView, capsule: Bool, fixedRadius: CGFloat) {
            self.view = view
            self.capsule = capsule
            self.fixedRadius = fixedRadius
            observer = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: view,
                queue: .main
            ) { [weak self] _ in self?.applyMask() }
            applyMask()
        }

        func update(view: NSVisualEffectView, capsule: Bool, fixedRadius: CGFloat) {
            self.view = view
            self.capsule = capsule
            self.fixedRadius = fixedRadius
            applyMask()
        }

        private func applyMask() {
            guard let view = view else { return }
            let size = view.bounds.size
            guard size.width > 0 && size.height > 0 else { return }

            let radius: CGFloat = capsule ? (size.height / 2) : fixedRadius
            guard radius > 0 else {
                view.maskImage = nil
                lastMaskedSize = .zero
                lastMaskedRadius = -1
                return
            }

            // Avoid regenerating when nothing meaningful changed
            if lastMaskedSize == size && lastMaskedRadius == radius { return }
            lastMaskedSize = size
            lastMaskedRadius = radius

            let image = NSImage(size: size, flipped: false) { rect in
                NSColor.black.setFill()
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
                return true
            }
            // capInsets lets macOS stretch the center pixels if the view is later resized
            // without a frame notification; the rounded caps stay intact.
            image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
            image.resizingMode = .stretch
            view.maskImage = image
        }

        deinit {
            if let observer = observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

// MARK: - White spinner

/// An `NSViewRepresentable` wrapper around `NSProgressIndicator` that renders a spinning indicator.
/// Adapts appearance between dark and light modes via the `isDark` parameter.
struct WhiteSpinner: NSViewRepresentable {
    /// When true, uses dark aqua appearance (white spinner). When false, uses aqua appearance (dark spinner).
    var isDark: Bool = true

    func makeNSView(context: Context) -> NSProgressIndicator {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        spinner.contentFilters = []
        spinner.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        return spinner
    }

    func updateNSView(_ nsView: NSProgressIndicator, context: Context) {
        nsView.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
}
