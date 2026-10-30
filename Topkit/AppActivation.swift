import AppKit

/// Brings Topkit to the front before it shows something that needs the user's focus: a system
/// permission prompt (TCC) or one of Topkit's own permission panels.
///
/// `NSApp.activate` only *requests* activation — the app becomes active on a later run-loop turn
/// (and switching an accessory app to `.regular` is asynchronous too). Presenting in the same turn
/// opens the prompt while the previously frontmost app still owns focus, so it appears unfocused
/// (Return does nothing, the window is not key). Waiting for `didBecomeActive` fixes that.
enum AppActivation {
    /// Upper bound on the wait, so the prompt is always shown even if the system declines to
    /// activate Topkit (macOS 14+ cooperative activation can refuse without user intent).
    static let defaultTimeout: TimeInterval = 0.75

    /// Activate Topkit, then run `present` on the main thread once Topkit is the active app
    /// (immediately if it already is), or after `timeout` at the latest.
    static func activateThen(timeout: TimeInterval = defaultTimeout, _ present: @escaping () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        ActivationWait.start(
            isActive: { NSApp.isActive },
            notificationCenter: .default,
            timeout: timeout,
            schedule: { delay, work in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            },
            body: present
        )
    }
}

/// Runs `body` exactly once: immediately when the app is already active, otherwise on the first
/// `NSApplication.didBecomeActiveNotification` or when `timeout` passes, whichever comes first.
/// Dependencies are injected so the ordering logic is unit-testable without a running app.
final class ActivationWait {
    private let notificationCenter: NotificationCenter
    private var observer: NSObjectProtocol?
    private var body: (() -> Void)?

    private init(notificationCenter: NotificationCenter, body: @escaping () -> Void) {
        self.notificationCenter = notificationCenter
        self.body = body
    }

    @discardableResult
    static func start(
        isActive: () -> Bool,
        notificationCenter: NotificationCenter,
        timeout: TimeInterval,
        schedule: (TimeInterval, @escaping () -> Void) -> Void,
        body: @escaping () -> Void
    ) -> ActivationWait? {
        if isActive() {
            body()
            return nil
        }
        let wait = ActivationWait(notificationCenter: notificationCenter, body: body)
        // queue nil: run on the posting thread (AppKit posts this on main), so the body runs
        // in the same turn the app becomes active.
        wait.observer = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { _ in wait.fire() }
        schedule(timeout) { wait.fire() }
        return wait
    }

    private func fire() {
        if let observer {
            notificationCenter.removeObserver(observer)
            self.observer = nil
        }
        guard let body else { return }
        self.body = nil
        body()
    }
}
