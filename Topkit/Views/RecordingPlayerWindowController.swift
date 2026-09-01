import AppKit
import AVKit
import AVFoundation

/// Player + trimmer for recordings Topkit just made. Not a general video
/// player: it only ever opens files produced by ScreenRecordingManager.
/// Trim uses AVPlayerView's built-in QuickTime trim UI; committing a trim
/// passthrough-exports the kept range and atomically overwrites the file.
final class RecordingPlayerWindowController: NSWindowController, NSWindowDelegate {

    private var fileURL: URL
    private let playerView = AVPlayerView()
    private var trimButton: NSButton?
    private var renameButton: NSButton?
    private var keyMonitor: Any?
    private var onClose: (() -> Void)?

    init(fileURL: URL, onClose: (() -> Void)? = nil) {
        self.fileURL = fileURL
        self.onClose = onClose

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = fileURL.lastPathComponent
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: 480, height: 300)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        playerView.controlsStyle = .floating // QuickTime-style floating controls
        playerView.showsFullScreenToggleButton = true
        playerView.player = AVPlayer(url: fileURL)
        window.contentView = playerView

        // Rename + Trim buttons in the titlebar. Trim mirrors QuickTime's
        // Edit > Trim (⌘T); Rename (⌘R) renames the file on disk in place.
        let accessory = NSTitlebarAccessoryViewController()

        let rename = NSButton(title: String(localized: "Rename"), target: self, action: #selector(renameTapped))
        rename.bezelStyle = .toolbar
        if let pencil = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Rename") {
            rename.image = pencil
            rename.imagePosition = .imageLeading
        }

        let trim = NSButton(title: String(localized: "Trim"), target: self, action: #selector(trimTapped))
        trim.bezelStyle = .toolbar
        if let scissors = NSImage(systemSymbolName: "scissors", accessibilityDescription: "Trim") {
            trim.image = scissors
            trim.imagePosition = .imageLeading
        }

        let renameWidth = rename.fittingSize.width + 8
        let trimWidth = trim.fittingSize.width + 8
        let gap: CGFloat = 8
        let container = NSView(frame: NSRect(x: 0, y: 0, width: renameWidth + gap + trimWidth + 16, height: 28))
        rename.frame = NSRect(x: 0, y: 3, width: renameWidth, height: 22)
        trim.frame = NSRect(x: renameWidth + gap, y: 3, width: trimWidth, height: 22)
        container.addSubview(rename)
        container.addSubview(trim)
        accessory.view = container
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)
        trimButton = trim
        renameButton = rename

        // ⌘T (trim) / ⌘W (close) while this window is key — an accessory app
        // has no main menu, so the standard Close equivalent must be manual,
        // same as the preferences window.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true,
                  event.modifierFlags.contains(.command) else { return event }
            switch event.charactersIgnoringModifiers {
            case "t":
                self.trimTapped()
                return nil
            case "r":
                self.renameTapped()
                return nil
            case "w":
                self.window?.performClose(nil)
                return nil
            default:
                return event
            }
        }

        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Trim

    @objc private func trimTapped() {
        guard playerView.canBeginTrimming else { return }
        trimButton?.isEnabled = false
        playerView.beginTrimming { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                guard result == .okButton,
                      let item = self.playerView.player?.currentItem,
                      let range = TrimRange.resolve(
                        start: item.reversePlaybackEndTime,
                        end: item.forwardPlaybackEndTime,
                        duration: item.duration
                      ) else {
                    self.resetTrimState()
                    return
                }
                self.exportTrimmed(range: range)
            }
        }
    }

    /// Clear trim bounds AVPlayerView left on the item so playback covers the
    /// whole (current) file again.
    private func resetTrimState() {
        trimButton?.isEnabled = true
        if let item = playerView.player?.currentItem {
            item.reversePlaybackEndTime = .invalid
            item.forwardPlaybackEndTime = .invalid
        }
    }

    private func exportTrimmed(range: CMTimeRange) {
        trimButton?.title = String(localized: "Trimming…")
        let asset = AVURLAsset(url: fileURL)
        // Passthrough = no re-encode, QuickTime-style instant trim. Falls back
        // to a re-encoding preset if passthrough is unavailable for the asset.
        let preset = AVAssetExportSession.exportPresets(compatibleWith: asset).contains(AVAssetExportPresetPassthrough)
            ? AVAssetExportPresetPassthrough
            : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            finishTrim(success: false)
            return
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Trim_\(UUID().uuidString).mov")
        session.outputURL = tempURL
        session.outputFileType = .mov
        session.timeRange = range
        session.exportAsynchronously { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                guard session.status == .completed else {
                    debugLog("❌ Trim export failed: \(session.error?.localizedDescription ?? "unknown")")
                    try? FileManager.default.removeItem(at: tempURL)
                    self.finishTrim(success: false)
                    return
                }
                // Overwrite the original — one file, same name, trimmed.
                self.playerView.player?.replaceCurrentItem(with: nil)
                if RecordingDestination.replaceRecording(at: self.fileURL, with: tempURL) != nil {
                    self.playerView.player = AVPlayer(url: self.fileURL)
                    self.finishTrim(success: true)
                } else {
                    try? FileManager.default.removeItem(at: tempURL)
                    self.playerView.player = AVPlayer(url: self.fileURL)
                    self.finishTrim(success: false)
                }
            }
        }
    }

    private func finishTrim(success: Bool) {
        trimButton?.title = String(localized: "Trim")
        resetTrimState()
        ToastPresenter.shared.show(
            message: success ? String(localized: "Recording trimmed") : String(localized: "Trim failed"),
            force: !success
        )
    }

    // MARK: - Rename

    @objc private func renameTapped() {
        guard let window else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = fileURL.deletingPathExtension().lastPathComponent
        field.placeholderString = String(localized: "Recording name")

        let alert = NSAlert()
        alert.messageText = String(localized: "Rename Recording")
        alert.informativeText = String(localized: "Enter a new name. The file is renamed on disk.")
        alert.addButton(withTitle: String(localized: "Rename"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.performRename(to: field.stringValue)
        }
    }

    private func performRename(to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Blank, or unchanged: nothing to do.
        guard !trimmed.isEmpty, trimmed != fileURL.deletingPathExtension().lastPathComponent else { return }

        // Detach the player before moving the file, mirroring trim, then reload
        // from the new URL at the same spot.
        let wasPlaying = (playerView.player?.rate ?? 0) > 0
        let resumeTime = playerView.player?.currentTime()
        playerView.player?.pause()
        playerView.player?.replaceCurrentItem(with: nil)

        guard let newURL = RecordingDestination.renameRecording(at: fileURL, to: trimmed) else {
            playerView.player = AVPlayer(url: fileURL)
            ToastPresenter.shared.show(message: String(localized: "Rename failed"), force: true)
            return
        }

        fileURL = newURL
        let player = AVPlayer(url: newURL)
        playerView.player = player
        if let resumeTime { player.seek(to: resumeTime) }
        if wasPlaying { player.play() }
        window?.title = newURL.lastPathComponent
        ToastPresenter.shared.show(message: String(localized: "Recording renamed"))
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        playerView.player?.pause()
        playerView.player = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        onClose?()
    }
}
