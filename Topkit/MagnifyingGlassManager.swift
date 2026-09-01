import Foundation
import AppKit

class MagnifyingGlassManager: ObservableObject {
    static let shared = MagnifyingGlassManager()
    
    private var magnifyingGlass: MagnifyingGlass?
    
    // Check if magnifying glass is currently active
    var isMagnifying: Bool {
        return magnifyingGlass != nil
    }
    
    // Callback for status bar icon update
    var onMagnifyingStateChanged: ((Bool) -> Void)?
    
    private init() {}
    
    func startMagnifyingGlass() {
        // If already active, stop it (toggle off)
        if let existing = magnifyingGlass {
            existing.cancelWithToast()
            // Don't set to nil here - let the completion handler do it
            return
        }
        
        // Use the LIVE check (not cached preflight, which stays true after a mid-session
        // revoke). If permission is actually gone, re-request instead of capturing garbage.
        PermissionManager.shared.verifyScreenRecordingPermission { [weak self] granted in
            if granted {
                self?.startGlass()
            } else {
                PermissionManager.shared.requestScreenRecordingAndWaitForGrant { [weak self] in
                    self?.startGlass()
                }
            }
        }
    }

    /// Tear down an active magnifier because screen recording permission was revoked.
    func cancelForPermissionLoss() {
        guard let existing = magnifyingGlass else { return }
        existing.cancelWithToast()
    }

    /// Used by `EscapeCascade` while a screen recording owns the global Esc hotkey.
    @discardableResult
    func consumeEscape() -> Bool {
        guard let existing = magnifyingGlass else { return false }
        existing.cancelWithToast()
        return true
    }

    private func startGlass() {
        // Guard against double-start
        if magnifyingGlass != nil { return }

        PermissionManager.shared.markScreenRecordingPermissionGranted()
        (NSApp.delegate as? AppDelegate)?.orderOutPreferencesWindowForToolOverlay()
        let glass = MagnifyingGlass()
        magnifyingGlass = glass
        EscapeCascade.push(.magnifier)
        onMagnifyingStateChanged?(true)
        glass.start {
            EscapeCascade.pop(.magnifier)
            self.magnifyingGlass = nil
            self.onMagnifyingStateChanged?(false)
        }
    }
}
