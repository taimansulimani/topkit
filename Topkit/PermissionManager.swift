import Foundation
import AppKit
import AVFoundation
import CoreGraphics
import ScreenCaptureKit
import Speech

/// Centralized permission management for Topkit.
///
/// Tools that need screen recording: Pick Color, Magnify, Screenshot.
/// Guides and global shortcuts no longer need Accessibility: guides handle input via the
/// overlay window, and shortcuts use Carbon hotkeys (see HotKeyManager).
final class PermissionManager {
    static let shared = PermissionManager()
    private init() {}

    private func log(_ message: String) {
        debugLog(message)
    }

    // MARK: - Screen Recording Permission

    /// Screen recording permission check without prompting.
    func hasScreenRecordingPermission() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }

    /// Live permission check that bypasses cached preflight state.
    /// Completion is always called on the main thread.
    ///
    /// Note: On macOS 12.3+ this uses `SCShareableContent.getExcludingDesktopWindows`, which can
    /// produce a brief full-screen compositor flicker. For screenshot hot paths where
    /// `hasScreenRecordingPermission()` is already true, skip this and capture directly.
    func verifyScreenRecordingPermission(completion: @escaping (Bool) -> Void) {
        guard CGPreflightScreenCaptureAccess() else {
            DispatchQueue.main.async { completion(false) }
            return
        }

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            DispatchQueue.main.async {
                completion(error == nil && content != nil)
            }
        }
    }

    /// Show the native macOS screen recording permission dialog and poll until
    /// permission is granted (or timeout). Calls `onGranted` on the main thread.
    ///
    /// If the user clicks "Allow" in the native dialog, the poll detects it and
    /// fires `onGranted`. If the user goes to System Settings instead, the poll
    /// also checks when the app becomes active again.
    func requestScreenRecordingAndWaitForGrant(onGranted: @escaping () -> Void) {
        // Use live check to avoid stale cached preflight state.
        verifyScreenRecordingPermission { [weak self] hasPermission in
            if hasPermission {
                onGranted()
                return
            }

            self?.log("🔑 Requesting screen recording permission")
            // Become a regular foreground app first so the system TCC dialog appears in
            // front and focused — accessory (menu-bar) apps otherwise get it behind.
            self?.bringAppToForegroundForPrompt()
            // Show ONLY the native TCC dialog. Its own "Open System Settings" button hands
            // off to the pane; opening System Settings ourselves stacked a second window on
            // top of the dialog. On a mid-session revoke the OS won't re-show the dialog and
            // nothing appears — accepted in exchange for the clean single-dialog flow.
            _ = CGRequestScreenCaptureAccess()

            var pollTimer: Timer?
            var activationObserver: NSObjectProtocol?
            var timedOut = false

            let cleanup: () -> Void = { [weak self] in
                pollTimer?.invalidate()
                pollTimer = nil
                if let obs = activationObserver {
                    NotificationCenter.default.removeObserver(obs)
                    activationObserver = nil
                }
                self?.restoreActivationPolicyAfterPrompt()
            }

            let check: () -> Void = { [weak self] in
                guard !timedOut, let self = self else { return }
                self.verifyScreenRecordingPermission { hasPermission in
                    guard hasPermission else { return }
                    // Only continue once the user returns to Topkit.
                    guard NSApp.isActive else { return }
                    self.log("🔑 Screen recording permission granted!")
                    cleanup()
                    onGranted()
                }
            }

            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in check() }

            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { check() }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
                timedOut = true
                cleanup()
            }
        }
    }

    // MARK: - Microphone + Speech Recognition (recording subtitles / audio)

    /// Ensure mic access for recording extras. Prompts on first ask (bringing
    /// the app foreground so the TCC dialog isn't lost behind overlays); a
    /// prior denial completes false without any UI. Completion on main.
    func ensureMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            DispatchQueue.main.async { completion(true) }
        case .notDetermined:
            bringAppToForegroundForPrompt()
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.restoreActivationPolicyAfterPrompt()
                    completion(granted)
                }
            }
        default:
            DispatchQueue.main.async { completion(false) }
        }
    }

    /// Speech Recognition TCC grant — only needed by the legacy
    /// SFSpeechRecognizer caption path (macOS 14/15); the macOS 26
    /// SpeechAnalyzer stack is on-device and mic-only. Completion on main.
    func ensureSpeechRecognitionAccess(completion: @escaping (Bool) -> Void) {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            DispatchQueue.main.async { completion(true) }
        case .notDetermined:
            bringAppToForegroundForPrompt()
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    self?.restoreActivationPolicyAfterPrompt()
                    completion(status == .authorized)
                }
            }
        default:
            DispatchQueue.main.async { completion(false) }
        }
    }

    /// Activation policy captured before a prompt forced us to `.regular`, so we can revert.
    private var activationPolicyBeforePrompt: NSApplication.ActivationPolicy?

    /// Make the app a regular foreground app and activate it so a system permission dialog
    /// is presented in front and focused. No-op if we're already regular.
    private func bringAppToForegroundForPrompt() {
        if NSApp.activationPolicy() != .regular {
            activationPolicyBeforePrompt = NSApp.activationPolicy()
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Revert the activation policy changed by `bringAppToForegroundForPrompt`.
    private func restoreActivationPolicyAfterPrompt() {
        guard let prior = activationPolicyBeforePrompt else { return }
        activationPolicyBeforePrompt = nil
        NSApp.setActivationPolicy(prior)
    }

#if ALLOW_AUTOPASTE
    // MARK: - Post Event (Accessibility) Permission — auto-paste only

    /// UserDefaults flag: have we ever asked the OS for PostEvent access? Once the user has made
    /// a decision (granted or denied), `CGRequestPostEventAccess()` will NOT re-show the system
    /// dialog — so on a re-toggle after that, we deep-link to System Settings instead.
    private static let postEventEverRequestedKey = "postEventEverRequested"

    /// In-process preflight. RELIABLE ONLY AS A POSITIVE: a `true` means access is granted, but a
    /// `false` is frequently stale (it sticks for the rest of the session after a grant, and can
    /// stay `true` after a revoke). For an accurate live read use `probePostEventAccessLive`.
    func hasPostEventAccess() -> Bool {
        CGPreflightPostEventAccess()
    }

    /// Accurate LIVE check of PostEvent access by sublaunching the embedded `postevent-probe`
    /// helper tool (Contents/MacOS/postevent-probe). A fresh process reads the current TCC state
    /// instead of the long-running app's stale in-process cache. The helper is signed with exactly
    /// `com.apple.security.app-sandbox` + `com.apple.security.inherit`, so it inherits the app's
    /// sandbox — Apple's documented, App-Store-approved way to embed a command-line tool in a
    /// sandboxed app (it therefore cannot be run from Terminal, only sublaunched by us).
    ///
    /// Completion is always called on the main thread. Cheap (~tens of ms), runs off the main
    /// thread; safe to call on a timer and on app activation.
    func probePostEventAccessLive(completion: @escaping (Bool) -> Void) {
        // Fast path: an in-process `true` is trustworthy (only `false` is unreliable), so we can
        // skip the spawn when we already know we're granted.
        if CGPreflightPostEventAccess() {
            DispatchQueue.main.async { completion(true) }
            return
        }
        guard let helperURL = Bundle.main.url(forAuxiliaryExecutable: "postevent-probe") else {
            // Helper missing (shouldn't happen in a shipped build) — fall back to the (less
            // reliable) in-process read rather than spawning the main app binary, which would
            // trap under the sandbox.
            DispatchQueue.main.async { completion(CGPreflightPostEventAccess()) }
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let proc = Process()
            proc.executableURL = helperURL
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            var granted = false
            do {
                try proc.run()
                proc.waitUntilExit()
                granted = (proc.terminationStatus == 0)
            } catch {
                granted = CGPreflightPostEventAccess()
            }
            DispatchQueue.main.async { completion(granted) }
        }
    }

    /// Request PostEvent (Accessibility) access for auto-paste, called when the user turns the
    /// toggle on. Uses a LIVE probe to decide what to do, so it behaves correctly even when the
    /// in-process preflight cache is stale:
    ///   - already granted  → no-op (the banner monitor will show green);
    ///   - first ask ever    → show the native TCC dialog (its own button hands off to Settings);
    ///   - decided before    → the OS won't re-show the dialog, so deep-link to the Accessibility
    ///                          pane in System Settings.
    /// Never flips the toggle off itself — the banner monitor owns revoke detection.
    func requestPostEventAccess() {
        probePostEventAccessLive { [weak self] granted in
            guard let self = self, !granted else { return }

            let everRequested = UserDefaults.standard.bool(forKey: Self.postEventEverRequestedKey)
            self.log("🔑 Requesting PostEvent (Accessibility) permission (everRequested=\(everRequested))")
            self.bringAppToForegroundForPrompt()

            if !everRequested {
                UserDefaults.standard.set(true, forKey: Self.postEventEverRequestedKey)
                // First ask: this shows the native dialog when the decision is still undetermined.
                // Don't also open System Settings — that stacks a second window on the dialog.
                if CGRequestPostEventAccess() {
                    self.restoreActivationPolicyAfterPrompt()
                    return
                }
            } else {
                // A decision already exists (typically a prior grant that was later revoked), so
                // the OS won't re-show its dialog. Send the user straight to the right pane.
                self.openAccessibilitySettings()
            }

            // Restore the menu-bar activation policy once the dialog / Settings has been presented.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.restoreActivationPolicyAfterPrompt()
            }
        }
    }

    /// Open System Settings directly at Privacy & Security ▸ Accessibility (where the PostEvent
    /// privilege is surfaced).
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
#endif

    // MARK: - Background Permission Monitors

    private let screenRecordingMonitorQueue = DispatchQueue(
        label: "com.topkit.screen-recording-monitor",
        qos: .utility
    )

    private var screenRecordingMonitorSource: DispatchSourceTimer?
    private var screenRecordingMonitorHadPermission = false

    /// Called on the main thread when screen recording is revoked while the app is running.
    /// Set by AppDelegate to tear down any active capture UI and warn the user — replaces a hard exit.
    var onScreenRecordingRevoked: (() -> Void)?

    /// Call when we have actually used screen recording (e.g. started color picker).
    /// Ensures we will exit if permission is later revoked.
    func markScreenRecordingPermissionGranted() {
        screenRecordingMonitorQueue.async { [weak self] in
            self?.screenRecordingMonitorHadPermission = true
        }
    }

    /// Start background polling for screen recording permission revocation.
    func startScreenRecordingPermissionMonitor() {
        guard screenRecordingMonitorSource == nil else { return }

        log("🔑 Starting background screen recording permission monitor")

        // 2s is responsive enough for revoke detection; a 10Hz tick at high QoS for the
        // app's whole lifetime shows up in energy diagnostics for no benefit.
        let source = DispatchSource.makeTimerSource(queue: screenRecordingMonitorQueue)
        source.schedule(deadline: .now() + 2.0, repeating: 2.0)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard self.screenRecordingMonitorHadPermission else { return }
            if !CGPreflightScreenCaptureAccess() {
                // Disarm so we fire exactly once per revocation; re-arms when a tool is next used
                // (each tool calls markScreenRecordingPermissionGranted on start).
                self.screenRecordingMonitorHadPermission = false
                DispatchQueue.main.async { [weak self] in
                    self?.onScreenRecordingRevoked?()
                }
            }
        }
        source.resume()
        screenRecordingMonitorSource = source
    }

    func stopScreenRecordingPermissionMonitor() {
        screenRecordingMonitorSource?.cancel()
        screenRecordingMonitorSource = nil
        screenRecordingMonitorHadPermission = false
    }
}
