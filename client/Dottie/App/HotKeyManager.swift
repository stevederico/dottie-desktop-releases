//
//  HotKeyManager.swift
//  Dottie
//
//  Created by Steve Derico on 6/29/25.
//  Updated 7/6/25 – Carbon-only Cmd+Shift+E + Caps Lock (Voice Mode)
//  Updated 1/25/26 – Spacebar hold-to-talk
//  Updated 1/25/26 – Remappable activation key
//  Updated 1/27/26 – Changed Read Aloud from Cmd+Shift+R to Cmd+Shift+E
//  Updated 1/27/26 – Added Option key hold (300ms) for Read Aloud
//  Updated 2/7/26 – Added Option+Space as default activation key
//  Updated 2/7/26 – ESC is universal stop for all recording modes
//  Updated 2/7/26 – Simplified to push-to-type only (no voice mode toggle)
//  Updated 2/9/26 – Added configurable Speak Selected Text shortcut
//

import Foundation
import AppKit

// MARK: - Speak Shortcut Options

/// Configurable keyboard shortcuts for the "Speak Selected Text" TTS feature.
enum SpeakShortcut: String, CaseIterable, Identifiable {
    case rightOption = "rightOption"
    case rightControl = "rightControl"
    case controlSpace = "controlSpace"
    case cmdShiftS = "cmdShiftS"
    case cmdShiftR = "cmdShiftR"
    case none = "none"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rightOption: return "Right Option (⌥)"
        case .rightControl: return "Right Control (⌃)"
        case .controlSpace: return "⌃Space"
        case .cmdShiftS: return "⌘⇧S"
        case .cmdShiftR: return "⌘⇧R"
        case .none: return "Disabled"
        }
    }

    /// The virtual keycode for the key in the shortcut.
    var keyCode: Int64 {
        switch self {
        case .rightOption: return 61   // Right Option
        case .rightControl: return 62  // Right Control
        case .controlSpace: return 49  // Space
        case .cmdShiftS: return 1      // S
        case .cmdShiftR: return 15     // R
        case .none: return -1
        }
    }

    /// Whether this shortcut is a modifier key (detected via flagsChanged, not keyDown).
    var isModifier: Bool {
        self == .rightOption || self == .rightControl
    }

    /// Whether the shortcut requires Cmd+Shift modifiers (vs Control).
    var isControlCombo: Bool {
        self == .controlSpace
    }
}

// MARK: - Agent Shortcut Options

/// Configurable keyboard shortcuts for toggling agent mode recording.
enum AgentShortcut: String, CaseIterable, Identifiable {
    case fn = "fn"
    case cmdShiftA = "cmdShiftA"
    case cmdShiftD = "cmdShiftD"
    case none = "none"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fn: return "Fn"
        case .cmdShiftA: return "⌘⇧A"
        case .cmdShiftD: return "⌘⇧D"
        case .none: return "Disabled"
        }
    }

    /// The virtual keycode for the key in the shortcut.
    var keyCode: Int64 {
        switch self {
        case .fn: return 63
        case .cmdShiftA: return 0   // A
        case .cmdShiftD: return 2   // D
        case .none: return -1
        }
    }

    /// Whether this shortcut is a modifier key (detected via flagsChanged, not keyDown).
    var isModifier: Bool {
        self == .fn
    }
}

// MARK: - Launcher Shortcut Options

/// Configurable keyboard shortcuts for the Spotlight-style launcher.
enum LauncherShortcut: String, CaseIterable, Identifiable {
    case cmdShiftSpace = "cmdShiftSpace"
    case cmdK = "cmdK"
    case cmdP = "cmdP"
    case none = "none"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cmdShiftSpace: return "⌘⇧Space"
        case .cmdK: return "⌘K"
        case .cmdP: return "⌘P"
        case .none: return "Disabled"
        }
    }

    /// The virtual keycode for the key in the shortcut.
    var keyCode: Int64 {
        switch self {
        case .cmdShiftSpace: return 49  // Space
        case .cmdK: return 40           // K
        case .cmdP: return 35           // P
        case .none: return -1
        }
    }

    /// Whether the shortcut requires Shift modifier (Cmd+Shift+Space).
    var requiresShift: Bool {
        self == .cmdShiftSpace
    }
}

// MARK: - Activation Key Options

/// Configurable activation keys for push-to-type dictation.
/// Each key type has different detection mechanisms: combo keys use CGEvent taps with modifier checks,
/// modifier keys use `NSEvent.flagsChanged` monitors, and regular keys use CGEvent taps on keyDown/keyUp.
enum ActivationKey: String, CaseIterable, Identifiable {
    case optionSpace = "optionSpace"
    case spacebar = "spacebar"
    case rightOption = "rightOption"
    case rightCommand = "rightCommand"
    case rightControl = "rightControl"
    case fn = "fn"
    case tab = "tab"
    case capsLock = "capsLock"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .optionSpace: return "Option + Space (⌥ Space)"
        case .spacebar: return "Spacebar"
        case .rightOption: return "Right Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .rightControl: return "Right Control (⌃)"
        case .fn: return "Fn"
        case .tab: return "Tab"
        case .capsLock: return "Caps Lock"
        }
    }

    /// The virtual keycode used by CGEvent to identify this key.
    var keyCode: Int64 {
        switch self {
        case .optionSpace: return 49  // Space keycode (Option is checked via modifier)
        case .spacebar: return 49
        case .rightOption: return 61  // Right Option
        case .rightCommand: return 54 // Right Command
        case .rightControl: return 62 // Right Control
        case .fn: return 63           // Fn key
        case .tab: return 48
        case .capsLock: return 57
        }
    }

    /// Whether this key is a modifier detected via `flagsChanged` rather than `keyDown`/`keyUp`.
    var isModifier: Bool {
        switch self {
        case .rightOption, .rightCommand, .rightControl, .fn, .capsLock:
            return true
        case .optionSpace, .spacebar, .tab:
            return false
        }
    }

    /// Whether this key requires a modifier+key combination (e.g., Option+Space).
    var isComboKey: Bool {
        switch self {
        case .optionSpace:
            return true
        default:
            return false
        }
    }
}

/// Manages global keyboard shortcuts for push-to-type dictation, speak-selected-text,
/// and agent mode activation. Uses CGEvent taps and NSEvent monitors depending on the
/// configured activation key type. Requires macOS accessibility permission.
final class HotKeyManager: ObservableObject {
    static let shared = HotKeyManager()

    private let escapeKeyCode: Int64 = 53  // ESC key

    // Fn key state tracking (to avoid double-trigger on press+release)
    private var wasFnPressed: Bool = false

    // Local event monitor for Fn key (global monitors don't reliably catch Fn)
    private var fnLocalMonitor: Any?

    // Accessibility permission tracking
    @Published var accessibilityPermissionGranted: Bool = false

    // Configurable activation key
    @Published var activationKey: ActivationKey {
        didSet {
            UserDefaults.standard.set(activationKey.rawValue, forKey: "activationKey")
            // Re-register with new key
            if eventTap != nil || modifierMonitor != nil {
                unregisterGlobalHotKeys()
                registerGlobalHotKeys()
            }
        }
    }

    // Configurable speak selected text shortcut
    @Published var speakShortcut: SpeakShortcut {
        didSet {
            UserDefaults.standard.set(speakShortcut.rawValue, forKey: "speakShortcutKey")
            // Re-register to pick up new shortcut
            if eventTap != nil || modifierMonitor != nil {
                unregisterGlobalHotKeys()
                registerGlobalHotKeys()
            }
        }
    }

    // Configurable agent mode shortcut
    @Published var agentShortcut: AgentShortcut {
        didSet {
            UserDefaults.standard.set(agentShortcut.rawValue, forKey: "agentShortcutKey")
            // Re-register to pick up new shortcut
            if eventTap != nil || modifierMonitor != nil {
                unregisterGlobalHotKeys()
                registerGlobalHotKeys()
            }
        }
    }

    // Configurable launcher shortcut
    @Published var launcherShortcut: LauncherShortcut {
        didSet {
            UserDefaults.standard.set(launcherShortcut.rawValue, forKey: "launcherShortcutKey")
            // Re-register to pick up new shortcut
            if eventTap != nil || modifierMonitor != nil {
                unregisterGlobalHotKeys()
                registerGlobalHotKeys()
            }
        }
    }

    // Hold-to-talk tracking
    private var isKeyHeld = false
    private var keyPressTime: Date?
    private var isSpeakKeyHeld = false
    private var speakKeyPressTime: Date?
    private var speakKeyComboUsed = false
    /// Fixed 100ms hold before push-to-talk dictation arms. Previously user-tunable
    /// (Settings → Voice → Hold Duration); now a constant — a short, predictable
    /// debounce that filters accidental taps without a setting to manage.
    let holdThreshold: Double = 0.1
    private var holdTimer: Timer?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var modifierMonitor: Any?
    private var modifierLocalMonitor: Any?
    private var fnGlobalMonitor: Any?
    private var permissionPollTimer: Timer?

    // Dedicated launcher shortcut tap — runs regardless of activation key mode, so
    // Cmd+K / Cmd+Shift+Space / Cmd+P always works even when the activation key is a
    // modifier (rightOption, rightCommand, fn, capsLock) that doesn't use a CGEvent tap.
    private var launcherEventTap: CFMachPort?
    private var launcherRunLoopSource: CFRunLoopSource?

    weak var delegate: HotKeyManagerDelegate?

    private init() {
        // Load saved activation key. Default: Right Command — it exists on EVERY
        // Apple keyboard. The old Right Control default was unusable on MacBooks
        // (built-in laptop keyboards have no right Control key), so the first-run
        // "hold Right Control and say something" prompt pointed at a key that
        // wasn't there. Users who explicitly picked a key keep it.
        if let savedKey = UserDefaults.standard.string(forKey: "activationKey"),
           let key = ActivationKey(rawValue: savedKey) {
            self.activationKey = key
        } else {
            self.activationKey = .rightCommand
        }

        // Load saved speak shortcut (default: Right Option)
        if let savedSpeak = UserDefaults.standard.string(forKey: "speakShortcutKey"),
           let key = SpeakShortcut(rawValue: savedSpeak) {
            self.speakShortcut = key
        } else {
            self.speakShortcut = .rightOption
        }

        // Load saved agent shortcut (default: Fn)
        if let savedAgent = UserDefaults.standard.string(forKey: "agentShortcutKey"),
           let key = AgentShortcut(rawValue: savedAgent) {
            self.agentShortcut = key
        } else {
            self.agentShortcut = .fn
        }

        // Load saved launcher shortcut (default: Cmd+K)
        if let savedLauncher = UserDefaults.standard.string(forKey: "launcherShortcutKey"),
           let key = LauncherShortcut(rawValue: savedLauncher) {
            self.launcherShortcut = key
        } else {
            self.launcherShortcut = .cmdK
        }

        // Check initial accessibility permission
        checkAccessibilityPermission()
    }

    deinit {
        // Clean up all timers and monitors to prevent resource leaks
        holdTimer?.invalidate()
        holdTimer = nil

        permissionPollTimer?.invalidate()
        permissionPollTimer = nil

        // Unregister all hotkeys and monitors
        unregisterGlobalHotKeys()
    }

    // MARK: - Accessibility Permission

    /// Checks whether the app has macOS accessibility permission without prompting the user.
    func checkAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        accessibilityPermissionGranted = AXIsProcessTrustedWithOptions(options)
    }

    /// Triggers the macOS accessibility permission prompt and begins polling for approval.
    /// Brings the Settings window back to front after the system dialog appears.
    func requestAccessibilityPermission() {
        // This will show the system prompt asking user to grant permission
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        // Start polling to detect when user grants permission
        startPermissionPolling()

        // Bring settings window back to front after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.title == "Settings" {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Opens System Settings to the Accessibility > Privacy pane and begins polling for permission changes.
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
            startPermissionPolling()
        }
    }

    /// Polls every 2 seconds for accessibility permission approval, then auto-registers hotkeys once granted.
    func startPermissionPolling() {
        stopPermissionPolling()
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.checkAccessibilityPermission()
            guard self.accessibilityPermissionGranted else { return }
            self.stopPermissionPolling()
            self.registerGlobalHotKeys()
            // registerGlobalHotKeys() may fail to create the CGEvent tap if permission was
            // revoked in the TOCTOU window between the poll-check above and tap creation. Without
            // recovery the hotkeys stay dead until app relaunch, so re-check and resume polling.
            self.checkAccessibilityPermission()
            if !self.accessibilityPermissionGranted {
                self.startPermissionPolling()
            }
        }
    }

    /// Stops the accessibility permission polling timer.
    func stopPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    // MARK: - Public

    /// Tears down existing monitors and re-registers global hotkeys based on the current activation key configuration.
    func registerGlobalHotKeys() {
        unregisterGlobalHotKeys()
        setupActivationKeyMonitor()
        setupFnKeyMonitor()
        setupLauncherShortcutTap()
    }

    /// Sets up both local and global event monitors for Fn/Globe key when agent shortcut is Fn.
    /// On newer Macs, the globe key (keyCode 63) may not set .function flag reliably.
    private func setupFnKeyMonitor() {
        guard agentShortcut == .fn else { return }

        // Local monitor for when app is focused (flags + keyDown for ESC)
        fnLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            if event.type == .keyDown && event.keyCode == 53 {
                AppLogger.shared.info("[HotKeyManager] ESC pressed - universal stop (local)")
                DispatchQueue.main.async { self?.delegate?.escapePressed() }
                return event
            }
            self?.handleFnEvent(event)
            self?.handleSpeakModifierEvent(event)
            return event
        }

        // Global monitor for when app is not focused (flags + keyDown for ESC)
        fnGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            if event.type == .keyDown && event.keyCode == 53 {
                AppLogger.shared.info("[HotKeyManager] ESC pressed - universal stop (global)")
                DispatchQueue.main.async { self?.delegate?.escapePressed() }
                return
            }
            self?.handleFnEvent(event)
            self?.handleSpeakModifierEvent(event)
        }

        AppLogger.shared.info("[HotKeyManager] Fn/Globe key monitor enabled for agent mode")
    }

    /// Handles Fn/Globe key events from either local or global monitor.
    private func handleFnEvent(_ event: NSEvent) {
        // Arrow keys (123-126) and other function keys carry .function modifier flag —
        // must check keyCode == 63 to distinguish actual Fn/Globe key presses
        let fnPressed = event.modifierFlags.contains(.function) && event.keyCode == 63
        if fnPressed && !wasFnPressed {
            AppLogger.shared.info("[HotKeyManager] Fn/Globe pressed - toggling agent mode")
            delegate?.conversationModePressed()
        }
        wasFnPressed = fnPressed
    }

    /// Handles modifier-alone tap detection for Read Aloud from any flagsChanged monitor.
    private func handleSpeakModifierEvent(_ event: NSEvent) {
        guard speakShortcut.isModifier, !speakModifierConflictsWithActivation else { return }

        // If a non-modifier key is pressed while speak key is held, it's a combo
        if isSpeakKeyHeld && event.type == .keyDown {
            speakKeyComboUsed = true
            return
        }

        if trackSpeakModifierTap(pressed: isSpeakModifierPressed(event: event)) {
            AppLogger.shared.info("[HotKeyManager] \(speakShortcut.displayName) tap - Read Aloud")
            delegate?.speakSelectedTextPressed()
        }
    }

    /// True when Dictate Key and Read Aloud share the same physical modifier.
    private var speakModifierConflictsWithActivation: Bool {
        switch speakShortcut {
        case .rightOption: return activationKey == .rightOption
        case .rightControl: return activationKey == .rightControl
        default: return false
        }
    }

    private func isSpeakModifierPressed(event: NSEvent) -> Bool {
        switch speakShortcut {
        case .rightOption:
            return event.modifierFlags.contains(.option) && event.keyCode == 61
        case .rightControl:
            return event.modifierFlags.contains(.control) && event.keyCode == 62
        default:
            return false
        }
    }

    private func isSpeakModifierPressed(cgEvent: CGEvent) -> Bool {
        let code = cgEvent.getIntegerValueField(.keyboardEventKeycode)
        switch speakShortcut {
        case .rightOption:
            return cgEvent.flags.contains(.maskAlternate) && code == 61
        case .rightControl:
            return cgEvent.flags.contains(.maskControl) && code == 62
        default:
            return false
        }
    }

    // MARK: - Shared Shortcut Detection (CGEvent tap paths + Right Option tap state machine)

    /// ESC keyDown — fires the universal stop on the delegate. Callers pass the event through.
    private func handleEscapeKeyDown() {
        AppLogger.shared.info("[HotKeyManager] ESC pressed - universal stop")
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.escapePressed()
        }
    }

    /// Matches the Speak Selected Text shortcut on a keyDown CGEvent and notifies the delegate.
    /// - Returns: `true` when matched, so the caller consumes the event.
    private func detectSpeakShortcut(keyCode: Int64, event: CGEvent) -> Bool {
        guard speakShortcut != .none && keyCode == speakShortcut.keyCode else { return false }
        let flags = event.flags
        let matched: Bool
        if speakShortcut.isControlCombo {
            matched = flags.contains(.maskControl) &&
                      !flags.contains(.maskCommand) && !flags.contains(.maskAlternate) && !flags.contains(.maskShift)
        } else {
            matched = flags.contains(.maskCommand) && flags.contains(.maskShift)
        }
        guard matched else { return false }
        AppLogger.shared.info("[HotKeyManager] Speak shortcut detected (\(speakShortcut.displayName))")
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.speakSelectedTextPressed()
        }
        return true
    }

    /// Matches the Agent Mode shortcut (Cmd+Shift+{key}) on a keyDown CGEvent, ignoring key repeats,
    /// and notifies the delegate.
    /// - Returns: `true` when matched, so the caller consumes the event.
    private func detectAgentShortcut(keyCode: Int64, event: CGEvent) -> Bool {
        guard agentShortcut != .none && !agentShortcut.isModifier && keyCode == agentShortcut.keyCode else { return false }
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        guard !isRepeat else { return false }
        let flags = event.flags
        guard flags.contains(.maskCommand) && flags.contains(.maskShift) else { return false }
        AppLogger.shared.info("[HotKeyManager] Agent shortcut detected (\(agentShortcut.displayName))")
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.conversationModePressed()
        }
        return true
    }

    /// Shared modifier-alone tap state machine for Read Aloud (press tracking, <0.4s tap, combo suppression).
    /// Reads/writes `isSpeakKeyHeld`, `speakKeyPressTime`, `speakKeyComboUsed`.
    /// - Returns: `true` when a tap fired; the caller logs, notifies the delegate, and decides
    ///   per-path whether to return early (event handling differs between CGEvent and NSEvent paths).
    private func trackSpeakModifierTap(pressed: Bool) -> Bool {
        guard speakShortcut.isModifier, !speakModifierConflictsWithActivation else { return false }
        if pressed && !isSpeakKeyHeld {
            isSpeakKeyHeld = true
            speakKeyPressTime = Date()
            speakKeyComboUsed = false
        } else if !pressed && isSpeakKeyHeld {
            let elapsed = Date().timeIntervalSince(speakKeyPressTime ?? Date())
            isSpeakKeyHeld = false
            speakKeyPressTime = nil
            if elapsed < 0.4 && !speakKeyComboUsed {
                return true
            }
            speakKeyComboUsed = false
        }
        return false
    }

    /// Fn key detection on a flagsChanged CGEvent — toggles agent mode on press (not release).
    /// Arrow keys (123-126) also set .maskSecondaryFn — check keyCode to disambiguate.
    /// Reads/writes `wasFnPressed`.
    private func handleFnFlagsChanged(event: CGEvent, pathLabel: String) {
        let fnPressed = event.flags.contains(.maskSecondaryFn) && event.getIntegerValueField(.keyboardEventKeycode) == 63
        if agentShortcut == .fn {
            if fnPressed && !wasFnPressed {
                AppLogger.shared.info("[HotKeyManager] Fn pressed - toggling agent mode (\(pathLabel))")
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.conversationModePressed()
                }
            }
            wasFnPressed = fnPressed
        }
    }

    // MARK: - Launcher Shortcut Tap

    /// Creates a dedicated CGEvent tap just for the launcher shortcut (Cmd+K / Cmd+Shift+Space / Cmd+P).
    /// Runs independently of the activation-key tap so it works even when the activation key is a
    /// modifier key (rightOption, rightCommand, fn, capsLock) whose monitor uses NSEvent instead of CGEventTap.
    private func setupLauncherShortcutTap() {
        guard launcherShortcut != .none else { return }

        let eventMask = (1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (_, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleLauncherShortcutEvent(type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            AppLogger.shared.warn("[HotKeyManager] Failed to create launcher shortcut tap - check accessibility permissions")
            return
        }

        launcherEventTap = tap
        launcherRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let source = launcherRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            AppLogger.shared.info("[HotKeyManager] Launcher shortcut tap enabled (\(launcherShortcut.displayName))")
        }
    }

    /// Matches the configured launcher shortcut against a keyDown event. Returns `nil` to consume
    /// the event when matched so the system does not beep and no other handler fires.
    private func handleLauncherShortcutEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout {
            if let tap = launcherEventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passRetained(event)
        }

        guard type == .keyDown else { return Unmanaged.passRetained(event) }
        guard launcherShortcut != .none else { return Unmanaged.passRetained(event) }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == launcherShortcut.keyCode else { return Unmanaged.passRetained(event) }

        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        guard !isRepeat else { return Unmanaged.passRetained(event) }

        let flags = event.flags
        let matched: Bool
        if launcherShortcut.requiresShift {
            matched = flags.contains(.maskCommand) && flags.contains(.maskShift) && !flags.contains(.maskAlternate)
        } else {
            matched = flags.contains(.maskCommand) && !flags.contains(.maskShift) && !flags.contains(.maskAlternate)
        }
        guard matched else { return Unmanaged.passRetained(event) }

        AppLogger.shared.info("[HotKeyManager] Launcher shortcut detected (\(launcherShortcut.displayName))")
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.launcherShortcutPressed()
        }
        return nil  // Consume the event so the key window does not beep
    }

    /// Removes all CGEvent taps, NSEvent monitors, and timers, resetting hold-to-talk state.
    func unregisterGlobalHotKeys() {
        // Invalidate all timers
        holdTimer?.invalidate()
        holdTimer = nil

        permissionPollTimer?.invalidate()
        permissionPollTimer = nil

        // Remove run loop source before invalidating tap
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }

        // Properly clean up CGEvent tap to prevent dangling pointer
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)  // Properly invalidate the mach port to prevent memory leak
            eventTap = nil
        }

        // Tear down the dedicated launcher shortcut tap
        if let source = launcherRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            launcherRunLoopSource = nil
        }
        if let tap = launcherEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            launcherEventTap = nil
        }

        // Remove event monitors
        if let monitor = modifierMonitor {
            NSEvent.removeMonitor(monitor)
            modifierMonitor = nil
        }

        if let monitor = modifierLocalMonitor {
            NSEvent.removeMonitor(monitor)
            modifierLocalMonitor = nil
        }

        if let monitor = fnLocalMonitor {
            NSEvent.removeMonitor(monitor)
            fnLocalMonitor = nil
        }

        if let monitor = fnGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            fnGlobalMonitor = nil
        }

        // Reset state
        isKeyHeld = false
        keyPressTime = nil
    }

    // MARK: - Activation Key Monitor
    private func setupActivationKeyMonitor() {
        if activationKey.isComboKey {
            setupComboKeyMonitor()
        } else if activationKey.isModifier {
            setupModifierMonitor()
        } else {
            setupRegularKeyMonitor()
        }
    }

    // MARK: - Combo Key Monitor (Option+Space)
    private func setupComboKeyMonitor() {
        // Create event tap for keyDown, keyUp, and flagsChanged (to detect Option release)
        let eventMask = (1 << CGEventType.keyDown.rawValue) |
                        (1 << CGEventType.keyUp.rawValue) |
                        (1 << CGEventType.flagsChanged.rawValue)

        // Store self reference for callback
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleComboKeyEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            AppLogger.shared.warn("[HotKeyManager] Failed to create event tap - check accessibility permissions")
            DispatchQueue.main.async { [weak self] in
                self?.accessibilityPermissionGranted = false
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.accessibilityPermissionGranted = true
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            AppLogger.shared.info("[HotKeyManager] Option+Space hold-to-talk enabled")
        }
    }

    /// Handles CGEvent callbacks for combo key mode (Option+Space).
    /// Processes ESC (universal stop), speak shortcut, agent shortcut, and the Option+Space hold-to-talk gesture.
    /// - Returns: `nil` to consume the event, or a passthrough `Unmanaged<CGEvent>` to let it propagate.
    private func handleComboKeyEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if macOS disabled it due to timeout
        if type == .tapDisabledByTimeout {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passRetained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let spaceKeyCode: Int64 = 49

        // ESC is stop only when Dottie is actively recording or playing audio
        if keyCode == escapeKeyCode && type == .keyDown {
            handleEscapeKeyDown()
            return Unmanaged.passRetained(event)
        }

        // Detect Speak Selected Text shortcut
        if type == .keyDown && detectSpeakShortcut(keyCode: keyCode, event: event) {
            return nil  // Consume the event
        }

        // Detect Agent Mode shortcut (Cmd+Shift+{key}) — ignore key repeats
        if type == .keyDown && detectAgentShortcut(keyCode: keyCode, event: event) {
            return nil  // Consume the event
        }

        // Any keyDown while Right Option is held means it's a combo (e.g. Option+Arrow), not a tap
        if type == .keyDown && isSpeakKeyHeld {
            speakKeyComboUsed = true
        }

        // Only handle Space key
        guard keyCode == spaceKeyCode else {
            return Unmanaged.passRetained(event)
        }

        let flags = event.flags
        let optionHeld = flags.contains(.maskAlternate)

        if type == .keyDown {
            // For keyDown, require Option to be held
            guard optionHeld else {
                return Unmanaged.passRetained(event)
            }

            // Ignore if other modifiers are pressed (allow Cmd+Option+Space, etc.)
            if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskShift) {
                return Unmanaged.passRetained(event)
            }

            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if isRepeat {
                // Suppress repeats when held for dictation
                return isKeyHeld ? nil : Unmanaged.passRetained(event)
            }

            if !isKeyHeld && keyPressTime == nil {
                keyPressTime = Date()
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.holdTimer?.invalidate()
                    self.holdTimer = Timer.scheduledTimer(withTimeInterval: self.holdThreshold, repeats: false) { [weak self] _ in
                        guard let self = self, self.keyPressTime != nil else { return }
                        self.isKeyHeld = true
                        AppLogger.shared.info("[HotKeyManager] Option+Space hold detected - starting dictation")
                        self.delegate?.clipboardListenKeyPressed()
                    }
                }
            }
            // Consume the event to prevent space from typing
            return nil

        } else if type == .keyUp {
            // For keyUp, always process if we were tracking a press (regardless of Option state)
            // This handles the case where user releases Option before Space
            guard keyPressTime != nil || isKeyHeld else {
                return Unmanaged.passRetained(event)
            }

            let wasHeld = isKeyHeld
            holdTimer?.invalidate()
            holdTimer = nil
            isKeyHeld = false
            keyPressTime = nil

            if wasHeld {
                AppLogger.shared.info("[HotKeyManager] Option+Space released - stopping dictation")
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.clipboardListenKeyReleased()
                }
            }
            // Consume the keyUp as well
            return nil

        } else if type == .flagsChanged {
            // Detect speak-modifier tap for Read Aloud (combo key path)
            if trackSpeakModifierTap(pressed: isSpeakModifierPressed(cgEvent: event)) {
                AppLogger.shared.info("[HotKeyManager] \(speakShortcut.displayName) tap - Read Aloud (combo)")
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.speakSelectedTextPressed()
                }
                return Unmanaged.passRetained(event)
            }

            // Detect Fn key for agent mode (toggle on press, not release)
            handleFnFlagsChanged(event: event, pathLabel: "CGEvent")

            // Detect when Option is released while we're in a push-to-type session
            let optionHeld = event.flags.contains(.maskAlternate)

            if !optionHeld && (keyPressTime != nil || isKeyHeld) {
                // Option was released while we were tracking a press
                let wasHeld = isKeyHeld
                holdTimer?.invalidate()
                holdTimer = nil
                isKeyHeld = false
                keyPressTime = nil

                if wasHeld {
                    AppLogger.shared.info("[HotKeyManager] Option released - stopping dictation")
                    DispatchQueue.main.async { [weak self] in
                        self?.delegate?.clipboardListenKeyReleased()
                    }
                }
            }
            // Pass through flags changed events
            return Unmanaged.passRetained(event)
        }

        return Unmanaged.passRetained(event)
    }

    // MARK: - Modifier Key Monitor (Right Option, Right Command, Fn, Caps Lock)
    private func setupModifierMonitor() {
        // Global monitor: receives flagsChanged/keyDown events delivered to OTHER apps.
        // By AppKit contract a global monitor NEVER sees events delivered to Dottie's own
        // process, so when Dottie itself is frontmost a modifier activation key would do
        // nothing without the local monitor below.
        modifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handleModifierMonitorEvent(event)
        }
        // Local monitor: covers the own-process case (Dottie frontmost). Must return the
        // event so it isn't swallowed and continues to the normal responder chain.
        modifierLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handleModifierMonitorEvent(event)
            return event
        }
        AppLogger.shared.info("[HotKeyManager] \(activationKey.displayName) hold-to-talk enabled (modifier)")
    }

    /// Shared handler for the modifier-key activation monitors (global + local).
    /// Detects the combo-suppression case, Fn agent toggle, Right Option Read-Aloud tap,
    /// and the activation-modifier hold-to-talk gesture.
    private func handleModifierMonitorEvent(_ event: NSEvent) {
        // Any keyDown while Right Option is held means it's a combo (e.g. Option+Arrow), not a tap
        if event.type == .keyDown && self.isSpeakKeyHeld {
            self.speakKeyComboUsed = true
            return
        }

        // Detect Fn for agent mode (only when activation key is NOT Fn to avoid conflict)
        // Track state to only trigger on press, not release
        // Must check keyCode == 63 — arrow keys (123-126) also carry .function modifier flag
        let fnPressed = event.modifierFlags.contains(.function) && event.keyCode == 63
        if self.agentShortcut == .fn && self.activationKey != .fn {
            if fnPressed && !self.wasFnPressed {
                AppLogger.shared.info("[HotKeyManager] Fn pressed - toggling agent mode (modifier monitor)")
                self.delegate?.conversationModePressed()
            }
            self.wasFnPressed = fnPressed
            if fnPressed { return }
        }

        // Detect speak-modifier tap for Read Aloud (only when it's not the activation key)
        // Quick tap (under 0.4s) triggers Read Aloud, but not if another key was pressed (combo)
        if self.trackSpeakModifierTap(pressed: self.isSpeakModifierPressed(event: event)) {
            AppLogger.shared.info("[HotKeyManager] \(self.speakShortcut.displayName) tap - Read Aloud")
            self.delegate?.speakSelectedTextPressed()
            return
        }

        let isPressed = self.isActivationModifierPressed(event: event)

        if isPressed && !self.isKeyHeld {
            // Key pressed — start dictation IMMEDIATELY, no hold threshold.
            // A bare modifier types nothing, so there's no typing conflict to
            // debounce (unlike the combo/character-key paths, which keep the
            // threshold). The old 100ms wait was dead time on every dictation
            // and clipped fast speakers' first syllable; an accidental tap now
            // just records ~0.1s of silence and is discarded without UI
            // (header-only-WAV guard + empty stream finalize).
            self.keyPressTime = Date()
            self.holdTimer?.invalidate()
            self.holdTimer = nil
            self.isKeyHeld = true
            AppLogger.shared.info("[HotKeyManager] \(self.activationKey.displayName) pressed - starting dictation")
            self.delegate?.clipboardListenKeyPressed()
        } else if !isPressed && self.keyPressTime != nil {
            // Key released
            let wasHeld = self.isKeyHeld

            self.holdTimer?.invalidate()
            self.holdTimer = nil
            self.isKeyHeld = false
            self.keyPressTime = nil

            if wasHeld {
                AppLogger.shared.info("[HotKeyManager] \(self.activationKey.displayName) released - stopping dictation")
                self.delegate?.clipboardListenKeyReleased()
            }
        }
    }

    /// Determines whether the activation modifier key is currently pressed based on the event's modifier flags and keycode.
    /// - Parameter event: The `NSEvent` flagsChanged event to inspect.
    /// - Returns: `true` if the configured activation modifier is pressed.
    private func isActivationModifierPressed(event: NSEvent) -> Bool {
        switch activationKey {
        case .rightOption:
            // Check if right option specifically (not left)
            return event.modifierFlags.contains(.option) &&
                   event.keyCode == 61
        case .rightCommand:
            // Check if right command specifically
            return event.modifierFlags.contains(.command) &&
                   event.keyCode == 54
        case .rightControl:
            // Check if right control specifically (not left)
            return event.modifierFlags.contains(.control) &&
                   event.keyCode == 62
        case .fn:
            // Arrow keys also carry .function modifier — must check keyCode == 63
            return event.modifierFlags.contains(.function) && event.keyCode == 63
        case .capsLock:
            return event.modifierFlags.contains(.capsLock)
        default:
            return false
        }
    }

    // MARK: - Regular Key Monitor (Spacebar, Tab)
    private func setupRegularKeyMonitor() {
        // Create event tap for keyDown, keyUp, and flagsChanged (for Fn agent shortcut)
        let eventMask = (1 << CGEventType.keyDown.rawValue) |
                        (1 << CGEventType.keyUp.rawValue) |
                        (1 << CGEventType.flagsChanged.rawValue)

        // Store self reference for callback
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleKeyEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            AppLogger.shared.warn("[HotKeyManager] Failed to create event tap - check accessibility permissions")
            DispatchQueue.main.async { [weak self] in
                self?.accessibilityPermissionGranted = false
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.accessibilityPermissionGranted = true
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            AppLogger.shared.info("[HotKeyManager] \(activationKey.displayName) hold-to-talk enabled")
        }
    }

    /// Handles CGEvent callbacks for regular key mode (Spacebar, Tab).
    /// Processes ESC (universal stop), speak shortcut, agent shortcut, and the hold-to-talk gesture on the configured key.
    /// - Returns: `nil` to consume the event, or a passthrough `Unmanaged<CGEvent>` to let it propagate.
    private func handleKeyEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if macOS disabled it due to timeout
        if type == .tapDisabledByTimeout {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passRetained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let targetKeyCode = activationKey.keyCode

        // ESC is stop only when Dottie is actively recording or playing audio
        if keyCode == escapeKeyCode && type == .keyDown {
            handleEscapeKeyDown()
            return Unmanaged.passRetained(event)
        }

        // Detect Speak Selected Text shortcut
        if type == .keyDown && detectSpeakShortcut(keyCode: keyCode, event: event) {
            return nil  // Consume the event
        }

        // Detect Agent Mode shortcut (Cmd+Shift+{key}) — ignore key repeats
        if type == .keyDown && detectAgentShortcut(keyCode: keyCode, event: event) {
            return nil  // Consume the event
        }

        // Only handle configured activation key
        guard keyCode == targetKeyCode else {
            return Unmanaged.passRetained(event)
        }

        // Ignore if any modifier is pressed (allow Cmd+Space, etc.)
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) ||
           flags.contains(.maskAlternate) || flags.contains(.maskShift) {
            return Unmanaged.passRetained(event)
        }

        if type == .keyDown {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if isRepeat {
                // Suppress repeats only when held for dictation
                return isKeyHeld ? nil : Unmanaged.passRetained(event)
            }

            if !isKeyHeld && keyPressTime == nil {
                keyPressTime = Date()
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.holdTimer?.invalidate()
                    self.holdTimer = Timer.scheduledTimer(withTimeInterval: self.holdThreshold, repeats: false) { [weak self] _ in
                        guard let self = self, self.keyPressTime != nil else { return }
                        self.isKeyHeld = true
                        AppLogger.shared.info("[HotKeyManager] Hold detected - starting dictation")
                        self.delegate?.clipboardListenKeyPressed()
                    }
                }
            }
            // Pass through keyDown - let character type normally
            return Unmanaged.passRetained(event)

        } else if type == .keyUp {
            let wasHeld = isKeyHeld
            holdTimer?.invalidate()
            holdTimer = nil
            isKeyHeld = false
            keyPressTime = nil

            if wasHeld {
                AppLogger.shared.info("[HotKeyManager] Released - stopping dictation")
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.clipboardListenKeyReleased()
                }
            }
            // Pass through keyUp
            return Unmanaged.passRetained(event)

        } else if type == .flagsChanged {
            // Detect speak-modifier tap for Read Aloud (regular key path)
            if trackSpeakModifierTap(pressed: isSpeakModifierPressed(cgEvent: event)) {
                AppLogger.shared.info("[HotKeyManager] \(speakShortcut.displayName) tap - Read Aloud (regular)")
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.speakSelectedTextPressed()
                }
                return Unmanaged.passRetained(event)
            }

            // Detect Fn key for agent mode (toggle on press, not release)
            handleFnFlagsChanged(event: event, pathLabel: "CGEvent fallback")
            return Unmanaged.passRetained(event)
        }

        return Unmanaged.passRetained(event)
    }
}

/// Delegate protocol for responding to global hotkey events detected by `HotKeyManager`.
protocol HotKeyManagerDelegate: AnyObject {
    /// Called when the push-to-type activation key is held past the threshold, starting clipboard dictation.
    func clipboardListenKeyPressed()
    /// Called when the push-to-type activation key is released, stopping clipboard dictation.
    func clipboardListenKeyReleased()
    /// Called when ESC is pressed while recording or playing audio, acting as a universal stop.
    func escapePressed()
    /// Called when the speak-selected-text shortcut is triggered, initiating TTS on the current selection.
    func speakSelectedTextPressed()
    /// Called when the conversation mode shortcut is triggered, toggling full-duplex voice.
    func conversationModePressed()
    /// Called when the launcher shortcut is triggered, toggling the Spotlight-style launcher.
    func launcherShortcutPressed()
}
