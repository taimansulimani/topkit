import Foundation
import AppKit
import Combine

class ColorPickerManager: ObservableObject {
    static let shared = ColorPickerManager()
    
    @Published var pickedColor: NSColor?
    @Published var isPicking = false
    private var livePicker: LiveColorPicker?
    
    // Callback for status bar icon update
    var onPickerStateChanged: ((Bool) -> Void)?
    
    private init() {}
    
    func pickColor() {
        // If already active, cancel it (toggle off)
        if let existing = livePicker, existing.isActive {
            isPicking = false
            EscapeCascade.pop(.colorPicker)
            onPickerStateChanged?(false)
            existing.cancel()
            livePicker = nil
            return
        }
        
        // Use the LIVE check (not cached preflight, which stays true after a mid-session
        // revoke). If permission is actually gone, re-request instead of capturing garbage.
        PermissionManager.shared.verifyScreenRecordingPermission { [weak self] granted in
            if granted {
                self?.startPicker()
            } else {
                PermissionManager.shared.requestScreenRecordingAndWaitForGrant { [weak self] in
                    self?.startPicker()
                }
            }
        }
    }
    
    /// Tear down an active picker because screen recording permission was revoked.
    func cancelForPermissionLoss() {
        guard let existing = livePicker else { return }
        existing.cancel()
        livePicker = nil
        isPicking = false
        EscapeCascade.pop(.colorPicker)
        onPickerStateChanged?(false)
    }

    /// Used by `EscapeCascade` while a screen recording owns the global Esc hotkey.
    @discardableResult
    func consumeEscape() -> Bool {
        guard let existing = livePicker, existing.isActive else { return false }
        existing.cancel()
        livePicker = nil
        isPicking = false
        EscapeCascade.pop(.colorPicker)
        onPickerStateChanged?(false)
        return true
    }

    private func startPicker() {
        // Guard against double-start (e.g., user clicked again while waiting for permission)
        if let existing = livePicker, existing.isActive { return }

        PermissionManager.shared.markScreenRecordingPermissionGranted()
        (NSApp.delegate as? AppDelegate)?.orderOutPreferencesWindowForToolOverlay()
        let picker = LiveColorPicker()
        livePicker = picker
        isPicking = true
        EscapeCascade.push(.colorPicker)
        onPickerStateChanged?(true)
        picker.start(
            onColorPicked: { [weak self] color in
                self?.pickedColor = color
                self?.copyHexToClipboard(color)
            },
            completion: { [weak self] color in
                self?.isPicking = false
                EscapeCascade.pop(.colorPicker)
                self?.onPickerStateChanged?(false)
                self?.livePicker = nil
                guard let color else { return }
                self?.pickedColor = color
                self?.copyHexToClipboard(color)
            }
        )
    }

    private func copyHexToClipboard(_ color: NSColor) {
        let hex = colorToHex(color)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hex, forType: .string)
    }

    private func colorToHex(_ color: NSColor) -> String {
        HexColorConverter.colorToHex(color)
    }
}
