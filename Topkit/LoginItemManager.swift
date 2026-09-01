import Foundation
import ServiceManagement

/// Manages the app's registration as a macOS Login Item (launch at login) via SMAppService.
enum LoginItemManager {

    /// Whether the app is currently registered as a login item (actual system state).
    static var isRegistered: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    /// Registers the app as a login item so it launches at user login.
    /// No-op if already registered (avoids "Operation not permitted" when syncing UI).
    /// - Throws: Errors from SMAppService (e.g. authorization denied).
    static func register() throws {
        let status = SMAppService.mainApp.status
        if status == .enabled || status == .requiresApproval { return }
        try SMAppService.mainApp.register()
        UserDefaults.standard.set(true, forKey: "launchOnLogin")
    }

    /// Removes the app from login items.
    /// No-op if already not registered (avoids "Operation not permitted" when syncing UI).
    /// - Throws: Errors from SMAppService.
    static func unregister() throws {
        let status = SMAppService.mainApp.status
        if status == .notRegistered || status == .notFound { return }
        try SMAppService.mainApp.unregister()
        UserDefaults.standard.set(false, forKey: "launchOnLogin")
    }

    /// Applies the given preference: registers or unregisters the app as a login item.
    /// Syncs UserDefaults to match. On failure (e.g. user denies in System Settings), rethrows.
    static func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try register()
        } else {
            try unregister()
        }
    }
}
