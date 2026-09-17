//
//  WebAvatars.swift
//  Dottie
//
//  Web / Galaxy orb avatars: WKWebView factory, avatar.html sync, WebAvatarView, AgentOrbAvatarView.
//

import Foundation
import AppKit
import SwiftUI
import WebKit

// MARK: - WebView Factory

/// Creates pre-configured WKWebView instances.
enum WebViewFactory {

    /// Base WKWebViewConfiguration shared by every WKWebView in the app:
    /// just enables Web Inspector developer extras. Callers add their own
    /// userContentController scripts / webpage preferences on top.
    static func makeBaseConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        return config
    }

    /// Applies the Web Inspector + transparent under-page background tweaks
    /// shared by the inline transparent representables (spinner, avatar).
    /// Kept separate from transparency layer/drawsBackground tweaks, which
    /// stay inline because each view clears its own scroll/subview chain.
    static func applyInspectAndUnderPageBackground(to webView: WKWebView) {
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = .clear
        }
    }

    /// Creates a WKWebView configured for gateway-hosted UI pages.
    /// - Parameters:
    ///   - navigationDelegate: Optional delegate for intercepting navigation.
    ///   - uiDelegate: Optional delegate for intercepting window.open() calls.
    /// - Returns: A configured WKWebView.
    static func makeWebView(
        navigationDelegate: WKNavigationDelegate? = nil,
        uiDelegate: WKUIDelegate? = nil
    ) -> WKWebView {
        let config = makeBaseConfiguration()

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = navigationDelegate
        webView.uiDelegate = uiDelegate
        webView.autoresizingMask = [.width, .height]
        return webView
    }
}

// MARK: - Avatar File Manager

/// Manages the avatar HTML file lifecycle: directory creation, bundle copy,
/// and version-based updates. Used by both WebAvatarView and AvatarPanelManager.
enum AvatarFileManager {

    /// Path to ~/.dottie/avatar/
    static let avatarDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".dottie/avatar")

    /// Ensures ~/.dottie/avatar/ exists and avatar.html is copied/updated from bundle.
    /// - Parameter caller: Log tag identifying the call site (e.g. "WebAvatarView").
    static func ensureAvatarFiles(caller: String = "AvatarFileManager") {
        let fm = FileManager.default
        let htmlFile = avatarDir.appendingPathComponent("avatar.html")

        // Create directory if needed
        if !fm.fileExists(atPath: avatarDir.path) {
            do {
                try fm.createDirectory(at: avatarDir, withIntermediateDirectories: true)
                AppLogger.shared.debug("[\(caller)] Created avatar directory at \(avatarDir.path)")
            } catch {
                AppLogger.shared.error("[\(caller)] Failed to create avatar directory: \(error)")
                return
            }
        }

        guard let bundleURL = Bundle.main.url(forResource: "avatar", withExtension: "html") else {
            AppLogger.shared.debug("[\(caller)] avatar.html not found in bundle")
            return
        }

        // Copy if missing or bundle version is newer
        let shouldCopy: Bool
        if !fm.fileExists(atPath: htmlFile.path) {
            shouldCopy = true
        } else {
            let bundleVersion = extractAvatarVersion(from: bundleURL)
            let userVersion = extractAvatarVersion(from: htmlFile)
            shouldCopy = bundleVersion > userVersion
            if shouldCopy {
                AppLogger.shared.debug("[\(caller)] Updating avatar: v\(userVersion) -> v\(bundleVersion)")
            }
        }

        if shouldCopy {
            // Copy to a temp file first, then atomically swap into place. This
            // avoids a torn state (missing/truncated avatar.html) if the process
            // is killed or the disk fills mid-copy: the destination is only ever
            // the old complete file or the new complete file, never a partial one.
            let tempFile = avatarDir.appendingPathComponent("avatar.html.\(UUID().uuidString).tmp")
            do {
                try fm.copyItem(at: bundleURL, to: tempFile)
                if fm.fileExists(atPath: htmlFile.path) {
                    // Atomic replace of the existing file with the temp copy.
                    _ = try fm.replaceItemAt(htmlFile, withItemAt: tempFile)
                } else {
                    // No existing file to replace; a rename (move) is atomic.
                    try fm.moveItem(at: tempFile, to: htmlFile)
                }
                AppLogger.shared.debug("[\(caller)] Copied avatar.html from bundle to \(htmlFile.path)")
            } catch {
                AppLogger.shared.error("[\(caller)] Failed to copy avatar.html: \(error)")
                // Best-effort cleanup of the temp file if the swap never happened.
                try? fm.removeItem(at: tempFile)
            }
        }
    }

    /// Extracts avatar-version meta tag value from an HTML file.
    /// - Parameter url: File URL to read.
    /// - Returns: Version number, or 0 if not found.
    static func extractAvatarVersion(from url: URL) -> Int {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        // Match: <meta name="avatar-version" content="X">
        let pattern = #"<meta\s+name="avatar-version"\s+content="(\d+)">"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              let versionRange = Range(match.range(at: 1), in: content) else {
            return 0
        }
        return Int(content[versionRange]) ?? 0
    }
}

// MARK: - Web Avatar View

// MARK: - WebAvatarView

/// SwiftUI view that embeds a WKWebView rendering the React-based avatar.
/// Syncs `agentState` and `audioLevel` changes to the JavaScript layer.
struct WebAvatarView: View {
    let agentState: AgentState
    var audioLevel: Float = 0
    var size: CGFloat = 128

    var body: some View {
        // Use larger frame to accommodate glow effects (1.5x avatar size)
        // NOTE: Hover is handled via CSS :hover in the React app to avoid
        // Swift state changes that cause WKWebView transparency flicker
        let frameSize = size * 1.6
        WebAvatarRepresentable(agentState: agentState, audioLevel: audioLevel, size: size)
            .frame(width: frameSize, height: frameSize)
    }
}

// MARK: - NSViewRepresentable

/// AppKit bridge that hosts a WKWebView for the avatar HTML.
struct WebAvatarRepresentable: NSViewRepresentable {
    let agentState: AgentState
    let audioLevel: Float
    let size: CGFloat

    /// Coordinator to track previous state and avoid redundant JS calls.
    class Coordinator {
        var lastState: AgentState?
        var lastAudioLevel: Float?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WebViewFactory.makeBaseConfiguration()

        // Inject CSS scaling and force transparency on page load
        let scale = size / 160.0
        let scaleScript = WKUserScript(
            source: """
            document.addEventListener('DOMContentLoaded', function() {
                // Force transparent backgrounds
                document.documentElement.style.backgroundColor = 'transparent';
                document.body.style.backgroundColor = 'transparent';

                // Scale the container
                var container = document.querySelector('.avatar-container');
                if (container) {
                    container.style.transform = 'scale(\(scale))';
                    container.style.transformOrigin = 'center center';
                }

                // Also inject a style tag to ensure transparency
                var style = document.createElement('style');
                style.textContent = 'html, body, #root { background: transparent !important; background-color: transparent !important; }';
                document.head.appendChild(style);
            });
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(scaleScript)

        let webView = WKWebView(frame: .zero, configuration: config)

        // Multiple approaches to ensure transparency
        webView.setValue(false, forKey: "drawsBackground")
        webView.wantsLayer = true
        webView.layer?.backgroundColor = .clear
        webView.layer?.isOpaque = false

        // Also make the enclosing scroll view transparent
        if let scrollView = webView.enclosingScrollView {
            scrollView.drawsBackground = false
            scrollView.backgroundColor = .clear
        }

        // Try to find and clear any subview backgrounds
        for subview in webView.subviews {
            subview.wantsLayer = true
            subview.layer?.backgroundColor = .clear
            if let scrollView = subview as? NSScrollView {
                scrollView.drawsBackground = false
                scrollView.backgroundColor = .clear
            }
        }

        WebViewFactory.applyInspectAndUnderPageBackground(to: webView)

        // Ensure avatar directory exists and React app dist is copied
        AvatarFileManager.ensureAvatarFiles(caller: "WebAvatarView")

        // Load avatar.html
        let avatarDir = AvatarFileManager.avatarDir
        let htmlFile = avatarDir.appendingPathComponent("avatar.html")

        if FileManager.default.fileExists(atPath: htmlFile.path) {
            AppLogger.shared.debug("[WebAvatarView] Loading: \(htmlFile.path)")
            webView.loadFileURL(htmlFile, allowingReadAccessTo: avatarDir)
        } else {
            AppLogger.shared.error("[WebAvatarView] avatar.html not found at: \(htmlFile.path)")
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator

        // Only update if state or audio level actually changed
        let stateChanged = coordinator.lastState != agentState
        let audioChanged = coordinator.lastAudioLevel != audioLevel

        guard stateChanged || audioChanged else { return }

        // Track current values
        coordinator.lastState = agentState
        coordinator.lastAudioLevel = audioLevel

        let state = agentState.rawValue
        let level = audioLevel
        let js = """
        if (window.setAgentState) { window.setAgentState('\(state)'); }
        if (window.setAudioLevel) { window.setAudioLevel(\(level)); }
        """
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                AppLogger.shared.error("[WebAvatarView] JS error: \(error.localizedDescription)")
            }
        }
    }

}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        WebAvatarView(agentState: .idle, size: 128)
        HStack(spacing: 20) {
            WebAvatarView(agentState: .thinking, size: 80)
            WebAvatarView(agentState: .listening, size: 80)
            WebAvatarView(agentState: .speaking, size: 80)
        }
    }
    .padding(40)
    .background(Color.black.opacity(0.9))
}

// MARK: - Agent Orb Avatar View

// MARK: - AgentOrbAvatarView

/// SpaceXAI-style galaxy orb avatar (WebGL + CSS glass shell).
struct AgentOrbAvatarView: View {
    let agentState: AgentState
    var audioLevel: Float = 0
    var size: CGFloat = 160

    var body: some View {
        // Match Metal/Web glow headroom so the floor bloom isn't clipped.
        let frameSize = size * 1.6
        AgentOrbAvatarRepresentable(agentState: agentState, audioLevel: audioLevel, size: size)
            .frame(width: frameSize, height: frameSize)
    }
}

// MARK: - NSViewRepresentable

struct AgentOrbAvatarRepresentable: NSViewRepresentable {
    let agentState: AgentState
    let audioLevel: Float
    let size: CGFloat

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastState: AgentState?
        var lastAudioLevel: Float?
        var lastSize: CGFloat?
        var pageReady = false
        /// Latest values to push once the HTML bridge is live.
        var pendingState: AgentState = .idle
        var pendingAudio: Float = 0
        var pendingSize: CGFloat = 160

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageReady = true
            push(to: webView)
        }

        func push(to webView: WKWebView) {
            guard pageReady else { return }
            let js = """
            if (window.setAgentState) { window.setAgentState('\(pendingState.rawValue)'); }
            if (window.setAudioLevel) { window.setAudioLevel(\(pendingAudio)); }
            if (window.setOrbSize) { window.setOrbSize(\(pendingSize)); }
            """
            webView.evaluateJavaScript(js) { _, error in
                if let error = error {
                    AppLogger.shared.debug("[AgentOrbAvatarView] JS: \(error.localizedDescription)")
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WebViewFactory.makeBaseConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        // Same transparency dance as WebAvatarView — floating
        // panel needs every layer cleared or the orb sits on a black square.
        webView.setValue(false, forKey: "drawsBackground")
        webView.wantsLayer = true
        webView.layer?.backgroundColor = .clear
        webView.layer?.isOpaque = false
        if let scrollView = webView.enclosingScrollView {
            scrollView.drawsBackground = false
            scrollView.backgroundColor = .clear
        }
        for subview in webView.subviews {
            subview.wantsLayer = true
            subview.layer?.backgroundColor = .clear
            if let scrollView = subview as? NSScrollView {
                scrollView.drawsBackground = false
                scrollView.backgroundColor = .clear
            }
        }
        WebViewFactory.applyInspectAndUnderPageBackground(to: webView)

        context.coordinator.pendingState = agentState
        context.coordinator.pendingAudio = audioLevel
        context.coordinator.pendingSize = size

        if let url = Bundle.main.url(forResource: "agent-orb", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            AppLogger.shared.error("[AgentOrbAvatarView] agent-orb.html missing from bundle")
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        let stateChanged = coordinator.lastState != agentState
        let audioChanged = coordinator.lastAudioLevel != audioLevel
        let sizeChanged = coordinator.lastSize != size

        coordinator.pendingState = agentState
        coordinator.pendingAudio = audioLevel
        coordinator.pendingSize = size

        guard stateChanged || audioChanged || sizeChanged else { return }

        coordinator.lastState = agentState
        coordinator.lastAudioLevel = audioLevel
        coordinator.lastSize = size
        coordinator.push(to: webView)
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        AgentOrbAvatarView(agentState: .idle, size: 160)
        HStack(spacing: 20) {
            AgentOrbAvatarView(agentState: .thinking, size: 80)
            AgentOrbAvatarView(agentState: .listening, size: 80)
            AgentOrbAvatarView(agentState: .speaking, audioLevel: 0.6, size: 80)
        }
    }
    .padding(40)
    .background(Color.black.opacity(0.9))
}
