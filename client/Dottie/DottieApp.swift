//
//  DottieApp.swift
//  Dottie
//
//  Created by Steve Derico on 6/29/25.
//

import SwiftUI
import AppKit
import AVFoundation
import Combine
import ApplicationServices

// MARK: - Menu Bar State
/// Represents the visual state of the menu bar status icon (idle, working, speaking, listening, starting, or error).
enum MenuBarState: Equatable {
    case idle       // Servers running, not processing
    case working    // Processing request
    case speaking   // Read Aloud / TTS playback
    case listening  // Hold-to-dictate recording
    case starting   // Servers starting up
    case error      // Server error state

    var tintColor: NSColor {
        switch self {
        case .idle: return .systemGray
        case .working, .speaking: return .systemBlue
        case .listening: return .systemRed
        case .starting: return .systemYellow
        case .error: return .systemRed
        }
    }
}

@main
struct DottieApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    AppDelegate.shared?.showSettingsWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

/// The main application delegate responsible for window management, server lifecycle,
/// notification observers, deep link handling, hotkey dispatch, and graceful shutdown.
class AppDelegate: NSObject, NSApplicationDelegate, HotKeyManagerDelegate {
    static var shared: AppDelegate?
    
    var statusItem: NSStatusItem?
    var settingsWindow: NSWindow?
    let appState = AppState()
    private let gateway = GatewayClient.shared
    let voiceWakeManager = VoiceWakeManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var hasAttemptedAutoStart = false // Add flag to prevent multiple auto-start attempts
    private var appearanceObservation: NSKeyValueObservation?
    private var menuBarState: MenuBarState = .idle
    private var pulseAnimationTimer: Timer?
    private var settingsObserver: NSObjectProtocol?  // Store observer for proper cleanup
    private var copyKeyMonitor: Any?
    /// True when this instance launched but discovered another Dottie was already
    /// running and is on its way to terminating self. We skip applicationWillTerminate's
    /// child-process cleanup in this case — those processes belong to the OTHER
    /// instance, and killing them ports leaves the user's running app with a dead
    /// gateway + 6-15s of "engine_down" chat failures while the supervisor respawns.
    private var isTerminatingAsDuplicate = false
    private var themeObserver: NSObjectProtocol?
    /// Latch guaranteeing the gateway-dependent startup steps (connect / load
    /// conversations / preload STT) run EXACTLY ONCE — whether triggered by the
    /// first AgentManager.$status == .running transition or by the timeout
    /// fallback. AgentManager.$status can flap .running → .stopped → .running
    /// (checkStatusIfStale, regenerateAgentToken's stop→start, adopt-vs-spawn
    /// emitting .running twice), so a plain sink would re-run preloadSTTModel and
    /// re-call connect() on every recovery. Guarded + read/written only on the
    /// main queue (both the sink and the timeout fallback hop to .main).
    private var didFireGatewayReadySteps = false
    /// Cancellable for the readiness sink. Torn down the instant it fires so the
    /// subscription itself cannot deliver a second .running value.
    private var gatewayReadyCancellable: AnyCancellable?
    /// True only after completeLaunch() finishes (past the upgrade + registration
    /// gates). applicationDidBecomeActive can fire before the gates clear (or on any
    /// activation while a gate window is up); we gate startServices + app_opened on
    /// this so an abandoned-at-gate activation never starts services or fires the
    /// greeting event.
    private var isLaunchComplete = false
    /// Last time applicationDidBecomeActive re-fired startServices — used to debounce
    /// rapid re-activations (see applicationDidBecomeActive).
    private var lastServicesEnsureAt: Date?
    /// The onboarding window, retained so showOnboarding() is idempotent — it can be
    /// called both immediately at launch (kill the blank-desktop wait) and later
    /// from the gateway-ready path without stacking two windows.
    private var onboardingWindow: NSWindow?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    /// Applies the user's theme preference to all app windows.
    private func applyTheme() {
        let savedTheme = UserDefaults.standard.string(forKey: DefaultsKeys.appColorScheme.rawValue) ?? "dark"
        let appearance: NSAppearance?

        switch savedTheme {
        case "light":
            appearance = NSAppearance(named: .aqua)
        case "dark":
            appearance = NSAppearance(named: .darkAqua)
        default:
            appearance = nil // System default
        }

        settingsWindow?.appearance = appearance
    }

    deinit {
        // Clean up distributed notification observer for single-instance enforcement
        DistributedNotificationCenter.default().removeObserver(self)

        // Clean up appearance observer
        appearanceObservation?.invalidate()

        // Clean up timers
        pulseAnimationTimer?.invalidate()
        pulseAnimationTimer = nil

        // Clean up observers
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
            settingsObserver = nil
        }
        if let observer = themeObserver {
            NotificationCenter.default.removeObserver(observer)
            themeObserver = nil
        }

        // Unregister hotkeys
        HotKeyManager.shared.unregisterGlobalHotKeys()

        // Clean up copy key monitor
        if let monitor = copyKeyMonitor {
            NSEvent.removeMonitor(monitor)
            copyKeyMonitor = nil
        }
    }


    /// Called after the application finishes launching. Creates all windows, registers hotkeys,
    /// sets up notification observers, starts servers, and shows the chat window.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Enforce single instance — activate existing and exit if already running
        let bundleID = Bundle.main.bundleIdentifier ?? "com.example.dottie"
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)

        if runningApps.count > 1 {
            // Another instance is running — activate it and terminate self
            for app in runningApps where app != NSRunningApplication.current {
                app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                // Post notification to show chat window in the existing instance
                DistributedNotificationCenter.default().post(
                    name: Notification.Name("com.example.dottie.showChatWindow"),
                    object: nil
                )
            }
            AppLogger.shared.info("[DottieApp] Another instance running, activating it and terminating self")
            isTerminatingAsDuplicate = true
            NSApp.terminate(nil)
            return
        }

        // Listen for show requests from duplicate instances that may try to launch
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleShowChatWindowFromOtherInstance),
            name: Notification.Name("com.example.dottie.showChatWindow"),
            object: nil
        )

        // Cloud-first: resolve an unset chat provider to xAI (Grok) when a key +
        // consent already exist. Must run before the gateway boots so the first
        // config push (and the supervisor's llama-skip decision) see the result.
        ChatProvider.resolveDefaultProviderIfUnset()

        // Append a File menu with Show Launcher to whatever NSApp.mainMenu SwiftUI installs.
        // SwiftUI's Scene machinery installs its own default menu after applicationDidFinishLaunching
        // returns, so we must observe didBecomeActive to run *after* the install and add our item.
        DispatchQueue.main.async { [weak self] in
            self?.ensureFileMenu()
            self?.retargetAboutMenuItem()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        // Clean up old recordings to prevent disk bloat
        cleanupOldRecordings()

        // Register defaults for keys read directly via UserDefaults.bool(forKey:)
        // (AppStorage's default param doesn't propagate until the user toggles).
        // metalOrbHue defaults to 200 (blue/cyan). Without registering it, an
        // absent key reads as 0.0 via UserDefaults.double(forKey:) → a red orb on
        // fresh install until the user touches the slider.
        UserDefaults.standard.register(defaults: [
            "metalOrbHue": 200.0,
            DefaultsKeys.appColorScheme.rawValue: "dark",
            // Floating desktop avatar defaults: Metal Orb on. register(defaults:)
            // only fills absent keys — existing user picks still win.
            DefaultsKeys.avatarStyle.rawValue: ModelDefaults.avatarStyle, // "metal"
            "floatingAvatarEnabled": true,
        ])

        setupCopyKeyMonitor()

        // Persistent floating avatar: restore on launch (the Settings toggle only
        // shows/hides it live; without this it vanished on relaunch). show() gates
        // itself on floatingAvatarEnabled, so this is a no-op when it's off.
        AvatarPanelManager.shared.show()

        // Warm the agent/gateway NOW, in parallel with the gates below. It has no
        // UI and takes the longest (gateway boot + engine spawn + model load), so
        // serializing it behind the /api/version round-trip (15s timeout) and the
        // registration form directly lengthened time-to-first-chat and widened
        // the "first send hits an unready gateway" window. completeLaunch()'s own
        // startAgent() call is a no-op when this one is already running (guard).
        AgentManager.shared.startAgent()

        // Gates first: upgrade check + registration. UI subsystems (status menu,
        // hotkeys, voice wake, etc.) do not initialize until both clear.
        checkVersionThenProceed()
    }

    /// Queries /api/version. If the user's build is below minimum_required, shows
    /// the blocking upgrade gate. Otherwise (success, timeout, or any error),
    /// falls through to registration — the upgrade gate fails open so a server
    /// outage never locks users out of the app.
    private func checkVersionThenProceed() {
        Task { [weak self] in
            do {
                let info = try await DottieAPIClient.shared.fetchVersion()
                // Cache the server's model list + default provider before the
                // upgrade branch, so remote config lands even on a gated build.
                RemoteConfig.store(info)
                let current = DottieAPIClient.appVersion
                let outdated = DottieAPIClient.versionLessThan(current, info.minimum_required)
                await MainActor.run {
                    if outdated {
                        AppLogger.shared.info("[DottieApp] Upgrade required: \(current) < \(info.minimum_required)")
                        Task.detached { await RegistrationManager.shared.bootstrapTokenIfNeeded() }
                        self?.showUpgradeGate(latestVersion: info.latest, downloadURL: info.download_url)
                    } else {
                        self?.proceedAfterUpgradeCheck()
                    }
                }
            } catch {
                AppLogger.shared.info("[DottieApp] Version check failed (fail-open): \(error)")
                await MainActor.run { self?.proceedAfterUpgradeCheck() }
            }
        }
    }

    /// Decides whether to gate on registration or continue to full init.
    private func proceedAfterUpgradeCheck() {
        Task.detached { await RegistrationManager.shared.bootstrapTokenIfNeeded() }
        if RegistrationManager.shared.hasSubmittedRegistration {
            completeLaunch()
        } else {
            showRegistration()
        }
    }

    /// Runs all the subsystems that can surface UI: status menu, windows, hotkeys,
    /// voice wake, gateway, agent, update checker, etc. Called either directly
    /// (user is already registered) or from the registration gate's onComplete.
    private func completeLaunch() {
        // Registration-abandoned launches skip this; force-upgrade launches
        // never reach completeLaunch (product stays gated).
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            if let icon = NSImage(named: "StatusIcon") {
                icon.size = NSSize(width: 16, height: 16)
                icon.isTemplate = true
                button.image = icon
            } else {
                // Fallback: use system icon if StatusIcon asset is missing
                button.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Dottie")
            }
            button.action = #selector(showStatusMenu)
            button.target = self
            // Right-click pops the dictation-stats menu; left-click keeps the
            // direct launcher/voice action.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Prewarm the launcher panel + its SwiftUI host off the critical path so
        // the FIRST Cmd+K doesn't pay hosting construction + first layout inline.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            LauncherManager.shared.prewarm()
        }
        
        // Create the settings window
        settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        settingsWindow?.title = "Settings"
        settingsWindow?.contentViewController = NSHostingController(rootView: SettingsView().environmentObject(appState))
        settingsWindow?.level = .normal
        settingsWindow?.isReleasedWhenClosed = false
        settingsWindow?.tabbingMode = .disallowed
        settingsWindow?.toolbar = nil
        settingsWindow?.titlebarSeparatorStyle = .none

        applyTheme()

        // Observe system appearance changes (for "system" theme mode)
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.applyTheme()
            }
        }

        // Observe theme changes from Settings
        themeObserver = NotificationCenter.default.addObserver(
            forName: .themeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyTheme()
        }

        // Register for Services
        NSApplication.shared.servicesProvider = self
        NSUpdateDynamicServices()  // Force macOS to refresh Services menu
        
        // Setup global hotkey
        HotKeyManager.shared.delegate = self
    
        HotKeyManager.shared.registerGlobalHotKeys()
        
        // Observe AppState and server status changes for menu bar updates
        observeMenuBarState()
        
        // Write session markers to all server log files
        writeSessionMarkers()

        // Start agent service (handles its own health checking and startup).
        // This is the AUTHORITATIVE readiness driver — performAgentStart() flips
        // AgentManager.$status to .running once the gateway on :1317 is healthy/adopted.
        AgentManager.shared.startAgent()

        // Drive the gateway-dependent startup steps off AgentManager.$status instead
        // of hardcoded wall-clock delays (the old +2s/+3s/+8s asyncAfter ladder), which
        // silently failed on slow first launches (npm install / cold model). See
        // observeGatewayReadiness() for the fire-once + timeout-fallback contract.
        observeGatewayReadiness()

        // Setup VoiceWake callback. NOT part of the readiness sink — VoiceWake uses
        // on-device SFSpeechRecognizer, not the :1317 gateway, so it must start
        // regardless of gateway health (its internal +5s is launch jitter only).
        setupVoiceWake()

        // Observer to show Settings from anywhere - store for cleanup
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .openSettingsWindow,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Check if a specific section was requested
            if let section = notification.userInfo?["section"] as? String {
                self?.appState.targetSettingsSection = section
            }
            self?.showSettingsWindow()
        }

        // First-run: no setup wizard. Silently default to Dottie Pro + female voice
        // and mark onboarding complete (permissions prompt when used).
        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            applyFirstRunDefaults()
        }

        // Check for app updates now, then every UpdateChecker.recheckInterval.
        UpdateChecker.shared.startPeriodicChecks()

        RealtimeClient.shared.connect()

        // Retry any unconfirmed registration from a prior launch.
        RegistrationManager.shared.retryIfNeeded()

        // Pro free-credit paywall: realtime/gateway errors post this; show
        // Subscribe / Own Key / Local instead of a silent hang.
        NotificationCenter.default.addObserver(
            forName: ProPaywall.freeCreditUsedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.showProFreeCreditPaywall()
        }

        // Launch is fully past the gates — applicationDidBecomeActive may now act.
        isLaunchComplete = true
    }

    /// Modal paywall when Dottie Pro free credit is exhausted.
    private func showProFreeCreditPaywall() {
        let alert = NSAlert()
        alert.messageText = ProPaywall.freeCreditTitle
        alert.informativeText = ProPaywall.freeCreditMessage
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Subscribe")
        alert.addButton(withTitle: "Use Own xAI Key")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            Task { await ProPaywall.openCheckout() }
        case .alertSecondButtonReturn:
            UserDefaults.standard.set(ChatProvider.xai.rawValue, forKey: DefaultsKeys.chatProvider.rawValue)
            NotificationCenter.default.post(name: .openSettingsWindow, object: nil, userInfo: ["section": "agent"])
        default:
            break
        }
    }

    /// Creates a borderless floating window hosting the registration gate.
    /// The window blocks app use until the user submits name + email.
    /// On submit the view calls submit() (local save + background POST) and
    /// invokes the onComplete callback which runs completeLaunch().
    func showRegistration() {
        AppLogger.shared.info("[DottieApp] Showing registration gate")
        let window = KeyableBorderlessWindow.makeFloating(size: NSSize(width: 500, height: 460))
        window.title = "Welcome to Dottie"

        let view = RegistrationView(window: window) { [weak self] in
            self?.completeLaunch()
        }
        let hosting = NSHostingController(rootView: view)
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentViewController = hosting

        window.centerOnMainScreen()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Creates a blocking floating window that prevents any further app use until
    /// the user downloads an update. Shown when /api/version says the current build
    /// is below minimum_required.
    func showUpgradeGate(latestVersion: String, downloadURL: String) {
        let window = KeyableBorderlessWindow.makeFloating(size: NSSize(width: 500, height: 260))
        window.title = "Update Required"
        let hosting = NSHostingController(
            rootView: UpgradeGateView(latestVersion: latestVersion, downloadURL: downloadURL, window: window)
        )
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentViewController = hosting

        window.centerOnMainScreen()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Handles show-window request from a duplicate instance attempting to launch.
    /// Honors the Default View preference (launcher by default).
    @objc private func handleShowChatWindowFromOtherInstance() {
        DispatchQueue.main.async { [weak self] in
            self?.showDefaultSurface()
        }
    }

    /// Called when the app becomes active (brought to foreground).
    /// Fires the `app_opened` event to trigger greeting if cooldown allows.
    func applicationDidBecomeActive(_ notification: Notification) {
        // Don't act before the upgrade + registration gates clear. Activations that
        // happen while a gate window is up (or before completeLaunch runs) must not
        // start services or fire app_opened.
        guard isLaunchComplete else { return }

        // Backstop: engines may have stopped while gateway kept running. Re-fire
        // startServices on activate — supervisor.startService adopts an already-running
        // process without respawning. Can't gate on systemStatus (lazily populated by
        // SSE/poll, goes stale when engines are stopped out-of-band). But debounce
        // rapid re-activations (window switching fires this repeatedly): each call
        // POSTs /system/start + polls, and when the gateway is briefly unreachable,
        // overlapping 60s probes stack. Skip if we fired within the last 15s.
        let now = Date()
        if let last = lastServicesEnsureAt, now.timeIntervalSince(last) < 15 {
            AppLogger.shared.debug("[DottieApp] applicationDidBecomeActive: services ensured \(Int(now.timeIntervalSince(last)))s ago — skipping re-fire")
        } else {
            lastServicesEnsureAt = now
            AppLogger.shared.info("[DottieApp] applicationDidBecomeActive: ensuring services are running")
            GatewayClient.shared.startServices()
        }

        // Fire app_opened event — trigger handles 4-hour cooldown
        GatewayClient.shared.fireEvent("app_opened", onChunk: { _ in
        }, onComplete: { _ in
            // Completion handled silently
        })
    }

    /// Appends a "File" menu with "Show Launcher" to `NSApp.mainMenu` if not already present.
    /// Idempotent — safe to call on every app activation to survive SwiftUI reinstalls.
    /// The menu item has no keyEquivalent because the launcher CGEventTap in HotKeyManager
    /// owns ⌘K and fires regardless of which window is key.
    private func ensureFileMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }

        // Guard against duplicates — our File menu already installed.
        let existing = mainMenu.items.first { item in
            item.submenu?.title == "File" || item.title == "File"
        }
        if existing != nil { return }

        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let showLauncherItem = NSMenuItem(
            title: "Show Launcher",
            action: #selector(showLauncherFromMenu),
            keyEquivalent: ""
        )
        showLauncherItem.target = self
        fileMenu.addItem(showLauncherItem)

        fileMenuItem.submenu = fileMenu

        // Insert after the app menu (index 0) so the order is App / File / ...
        let insertIndex = mainMenu.items.count >= 1 ? 1 : 0
        mainMenu.insertItem(fileMenuItem, at: insertIndex)
    }

    /// Re-ensures the File menu on every activation so SwiftUI can't drop it.
    @objc private func handleAppDidBecomeActive() {
        ensureFileMenu()
        retargetAboutMenuItem()
    }

    /// Replace the default About menu item's action so the panel shows
    /// "Version 2026.5.2.27" instead of "Version 2026.5.2.27 (2026.5.2.27)".
    /// Default selector `orderFrontStandardAboutPanel:` reads CFBundleShortVersionString
    /// for the marketing version and CFBundleVersion for the parens build number;
    /// we set both to the same CalVer so the parens look redundant. Pass an explicit
    /// `Version` option = "" to suppress the parens portion entirely.
    private func retargetAboutMenuItem() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return }
        let aboutSel = NSSelectorFromString("orderFrontStandardAboutPanel:")
        let customSel = #selector(showCustomAboutPanel(_:))
        for item in appMenu.items where item.action == aboutSel {
            item.target = self
            item.action = customSel
        }
    }

    @objc private func showCustomAboutPanel(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            NSApplication.AboutPanelOptionKey.version: ""
        ])
    }

    /// Deletes all audio recordings older than 24 hours to prevent disk bloat.
    /// Recordings can accumulate when transcription fails, the app crashes, or error paths skip cleanup.
    /// Note: there is no in-use guard — any wav with a modification time older than 24h is removed.
    private func cleanupOldRecordings() {
        let recordingsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dottie")
            .appendingPathComponent("recordings")

        guard FileManager.default.fileExists(atPath: recordingsDir.path) else { return }

        let cutoffDate = Date().addingTimeInterval(-24 * 60 * 60) // 24 hours ago
        var deletedCount = 0
        var deletedBytes: Int64 = 0

        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: recordingsDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: .skipsHiddenFiles
            )

            for file in files where file.pathExtension == "wav" {
                let attributes = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                if let modDate = attributes.contentModificationDate, modDate < cutoffDate {
                    let size = Int64(attributes.fileSize ?? 0)
                    try FileManager.default.removeItem(at: file)
                    deletedCount += 1
                    deletedBytes += size
                }
            }

            if deletedCount > 0 {
                let mbDeleted = Double(deletedBytes) / 1_000_000
                AppLogger.shared.info("[Cleanup] Deleted \(deletedCount) old recordings (\(String(format: "%.1f", mbDeleted)) MB)")
            }
        } catch {
            AppLogger.shared.error("[Cleanup] Failed to clean recordings: \(error)")
        }
    }

    /// Sets up a local keyboard monitor to intercept Cmd+C/V/X/A and manually perform
    /// edit operations on NSTextView instances. This bypasses SwiftUI's responder chain
    /// issues that prevent Edit menu actions from reaching NSTextViews.
    private func setupCopyKeyMonitor() {
        copyKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Check for Cmd key (no control/option modifiers)
            guard event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.control),
                  !event.modifierFlags.contains(.option),
                  let key = event.charactersIgnoringModifiers else {
                return event
            }

            // Find the first responder (must be NSTextView)
            guard let window = NSApp.keyWindow,
                  let textView = window.firstResponder as? NSTextView else {
                return event
            }

            switch key {
            case "c":
                // Copy - requires selection
                guard textView.selectedRange().length > 0 else { return event }
                let selectedText = (textView.string as NSString).substring(with: textView.selectedRange())
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(selectedText, forType: .string)
                return nil

            case "v":
                // Paste - requires editable text view
                guard textView.isEditable,
                      let pasteText = NSPasteboard.general.string(forType: .string) else {
                    return event
                }
                textView.insertText(pasteText, replacementRange: textView.selectedRange())
                return nil

            case "x":
                // Cut - requires selection and editable
                guard textView.isEditable, textView.selectedRange().length > 0 else { return event }
                let selectedText = (textView.string as NSString).substring(with: textView.selectedRange())
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(selectedText, forType: .string)
                textView.insertText("", replacementRange: textView.selectedRange())
                return nil

            case "a":
                // Select All
                textView.selectAll(nil)
                return nil

            default:
                return event
            }
        }
    }

    /// Configures the VoiceWake callback to start recording on wake word detection,
    /// and auto-starts listening if VoiceWake is enabled in settings.
    private func setupVoiceWake() {
        voiceWakeManager.onWakeWordDetected = { [weak self] in
            AppLogger.shared.debug("[DottieApp] Wake word detected - starting agent mode")
            self?.openDefaultInteraction()
        }

        // Auto-start listening if enabled. The first mic/HAL access in the
        // process is a multi-second CoreAudio cold init — paying it inside
        // startListening() on main was a measured 5s beachball at launch+5s.
        // Prewarm on a background queue, THEN start on main (sequential, so the
        // engine is never touched from two threads at once).
        if voiceWakeManager.isEnabled {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4.0) {
                self.voiceWakeManager.prewarmAudio()
                DispatchQueue.main.async {
                    self.voiceWakeManager.startListening()
                }
            }
        } else {
            // HAL cold init is process-wide — warm it with a throwaway engine
            // (no shared state, zero race) so the first PTT dictation
            // (GlobalRecorder, main thread) doesn't pay the multi-second cost.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4.0) {
                let warm = AVAudioEngine()
                _ = warm.inputNode.inputFormat(forBus: 0)
            }
        }
    }
    
    /// Subscribes to gateway status, processing, TTS, and dictation to drive menu bar icon updates.
    private func observeMenuBarState() {
        let ttsBusy = Publishers.CombineLatest(
            RealtimeClient.shared.$isPlayingTTS,
            RealtimeClient.shared.$isGeneratingTTS
        )
        .map { $0 || $1 }
        .eraseToAnyPublisher()

        Publishers.CombineLatest4(
            gateway.$systemStatus,
            appState.$isProcessing,
            ttsBusy,
            GlobalRecorder.shared.$isRecording
        )
        .sink { [weak self] systemStatus, isProcessing, isTTSBusy, isListening in
            DispatchQueue.main.async {
                self?.updateMenuBarState(
                    systemStatus: systemStatus,
                    isProcessing: isProcessing,
                    isTTSBusy: isTTSBusy,
                    isListening: isListening
                )
            }
        }
        .store(in: &cancellables)
    }

    /// Derives the new menu bar visual state from gateway status, processing, TTS, and dictation,
    /// then updates the status bar icon if the state changed.
    private func updateMenuBarState(
        systemStatus: SystemStatus,
        isProcessing: Bool,
        isTTSBusy: Bool = false,
        isListening: Bool = false
    ) {
        let newState: MenuBarState

        if isListening {
            newState = .listening
        } else if isTTSBusy {
            newState = .speaking
        } else if isProcessing {
            newState = .working
        } else if systemStatus == .degraded || systemStatus == .down {
            newState = .error
        } else if systemStatus == .starting || systemStatus == .unknown {
            newState = .starting
        } else {
            newState = .idle
        }

        if menuBarState != newState {
            menuBarState = newState
            updateStatusBarIcon()
        }
    }

    /// Updates the status bar button image and starts/stops pulse animation based on the current menu bar state.
    private func updateStatusBarIcon() {
        guard let button = statusItem?.button else { return }

        // Remove any existing subviews (like progress indicators)
        button.subviews.forEach { $0.removeFromSuperview() }

        switch menuBarState {
        case .listening:
            if let img = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Dottie — Listening") {
                img.isTemplate = true
                button.image = img
            }
            button.toolTip = "Dottie — Listening…"
            startPulseAnimation()
            return
        case .speaking:
            if let img = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Dottie — Speaking") {
                img.isTemplate = true
                button.image = img
            }
            button.toolTip = "Dottie — Speaking…"
            startPulseAnimation()
            return
        default:
            break
        }

        // Show icon (always template mode for system appearance)
        guard let icon = NSImage(named: "StatusIcon") else {
            // Fallback: use system icon if StatusIcon asset is missing
            button.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Dottie")
            stopPulseAnimation()
            return
        }
        icon.size = NSSize(width: 16, height: 16)
        icon.isTemplate = true
        button.image = icon
        button.toolTip = "Dottie"

        // Use pulse animation for working or starting states
        if menuBarState == .working || menuBarState == .starting {
            startPulseAnimation()
        } else {
            stopPulseAnimation()
        }
    }

    // MARK: - Menu Bar Animations
    private func startPulseAnimation() {
        guard let button = statusItem?.button, pulseAnimationTimer == nil else { return }

        // Ensure button has a layer for animation
        button.wantsLayer = true

        var fadeIn = true
        pulseAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let button = self?.statusItem?.button else { return }

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.5
                context.allowsImplicitAnimation = true
                button.animator().alphaValue = fadeIn ? 1.0 : 0.4
            }
            fadeIn.toggle()
        }
    }

    private func stopPulseAnimation() {
        pulseAnimationTimer?.invalidate()
        pulseAnimationTimer = nil

        // Reset alpha
        if let button = statusItem?.button {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                button.animator().alphaValue = 1.0
            }
        }
    }

    /// Single source of truth for gateway readiness. Subscribes to AgentManager.$status
    /// (the authoritative signal — performAgentStart flips it to .running once :1317 is
    /// healthy/adopted) and runs the gateway-dependent startup steps on the FIRST
    /// transition to .running. Replaces the old +2s/+3s/+8s asyncAfter ladder AND the
    /// 1s-interval pollUntilReady loop, which were two separate mechanisms guessing at
    /// readiness; both silently failed on a slow first launch (npm install / cold model).
    ///
    /// Fire-once: the sink is filtered to `.isRunning` and torn down (`gatewayReadyCancellable
    /// = nil`) the instant it fires, AND fireGatewayReadySteps() latches on
    /// `didFireGatewayReadySteps`. AgentManager.$status flaps (.running → .stopped →
    /// .running on checkStatusIfStale recovery, regenerateAgentToken's stop→start, and
    /// adopt-vs-spawn each emitting .running), so both guards are required to stop a
    /// second invocation from re-running preloadSTTModel / re-calling connect().
    ///
    /// Timeout fallback: a +60s deadline (matching the startServices waitForGatewayReady
    /// budget / first-time-setup adaptive timeout) calls fireGatewayReadySteps() so that a
    /// never-.running agent (npm install failure, missing llama binary, stuck port) still
    /// attempts connect() and degrades gracefully — preserving the old behavior where the
    /// literals fired unconditionally regardless of agent health. The latch makes whichever
    /// path wins first the only one that runs.
    private func observeGatewayReadiness() {
        gatewayReadyCancellable = AgentManager.shared.$status
            .filter { $0.isRunning }
            .prefix(1)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.fireGatewayReadySteps(reason: "agent .running")
            }

        // Timeout fallback — degrade gracefully if .running never arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60.0) { [weak self] in
            self?.fireGatewayReadySteps(reason: "60s timeout fallback")
        }
    }

    /// Runs the gateway-dependent startup steps exactly once. Idempotent via the
    /// `didFireGatewayReadySteps` latch — safe to call from both the readiness sink
    /// and the timeout fallback; whichever reaches it first wins, the other no-ops.
    /// Must be called on the main queue (both callers hop to .main).
    private func fireGatewayReadySteps(reason: String) {
        guard !didFireGatewayReadySteps else { return }
        didFireGatewayReadySteps = true
        gatewayReadyCancellable = nil  // tear down the sink so it can't deliver again

        AppLogger.shared.info("DottieApp: firing gateway-ready steps (\(reason))")

        // Ordering is load-bearing: connect() first (binds the health stream and runs
        // startServices() which warms STT/TTS), then load conversations (tolerant — has
        // its own 1/2/4/8/16/32s backoff), then preload STT (single-shot, no retry, so it
        // must run after startServices() has launched parakeet or it silently no-ops).
        gateway.connect()
        MessageStore.shared.loadConversationsFromAPI()
        GatewayClient.shared.preloadSTTModel { success in
            AppLogger.shared.info("STT model preload: \(success ? "success" : "failed")")
        }

        // Onboarding decision (the only unique side effect of the old pollUntilReady).
        // Keys off gateway.systemStatus (AgentManager liveness) — short poll rather
        // than firing synchronously here.
        evaluateOnboardingState()
    }

    /// Marks first-run complete once services are ready (no setup wizard UI).
    private func evaluateOnboardingState(attempt: Int = 0, maxAttempts: Int = 30) {
        if UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            if self.gateway.systemStatus == .ready || attempt >= maxAttempts {
                self.applyFirstRunDefaults()
                AppLogger.shared.info("DottieApp: first-run defaults applied (no setup wizard)")
                return
            }
            self.evaluateOnboardingState(attempt: attempt + 1, maxAttempts: maxAttempts)
        }
    }

    /// Silent first-run: Dottie Pro + female voice + floating Metal Orb defaults.
    /// No "Setting Up Dottie" window. Permissions prompt on first use.
    func applyFirstRunDefaults() {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: DefaultsKeys.chatProvider.rawValue) == nil {
            defaults.set(ChatProvider.dottiePro.rawValue, forKey: DefaultsKeys.chatProvider.rawValue)
            defaults.set(RemoteConfig.defaultCloudModel, forKey: DefaultsKeys.selectedCloudModel.rawValue)
            defaults.set(true, forKey: "cloudProviderConsent")
        }
        if defaults.string(forKey: "selectedVoice") == nil {
            defaults.set("af_heart", forKey: "selectedVoice")
        }
        defaults.set(true, forKey: "hasCompletedOnboarding")
        // Registration token for Pro (async, non-blocking).
        Task {
            await RegistrationManager.shared.bootstrapTokenIfNeeded()
            await MainActor.run {
                GatewayClient.shared.pushChatConfig()
            }
        }
        // Close any leftover wizard window from older builds / Settings.
        onboardingWindow?.close()
        onboardingWindow = nil
    }

    /// Settings "Run Wizard" / legacy entry — no UI; re-applies silent first-run defaults.
    func showOnboarding() {
        AppLogger.shared.info("DottieApp: showOnboarding → silent first-run defaults (wizard removed)")
        UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
        applyFirstRunDefaults()
    }

    /// Short human name for the active model: "grok-4-fast-non-reasoning"
    /// → "Grok 4 Fast Non Reasoning". Falls back to the raw id tail for
    /// unrecognized shapes.
    private var statusMenuModelName: String {
        let resolved = ConfigStore.shared.activeModel
        let id = resolved.isEmpty
            ? (UserDefaults.standard.string(forKey: DefaultsKeys.selectedCloudModel.rawValue) ?? "")
            : resolved
        guard !id.isEmpty else { return "No model selected" }
        let tail = (id.split(separator: "#").first.map(String.init) ?? id)
            .split(separator: "/").last.map(String.init) ?? id
        let cleaned = tail
            .replacingOccurrences(of: "-GGUF", with: "")
            .replacingOccurrences(of: "-it", with: "")
        return cleaned
            .split(separator: "-")
            .map { part -> String in
                guard let first = part.first else { return String(part) }
                return String(first).uppercased() + part.dropFirst()
            }
            .joined(separator: " ")
    }

    /// Chat readiness line. Chat is cloud-only, so the gateway (which proxies
    /// the provider) is the only thing that has to be up.
    private var statusMenuChatState: String {
        switch AgentManager.shared.status {
        case .running: return "Ready"
        case .starting: return "Starting…"
        case .stopping, .stopped: return "Stopped"
        case .error: return "Not ready"
        }
    }

    /// Status-item click (left or right): pops the dropdown with the dictation
    /// habit stats (one row: words today · this week — the streak mechanic),
    /// the active model + readiness, the app version, Open Dottie
    /// (the old direct launcher/voice action), Settings, and Quit. The menu is
    /// attached only for the duration of the click and rebuilt each time so the
    /// stats are always live.
    @objc func showStatusMenu() {
        let menu = NSMenu()
        // One combined dictation row (was two) — the freed row shows model status.
        let today = DictationStats.wordsToday
        let week = DictationStats.wordsThisWeek
        var dictation = "Dictated today: \(today) word\(today == 1 ? "" : "s")"
        if week > 0 {
            dictation += " · week: \(week)"
        }
        menu.addItem(NSMenuItem(title: dictation, action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "\(statusMenuModelName) — \(statusMenuChatState)", action: nil, keyEquivalent: ""))
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        menu.addItem(NSMenuItem(title: "Dottie \(version)", action: nil, keyEquivalent: ""))
        // Refresh the cached service state so the next open shows live status.
        Task { await GatewayClient.shared.pollStatus() }
        menu.addItem(.separator())
        // Always-on voice call: local session stays up; Grok Voice Agent (if on)
        // still only bills while speech is active (3s idle hangup).
        let voiceOn = RealtimeClient.shared.conversationState != .inactive
        let voice = NSMenuItem(
            title: "Voice Session",
            action: #selector(toggleVoiceSessionFromMenu),
            keyEquivalent: ""
        )
        voice.target = self
        voice.state = voiceOn ? .on : .off
        menu.addItem(voice)
        let open = NSMenuItem(title: "Open Dottie", action: #selector(openDefaultInteraction), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettingsWindow), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        let update = NSMenuItem(
            title: UpdateChecker.shared.updateAvailable
                ? "Update To \(UpdateChecker.shared.latestVersion ?? "Latest")…"
                : "Check For Updates…",
            action: #selector(checkForUpdatesFromMenu),
            keyEquivalent: ""
        )
        update.target = self
        menu.addItem(update)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Dottie", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    /// Menu-bar "Check For Updates…". Re-opens the prompt immediately when an update
    /// is already known, otherwise refetches and reports the result either way.
    @objc func checkForUpdatesFromMenu() {
        if UpdateChecker.shared.updateAvailable, let version = UpdateChecker.shared.latestVersion {
            UpdatePrompt.recordPrompted(version)
            MainActor.assumeIsolated { UpdatePromptWindow.present(version: version) }
            return
        }
        UpdateChecker.shared.checkForUpdate(userInitiated: true)
    }

    /// Menu-bar enable/disable for full-duplex conversation (same as hotkey / avatar).
    @objc func toggleVoiceSessionFromMenu() {
        conversationModePressed()
    }

    /// Opens the launcher (text default) or the avatar + full-duplex conversation
    /// (voice default) — the pre-menu status-item click behavior.
    @objc func openDefaultInteraction() {
        let defaultInteraction = UserDefaults.standard.string(forKey: "defaultInteraction") ?? "voice"
        if defaultInteraction == "text" {
            LauncherManager.shared.show()
        } else {
            AvatarPanelManager.shared.show()
            conversationModePressed()
        }
    }
    
    /// Shows the launcher — the app's single chat surface. Used by the generic
    /// app-open paths (dock-icon reopen, duplicate-instance relaunch).
    @objc func showDefaultSurface() {
        LauncherManager.shared.show()
    }

    /// Shows the Spotlight-style launcher from the File menu.
    @objc func showLauncherFromMenu() {
        AppLogger.shared.info("showLauncherFromMenu - showing launcher")
        LauncherManager.shared.show()
    }

    @objc func showSettingsWindow() {
        if let window = settingsWindow {
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    /// Initiates a graceful shutdown: stops all services, kills port processes, then terminates the app.
    @objc func quitApp() {
        AppLogger.shared.info("[DottieApp] Quit initiated - stopping all services")

        // Clean up UI resources first
        pulseAnimationTimer?.invalidate()
        pulseAnimationTimer = nil

        // Unregister hotkeys
        HotKeyManager.shared.unregisterGlobalHotKeys()

        // Stop VoiceWake listening
        voiceWakeManager.stopListening()

        // Gateway architecture: disconnect stops all managed services (audio, llm, store)
        AppLogger.shared.info("[DottieApp] Disconnecting gateway (stops all services)...")
        gateway.disconnect()

        // Stop agent service (not managed by gateway supervisor)
        AgentManager.shared.stopAgent()

        // Use semaphore to wait for graceful shutdown
        DispatchQueue.global(qos: .userInitiated).async {
            // Wait for server to stop (up to 2 seconds)
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 2.5)

            // Force kill any remaining processes on specific ports
            DispatchQueue.main.async {
                self.killProcessesOnPorts()

                // Terminate after cleanup
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    AppLogger.shared.info("[DottieApp] Terminating application")
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Duplicate-instance termination: bail before any cleanup. We never set
        // up gateway/agent/services in this code path (the duplicate check is
        // first in applicationDidFinishLaunching), and any port-kill we do here
        // would tear down the OTHER instance's running services — which is
        // exactly the bug that surfaced as "engine_down" chat death right after
        // a stray dock-icon double-click.
        if isTerminatingAsDuplicate {
            AppLogger.shared.info("[DottieApp] Duplicate instance terminating — skipping cleanup")
            return
        }

        AppLogger.shared.info("[DottieApp] Application will terminate - final cleanup")

        // Flush any pending conversation syncs before shutdown
        MessageStore.shared.flushPendingSyncs()

        // Clean up timers
        pulseAnimationTimer?.invalidate()
        pulseAnimationTimer = nil

        // Unregister hotkeys
        HotKeyManager.shared.unregisterGlobalHotKeys()

        // Stop VoiceWake listening
        voiceWakeManager.stopListening()

        // Fire app_closed event before agent shuts down
        GatewayClient.shared.fireEventSilent("app_closed")

        // Gateway architecture: final disconnect (stops audio, llm, store)
        gateway.disconnect()

        // Stop agent service (not managed by gateway supervisor)
        AgentManager.shared.stopAgent()

        // Force kill processes on specific ports
        killProcessesOnPorts()
    }

    /// Force-kills any processes listening on all managed server ports.
    private func killProcessesOnPorts() {
        AppLogger.shared.info("[DottieApp] Force killing processes on ports \(AppPorts.ttsServer), \(AppPorts.audioServer), \(AppPorts.agentServer)")

        // TTS (1314), STT (1315), gateway (1317).
        let ports = ["\(AppPorts.ttsServer)", "\(AppPorts.audioServer)", "\(AppPorts.agentServer)"]
        
        for port in ports {
            AppLogger.shared.debug("[DottieApp] Killing processes on port \(port)")
            
            // Use lsof to find processes LISTENING on the port, then kill them.
            // -sTCP:LISTEN avoids killing unrelated processes with client connections.
            let lsofProcess = Process()
            lsofProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            lsofProcess.arguments = ["-ti", "TCP:\(port)", "-sTCP:LISTEN"]
            
            let pipe = Pipe()
            lsofProcess.standardOutput = pipe
            lsofProcess.standardError = Pipe()
            
            do {
                try lsofProcess.run()
                lsofProcess.waitUntilExit()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                
                if !output.isEmpty {
                    let pids = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
                    
                    for pid in pids {
                        AppLogger.shared.debug("[DottieApp] Killing process \(pid) on port \(port)")
                        let killProcess = Process()
                        killProcess.executableURL = URL(fileURLWithPath: "/bin/kill")
                        killProcess.arguments = ["-9", pid]
                        do {
                            try killProcess.run()
                            killProcess.waitUntilExit()
                        } catch {
                            AppLogger.shared.error("[DottieApp] Error killing process \(pid): \(error)")
                        }
                    }
                } else {
                    AppLogger.shared.debug("[DottieApp] No processes found on port \(port)")
                }
            } catch {
                AppLogger.shared.error("[DottieApp] Error finding processes on port \(port): \(error)")
            }
        }

        // Additional cleanup for other server patterns
        let processPatterns = [
            "mcp-stdio.js", 
            "python.*server.*1315"
        ]
        
        for pattern in processPatterns {
            AppLogger.shared.debug("[DottieApp] Killing processes matching pattern: \(pattern)")
            let killProcess = Process()
            killProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            killProcess.arguments = ["-f", pattern]
            do {
                try killProcess.run()
                killProcess.waitUntilExit()
            } catch {
                AppLogger.shared.error("[DottieApp] Error killing processes matching \(pattern): \(error)")
            }
        }
    }
    
    // MARK: - Session Markers

    /// Appends a session start marker to all server log files.
    /// Lets the log viewer show where the current session began.
    private func writeSessionMarkers() {
        let marker = "\n━━━ SESSION START [\(Date())] ━━━\n"
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dottie/logs")
        // app.log is NOT in this list — AppLogger.init already stamps its own
        // SESSION START there; a second marker read as a phantom self-relaunch.
        let logFiles = [
            "gateway.log",
            "talk.log",
            "macuse.log",
        ]

        guard let data = marker.data(using: .utf8) else { return }
        for name in logFiles {
            let path = logsDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            do {
                let handle = try FileHandle(forWritingTo: path)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                AppLogger.warn("[DottieApp] failed to write session marker to \(name): \(error)")
            }
        }
    }

    // MARK: - HotKeyManagerDelegate
    /// Starts push-to-type cursor mode recording when the clipboard listen key is pressed.
    func clipboardListenKeyPressed() {
        AppLogger.shared.info("clipboardListenKeyPressed - starting cursor mode")
        appState.recordingRequested = true
        appState.isHoldToTalkRecording = true
        GlobalRecorder.shared.startRecording(mode: .cursorMode)
    }

    /// Stops cursor mode recording when the clipboard listen key is released.
    func clipboardListenKeyReleased() {
        AppLogger.shared.info("clipboardListenKeyReleased - stopping cursor mode")
        GlobalRecorder.shared.stopRecording()
        // Reset flag after a delay to ensure transcription uses it
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            self.appState.isHoldToTalkRecording = false
        }
    }

    /// Speaks selected text: AX selection first, then clipboard; terminals never get synthetic Cmd+C.
    func speakSelectedTextPressed() {
        AppLogger.shared.info("Speak Selected Text shortcut pressed")

        // Second tap stops Read Aloud (same idea as talk-keys stop).
        if RealtimeClient.shared.isPlayingTTS || RealtimeClient.shared.isGeneratingTTS {
            AppLogger.shared.info("Speak shortcut — stopping TTS")
            RealtimeClient.shared.stopTTS()
            return
        }

        if let ax = axSelectedTextForSpeak() {
            speakSelectedText(ax, via: "AX")
            return
        }

        let pasteboard = NSPasteboard.general
        let savedString = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Terminals (Warp/Ghostty/…): never Cmd+C — it clobbers agent "Copied" pasteboards.
        if isTerminalFrontmostForSpeak() {
            if !isJunkSpeakText(savedString) {
                speakSelectedText(savedString, via: "clip")
                return
            }
            AppLogger.shared.info("No text selected to speak (terminal)")
            NSSound(named: "Funk")?.play()
            return
        }

        let savedChangeCount = pasteboard.changeCount

        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            AppLogger.shared.error("Failed to create CGEventSource for Cmd+C")
            NSSound(named: "Funk")?.play()
            return
        }

        let cKeyCode: CGKeyCode = 8  // C key
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: false) else {
            AppLogger.shared.error("Failed to create CGEvent for Cmd+C")
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        // Prefer front app pid so Cmd+C doesn't hit Dottie.
        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            keyDown.postToPid(app.processIdentifier)
            usleep(10000)
            keyUp.postToPid(app.processIdentifier)
        } else {
            keyDown.post(tap: .cghidEventTap)
            usleep(10000)
            keyUp.post(tap: .cghidEventTap)
        }

        func processSelection() {
            let clipboardChanged = pasteboard.changeCount != savedChangeCount
            let copiedText = (pasteboard.string(forType: .string) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if clipboardChanged {
                pasteboard.clearContents()
                if !savedString.isEmpty {
                    pasteboard.setString(savedString, forType: .string)
                }
            }

            let textToSpeak = clipboardChanged ? copiedText : savedString
            guard !isJunkSpeakText(textToSpeak) else {
                AppLogger.shared.info("No text selected to speak")
                NSSound(named: "Funk")?.play()
                return
            }

            speakSelectedText(textToSpeak, via: clipboardChanged ? "copied" : "clip")
        }

        let pollStart = Date()
        func pollForSelection() {
            if pasteboard.changeCount != savedChangeCount || Date().timeIntervalSince(pollStart) >= 0.25 {
                processSelection()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { pollForSelection() }
            }
        }
        pollForSelection()
    }

    private func speakSelectedText(_ text: String, via: String) {
        AppLogger.shared.info("Speaking selected text via \(via) (\(text.count) chars)")
        RealtimeClient.shared.speakText(text, onComplete: { success in
            if !success {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Read Aloud Failed"
                    alert.informativeText = "Could not generate audio. Check that the audio server is running."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        })
    }

    /// AX selected text in the frontmost app (skips URL-only / huge dumps).
    private func axSelectedTextForSpeak() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let el = unsafeBitCast(focused, to: AXUIElement.self)
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &selected) == .success
        else { return nil }
        let s = (selected as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if s.isEmpty || isJunkSpeakText(s) { return nil }
        // Full-control dump: selection equals entire value and is long.
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value) == .success,
           let v = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           v == s, s.count > 80
        {
            return nil
        }
        return s
    }

    private func isTerminalFrontmostForSpeak() -> Bool {
        switch NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
        case "com.mitchellh.ghostty",
             "dev.warp.Warp-Stable",
             "dev.warp.Warp",
             "com.googlecode.iterm2",
             "com.apple.Terminal",
             "net.kovidgoyal.kitty",
             "com.github.wez.wezterm",
             "org.alacritty":
            return true
        default:
            return false
        }
    }

    private func isJunkSpeakText(_ s: String) -> Bool {
        if s.isEmpty { return true }
        if s.count > 4000 { return true }
        if s.contains(where: \.isWhitespace) { return false }
        return s.hasPrefix("http://") || s.hasPrefix("https://")
    }

    /// Toggles full-duplex conversation mode (Grok Voice experience).
    func conversationModePressed() {
        AppLogger.shared.info("conversationModePressed - toggling conversation")
        RealtimeClient.shared.toggleConversation()
    }

    /// Toggles the Spotlight-style launcher panel.
    func launcherShortcutPressed() {
        AppLogger.shared.info("launcherShortcutPressed - toggling launcher")
        LauncherManager.shared.toggle()
    }

    func escapePressed() {
        AppLogger.shared.info("ESC pressed - universal stop")

        // Hide launcher if visible
        if LauncherManager.shared.isVisible {
            AppLogger.shared.info("Hiding launcher")
            LauncherManager.shared.hide()
            return
        }

        // Abort any active recording (push-to-type, agent mode, voice wake).
        // ESC must CANCEL, not stop: stopRecording() transcribes + pastes the
        // partial dictation at the cursor, which is exactly what the user is
        // trying to avoid by hitting ESC. cancelRecording() aborts cleanly with
        // no transcription/paste.
        if GlobalRecorder.shared.isRecording {
            AppLogger.shared.info("Cancelling active recording")
            GlobalRecorder.shared.cancelRecording()
        }

        // If one-shot dictation is armed (user said "start dictation" and we're
        // waiting for the utterance to paste), ESC cancels JUST the dictation and
        // keeps the conversation alive — the user resumes normal voice with no
        // dictated paste. This must run before the conversation-stop tier below so
        // a mistaken arm doesn't tear down the whole conversation.
        if AgentStateCoordinator.shared.dictationActive
            && RealtimeClient.shared.conversationState != .inactive {
            AppLogger.shared.info("Cancelling pending dictation (conversation stays active)")
            RealtimeClient.shared.cancelDictation()
            return
        }

        // ESC behavior in conversation mode is two-tiered: if Dottie is currently
        // speaking, ESC interrupts the response (stops TTS, sends input.interrupt
        // server-side) without ending the conversation — so the user can cut Dottie
        // off and immediately speak their next turn. ESC at any other conversation
        // state ends the conversation entirely. Without this split, users on
        // hardware where AEC barge-in doesn't work (multi-channel outputs like
        // Apple Studio Display) had no way to interrupt at all.
        if RealtimeClient.shared.conversationState == .assistantSpeaking {
            AppLogger.shared.info("Interrupting assistant speech (conversation stays active)")
            RealtimeClient.shared.stopTTS()
        } else if RealtimeClient.shared.conversationState != .inactive {
            AppLogger.shared.info("Stopping conversation mode")
            RealtimeClient.shared.stopConversation()
        }

        // Always stop TTS — covers playback, generation, and stuck states
        RealtimeClient.shared.stopTTS()

        // Reset hold-to-talk state
        appState.isHoldToTalkRecording = false
    }


    @objc func generateAudioFromService(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        AppLogger.info("generateAudioFromService called - TTS from right-click menu")

        guard let text = pboard.string(forType: .string), !text.isEmpty else {
            error.pointee = "No text selected" as NSString
            return
        }

        // Force hide the launcher - services can activate the app
        LauncherManager.shared.hide()

        RealtimeClient.shared.speakText(text, onComplete: { _ in
        })
    }
    
    @objc func stopAudioFromService(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        AppLogger.info("stopAudioFromService called")
        RealtimeClient.shared.stopTTS()
    }

    // MARK: - Dock Icon Click Handler
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppLogger.info("Dock icon clicked - hasVisibleWindows: \(flag)")

        // Show the user's chosen default surface (launcher by default) on dock reopen.
        showDefaultSurface()

        return true
    }
}
